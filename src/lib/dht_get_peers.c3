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
    dht_traversal::Traversal* traversal;      // Underlying traversal
    common::InfoHash info_hash;               // Target info hash
    common::Peer[MAX_PEERS_PER_TORRENT] peers; // Collected peers
    int peer_count;                           // Number of peers collected
    AnnounceToken[8] tokens;                  // Announce tokens from closest nodes
    int token_count;                          // Number of tokens collected
    bool found_peers;                         // Whether we found any peers
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
 *
 * @param search Search to free
 */
fn void free_search(GetPeersSearch* search) @public
{
    if (!search) return;

    if (search.traversal)
    {
        dht_traversal::free_traversal(search.traversal);
    }

    free(search);
}

// ============================================================================
// Peer Management
// ============================================================================

/**
 * Add a peer to the search results
 *
 * @param search Search state
 * @param ip Peer IP address
 * @param port Peer port
 * @return true if peer was added
 */
fn bool add_peer(GetPeersSearch* search, common::Ipv4Addr ip, ushort port) @public
{
    // Check if we already have this peer
    for (int i = 0; i < search.peer_count; i++)
    {
        if (search.peers[i].ip[0] == ip[0] &&
            search.peers[i].ip[1] == ip[1] &&
            search.peers[i].ip[2] == ip[2] &&
            search.peers[i].ip[3] == ip[3] &&
            search.peers[i].port == port)
        {
            return false;  // Duplicate
        }
    }

    // Check if we have space
    if (search.peer_count >= MAX_PEERS_PER_TORRENT) return false;

    // Add peer
    common::Peer* peer = &search.peers[search.peer_count];
    for (int i = 0; i < 4; i++) peer.ip[i] = ip[i];
    peer.port = port;

    search.peer_count++;
    search.found_peers = true;

    return true;
}

/**
 * Add multiple peers from compact format
 *
 * @param search Search state
 * @param compact_peers Compact peer data (6 bytes per peer)
 * @return Number of peers added
 */
fn int add_peers_compact(GetPeersSearch* search, char[] compact_peers) @public
{
    int added = 0;

    // Each peer is 6 bytes: 4 bytes IP + 2 bytes port
    for (usz i = 0; i + 6 <= compact_peers.len; i += 6)
    {
        common::Ipv4Addr ip;
        ip[0] = compact_peers[i];
        ip[1] = compact_peers[i + 1];
        ip[2] = compact_peers[i + 2];
        ip[3] = compact_peers[i + 3];

        ushort port = ((ushort)compact_peers[i + 4] << 8) | (ushort)compact_peers[i + 5];

        if (add_peer(search, ip, port))
        {
            added++;
        }
    }

    return added;
}

/**
 * Get all discovered peers
 *
 * @param search Search state
 * @return Array of peers (caller must free)
 */
fn common::Peer[] get_peers(GetPeersSearch* search) @public
{
    common::Peer[] result = mem::new_array(common::Peer, search.peer_count);
    for (int i = 0; i < search.peer_count; i++)
    {
        result[i] = search.peers[i];
    }
    return result;
}

// ============================================================================
// Token Management
// ============================================================================

/**
 * Add an announce token
 *
 * @param search Search state
 * @param node_id Node ID that provided the token
 * @param node_ip Node IP
 * @param node_port Node port
 * @param token Token data
 * @return true if token was added
 */
fn bool add_token(GetPeersSearch* search, common::NodeId node_id,
                  common::Ipv4Addr node_ip, ushort node_port, char[] token) @public
{
    // Check if we have space
    if (search.token_count >= 8) return false;

    // Add token
    AnnounceToken* t = &search.tokens[search.token_count];

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

    search.token_count++;
    return true;
}

/**
 * Get the best announce token
 * Returns the token from the closest node
 *
 * @param search Search state
 * @param token_out Output buffer for token (must be at least 32 bytes)
 * @param token_len_out Output: token length
 * @param node_id_out Output: node ID that provided the token
 * @param node_ip_out Output: node IP
 * @param node_port_out Output: node port
 * @return true if a token is available
 */
fn bool get_announce_token(GetPeersSearch* search, char* token_out, char* token_len_out,
                           common::NodeId* node_id_out, common::Ipv4Addr* node_ip_out,
                           ushort* node_port_out) @public
{
    if (search.token_count == 0) return false;

    // Return the first token (in full implementation, should return from closest node)
    AnnounceToken* t = &search.tokens[0];

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
 * @param search Search state
 * @param peer_count Output: number of peers found
 * @param token_count Output: number of tokens collected
 * @param nodes_queried Output: number of nodes queried
 */
fn void get_stats(GetPeersSearch* search, int* peer_count, int* token_count,
                  int* nodes_queried) @public
{
    *peer_count = search.peer_count;
    *token_count = search.token_count;

    int total, queries, responses;
    dht_traversal::get_stats(search.traversal, &total, &queries, &responses);
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
 * @param search Search state
 * @return true if search should stop
 */
fn bool is_done(GetPeersSearch* search) @public
{
    return dht_traversal::is_done(search.traversal);
}
