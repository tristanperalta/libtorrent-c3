module libtorrent::peer_pool;

import libtorrent::event_loop;
import libtorrent::tracker;
import libtorrent::peer_connection;
import libtorrent::peer_wire;
import std::io;
import std::time;

<*
 Peer Pool - Async Peer Management
 ==================================
 Manages peer discovery, connection lifecycle, and quality tracking.
 Inspired by libtorrent's peer_list class.

 This module implements a per-torrent peer manager that:
 - Stores discovered peers (up to max_peerlist_size, default 1000)
 - Manages active connections (up to max_active_connections, default 25)
 - Deduplicates peers by IP:port
 - Ranks peers by quality
 - Automatically retries/bans peers based on failures

 Phase 1: Core Storage & Discovery
 - Basic peer storage with sorted array
 - Deduplication by IP:port
 - Capacity management
 - Find and erase operations
*>

// Faults
faultdef PEER_NOT_FOUND;

// Configuration
struct PeerPoolConfig
{
    usz max_peerlist_size;      // Default: 1000 (libtorrent default)
    usz max_active_connections; // Default: 25
    usz max_failcount;          // Default: 3 (ban after 3 failures)
    uint min_reconnect_time;    // Default: 60 seconds
}

// Default configuration
const PeerPoolConfig DEFAULT_CONFIG = {
    .max_peerlist_size = 1000,
    .max_active_connections = 25,
    .max_failcount = 3,
    .min_reconnect_time = 60
};

// Peer state
enum PeerState : const char
{
    DISCOVERED,    // Just learned about this peer
    CANDIDATE,     // Ready to connect (passed initial filters)
    CONNECTING,    // Connection in progress (async)
    CONNECTED,     // Active connection established
    DISCONNECTED,  // Previously connected, now closed
    BANNED         // Too many failures or misbehavior - never retry
}

// Single peer info
struct TorrentPeer
{
    // Identity
    char[4] ip;                  // IPv4 address
    ushort port;                 // Port number
    char[20] peer_id;            // Peer ID (empty until handshake)

    // Connection
    peer_connection::PeerConnection* connection;  // Active connection (null if not connected)
    PeerState state;             // Current state

    // Statistics (for ranking and quality tracking)
    ulong prev_amount_download;  // Bytes downloaded from this peer
    ulong prev_amount_upload;    // Bytes uploaded to this peer
    uint hashfails;              // Failed piece hash verifications
    uint failcount;              // Connection failures (ban if >= max_failcount)
    uint last_connected;         // Timestamp of last connection (seconds since epoch)

    // Flags
    bool seed;                   // Is this peer a seed (has all pieces)?
    bool optimistically_unchoked; // Currently optimistically unchoked?

    // Ranking
    int peer_rank;               // Priority for connection (higher = better)

    // Source tracking
    bool from_tracker;           // Did we get this peer from tracker?
}

// Callbacks
alias PeerConnectedCallback = fn void(peer_connection::PeerConnection* peer,
                                       char[4] ip, ushort port, void* user_data);
alias PeerMessageCallback = fn void(peer_connection::PeerConnection* peer,
                                     peer_wire::Message* msg,
                                     char[4] ip, ushort port, void* user_data);
alias PeerDisconnectedCallback = fn void(char[4] ip, ushort port,
                                          bool was_error, void* user_data);

// Main peer pool
struct PeerPool
{
    event_loop::EventLoop* loop;  // Event loop for async operations
    PeerPoolConfig config;        // Configuration

    // Storage
    // Note: C3 doesn't have HashMap yet, so we use sorted array for O(log n) lookups
    // Sorted by IP:port for binary search
    TorrentPeer*[] peers;         // Main peer list (sorted by IP:port)

    // Phase 2: Candidate selection (sorted by rank, highest first)
    TorrentPeer*[] candidate_cache;  // Ready-to-connect peers (sorted by rank descending)

    // Phase 3: Connection management
    usz num_active_connections;     // Current number of active connections

    // Torrent info (needed for peer connections)
    char[20] info_hash;           // Torrent info hash
    char[20] our_peer_id;         // Our peer ID

    // Callbacks (user-provided)
    PeerConnectedCallback on_connected;       // Called when peer connects successfully
    PeerMessageCallback on_message;           // Called when peer sends message
    PeerDisconnectedCallback on_disconnected; // Called when peer disconnects
    void* user_data;              // User data passed to callbacks
}

<*
 Compare two peers by IP:port for sorting.
 Returns: <0 if a < b, 0 if a == b, >0 if a > b
