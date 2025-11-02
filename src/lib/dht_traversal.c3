module libtorrent::dht_traversal;

import std::io;
import std::collections::list;
import libtorrent::common;
import libtorrent::dht_routing_table;

/**
 * DHT Traversal Algorithm
 * =======================
 * Implements Kademlia iterative node lookup (BEP 5).
 *
 * The algorithm progressively queries nodes to find the k closest nodes to a target ID.
 * It maintains a list of candidate nodes, queries the closest unqueried nodes in parallel,
 * and updates the list as responses arrive with closer nodes.
 */

// ============================================================================
// Constants
// ============================================================================

const int TRAVERSAL_K = 8;        // Number of closest nodes to find (k parameter)
const int TRAVERSAL_ALPHA = 3;    // Concurrent queries (alpha parameter)
const int MAX_TRAVERSAL_NODES = 64; // Maximum nodes to track during traversal

// ============================================================================
// Data Structures
// ============================================================================

/**
 * Node state during traversal
 */
enum NodeState : char
{
    UNQUERIED,    // Not yet queried
    QUERYING,     // Query sent, waiting for response
    RESPONDED,    // Received response
    FAILED        // Query failed/timed out
}

/**
 * Candidate node during traversal
 */
struct TraversalNode
{
    common::NodeId id;           // Node ID
    common::Ipv4Addr ip;         // IP address
    ushort port;                 // Port number
    NodeState state;             // Current state
    int distance_exp;            // XOR distance exponent to target
}

/**
 * Traversal state
 * Tracks an ongoing find_node operation
 */
struct Traversal
{
    common::NodeId target;                      // Target node ID we're searching for
    TraversalNode[MAX_TRAVERSAL_NODES] nodes;   // Candidate nodes
    int node_count;                             // Number of candidate nodes
    int queries_sent;                           // Total queries sent
    int responses_received;                     // Total responses received
    bool is_done;                               // Traversal complete
}

// ============================================================================
// Utility Functions
// ============================================================================

/**
 * Calculate XOR distance between two node IDs and return the position
 * of the first differing bit (counting from MSB).
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
 * Compare two nodes by distance to target (for sorting)
 *
 * @param a First node
 * @param b Second node
 * @return true if a is closer than b to target
 */
fn bool node_is_closer(TraversalNode* a, TraversalNode* b)
{
    return a.distance_exp < b.distance_exp;
}

/**
 * Find a node in the traversal candidate list
 *
 * @param traversal Traversal state
 * @param id Node ID to find
 * @return Index of node, or -1 if not found
 */
