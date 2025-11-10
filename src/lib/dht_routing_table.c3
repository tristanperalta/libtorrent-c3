module libtorrent::dht_routing_table;

import std::io;
import std::time;
import std::core::mem::allocator;
import libtorrent::common;
import libtorrent::dht_security;

/**
 * DHT Routing Table Implementation (BEP 5)
 * ========================================
 * Implements Kademlia routing table with k-buckets for DHT node management.
 * Based on libtorrent's routing_table implementation.
 *
 * Key concepts:
 * - 160 buckets (one for each bit in 160-bit node ID space)
 * - Each bucket holds up to 8 nodes (k = 8)
 * - Nodes sorted by quality (verified + low RTT preferred)
 * - Replacement cache for when buckets are full
 * - XOR distance metric for node proximity
 */

// ============================================================================
// Constants
// ============================================================================

const int BUCKET_SIZE = 8;       // Kademlia k parameter
const int NUM_BUCKETS = 160;     // 160-bit node ID space
const char MAX_TIMEOUT_COUNT = 3; // Max failures before removal

// ============================================================================
// Fault Definitions
// ============================================================================

faultdef DHT_BUCKET_FULL;        // Bucket is full and no replacement possible
faultdef DHT_INVALID_NODE;       // Invalid node data

// ============================================================================
// Data Structures
// ============================================================================

/**
 * Node entry in routing table
 */
struct NodeEntry {
    common::NodeId id;           // 20-byte Kademlia ID
    common::SocketAddress addr;  // IPv4/IPv6 address and port
    long last_queried;           // Unix timestamp of last query
    ushort rtt_ms;               // Round-trip time in milliseconds
    char timeout_count;          // Number of consecutive failures (255 = never queried)
    bool verified;               // Node ID verified (BEP 42)
}

/**
 * K-bucket holding nodes at a specific distance
 */
struct KBucket {
    NodeEntry[BUCKET_SIZE] live_nodes;
    NodeEntry[BUCKET_SIZE] replacements;
    char live_count;
    char replacement_count;
}

/**
 * Routing table with 160 k-buckets
 */
struct RoutingTable {
    KBucket[NUM_BUCKETS] buckets;
    common::NodeId our_id;
    int num_active_buckets;      // Number of buckets with at least one node
    bool enforce_bep42;          // Enable BEP 42 node ID verification (default: true)
}

// ============================================================================
// Utility Functions
// ============================================================================

/**
 * Calculate XOR distance between two node IDs and return the position
 * of the first differing bit (counting from MSB).
 *
 * This gives us the "distance exponent" - the bucket number where this
 * node should be placed.
 *
 * @param a First node ID
 * @param b Second node ID
 * @return Bit position (0-159) or 160 if IDs are identical
 */
fn int distance_exp(common::NodeId a, common::NodeId b)
{
    // XOR the two IDs and find the position of the first 1 bit
    for (int byte_idx = 0; byte_idx < 20; byte_idx++)
    {
        char xor_byte = a[byte_idx] ^ b[byte_idx];
        if (xor_byte != 0)
        {
            // Find the position of the first 1 bit in this byte
            for (int bit_idx = 7; bit_idx >= 0; bit_idx--)
            {
                if ((xor_byte & (1 << bit_idx)) != 0)
                {
                    return byte_idx * 8 + (7 - bit_idx);
                }
            }
        }
    }
    return 160;  // IDs are identical
}

/**
 * Get the bucket index for a given node ID
 *
 * @param id Node ID to find bucket for
 * @return Bucket index (0-159)
 */
fn int RoutingTable.bucket_index(&self, common::NodeId id)
{
    int dist = distance_exp(self.our_id, id);
    if (dist >= 160) return 159;  // Our own ID goes in last bucket
    return 159 - dist;  // Invert so closest nodes are in higher buckets
}

/**
 * Compare two node entries for quality sorting
 * Better nodes (verified + lower RTT) are considered "less than"
 *
 * @param a First node
 * @param b Second node
 * @return true if a is better than b
 */
fn bool node_is_better(NodeEntry* a, NodeEntry* b)
{
    // Verified nodes are always better
    if (a.verified != b.verified) return a.verified;

    // Lower RTT is better
    return a.rtt_ms < b.rtt_ms;
}

/**
 * Find a node in a bucket by ID
 *
 * @param bucket Bucket to search
 * @param id Node ID to find
 * @return Index in live_nodes array, or -1 if not found
 */