*>
fn int compare_peers(TorrentPeer* a, TorrentPeer* b)
{
    // Compare IP bytes
    for (usz i = 0; i < 4; i++)
    {
        if (a.ip[i] != b.ip[i])
        {
            return (int)a.ip[i] - (int)b.ip[i];
        }
    }

    // IP is equal, compare port
    return (int)a.port - (int)b.port;
}

<*
 Find peer index using binary search.
 Returns index if found, otherwise returns the insertion point (as negative).
*>
fn isz find_peer_index(PeerPool* pool, char[4] ip, ushort port)
{
    if (pool.peers.len == 0)
    {
        return -1; // Insert at index 0
    }

    // Create temporary peer for comparison
    TorrentPeer temp;
    temp.ip = ip;
    temp.port = port;

    // Binary search
    isz left = 0;
    isz right = (isz)pool.peers.len - 1;

    while (left <= right)
    {
        isz mid = left + (right - left) / 2;
        int cmp = compare_peers(&temp, pool.peers[mid]);

        if (cmp == 0)
        {
            return mid; // Found
        }
        else if (cmp < 0)
        {
            right = mid - 1;
        }
        else
        {
            left = mid + 1;
        }
    }

    // Not found, return insertion point as negative
    return -(left + 1);
}

<*
 Calculate peer rank for prioritization (Phase 2).
 Higher rank = better peer = higher priority for connections.

 Ranking algorithm (inspired by libtorrent):
 - +100: Has downloaded data from this peer before (proven good)
 - +50: Peer is a seed (has all pieces)
 - -20 per failcount: Connection failures (unreliable)
 - -30 per hashfails: Hash verification failures (bad data)
 - +0-19: Deterministic randomness based on IP (symmetric priority)

 Returns: Rank value (higher is better)
*>
fn int calculate_peer_rank(PeerPool* pool, TorrentPeer* peer)
{
    int rank = 0;

    // Prioritize peers we've successfully downloaded from
    if (peer.prev_amount_download > 0)
    {
        rank += 100;
    }

    // Prioritize seeds if we're downloading
    if (peer.seed)
    {
        rank += 50;
    }

    // Penalize failed connections
    rank -= (int)peer.failcount * 20;

    // Penalize hash failures (bad peer)
    rank -= (int)peer.hashfails * 30;

    // Add deterministic randomness based on IP
    // This ensures symmetric priority (both peers rank each other similarly)
    // and provides variety in initial connection attempts
    rank += ((int)peer.ip[3] * 7) % 20;

    return rank;
}

<*
 Compare two peers by rank for sorting candidate cache.
 Returns: >0 if a has higher rank (better peer), <0 if b is better, 0 if equal
 Note: Reversed from typical comparator (higher rank first)
*>
fn int compare_peers_by_rank(TorrentPeer* a, TorrentPeer* b)
{
    // Higher rank first (descending order)
    return b.peer_rank - a.peer_rank;
}

<*
 Create a peer pool for a torrent.

 @param loop : "Event loop for async operations"
 @param config : "Configuration"
 @param info_hash : "Torrent info hash"
 @param our_peer_id : "Our peer ID"
 @return "Initialized peer pool"
*>
fn PeerPool* create(event_loop::EventLoop* loop,
                    PeerPoolConfig config,
                    char[20]* info_hash,
                    char[20]* our_peer_id) @public
{
    PeerPool* pool = mem::new(PeerPool);
    pool.loop = loop;
    pool.config = config;

    // Copy info hash and peer ID
    for (usz i = 0; i < 20; i++)
    {
        pool.info_hash[i] = (*info_hash)[i];
        pool.our_peer_id[i] = (*our_peer_id)[i];
    }

    // Initialize empty peer list
    pool.peers = {};

    // Initialize empty candidate cache (Phase 2)
    pool.candidate_cache = {};

    // Initialize connection count (Phase 3)
    pool.num_active_connections = 0;

    // No callbacks yet
    pool.on_connected = null;
    pool.on_message = null;
    pool.on_disconnected = null;
    pool.user_data = null;

    return pool;
}

<*
 Free peer pool and all associated resources.

 @param pool : "Peer pool to free"
*>
fn void free(PeerPool* pool) @public
{
    if (!pool) return;

    // Disconnect all active connections (Phase 3)
    pool.disconnect_all();

    // Free all peer structures
    for (usz i = 0; i < pool.peers.len; i++)
    {
        std::core::mem::free(pool.peers[i]);
    }

    // Free peer array
    if (pool.peers.len > 0)
    {
        std::core::mem::free(pool.peers);
    }

    // Free candidate cache (Phase 2)
    // Note: candidate_cache contains pointers to same peers, so don't free the peers again
    if (pool.candidate_cache.len > 0)
    {
        std::core::mem::free(pool.candidate_cache);
    }

    // Free pool itself
    std::core::mem::free(pool);
}

