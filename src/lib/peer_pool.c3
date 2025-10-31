module libtorrent::peer_pool;

import libtorrent::common;
import async::event_loop;
import libtorrent::tracker;
import libtorrent::dht_get_peers;
import libtorrent::peer_connection;
import libtorrent::peer_wire;
import libtorrent::bitfield;
import libtorrent::pex;
import libtorrent::logger;
import std::io;
import std::time;
import std::sort;

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

<*
 Get default peer pool configuration.

 @return "Default configuration with recommended values"
*>
fn PeerPoolConfig get_default_config() @public
{
    return DEFAULT_CONFIG;
}

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
    common::Ipv4Addr ip;         // IPv4 address
    ushort port;                 // Port number
    common::PeerId peer_id;      // Peer ID (empty until handshake)

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
    bool handshake_ok;           // Has handshake completed successfully?
    bool received_bitfield;      // Have we received BITFIELD from this peer?

    // Piece tracking
    bitfield::Bitfield pieces;   // Which pieces this peer has

    // Ranking
    int peer_rank;               // Priority for connection (higher = better)

    // Source tracking
    common::PeerSource source;   // Where did we discover this peer?
}

<*
 Peer display information for GUI.
 Contains formatted/calculated data ready for display.
*>
struct PeerDisplayInfo
{
    String ip_address;           // Formatted IP (e.g., "192.168.1.1")
    ushort port;                 // Port number
    String client;               // Client name (e.g., "μTorrent 1.7.7")
    float percent_complete;      // Percent of torrent this peer has (0.0-100.0)
    float download_speed;        // Current download speed from peer (bytes/sec)
    float upload_speed;          // Current upload speed to peer (bytes/sec)
    String state;                // Connection state as string
}

<*
 Peer state bitflags for filtering.
 Can be combined with bitwise OR (|) to show multiple states.

 Examples:
   PeerStateFlag.CONNECTED - Only connected peers
   PeerStateFlag.CONNECTED | PeerStateFlag.CONNECTING - Connected or connecting
   PeerStateFlag.ALL & ~PeerStateFlag.BANNED - All except banned
*>
enum PeerStateFlag : const char
{
    DISCOVERED = 1 << 0,    // 0b000001 - Just learned about this peer
    CANDIDATE = 1 << 1,     // 0b000010 - Ready to connect
    CONNECTING = 1 << 2,    // 0b000100 - Connection in progress
    CONNECTED = 1 << 3,     // 0b001000 - Active connection
    DISCONNECTED = 1 << 4,  // 0b010000 - Previously connected
    BANNED = 1 << 5,        // 0b100000 - Banned due to failures
    ALL = 0x3F,             // 0b111111 - All states (bits 0-5 set)
}

<*
 Sort order for peer display list.
*>
enum PeerSortOrder : char
{
    SORT_BY_STATE,         // Connected first, then by rank (default)
    SORT_BY_DOWNLOADED,    // Highest bytes downloaded first
    SORT_BY_DOWNLOAD_SPEED,   // Fastest current download speed
    SORT_BY_UPLOAD_SPEED,     // Fastest current upload speed
    SORT_BY_COMPLETION,       // Highest % complete (seeds first)
    SORT_BY_RANK,             // Highest peer_rank first
    SORT_BY_RELIABILITY,      // Fewest failures (hashfails + failcount) first
}

<*
 Filter options for peer display.
 All criteria are AND-ed together.
*>
struct PeerFilter
{
    char state_flags;                 // Bitfield of PeerStateFlag values to include
    bool active_only;                 // Only peers with download/upload speed > 0
    bool seeds_only;                  // Only seeds (100% complete)
    bool leechers_only;               // Only leechers (< 100%)
    bool filter_by_source;            // Apply source filter?
    common::PeerSource source_filter; // Which sources (TRACKER, DHT, PEX) - only used if filter_by_source is true
    int min_completion_percent;       // Minimum % complete (0-100)
    int max_failures;                 // Maximum hashfails + failcount
}

<*
 Create default filter that shows all peers.

 @return "Filter with no restrictions"
*>
fn PeerFilter create_default_filter() @public
{
    PeerFilter filter;
    filter.state_flags = (char)PeerStateFlag.ALL;  // Show all states
    filter.active_only = false;
    filter.seeds_only = false;
    filter.leechers_only = false;
    filter.filter_by_source = false;  // Don't filter by source by default
    filter.source_filter = common::PeerSource.TRACKER;  // Unused when filter_by_source is false
    filter.min_completion_percent = 0;
    filter.max_failures = 999;
    return filter;
}