fn int find_node_in_bucket(KBucket* bucket, common::NodeId id)
{
    for (int i = 0; i < bucket.live_count; i++)
    {
        bool match = true;
        for (int j = 0; j < 20; j++)
        {
            if (bucket.live_nodes[i].id[j] != id[j])
            {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return -1;
}

// ============================================================================
// Routing Table Management
// ============================================================================

/**
 * Create a new routing table
 *
 * @param our_id Our node ID (20 random bytes)
 * @param allocator Allocator to use for RoutingTable allocation (typically arena)
 * @param enforce_bep42 Enable BEP 42 node ID verification (default: true)
 * @return Initialized routing table (allocated from allocator, caller manages lifetime)
 */
fn RoutingTable* create_routing_table(common::NodeId our_id, Allocator allocator,
                                      bool enforce_bep42 = true) @public
{
    RoutingTable* table = allocator::new(allocator, RoutingTable);

    // Copy our ID
    for (int i = 0; i < 20; i++)
    {
        table.our_id[i] = our_id[i];
    }

    // Initialize all buckets
    for (int i = 0; i < NUM_BUCKETS; i++)
    {
        table.buckets[i].live_count = 0;
        table.buckets[i].replacement_count = 0;
    }

    table.num_active_buckets = 0;
    table.enforce_bep42 = enforce_bep42;

    return table;
}

/**
 * Free a routing table
 *
 * NOTE: When allocated from arena (as in DhtClient), do not call this.
 * The arena cleanup will handle it. This method is for tests and other
 * code that allocates from heap.
 *
 * @param table Routing table to free
 */
fn void RoutingTable.free(&self) @public
{
    free(self);
}

/**
 * Add or update a node in the routing table
 * Called when we receive a valid response from a node
 *
 * @param table Routing table
 * @param id Node ID
 * @param addr Socket address (IPv4 or IPv6)
 * @param rtt_ms Round-trip time in milliseconds
 * @return true if node was added/updated successfully
 */
fn bool RoutingTable.add_node(&self, common::NodeId id, common::SocketAddress addr,
                              ushort rtt_ms) @public
{
    // Don't add ourselves
    bool is_our_id = true;
    for (int i = 0; i < 20; i++)
    {
        if (id[i] != self.our_id[i])
        {
            is_our_id = false;
            break;
        }
    }
    if (is_our_id) return false;

    // BEP 42: Verify node ID (if enforcement enabled)
    bool verified = false;
    if (self.enforce_bep42)
    {
        // Verify node ID for both IPv4 and IPv6
        verified = dht_security::verify_node_id_for_address(id, addr);
        // Note: We mark as verified/unverified but still add the node
        // Verified nodes are preferred during quality comparisons
    }
    else
    {
        // BEP 42 disabled - mark all nodes as verified
        verified = true;
    }

    // Find the appropriate bucket
    int bucket_idx = self.bucket_index(id);
    KBucket* bucket = &self.buckets[bucket_idx];

    // Check if node already exists
    int existing_idx = find_node_in_bucket(bucket, id);
    if (existing_idx >= 0)
    {
        // Update existing node
        NodeEntry* node = &bucket.live_nodes[existing_idx];
        node.addr = addr;
        node.last_queried = (long)time::now().to_seconds();
        node.rtt_ms = rtt_ms;
        node.timeout_count = 0;  // Reset failures
        node.verified = verified;  // Update verification status
        return true;
    }

    // Try to add new node
    if (bucket.live_count < BUCKET_SIZE)
    {
        // Bucket has space
        NodeEntry* node = &bucket.live_nodes[bucket.live_count];
        for (int i = 0; i < 20; i++) node.id[i] = id[i];
        node.addr = addr;
        node.last_queried = (long)time::now().to_seconds();
        node.rtt_ms = rtt_ms;
        node.timeout_count = 0;
        node.verified = verified;

        bucket.live_count++;

        // Update active bucket count if this bucket was empty
        if (bucket.live_count == 1) self.num_active_buckets++;

        return true;
    }

    // Bucket is full - try to replace worst node
    return try_replace_node(bucket, id, addr, rtt_ms, verified);
}

/**
 * Try to replace the worst node in a full bucket
 *
 * @param bucket Full bucket
 * @param new_id New node ID
 * @param new_addr New socket address
 * @param new_rtt New RTT
 * @param verified BEP 42 verification status
 * @return true if replacement succeeded
 */
fn bool try_replace_node(KBucket* bucket, common::NodeId new_id, common::SocketAddress new_addr,
                         ushort new_rtt, bool verified)
{
    // Find the node with highest timeout_count
    int worst_idx = -1;
    char max_timeouts = 0;

    for (int i = 0; i < bucket.live_count; i++)
    {
        if (bucket.live_nodes[i].timeout_count > max_timeouts)
        {
            max_timeouts = bucket.live_nodes[i].timeout_count;
            worst_idx = i;
        }
    }

    // Only replace if we found a failed node
    if (worst_idx >= 0 && max_timeouts >= MAX_TIMEOUT_COUNT)
    {
        NodeEntry* node = &bucket.live_nodes[worst_idx];
        for (int i = 0; i < 20; i++) node.id[i] = new_id[i];
        node.addr = new_addr;
        node.last_queried = (long)time::now().to_seconds();
        node.rtt_ms = new_rtt;
        node.timeout_count = 0;
        node.verified = verified;
        return true;
    }

    // Could not replace - add to replacement cache
    if (bucket.replacement_count < BUCKET_SIZE)
    {
        NodeEntry* node = &bucket.replacements[bucket.replacement_count];
        for (int i = 0; i < 20; i++) node.id[i] = new_id[i];
        node.addr = new_addr;
        node.last_queried = (long)time::now().to_seconds();
        node.rtt_ms = new_rtt;
        node.timeout_count = 0;
        node.verified = verified;
        bucket.replacement_count++;
    }

    return false;
}

/**
 * Mark a node as failed (timeout or error response)
 *
 * @param table Routing table
 * @param id Node ID that failed
 */
fn void RoutingTable.node_failed(&self, common::NodeId id) @public
{
    int bucket_idx = self.bucket_index(id);
    KBucket* bucket = &self.buckets[bucket_idx];

    int node_idx = find_node_in_bucket(bucket, id);
    if (node_idx < 0) return;  // Node not found

    NodeEntry* node = &bucket.live_nodes[node_idx];
    node.timeout_count++;
}

/**
 * Find the k closest nodes to a target ID
 *
 * @param table Routing table
 * @param target Target node ID
 * @param count Maximum number of nodes to return (typically 8)
 * @return Array of closest nodes (caller must free)
 */
fn NodeEntry[] RoutingTable.find_closest_nodes(&self, common::NodeId target, int count) @public
{
    // Allocate result array
    NodeEntry[] results = mem::new_array(NodeEntry, count);
    int result_count = 0;

    // Find the bucket containing the target
    int target_bucket = self.bucket_index(target);

    // Collect nodes from target bucket and surrounding buckets
    // Search outward from target bucket in both directions
    for (int offset = 0; offset < NUM_BUCKETS && result_count < count; offset++)
    {
        // Try bucket at target + offset
        if (target_bucket + offset < NUM_BUCKETS)
        {
            KBucket* bucket = &self.buckets[target_bucket + offset];
            for (int i = 0; i < bucket.live_count && result_count < count; i++)
            {
                results[result_count++] = bucket.live_nodes[i];
            }
        }

        // Try bucket at target - offset (if different from +offset)
        if (offset > 0 && target_bucket - offset >= 0 && result_count < count)
        {
            KBucket* bucket = &self.buckets[target_bucket - offset];
            for (int i = 0; i < bucket.live_count && result_count < count; i++)
            {
                results[result_count++] = bucket.live_nodes[i];
            }
        }
    }

    // Return only the filled portion of the array
    if (result_count < count)
    {
        NodeEntry[] trimmed = mem::new_array(NodeEntry, result_count);
        for (int i = 0; i < result_count; i++)
        {
            trimmed[i] = results[i];
        }
        free(results);
        return trimmed;
    }

    return results;
}

/**
 * Get statistics about the routing table
 *
 * @param table Routing table
 * @param total_nodes Output: total number of nodes in routing table
 * @param active_buckets Output: number of buckets with at least one node
 */
fn void RoutingTable.get_stats(&self, int* total_nodes, int* active_buckets) @public
{
    int total = 0;
    int active = 0;

    for (int i = 0; i < NUM_BUCKETS; i++)
    {
        total += self.buckets[i].live_count;
        if (self.buckets[i].live_count > 0) active++;
    }

    *total_nodes = total;
    *active_buckets = active;
}