<*
 Update candidate cache with all eligible peers sorted by rank (Phase 2).

 This rebuilds the candidate cache from scratch by:
 1. Filtering peers that are eligible to connect (DISCOVERED or DISCONNECTED)
 2. Calculating/updating their ranks
 3. Sorting by rank (highest first)

 Called after adding new peers or when peer states/statistics change.
*>
fn void PeerPool.update_candidate_cache(&self) @public
{
    // Free old cache
    if (self.candidate_cache.len > 0)
    {
        std::core::mem::free(self.candidate_cache);
        self.candidate_cache = {};
    }

    // Count eligible candidates
    usz eligible_count = 0;
    for (usz i = 0; i < self.peers.len; i++)
    {
        PeerState state = self.peers[i].state;
        // Only DISCOVERED and DISCONNECTED peers are eligible for new connections
        // (CONNECTING, CONNECTED, and BANNED are not)
        if (state == PeerState.DISCOVERED || state == PeerState.DISCONNECTED)
        {
            eligible_count++;
        }
    }

    if (eligible_count == 0)
    {
        return; // No candidates
    }

    // Allocate candidate cache
    self.candidate_cache = mem::new_array(TorrentPeer*, eligible_count);

    // Populate cache with eligible peers and update ranks
    usz cache_index = 0;
    for (usz i = 0; i < self.peers.len; i++)
    {
        PeerState state = self.peers[i].state;
        if (state == PeerState.DISCOVERED || state == PeerState.DISCONNECTED)
        {
            // Update peer rank
            self.peers[i].peer_rank = calculate_peer_rank(self, self.peers[i]);

            // Add to cache
            self.candidate_cache[cache_index] = self.peers[i];
            cache_index++;
        }
    }

    // Sort cache by rank (highest first)
    // Simple bubble sort - good enough for typical candidate counts
    for (usz i = 0; i < self.candidate_cache.len; i++)
    {
        for (usz j = i + 1; j < self.candidate_cache.len; j++)
        {
            if (compare_peers_by_rank(self.candidate_cache[i], self.candidate_cache[j]) > 0)
            {
                // Swap
                TorrentPeer* temp = self.candidate_cache[i];
                self.candidate_cache[i] = self.candidate_cache[j];
                self.candidate_cache[j] = temp;
            }
        }
    }
}

<*
 Pick the best candidate peer to connect to (Phase 2).

 Returns the highest-ranked peer from the candidate cache, or fault if no candidates available.

 @return "Best peer to connect to, or PEER_NOT_FOUND fault"
*>
fn TorrentPeer*? PeerPool.pick_best_candidate(&self) @public
{
    if (self.candidate_cache.len == 0)
    {
        return PEER_NOT_FOUND?;
    }

    // Return first peer (highest rank due to sorting)
    return self.candidate_cache[0];
}

<*
 Set user callbacks for peer events (Phase 3).

 @param on_connected : "Callback when peer connects successfully (can be null)"
 @param on_message : "Callback when peer sends message (can be null)"
 @param on_disconnected : "Callback when peer disconnects (can be null)"
 @param user_data : "User context passed to callbacks"
*>
fn void PeerPool.set_callbacks(&self,
                                 PeerConnectedCallback on_connected,
                                 PeerMessageCallback on_message,
                                 PeerDisconnectedCallback on_disconnected,
                                 void* user_data) @public
{
    self.on_connected = on_connected;
    self.on_message = on_message;
    self.on_disconnected = on_disconnected;
    self.user_data = user_data;
}

<*
 Add single peer from any source (deduplicates by IP:port).

 @param ip : "IPv4 address"
 @param port : "Port number"
 @param from_tracker : "Is this peer from tracker?"
