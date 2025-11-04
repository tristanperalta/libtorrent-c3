module libtorrent::dht_get_peers;

import std::io;
import std::collections::list;
import libtorrent::common;
import libtorrent::dht_traversal;

/**
 * DHT Get Peers Implementation
 * ============================
 * Implements get_peers operation for finding peers that have a specific torrent.
 * Similar to find_node traversal, but searches for an info_hash instead of a node ID.
 *
 * The get_peers query returns either:
 * - Peers that have the torrent (compact peer format)
 * - Closer nodes to continue the search
 * - A token for announcing we have the torrent
 */

// ============================================================================
// Constants
// ============================================================================

const int MAX_PEERS_PER_TORRENT = 200;  // Maximum peers to collect per torrent

// ============================================================================
// Data Structures
// ============================================================================

/**
 * Announce token from a node
 * Tokens are opaque values that must be echoed back when announcing
 */
struct AnnounceToken
{
    common::NodeId node_id;  // Node that provided the token
    common::Ipv4Addr node_ip; // Node IP
    ushort node_port;        // Node port
    char[32] token;          // Token value (up to 32 bytes)
    char token_len;          // Actual token length
    long received_time;      // When token was received
}

/**
 * Get peers search state
 * Extends basic traversal with peer collection
 */
struct GetPeersSearch
{
    dht_traversal::Traversal* traversal;             // Underlying traversal
    common::InfoHash info_hash;                      // Target info hash
    common::SocketAddress[MAX_PEERS_PER_TORRENT] peers; // Collected peers
    int peer_count;                                  // Number of peers collected
    AnnounceToken[8] tokens;                         // Announce tokens from closest nodes
    int token_count;                                 // Number of tokens collected
    bool found_peers;                                // Whether we found any peers
}

// ============================================================================
// Search Management
// ============================================================================

/**
 * Create a new get_peers search
 *
 * @param info_hash Target info hash (torrent we're searching for)
 * @return Initialized search (allocated on heap)
 */
fn GetPeersSearch* create_search(common::InfoHash info_hash) @public
{
    GetPeersSearch* search = mem::new(GetPeersSearch);

    // Copy info hash
    for (int i = 0; i < 20; i++)
    {
        search.info_hash[i] = info_hash[i];
    }

    // Create underlying traversal (searching for info_hash as if it were a node ID)
    common::NodeId target;
    for (int i = 0; i < 20; i++) target[i] = info_hash[i];
    search.traversal = dht_traversal::create_traversal(target);

    search.peer_count = 0;
    search.token_count = 0;
    search.found_peers = false;

    return search;
}

/**
 * Free a get_peers search
 */
fn void GetPeersSearch.free(&self) @public
{
    if (self.traversal)
    {
        self.traversal.free();
    }

    free(self);
}

// ============================================================================
// Peer Management
// ============================================================================

/**
 * Add a peer to the search results
 *
 * @param peer_addr Socket address (IPv4 or IPv6)
 * @return true if peer was added
 */
fn bool GetPeersSearch.add_peer(&self, common::SocketAddress peer_addr) @public
{
    // Check if we already have this peer (compare IP and port)
    for (int i = 0; i < self.peer_count; i++)
    {
        // Compare IP version first
        if (self.peers[i].addr.is_ipv6 != peer_addr.addr.is_ipv6) continue;

        // Compare address bytes
        bool addr_match;
        if (peer_addr.addr.is_ipv6)
        {
            // Compare IPv6 addresses
            char* a = (char*)&self.peers[i].addr.ipv6;
            char* b = (char*)&peer_addr.addr.ipv6;
            addr_match = true;
            for (usz j = 0; j < common::IPV6_ADDR_SIZE; j++)
            {
                if (a[j] != b[j])
                {
                    addr_match = false;
                    break;
                }
            }
        }
        else
        {
            // Compare IPv4 addresses
            addr_match = (self.peers[i].addr.ipv4.a == peer_addr.addr.ipv4.a &&
                         self.peers[i].addr.ipv4.b == peer_addr.addr.ipv4.b &&
                         self.peers[i].addr.ipv4.c == peer_addr.addr.ipv4.c &&
                         self.peers[i].addr.ipv4.d == peer_addr.addr.ipv4.d);
        }

        if (addr_match && self.peers[i].port == peer_addr.port)
        {
            return false;  // Duplicate
        }
    }

    // Check if we have space
    if (self.peer_count >= MAX_PEERS_PER_TORRENT) return false;

    // Add peer
    self.peers[self.peer_count] = peer_addr;
    self.peer_count++;
    self.found_peers = true;

    return true;
}