fn int find_node(Traversal* traversal, common::NodeId id)
{
    for (int i = 0; i < traversal.node_count; i++)
    {
        bool match = true;
        for (int j = 0; j < 20; j++)
        {
            if (traversal.nodes[i].id[j] != id[j])
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
// Traversal Management
// ============================================================================

/**
 * Create a new traversal
 *
 * @param target Target node ID to search for
 * @return Initialized traversal (allocated on heap)
 */
fn Traversal* create_traversal(common::NodeId target) @public
{
    Traversal* t = mem::new(Traversal);

    // Copy target ID
    for (int i = 0; i < 20; i++)
    {
        t.target[i] = target[i];
    }

    t.node_count = 0;
    t.queries_sent = 0;
    t.responses_received = 0;
    t.is_done = false;

    return t;
}

/**
 * Free a traversal
 */
fn void Traversal.free(&self) @public
{
    free(self);
}

/**
 * Add initial nodes from routing table to traversal
 *
 * @param initial_nodes Initial candidate nodes from routing table
 * @return Number of nodes added
 */
fn int Traversal.add_initial_nodes(&self, dht_routing_table::NodeEntry[] initial_nodes) @public
{
    int added = 0;

    for (usz i = 0; i < initial_nodes.len && self.node_count < MAX_TRAVERSAL_NODES; i++)
    {
        TraversalNode* node = &self.nodes[self.node_count];

        // Copy node data
        for (int j = 0; j < 20; j++) node.id[j] = initial_nodes[i].id[j];
        for (int j = 0; j < 4; j++) node.ip[j] = initial_nodes[i].ip[j];
        node.port = initial_nodes[i].port;
        node.state = NodeState.UNQUERIED;
        node.distance_exp = distance_exp(node.id, self.target);

        self.node_count++;
        added++;
    }

    return added;
}

/**
 * Add a discovered node to the traversal candidate list
 *
 * @param id Node ID
 * @param ip IP address
 * @param port Port number
 * @return true if node was added (not a duplicate)
 */
fn bool Traversal.add_node(&self, common::NodeId id, common::Ipv4Addr ip, ushort port) @public
{
    // Check if node already exists
    if (find_node(self, id) >= 0) return false;

    // Check if we have space
    if (self.node_count >= MAX_TRAVERSAL_NODES) return false;

    // Add node
    TraversalNode* node = &self.nodes[self.node_count];
    for (int i = 0; i < 20; i++) node.id[i] = id[i];
    for (int i = 0; i < 4; i++) node.ip[i] = ip[i];
    node.port = port;
    node.state = NodeState.UNQUERIED;
    node.distance_exp = distance_exp(node.id, self.target);

    self.node_count++;
    return true;
}

/**
 * Get the next nodes to query
 * Returns up to alpha unqueried nodes closest to the target
 *
 * @param max_nodes Maximum number of nodes to return (typically alpha)
 * @return Array of node indices to query
 */
fn int[] Traversal.get_next_queries(&self, int max_nodes) @public
{
    // Find unqueried nodes
    List{int} candidates;
    candidates.init(mem);
    defer candidates.free();

    for (int i = 0; i < self.node_count; i++)
    {
        if (self.nodes[i].state == NodeState.UNQUERIED)
        {
            candidates.push(i);
        }
    }

    // Sort by distance (bubble sort for simplicity, should use better sort for production)
    for (usz i = 0; i < candidates.len(); i++)
    {
        for (usz j = i + 1; j < candidates.len(); j++)
        {
            int idx_i = candidates[i];
            int idx_j = candidates[j];

            if (self.nodes[idx_j].distance_exp < self.nodes[idx_i].distance_exp)
            {
                // Swap
                candidates[i] = idx_j;
                candidates[j] = idx_i;
            }
        }
    }

    // Take up to max_nodes closest
    int take = (int)candidates.len();
    if (take > max_nodes) take = max_nodes;

    int[] result = mem::new_array(int, take);
    for (int i = 0; i < take; i++)
    {
        result[i] = candidates[i];
    }

    return result;
}

/**
 * Mark a node as querying
 *
 * @param id Node ID
 */
fn void Traversal.mark_querying(&self, common::NodeId id) @public
{
    int idx = find_node(self, id);
    if (idx >= 0)
    {
        self.nodes[idx].state = NodeState.QUERYING;
        self.queries_sent++;
    }
}

/**
 * Mark a node as responded
 *
 * @param id Node ID
 */
fn void Traversal.mark_responded(&self, common::NodeId id) @public
{
    int idx = find_node(self, id);
    if (idx >= 0)
    {
        self.nodes[idx].state = NodeState.RESPONDED;
        self.responses_received++;
    }
}

/**
 * Mark a node as failed
 *
 * @param id Node ID
 */
fn void Traversal.mark_failed(&self, common::NodeId id) @public
{
    int idx = find_node(self, id);
    if (idx >= 0)
    {
        self.nodes[idx].state = NodeState.FAILED;
    }
}

/**
 * Check if traversal is done
 * Traversal is done when:
 * - We have k responded nodes and no better unqueried nodes exist
 * - All nodes have been queried
 *
 * @param traversal Traversal state
 * @return true if traversal should stop
 */
fn bool is_done(Traversal* traversal) @public
{
    if (traversal.is_done) return true;

    // Count responded nodes
    int responded = 0;
    int unqueried = 0;

    for (int i = 0; i < traversal.node_count; i++)
    {
        if (traversal.nodes[i].state == NodeState.RESPONDED) responded++;
        if (traversal.nodes[i].state == NodeState.UNQUERIED) unqueried++;
    }

    // Done if no more nodes to query
    if (unqueried == 0)
    {
        traversal.is_done = true;
        return true;
    }

    // Done if we have k responded nodes and they're the closest
    if (responded >= TRAVERSAL_K)
    {
        // Find the distance of the kth closest responded node
        int k_distance = -1;
        int count = 0;

        // Sort responded nodes by distance
        for (int i = 0; i < traversal.node_count && count < TRAVERSAL_K; i++)
        {
            if (traversal.nodes[i].state == NodeState.RESPONDED)
            {
                if (count == TRAVERSAL_K - 1)
                {
                    k_distance = traversal.nodes[i].distance_exp;
                }
                count++;
            }
        }

        // Check if any unqueried node is closer than the kth responded node
        bool has_closer = false;
        for (int i = 0; i < traversal.node_count; i++)
        {
            if (traversal.nodes[i].state == NodeState.UNQUERIED &&
                traversal.nodes[i].distance_exp < k_distance)
            {
                has_closer = true;
                break;
            }
        }

        if (!has_closer)
        {
            traversal.is_done = true;
            return true;
        }
    }

    return false;
}

/**
 * Get the k closest responded nodes
 *
 * @return Array of closest nodes (caller must free)
 */
fn TraversalNode[] Traversal.get_closest_nodes(&self) @public
{
    // Collect responded nodes
    List{int} responded_indices;
    responded_indices.init(mem);
    defer responded_indices.free();

    for (int i = 0; i < self.node_count; i++)
    {
        if (self.nodes[i].state == NodeState.RESPONDED)
        {
            responded_indices.push(i);
        }
    }

    // Sort by distance
    for (usz i = 0; i < responded_indices.len(); i++)
    {
        for (usz j = i + 1; j < responded_indices.len(); j++)
        {
            int idx_i = responded_indices[i];
            int idx_j = responded_indices[j];

            if (self.nodes[idx_j].distance_exp < self.nodes[idx_i].distance_exp)
            {
                responded_indices[i] = idx_j;
                responded_indices[j] = idx_i;
            }
        }
    }

    // Take up to k closest
    int take = (int)responded_indices.len();
    if (take > TRAVERSAL_K) take = TRAVERSAL_K;

    TraversalNode[] result = mem::new_array(TraversalNode, take);
    for (int i = 0; i < take; i++)
    {
        result[i] = self.nodes[responded_indices[i]];
    }

    return result;
}

/**
 * Get traversal statistics
 *
 * @param total_nodes Output: total candidate nodes
 * @param queries_sent Output: queries sent
 * @param responses_received Output: responses received
 */
fn void Traversal.get_stats(&self, int* total_nodes, int* queries_sent,
                            int* responses_received) @public
{
    *total_nodes = self.node_count;
    *queries_sent = self.queries_sent;
    *responses_received = self.responses_received;
}