*>
fn void PeerPool.add_peer(&self, char[4] ip, ushort port, bool from_tracker) @public
{
    // Check if peer already exists
    isz idx = find_peer_index(self, ip, port);
    if (idx >= 0)
    {
        // Already exists, just update source flag
        self.peers[idx].from_tracker = self.peers[idx].from_tracker || from_tracker;
        return;
    }

    // Check capacity
    if (self.peers.len >= self.config.max_peerlist_size)
    {
        // TODO: Enforce limit by removing lowest-ranked peer
        // For now, just don't add
        return;
    }

    // Create new peer
    TorrentPeer* peer = mem::new(TorrentPeer);
    peer.ip = ip;
    peer.port = port;
    peer.connection = null;
    peer.state = PeerState.DISCOVERED;
    peer.prev_amount_download = 0;
    peer.prev_amount_upload = 0;
    peer.hashfails = 0;
    peer.failcount = 0;
    peer.last_connected = 0;
    peer.seed = false;
    peer.optimistically_unchoked = false;
    peer.from_tracker = from_tracker;

    // Initialize peer_id to zeros
    for (usz i = 0; i < 20; i++)
    {
        peer.peer_id[i] = 0;
    }

    // Calculate initial rank (Phase 2)
    peer.peer_rank = calculate_peer_rank(self, peer);

    // Insert at correct position to maintain sort order
    isz insert_pos = -(idx + 1);  // Convert negative index to insertion point

    // Allocate new array with space for one more peer
    TorrentPeer*[] new_peers = mem::new_array(TorrentPeer*, self.peers.len + 1);

    // Copy peers before insertion point
    for (usz i = 0; i < (usz)insert_pos; i++)
    {
        new_peers[i] = self.peers[i];
    }

    // Insert new peer
    new_peers[insert_pos] = peer;

    // Copy peers after insertion point
    for (usz i = (usz)insert_pos; i < self.peers.len; i++)
    {
        new_peers[i + 1] = self.peers[i];
    }

    // Replace old array
    if (self.peers.len > 0)
    {
        std::core::mem::free(self.peers);
    }
    self.peers = new_peers;
}

<*
 Batch add peers from tracker response.

 @param peers : "Peers from tracker"
*>
fn void PeerPool.add_peers_from_tracker(&self, tracker::Peer[] peers) @public
{
    for (usz i = 0; i < peers.len; i++)
    {
        self.add_peer(peers[i].ip, peers[i].port, true);
    }

    // Update candidate cache after batch add (Phase 2)
    self.update_candidate_cache();
}

<*
 Find peer by IP:port.

 @param ip : "IPv4 address"
 @param port : "Port number"
 @return "Peer if found, fault if not found"
*>
fn TorrentPeer*? PeerPool.find_peer(&self, char[4] ip, ushort port) @public
{
    isz idx = find_peer_index(self, ip, port);
    if (idx < 0)
    {
        return PEER_NOT_FOUND?;
    }
    return self.peers[idx];
}

<*
 Remove peer from pool.

 @param peer : "Peer to remove"
*>
fn void PeerPool.erase_peer(&self, TorrentPeer* peer) @public
{
    if (!peer) return;

    // Find peer index
    isz idx = find_peer_index(self, peer.ip, peer.port);
    if (idx < 0)
    {
        return; // Not found
    }

    // Free the peer structure
    std::core::mem::free(self.peers[idx]);

    // If this is the only peer, just clear the array
    if (self.peers.len == 1)
    {
        std::core::mem::free(self.peers);
        self.peers = {};
        return;
    }

    // Allocate new array with one less peer
    TorrentPeer*[] new_peers = mem::new_array(TorrentPeer*, self.peers.len - 1);

    // Copy peers before erased peer
    for (usz i = 0; i < (usz)idx; i++)
    {
        new_peers[i] = self.peers[i];
    }

    // Copy peers after erased peer
    for (usz i = (usz)idx + 1; i < self.peers.len; i++)
    {
        new_peers[i - 1] = self.peers[i];
    }

    // Replace old array
    std::core::mem::free(self.peers);
    self.peers = new_peers;
}

<*
 Get statistics about peer pool.

 @param total_peers : "Output: total peers in list"
 @param candidates : "Output: peers ready to connect"
 @param connecting : "Output: connections in progress"
 @param connected : "Output: active connections"
*>
fn void PeerPool.get_stats(&self,
                            usz* total_peers,
                            usz* candidates,
                            usz* connecting,
                            usz* connected) @public
{
    *total_peers = self.peers.len;
    *candidates = 0;
    *connecting = 0;
    *connected = 0;

    for (usz i = 0; i < self.peers.len; i++)
    {
        switch (self.peers[i].state)
        {
            case PeerState.CANDIDATE:
                (*candidates)++;
            case PeerState.CONNECTING:
                (*connecting)++;
            case PeerState.CONNECTED:
                (*connected)++;
            default:
                // Count DISCOVERED, DISCONNECTED, BANNED in total only
        }
    }
}

// ===== Phase 3: Async Connection Management =====

<*
 Internal callback - bridges peer_connection state changes to peer pool (Phase 3).

 This receives state changes from peer_connection and updates the TorrentPeer state accordingly.