// Callbacks
alias PeerConnectedCallback = fn void(peer_connection::PeerConnection* peer,
                                       common::Ipv4Addr ip, ushort port, void* user_data);
alias PeerMessageCallback = fn void(peer_connection::PeerConnection* peer,
                                     peer_wire::Message* msg,
                                     common::Ipv4Addr ip, ushort port, void* user_data);
alias PeerDisconnectedCallback = fn void(common::Ipv4Addr ip, ushort port,
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
    bool shutting_down;             // Flag to prevent reconnection during cleanup

    // Torrent info (needed for peer connections)
    common::InfoHash info_hash;   // Torrent info hash
    common::PeerId our_peer_id;   // Our peer ID

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
fn isz find_peer_index(PeerPool* pool, common::Ipv4Addr ip, ushort port)
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
                    common::InfoHash* info_hash,
                    common::PeerId* our_peer_id) @public
{
    PeerPool* pool = mem::new(PeerPool);
    pool.loop = loop;
    pool.config = config;

    // Copy info hash and peer ID
    pool.info_hash[..] = (*info_hash)[..];
    pool.our_peer_id[..] = (*our_peer_id)[..];

    // Initialize empty peer list
    pool.peers = {};

    // Initialize empty candidate cache (Phase 2)
    pool.candidate_cache = {};

    // Initialize connection count (Phase 3)
    pool.num_active_connections = 0;
    pool.shutting_down = false;

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

    // Set shutdown flag to prevent reconnection attempts during cleanup
    pool.shutting_down = true;

    // Clear callbacks to prevent user notifications during cleanup
    pool.on_connected = null;
    pool.on_message = null;
    pool.on_disconnected = null;

    // Disconnect all active connections (Phase 3)
    pool.disconnect_all();

    // Free all peer structures
    for (usz i = 0; i < pool.peers.len; i++)
    {
        // Free bitfield if allocated
        if (pool.peers[i].pieces.data.len > 0)
        {
            bitfield::free(&pool.peers[i].pieces);
        }
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

    // Sort cache by rank (highest first) using quicksort (O(n log n))
    sort::quicksort(self.candidate_cache, &compare_peers_by_rank);
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
 Internal bridge: Called when peer_connection state changes.
 Routes to user's on_connected/on_disconnected callbacks with IP/port.
*>
fn void on_peer_state_internal(peer_connection::PeerConnection* conn,
                                 peer_connection::PeerState state,
                                 void* user_data)
{
    PeerPool* pool = (PeerPool*)user_data;

    // Find which peer this connection belongs to
    TorrentPeer* peer_info = null;
    for (usz i = 0; i < pool.peers.len; i++)
    {
        if (pool.peers[i].connection == conn)
        {
            peer_info = pool.peers[i];
            break;
        }
    }

    if (!peer_info) return;

    switch (state)
    {
        case peer_connection::PeerState.READY:
            // Peer handshake complete - notify user
            if (pool.on_connected)
            {
                pool.on_connected(conn, peer_info.ip, peer_info.port, pool.user_data);
            }

            // Broadcast this new peer to all other connected peers via PEX
            broadcast_pex_update(pool, peer_info.ip, peer_info.port, true);
            return;

        case peer_connection::PeerState.CLOSED:
            // Peer disconnected - update state and notify user
            peer_info.state = PeerState.DISCONNECTED;
            pool.num_active_connections--;

            // Don't call close() from here - it causes recursion since close()
            // triggers this callback. The peer will be freed by disconnect_all()
            // or when the connection object is freed.
            peer_info.connection = null;

            if (pool.on_disconnected)
            {
                pool.on_disconnected(peer_info.ip, peer_info.port, true, pool.user_data);
            }

            // Broadcast this peer drop to all other connected peers via PEX
            broadcast_pex_update(pool, peer_info.ip, peer_info.port, false);

            // Try to replace this connection (unless we're shutting down)
            if (!pool.shutting_down)
            {
                pool.connect_to_peers();
            }
            return;

        default:
            // Ignore other states (CONNECTING, HANDSHAKING)
            return;
    }
}

<*
 Internal bridge: Called when peer_connection receives message.
 Routes to user's on_message callback with IP/port added.
*>
fn void on_peer_message_internal(peer_connection::PeerConnection* conn,
                                   peer_wire::Message* msg,
                                   void* user_data)
{
    PeerPool* pool = (PeerPool*)user_data;

    // Find which peer this connection belongs to
    TorrentPeer* peer_info = null;
    for (usz i = 0; i < pool.peers.len; i++)
    {
        if (pool.peers[i].connection == conn)
        {
            peer_info = pool.peers[i];
            break;
        }
    }

    if (!peer_info) return;

    // Forward to user callback with IP/port
    if (pool.on_message)
    {
        pool.on_message(conn, msg, peer_info.ip, peer_info.port, pool.user_data);
    }
}

<*
 Internal bridge: Called when peer_connection receives PEX message.
 Adds peers to pool automatically.
*>
fn void on_pex_message_internal(peer_connection::PeerConnection* conn,
                                  pex::PexMessage* pex_msg,
                                  void* user_data)
{
    PeerPool* pool = (PeerPool*)user_data;

    // Add new peers from PEX to our pool
    if (pex_msg.added.len > 0)
    {
        logger::logf(logger::LogLevel.INFO, "[PEX] Received %d peers from peer",
                     pex_msg.added.len);
        pool.add_peers_from_pex(pex_msg.added);
    }

    // Note: We ignore dropped peers for now - we'll let our own connection
    // tracking determine when peers are actually disconnected
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
 @param source : "Peer discovery source"
 @param pex_flags : "PEX flags (optional, only used for PEX peers)"
*>
fn void PeerPool.add_peer(&self, common::Ipv4Addr ip, ushort port, common::PeerSource source, char pex_flags = 0) @public
{
    // Check if peer already exists
    isz idx = find_peer_index(self, ip, port);
    if (idx >= 0)
    {
        // Already exists, prioritize TRACKER source over others
        if (source == common::PeerSource.TRACKER && self.peers[idx].source != common::PeerSource.TRACKER)
        {
            self.peers[idx].source = common::PeerSource.TRACKER;
        }
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
    peer.handshake_ok = false;
    peer.received_bitfield = false;
    peer.source = source;

    // Initialize peer_id to zeros
    peer.peer_id = {};

    // Initialize empty bitfield (will be set when we receive BITFIELD message)
    peer.pieces = {};

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
 Batch add peers from any source.

 @param peers : "Peers to add"
 @param source : "Peer discovery source"
*>
fn void PeerPool.add_peers(&self, common::Peer[] peers, common::PeerSource source) @public
{
    for (usz i = 0; i < peers.len; i++)
    {
        // Skip peers with invalid port 0
        if (peers[i].port == 0) continue;

        self.add_peer(peers[i].ip, peers[i].port, source);
    }

    // Update candidate cache after batch add
    self.update_candidate_cache();
}

<*
 Batch add peers from tracker response.
 Convenience wrapper for add_peers() with TRACKER source.

 @param peers : "Peers from tracker"
*>
fn void PeerPool.add_peers_from_tracker(&self, common::Peer[] peers) @public
{
    self.add_peers(peers, common::PeerSource.TRACKER);
}

<*
 Batch add peers from DHT get_peers response.
 Convenience wrapper for add_peers() with DHT source.

 @param peers : "Peers from DHT"
*>
fn void PeerPool.add_peers_from_dht(&self, common::Peer[] peers) @public
{
    self.add_peers(peers, common::PeerSource.DHT);
}

<*
 Find peer by IP:port.

 @param ip : "IPv4 address"
 @param port : "Port number"
 @return "Peer if found, fault if not found"
*>
fn TorrentPeer*? PeerPool.find_peer(&self, common::Ipv4Addr ip, ushort port) @public
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

    // Free bitfield if allocated
    if (self.peers[idx].pieces.data.len > 0)
    {
        bitfield::free(&self.peers[idx].pieces);
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
 Disconnect a specific peer by IP:port (Phase 3).

 @param ip : "Peer IP address"
 @param port : "Peer port"
*>
fn void PeerPool.disconnect_peer(&self, common::Ipv4Addr ip, ushort port) @public
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
 Gracefully disconnect all active peer connections.

 Sends NOT_INTERESTED and final PEX messages to all connected peers before
 closing connections, allowing proper protocol shutdown.
*>
fn void PeerPool.disconnect_all_gracefully(&self) @public
{
    // Count peers for logging
    usz connected_count = 0;
    for (usz i = 0; i < self.peers.len; i++)
    {
        if (self.peers[i].connection) connected_count++;
    }

    if (connected_count > 0)
    {
        logger::logf(logger::LogLevel.INFO,
                     "[Shutdown] Gracefully disconnecting from %d peer%s",
                     connected_count, connected_count == 1 ? "" : "s");
    }

    // Gracefully disconnect each peer
    for (usz i = 0; i < self.peers.len; i++)
    {
        if (self.peers[i].connection)
        {
            peer_connection::graceful_close(self.peers[i].connection);
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

        // Connect to peer with internal bridge callbacks
        // The bridge callbacks add IP/port and route to user callbacks
        peer_connection::PeerConnection*? conn_opt = peer_connection::connect(
            self.loop,
            ip_str,
            peer.port,
            self.info_hash,
            self.our_peer_id,
            &on_peer_message_internal,  // Bridge: adds IP/port
            &on_peer_state_internal,    // Bridge: adds IP/port
            &on_pex_message_internal,   // Bridge: adds PEX peers to pool
            (PeerPool*)self              // Pass pool as user_data for bridge
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

        // Note: on_connected callback will be called from bridge when peer reaches READY state

        // Update candidate cache to remove this peer from candidates
        self.update_candidate_cache();
    }
}

// ============================================================================
// PEX (Peer Exchange) Integration
// ============================================================================

<*
 Broadcast a peer addition/drop to all connected peers via PEX.

 BEP 11: We should notify peers about new peers we connect to and peers
 that disconnect. This function queues the peer update for all connected
 peers that support PEX.

 Security: Does not broadcast private/reserved IP addresses.

 @param pool : "Peer pool"
 @param ip : "IP address of the peer to broadcast"
 @param port : "Port of the peer to broadcast"
 @param added : "True if peer was added, false if dropped"
*>
fn void broadcast_pex_update(PeerPool* pool, common::Ipv4Addr ip, ushort port, bool added) @private
{
    // Security: Don't broadcast private/reserved IPs
    if (pex::is_private_or_reserved_ip(ip))
    {
        return;
    }

    // Validate port
    if (port == 0)
    {
        return;
    }

    // Determine PEX flags if this is an added peer
    char flags = 0;
    if (added)
    {
        // Check if the added peer is a seed
        TorrentPeer*? peer_opt = pool.find_peer(ip, port);
        if (catch err = peer_opt)
        {
            // Peer not found, use default flags
            flags = 0;
        }
        else
        {
            TorrentPeer* peer = peer_opt;
            if (peer.seed)
            {
                flags |= (char)pex::PexFlags.SEED;
            }
            // TODO: Add other flags based on peer capabilities
            // - PREFERS_ENCRYPTION
            // - SUPPORTS_UTP
            // - SUPPORTS_HOLEPUNCH
            // - REACHABLE
        }
    }

    // Broadcast to all connected peers that support PEX
    usz notified_count = 0;
    for (usz i = 0; i < pool.peers.len; i++)
    {
        TorrentPeer* peer = pool.peers[i];

        // Skip if not connected or no connection object
        if (peer.state != PeerState.CONNECTED || !peer.connection)
        {
            continue;
        }

        // Don't broadcast a peer to itself
        if (peer.ip[0] == ip[0] && peer.ip[1] == ip[1] &&
            peer.ip[2] == ip[2] && peer.ip[3] == ip[3] &&
            peer.port == port)
        {
            continue;
        }

        // Queue the PEX update for this peer
        if (added)
        {
            peer_connection::add_pex_peer(peer.connection, ip, port, flags);
        }
        else
        {
            peer_connection::drop_pex_peer(peer.connection, ip, port);
        }
        notified_count++;
    }

    if (notified_count > 0)
    {
        logger::logf(logger::LogLevel.INFO, "[PEX] Queued peer %d.%d.%d.%d:%d (%s) for %d connected peers",
                     ip[0], ip[1], ip[2], ip[3], port,
                     added ? "added" : "dropped",
                     notified_count);
    }
}

<*
 Send queued PEX messages to all connected peers.

 Should be called periodically (e.g., every 60 seconds) to send accumulated
 PEX updates while respecting rate limits.
*>
fn void PeerPool.send_pex_updates(&self) @public
{
    for (usz i = 0; i < self.peers.len; i++)
    {
        TorrentPeer* peer = self.peers[i];

        if (peer.state == PeerState.CONNECTED && peer.connection)
        {
            // send_pex_message handles rate limiting internally
            // Ignore any errors (peer may have disconnected, etc.)
            (void)peer_connection::send_pex_message(peer.connection);
        }
    }
}

<*
 Send keepalive messages to all connected peers.

 Keepalive messages (BEP 3) are required to maintain connections during idle periods.
 Most BitTorrent clients will disconnect if they don't receive any message for 2-3 minutes.

 This should be called periodically (every ~120 seconds) via a timer.
*>
fn void PeerPool.send_keepalives(&self) @public
{
    for (usz i = 0; i < self.peers.len; i++)
    {
        TorrentPeer* peer = self.peers[i];

        if (peer.state == PeerState.CONNECTED && peer.connection)
        {
            // Ignore any errors (peer may have disconnected, etc.)
            (void)peer.connection.send_keepalive();
        }
    }
}

<*
 Process PEX peers received from a peer and add them to our pool.

 This should be called when we receive a PEX message from a peer.
 New peers are added to the pool as DISCOVERED peers.

 Security: Validates all peers before adding (rejects private IPs, invalid ports).

 @param pex_peers : "Array of peers from PEX message"
*>
fn void PeerPool.add_peers_from_pex(&self, pex::PexPeer[] pex_peers) @public
{
    usz added_count = 0;
    usz rejected_count = 0;

    foreach (pex_peer : pex_peers)
    {
        // Security: Validate peer before adding
        if (!pex::is_valid_pex_peer(&pex_peer))
        {
            rejected_count++;
            continue;
        }

        // Add peer to pool (will be deduplicated if already exists)
        // Use PeerSource.PEX and pass flags for seed detection
        self.add_peer(pex_peer.ip, pex_peer.port, common::PeerSource.PEX, pex_peer.flags);
        added_count++;

        // If the peer is marked as a seed, update our records
        if ((pex_peer.flags & (char)pex::PexFlags.SEED) != 0)
        {
            TorrentPeer*? peer_opt = self.find_peer(pex_peer.ip, pex_peer.port);
            if (catch err = peer_opt)
            {
                // Peer not found (shouldn't happen since we just added it)
                continue;
            }
            TorrentPeer* peer = peer_opt;
            peer.seed = true;
        }
    }

    // Log PEX peer additions
    if (added_count > 0 || rejected_count > 0)
    {
        logger::logf(logger::LogLevel.INFO, "[PEX] Added %d peers, rejected %d invalid peers",
                     added_count, rejected_count);
    }

    // After adding new peers, update candidate cache and try to connect
    if (added_count > 0)
    {
        self.update_candidate_cache();
        self.connect_to_peers();
    }
}

<*
 Helper function to recalculate and update a single peer's rank.

 @param peer : "Peer to update rank for"
*>
fn void update_peer_rank(PeerPool* pool, TorrentPeer* peer)
{
    peer.peer_rank = calculate_peer_rank(pool, peer);
}

<*
 Update peer statistics after data transfer.

 Updates the download and upload byte counters for a peer and recalculates
 its rank. Should be called periodically during active transfers.

 @param ip : "Peer IP address"
 @param port : "Peer port"
 @param bytes_downloaded : "Bytes downloaded from this peer"
 @param bytes_uploaded : "Bytes uploaded to this peer"
 @return "Fault if peer not found"
*>
fn fault? PeerPool.update_peer_stats(&self, common::Ipv4Addr ip, ushort port,
                                      ulong bytes_downloaded, ulong bytes_uploaded) @public
{
    TorrentPeer*? peer_opt = self.find_peer(ip, port);
    if (catch err = peer_opt)
    {
        return err?;
    }

    TorrentPeer* peer = peer_opt;

    // Update statistics
    peer.prev_amount_download = bytes_downloaded;
    peer.prev_amount_upload = bytes_uploaded;

    // Recalculate rank based on new statistics
    update_peer_rank((PeerPool*)self, peer);

    // Update candidate cache to reflect new ranking
    self.update_candidate_cache();

    return {};
}

<*
 Mark a peer as having sent a bad piece (hash verification failed).

 Increments the hash failure counter and penalizes the peer's rank.
 Multiple hash failures will significantly reduce peer priority.

 @param ip : "Peer IP address"
 @param port : "Peer port"
 @return "Fault if peer not found"
*>
fn fault? PeerPool.mark_hash_failure(&self, common::Ipv4Addr ip, ushort port) @public
{
    TorrentPeer*? peer_opt = self.find_peer(ip, port);
    if (catch err = peer_opt)
    {
        return err?;
    }

    TorrentPeer* peer = peer_opt;

    // Increment hash failure counter
    peer.hashfails++;

    // Debug output disabled for logging mode
    // io::printfn("  [POOL] Peer %d.%d.%d.%d:%d marked with hash failure (total: %d)",
    //             peer.ip[0], peer.ip[1], peer.ip[2], peer.ip[3], peer.port, peer.hashfails);

    // Recalculate rank with penalty (-30 per hash failure)
    update_peer_rank((PeerPool*)self, peer);

    // Update candidate cache to reflect new ranking
    self.update_candidate_cache();

    return {};
}

<*
 Mark a peer as a seed (has all pieces).

 Sets the seed flag and boosts the peer's rank. Seed peers are prioritized
 for connections as they can provide any piece we need.

 @param ip : "Peer IP address"
 @param port : "Peer port"
 @return "Fault if peer not found"
*>
fn fault? PeerPool.mark_peer_seed(&self, common::Ipv4Addr ip, ushort port) @public
{
    TorrentPeer*? peer_opt = self.find_peer(ip, port);
    if (catch err = peer_opt)
    {
        return err?;
    }

    TorrentPeer* peer = peer_opt;

    // Mark as seed
    peer.seed = true;

    // Debug output disabled for logging mode
    // io::printfn("  [POOL] Peer %d.%d.%d.%d:%d marked as seed",
    //             peer.ip[0], peer.ip[1], peer.ip[2], peer.ip[3], peer.port);

    // Recalculate rank with seed boost (+50)
    update_peer_rank((PeerPool*)self, peer);

    // Update candidate cache to reflect new ranking
    self.update_candidate_cache();

    return {};
}

// ============================================================================
// Peer Filtering and Sorting
// ============================================================================

// Thread-local sort order for comparison function
// Note: Not thread-safe if multiple threads sort simultaneously
// For better thread safety, consider using a mutex or thread-local storage
tlocal PeerSortOrder current_sort_order;

<*
 Check if a peer passes the filter criteria.
 Helper function for get_peer_display_info_filtered().
*>
fn bool peer_passes_filter(TorrentPeer* peer, PeerFilter* filter)
{
    // Check state filter using bitflags
    // Convert peer state enum to corresponding bit position
    char peer_state_flag = (char)(1 << (char)peer.state);
    if ((filter.state_flags & peer_state_flag) == 0) return false;

    // Check seed/leecher filter
    if (filter.seeds_only && !peer.seed) return false;
    if (filter.leechers_only && peer.seed) return false;

    // Check source filter
    if (filter.filter_by_source && peer.source != filter.source_filter) return false;

    // Check completion percentage
    float completion = 0.0;
    if (peer.seed)
    {
        completion = 100.0;
    }
    else if (peer.pieces.data.len > 0)
    {
        usz set_bits = 0;
        for (usz i = 0; i < peer.pieces.num_pieces; i++)
        {
            if (peer.pieces.has_piece(i)) set_bits++;
        }
        completion = peer.pieces.num_pieces > 0 ?
            (float)set_bits * 100.0 / (float)peer.pieces.num_pieces : 0.0;
    }
    if (completion < (float)filter.min_completion_percent) return false;

    // Check failure count
    int total_failures = (int)(peer.hashfails + peer.failcount);
    if (total_failures > filter.max_failures) return false;

    // Check active_only (would need speed tracking - for now always pass)
    // TODO: Add actual speed tracking to enable this filter
    // if (filter.active_only && download_speed == 0.0 && upload_speed == 0.0) return false;

    return true;
}

<*
 Compare two peers for display sorting.
 Uses current_sort_order from thread-local storage.
 Returns: negative if a < b, 0 if equal, positive if a > b
*>
fn int compare_peers_for_display(TorrentPeer* a, TorrentPeer* b)
{
    switch (current_sort_order)
    {
        case PeerSortOrder.SORT_BY_STATE:
            // Connected > Connecting > Candidate > Discovered > Disconnected > Banned
            // Map states to priority (higher number = higher priority)
            int priority_a, priority_b;
            switch (a.state)
            {
                case PeerState.CONNECTED: priority_a = 6;
                case PeerState.CONNECTING: priority_a = 5;
                case PeerState.CANDIDATE: priority_a = 4;
                case PeerState.DISCOVERED: priority_a = 3;
                case PeerState.DISCONNECTED: priority_a = 2;
                case PeerState.BANNED: priority_a = 1;
            }
            switch (b.state)
            {
                case PeerState.CONNECTED: priority_b = 6;
                case PeerState.CONNECTING: priority_b = 5;
                case PeerState.CANDIDATE: priority_b = 4;
                case PeerState.DISCOVERED: priority_b = 3;
                case PeerState.DISCONNECTED: priority_b = 2;
                case PeerState.BANNED: priority_b = 1;
            }
            if (priority_a != priority_b) return priority_b - priority_a;  // Higher priority first
            // Tie-break by rank
            return b.peer_rank - a.peer_rank;

        case PeerSortOrder.SORT_BY_DOWNLOADED:
            if (a.prev_amount_download > b.prev_amount_download) return -1;
            if (a.prev_amount_download < b.prev_amount_download) return 1;
            return 0;

        case PeerSortOrder.SORT_BY_DOWNLOAD_SPEED:
            // TODO: Add actual speed tracking
            // For now, sort by downloaded bytes as proxy
            if (a.prev_amount_download > b.prev_amount_download) return -1;
            if (a.prev_amount_download < b.prev_amount_download) return 1;
            return 0;

        case PeerSortOrder.SORT_BY_UPLOAD_SPEED:
            // TODO: Add actual speed tracking
            // For now, sort by uploaded bytes as proxy
            if (a.prev_amount_upload > b.prev_amount_upload) return -1;
            if (a.prev_amount_upload < b.prev_amount_upload) return 1;
            return 0;

        case PeerSortOrder.SORT_BY_COMPLETION:
            // Seeds first, then by completion %
            if (a.seed && !b.seed) return -1;
            if (!a.seed && b.seed) return 1;
            // Both same seed status, compare piece count
            usz a_pieces = 0;
            usz b_pieces = 0;
            if (a.pieces.data.len > 0)
            {
                for (usz i = 0; i < a.pieces.num_pieces; i++)
                {
                    if (a.pieces.has_piece(i)) a_pieces++;
                }
            }
            if (b.pieces.data.len > 0)
            {
                for (usz i = 0; i < b.pieces.num_pieces; i++)
                {
                    if (b.pieces.has_piece(i)) b_pieces++;
                }
            }
            if (a_pieces > b_pieces) return -1;
            if (a_pieces < b_pieces) return 1;
            return 0;

        case PeerSortOrder.SORT_BY_RANK:
            return b.peer_rank - a.peer_rank;  // Higher rank first

        case PeerSortOrder.SORT_BY_RELIABILITY:
            int a_failures = (int)(a.hashfails + a.failcount);
            int b_failures = (int)(b.hashfails + b.failcount);
            return a_failures - b_failures;  // Fewer failures first
    }

    return 0;  // Shouldn't reach here
}

<*
 Build PeerDisplayInfo for a single peer.
 Helper function to avoid code duplication.
*>
fn PeerDisplayInfo build_display_info(TorrentPeer* peer)
{
    PeerDisplayInfo info;

    // Format IP address
    DString ip_str;
    ip_str.appendf("%d.%d.%d.%d",
                  peer.ip[0], peer.ip[1], peer.ip[2], peer.ip[3]);
    info.ip_address = ip_str.copy_str(mem);
    info.port = peer.port;

    // Parse client name from peer_id
    if (peer.peer_id[0] == '-' && peer.peer_id.len >= 8)
    {
        char[2] client_code = { peer.peer_id[1], peer.peer_id[2] };
        char[4] version_str = { peer.peer_id[3], peer.peer_id[4], peer.peer_id[5], peer.peer_id[6] };

        DString client_name;
        if (client_code[0] == 'U' && client_code[1] == 'T')
        {
            client_name.appendf("μTorrent %c.%c.%c.%c",
                               version_str[0], version_str[1], version_str[2], version_str[3]);
        }
        else if (client_code[0] == 'l' && client_code[1] == 't')
        {
            client_name.appendf("libtorrent %c.%c.%c",
                               version_str[0], version_str[1], version_str[2]);
        }
        else if (client_code[0] == 'D' && client_code[1] == 'E')
        {
            client_name.appendf("Deluge %c.%c.%c",
                               version_str[0], version_str[1], version_str[2]);
        }
        else
        {
            client_name.appendf("%c%c %c.%c.%c.%c",
                               client_code[0], client_code[1],
                               version_str[0], version_str[1], version_str[2], version_str[3]);
        }
        info.client = client_name.copy_str(mem);
    }
    else
    {
        info.client = "Unknown".copy(mem);
    }

    // Calculate percent complete
    if (peer.seed)
    {
        info.percent_complete = 100.0;
    }
    else if (peer.pieces.data.len > 0)
    {
        usz set_bits = 0;
        for (usz i = 0; i < peer.pieces.num_pieces; i++)
        {
            if (peer.pieces.has_piece(i)) set_bits++;
        }
        info.percent_complete = peer.pieces.num_pieces > 0 ?
            (float)set_bits * 100.0 / (float)peer.pieces.num_pieces : 0.0;
    }
    else
    {
        info.percent_complete = 0.0;
    }

    // Speeds - TODO: track actual rates
    info.download_speed = 0.0;
    info.upload_speed = 0.0;

    // State as string
    switch (peer.state)
    {
        case PeerState.DISCOVERED:
            info.state = "Discovered".copy(mem);
        case PeerState.CANDIDATE:
            info.state = "Candidate".copy(mem);
        case PeerState.CONNECTING:
            info.state = "Connecting".copy(mem);
        case PeerState.CONNECTED:
            info.state = "Connected".copy(mem);
        case PeerState.DISCONNECTED:
            info.state = "Disconnected".copy(mem);
        case PeerState.BANNED:
            info.state = "Banned".copy(mem);
    }

    return info;
}

<*
 Get filtered and sorted peer display information.
 Applies filter criteria and sorts peers by specified order.

 @param filter: "Filter criteria (use create_default_filter() for no filtering)"
 @param sort_order: "Sort order for results"
 @return "Array of peer display info (caller must free)"
*>
fn PeerDisplayInfo[] PeerPool.get_peer_display_info_filtered(&self, PeerFilter* filter,
                                                               PeerSortOrder sort_order) @public => @pool()
{
    if (self.peers.len == 0)
    {
        PeerDisplayInfo[] empty;
        return empty;
    }

    // First pass: filter peers and build array of pointers
    // Use temp allocator since this is short-lived
    TorrentPeer*[] filtered_peers = mem::temp_array(TorrentPeer*, self.peers.len);

    usz filtered_count = 0;
    for (usz i = 0; i < self.peers.len; i++)
    {
        if (peer_passes_filter(self.peers[i], filter))
        {
            filtered_peers[filtered_count] = self.peers[i];
            filtered_count++;
        }
    }

    if (filtered_count == 0)
    {
        PeerDisplayInfo[] empty;
        return empty;
    }

    // Resize array to actual filtered count
    TorrentPeer*[] peers_to_sort = filtered_peers[:filtered_count];

    // Set thread-local sort order for comparison function
    current_sort_order = sort_order;

    // Sort the filtered peers
    sort::quicksort(peers_to_sort, fn int(TorrentPeer** a, TorrentPeer** b) => compare_peers_for_display(*a, *b));

    // Build display info array (uses mem since it's returned to caller)
    PeerDisplayInfo[] info_array = mem::new_array(PeerDisplayInfo, filtered_count);
    for (usz i = 0; i < filtered_count; i++)
    {
        info_array[i] = build_display_info(peers_to_sort[i]);
    }

    return info_array;
    // Note: filtered_peers is automatically freed by @pool() when function exits
}

<*
 Get peer display information for GUI.
 Returns array of PeerDisplayInfo structs allocated with mem allocator.
 Caller must free the array.

 @return "Array of peer display info"
*>
fn PeerDisplayInfo[] PeerPool.get_peer_display_info(&self) @public
{
    // Use filtered version with default filter and default sort order
    PeerFilter filter = create_default_filter();
    return self.get_peer_display_info_filtered(&filter, PeerSortOrder.SORT_BY_STATE);
}