/**
 * Add multiple peers from compact format
 *
 * @param compact_peers Compact peer data (6 bytes per peer)
 * @return Number of peers added
 */
fn int GetPeersSearch.add_peers_compact(&self, char[] compact_peers) @public
{
    int added = 0;

    // Each peer is 6 bytes: 4 bytes IP + 2 bytes port
    for (usz i = 0; i + 6 <= compact_peers.len; i += 6)
    {
        // Manually create address instead of using slice
        common::SocketAddress addr;
        addr.addr.is_ipv6 = false;
        addr.addr.ipv4.a = compact_peers[i];
        addr.addr.ipv4.b = compact_peers[i + 1];
        addr.addr.ipv4.c = compact_peers[i + 2];
        addr.addr.ipv4.d = compact_peers[i + 3];
        addr.port = ((ushort)compact_peers[i + 4] << 8) | (ushort)compact_peers[i + 5];

        if (self.add_peer(addr))
        {
            added++;
        }
    }

    return added;
}

/**
 * Get all discovered peers
 *
 * @return Array of peers (caller must free)
 */
fn common::SocketAddress[] GetPeersSearch.get_peers(&self) @public
{
    common::SocketAddress[] result = mem::new_array(common::SocketAddress, self.peer_count);
    for (int i = 0; i < self.peer_count; i++)
    {
        result[i] = self.peers[i];
    }
    return result;
}

// ============================================================================
// Token Management
// ============================================================================

/**
 * Add an announce token
 *
 * @param node_id Node ID that provided the token
 * @param node_ip Node IP
 * @param node_port Node port
 * @param token Token data
 * @return true if token was added
 */
fn bool GetPeersSearch.add_token(&self, common::NodeId node_id,
                                 common::Ipv4Addr node_ip, ushort node_port, char[] token) @public
{
    // Check if we have space
    if (self.token_count >= 8) return false;

    // Add token
    AnnounceToken* t = &self.tokens[self.token_count];

    for (int i = 0; i < 20; i++) t.node_id[i] = node_id[i];
    for (int i = 0; i < 4; i++) t.node_ip[i] = node_ip[i];
    t.node_port = node_port;

    // Copy token (max 32 bytes)
    t.token_len = (char)token.len;
    if (t.token_len > 32) t.token_len = 32;

    for (int i = 0; i < t.token_len; i++)
    {
        t.token[i] = token[i];
    }

    t.received_time = 0;  // Should be set to current time in full implementation

    self.token_count++;
    return true;
}

/**
 * Get the best announce token
 * Returns the token from the closest node
 *
 * @param token_out Output buffer for token (must be at least 32 bytes)
 * @param token_len_out Output: token length
 * @param node_id_out Output: node ID that provided the token
 * @param node_ip_out Output: node IP
 * @param node_port_out Output: node port
 * @return true if a token is available
 */
fn bool GetPeersSearch.get_announce_token(&self, char* token_out, char* token_len_out,
                                          common::NodeId* node_id_out, common::Ipv4Addr* node_ip_out,
                                          ushort* node_port_out) @public
{
    if (self.token_count == 0) return false;

    // Return the first token (in full implementation, should return from closest node)
    AnnounceToken* t = &self.tokens[0];

    for (int i = 0; i < t.token_len; i++)
    {
        token_out[i] = t.token[i];
    }
    *token_len_out = t.token_len;

    for (int i = 0; i < 20; i++) (*node_id_out)[i] = t.node_id[i];
    for (int i = 0; i < 4; i++) (*node_ip_out)[i] = t.node_ip[i];
    *node_port_out = t.node_port;

    return true;
}

// ============================================================================
// Statistics
// ============================================================================

/**
 * Get search statistics
 *
 * @param peer_count Output: number of peers found
 * @param token_count Output: number of tokens collected
 * @param nodes_queried Output: number of nodes queried
 */
fn void GetPeersSearch.get_stats(&self, int* peer_count, int* token_count,
                                 int* nodes_queried) @public
{
    *peer_count = self.peer_count;
    *token_count = self.token_count;

    int total, queries, responses;
    self.traversal.get_stats(&total, &queries, &responses);
    *nodes_queried = queries;
}

/**
 * Check if search found any peers
 *
 * @param search Search state
 * @return true if at least one peer was found
 */
fn bool found_peers(GetPeersSearch* search) @public
{
    return search.found_peers;
}

/**
 * Check if search is complete
 * Delegates to underlying traversal
 *
 * @return true if search should stop
 */
fn bool GetPeersSearch.is_done(&self) @public
{
    return dht_traversal::is_done(self.traversal);
}