*>
fn void on_peer_state_change_internal(peer_connection::PeerConnection* conn,
                                       peer_connection::PeerState conn_state,
                                       void* user_data)
{
    TorrentPeer* peer = (TorrentPeer*)user_data;
    PeerPool* pool = null;  // We need to find the pool from the peer

    // TODO: This is a limitation - we don't have easy access to pool from peer
    // For now, we'll handle state in connect_to_peers() via the user callback
    // This function signature is for future use
}

<*
 Internal callback - bridges peer_connection messages to user callback (Phase 3).
*>
fn void on_peer_message_internal(peer_connection::PeerConnection* conn,
                                  peer_wire::Message* msg,
                                  void* user_data)
{
    // Extract peer info from user_data
    // Format: We'll pack {TorrentPeer*, PeerPool*} later
    // For now, simplified approach
}

<*
 Disconnect a specific peer by IP:port (Phase 3).

 @param ip : "Peer IP address"
 @param port : "Peer port"
*>
fn void PeerPool.disconnect_peer(&self, char[4] ip, ushort port) @public
{
    // Find peer
    TorrentPeer*? peer_opt = self.find_peer(ip, port);
    if (catch err = peer_opt)
    {
        return; // Peer not found
    }

    TorrentPeer* peer = peer_opt;

    // Close connection if active
    if (peer.connection)
    {
        peer_connection::close(peer.connection);
        peer.connection = null;
        self.num_active_connections--;
    }

    // Update state
    peer.state = PeerState.DISCONNECTED;

    // Update candidate cache
    self.update_candidate_cache();

    // Call user callback
    if (self.on_disconnected)
    {
        self.on_disconnected(ip, port, false, self.user_data);
    }
}

<*
 Disconnect all active peer connections (Phase 3).
*>
fn void PeerPool.disconnect_all(&self) @public
{
    for (usz i = 0; i < self.peers.len; i++)
    {
        if (self.peers[i].connection)
        {
            peer_connection::close(self.peers[i].connection);
            self.peers[i].connection = null;
            self.peers[i].state = PeerState.DISCONNECTED;
        }
    }

    self.num_active_connections = 0;

    // Update candidate cache
    self.update_candidate_cache();
}

<*
 Fill available connection slots with best candidates (Phase 3).

 Automatically connects to the best peers from the candidate cache until
 max_active_connections is reached or no more candidates are available.

 This is the main entry point for automatic connection management.
*>
fn void PeerPool.connect_to_peers(&self) @public
{
    // Check if we have room for more connections
    while (self.num_active_connections < self.config.max_active_connections)
    {
        // Pick best candidate
        TorrentPeer*? best_opt = self.pick_best_candidate();
        if (catch err = best_opt)
        {
            // No more candidates available
            return;
        }

        TorrentPeer* peer = best_opt;

        // Format IP address for connection
        DString ip_builder;
        ip_builder.appendf("%d.%d.%d.%d",
                          (int)peer.ip[0] & 0xFF,
                          (int)peer.ip[1] & 0xFF,
                          (int)peer.ip[2] & 0xFF,
                          (int)peer.ip[3] & 0xFF);
        String ip_str = ip_builder.copy_str(mem);
        defer std::core::mem::free(ip_str);

        // Connect to peer
        // Note: For Phase 3, we pass message/state callbacks directly as null
        // Phase 4 will implement proper bridging to add IP/port to callbacks
        peer_connection::PeerConnection*? conn_opt = peer_connection::connect(
            self.loop,
            ip_str,
            peer.port,
            self.info_hash,
            self.our_peer_id,
            null,  // Message callback (Phase 4 will bridge this)
            null,  // State callback (Phase 4 will bridge this)
            self.user_data
        );

        if (catch err = conn_opt)
        {
            // Connection failed immediately
            peer.failcount++;

            if (peer.failcount >= self.config.max_failcount)
            {
                peer.state = PeerState.BANNED;
            }
            else
            {
                peer.state = PeerState.DISCONNECTED;
            }

            // Update candidate cache to exclude this peer
            self.update_candidate_cache();

            // Continue trying other candidates
            continue;
        }

        // Connection initiated successfully
        peer.connection = conn_opt;
        peer.state = PeerState.CONNECTING;
        self.num_active_connections++;

        // Call user callback if provided
        if (self.on_connected)
        {
            self.on_connected(conn_opt, peer.ip, peer.port, self.user_data);
        }

        // Update candidate cache to remove this peer from candidates
        self.update_candidate_cache();
    }
}
