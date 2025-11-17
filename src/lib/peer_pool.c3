module libtorrent::peer_pool;

import libtorrent::common;
import async::event_loop;
import libtorrent::tracker;
import libtorrent::dht_get_peers;
import libtorrent::peer_connection;
import libtorrent::network;
import libtorrent::network::tcp;
import libtorrent::peer_wire;
import libtorrent::bitfield;
import libtorrent::pex;
import std::core::log;
import std::io;
import std::time;
import std::sort;
import std::collections::map;
import std::core::mem::allocator;

<*
 Peer Pool - Async Peer Management
 ==================================
 Manages peer discovery, connection lifecycle, and quality tracking.
 Inspired by libtorrent's peer_list class.

 This module implements a per-torrent peer manager that:
 - Stores discovered peers (up to max_peerlist_size, default 1000)
 - Manages active connections (up to max_active_connections, default 25)
 - Deduplicates peers by IP:port using HashMap (O(1) operations)
 - Ranks peers by quality
 - Automatically retries/bans peers based on failures

 Implementation Details:
 - Uses HashMap{SocketAddress, TorrentPeer*} for O(1) peer operations
 - HashMap uses heap allocation (must support resize/free of buckets)
 - TorrentPeer structs and their data use arena allocation (bulk cleanup)
 - Automatic deduplication via SocketAddress.hash() and equals()
 - Candidate cache maintains sorted array for connection prioritization
 - All iterations use HashMap @each macro for safe enumeration

 Performance Characteristics:
 - Peer lookup: O(1) vs O(log n) with sorted array
 - Peer insertion: O(1) vs O(n) with sorted array
 - Peer removal: O(1) vs O(n) with sorted array
 - Candidate ranking: O(n log n) sorting maintained separately
*>

// Faults
faultdef PEER_NOT_FOUND;

// Transport type selection
enum TransportType : char
{
    TCP,  // Traditional TCP connections
    UTP   // μTP (BEP 29) connections
}

// Configuration
struct PeerPoolConfig
{
    usz max_peerlist_size;      // Default: 1000 (libtorrent default)
    usz max_active_connections; // Default: 25
    usz max_failcount;          // Default: 3 (ban after 3 failures)
    uint min_reconnect_time;    // Default: 60 seconds
    TransportType transport;    // Default: TCP (μTP when fully implemented)
}

// Default configuration
const PeerPoolConfig DEFAULT_CONFIG = {
    .max_peerlist_size = 1000,
    .max_active_connections = 25,
    .max_failcount = 3,
    .min_reconnect_time = 60,
    .transport = TransportType.TCP
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
    // Identity (BEP 7: Dual-stack IPv4/IPv6 support)
    common::SocketAddress addr;  // Peer address (IPv4 or IPv6)
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
    bool upload_only;            // BEP 21: Is this peer a partial seed (upload-only)?
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

// Callbacks (BEP 7: dual-stack IPv4/IPv6)
alias PeerConnectedCallback = fn void(peer_connection::PeerConnection* peer,
                                       common::SocketAddress* addr, void* user_data);
alias PeerMessageCallback = fn void(peer_connection::PeerConnection* peer,
                                     peer_wire::Message* msg,
                                     common::SocketAddress* addr, void* user_data);
alias PeerDisconnectedCallback = fn void(common::SocketAddress* addr,
                                          bool was_error, void* user_data);

// Main peer pool
struct PeerPool
{
    event_loop::EventLoop* loop;  // Event loop for async operations
    PeerPoolConfig config;        // Configuration

    // Memory management
    DynamicArenaAllocator arena;  // Arena allocator for pool-lifetime allocations

    // Storage
    // HashMap provides O(1) deduplication, insertion, lookup, and deletion
    // Uses heap allocator (not arena) because HashMap needs to resize/free buckets
    HashMap{common::SocketAddress, TorrentPeer*} peers;  // Main peer storage (deduplicated)

    // Phase 2: Connection management
    usz num_active_connections;     // Current number of active connections
    bool shutting_down;             // Flag to prevent reconnection during cleanup

    // Torrent info (needed for peer connections)
    common::InfoHash info_hash;   // Torrent info hash
    common::PeerId our_peer_id;   // Our peer ID
    bool is_private;              // BEP 27: Private torrent flag (DHT/PEX disabled)
    bool upload_only;             // BEP 21: Partial seed mode (upload-only, no downloads)

    // Callbacks (user-provided)
    PeerConnectedCallback on_connected;       // Called when peer connects successfully
    PeerMessageCallback on_message;           // Called when peer sends message
    PeerDisconnectedCallback on_disconnected; // Called when peer disconnects
    peer_connection::MetadataCallback on_metadata; // Called when metadata message received (BEP 9)
    void* user_data;              // User data passed to callbacks
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

    // Add deterministic randomness based on IP (BEP 7: dual-stack)
    // This ensures symmetric priority (both peers rank each other similarly)
    // and provides variety in initial connection attempts
    if (!peer.addr.addr.is_ipv6)
    {
        rank += ((int)peer.addr.addr.ipv4.d * 7) % 20;  // Last byte of IPv4
    }
    else
    {
        char* ipv6_bytes = (char*)&peer.addr.addr.ipv6;
        rank += ((int)ipv6_bytes[15] * 7) % 20;  // Use last byte of IPv6
    }

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
 @param is_private : "BEP 27: Private torrent flag (disables DHT/PEX)"
 @return "Initialized peer pool"
*>
fn PeerPool* create(event_loop::EventLoop* loop,
                    PeerPoolConfig config,
                    common::InfoHash* info_hash,
                    common::PeerId* our_peer_id,
                    bool is_private) @public
{
    PeerPool* pool = mem::new(PeerPool);
    pool.loop = loop;
    pool.config = config;

    // Copy info hash and peer ID
    pool.info_hash[..] = (*info_hash)[..];
    pool.our_peer_id[..] = (*our_peer_id)[..];
    pool.is_private = is_private;
    pool.upload_only = false;  // BEP 21: Start in normal download mode

    // Initialize arena allocator with 64KB pages
    // Will automatically grow as needed for peer storage
    pool.arena.init(mem, 64 * 1024);

    // Initialize HashMap with heap allocator (NOT arena!)
    // HashMap needs to free/reallocate buckets during resize, which is incompatible with arena.
    // Only TorrentPeer structs and their data use arena.
    pool.peers.init(mem);

    // Initialize connection count (Phase 2)
    pool.num_active_connections = 0;
    pool.shutting_down = false;

    // No callbacks yet
    pool.on_connected = null;
    pool.on_message = null;
    pool.on_disconnected = null;
    pool.on_metadata = null;
    pool.user_data = null;

    return pool;
}

<*
 Free peer pool and all associated resources.

 Cleanup order:
 1. Disconnect all connections
 2. Free HashMap (heap-allocated, needs manual free)
 3. Free arena (bulk free for all TorrentPeer structs, bitfields, candidate cache)
*>
fn void PeerPool.free(&self) @public
{
    // Set shutdown flag to prevent reconnection attempts during cleanup
    self.shutting_down = true;

    // Clear callbacks to prevent user notifications during cleanup
    self.on_connected = null;
    self.on_message = null;
    self.on_disconnected = null;

    // Note: By the time free() is called, the shutdown sequence has already:
    // 1. Called disconnect_all_gracefully() in main.c3 which called .close() on all PeerConnections
    // 2. Called loop.close_all_handles() which drained all TCP close callbacks
    // 3. TCP close callbacks freed the TcpConnection* wrappers (tcp.c3:366)
    //
    // With reference counting, PeerConnection* structs should already be freed
    // (refcount reached 0 after all async callbacks completed). However, we still
    // ensure any remaining connections are closed (e.g., connections still in progress).
    self.peers.@each(; common::SocketAddress addr, TorrentPeer* peer)
    {
        if (peer.connection && !peer.connection.is_closed)
        {
            // Call .close() to decrement owner refcount and free if no pending operations
            peer.connection.close();
            // Note: connection may be freed by close() if refcount reached 0
        }
    };

    // Free HashMap (heap-allocated buckets and entries)
    self.peers.free();

    // Free arena (all TorrentPeer structs, bitfields, candidate cache)
    self.arena.free();

    // Free pool structure itself (allocated from global heap in create())
    std::core::mem::free(self);
}

<*
 Set upload-only mode (BEP 21: Partial Seeds).
 When enabled, new peer connections will be told we're not downloading.
 Existing connections are not affected.

 @param upload_only: "True to enter upload-only mode (partial seed), false for normal mode"
*>
fn void PeerPool.set_upload_only(&self, bool upload_only) @public
{
    self.upload_only = upload_only;
}

<*
 Pick the best candidate peer to connect to.

 Iterates through all peers in the pool and returns the highest-ranked eligible peer.
 Only considers peers in DISCOVERED or DISCONNECTED states without active connections.

 Performance: O(N) where N is total peer count. For typical peer counts (50-200),
 this is negligible (~200-800 comparisons, <1μs on modern CPUs).

 @return "Best peer to connect to, or PEER_NOT_FOUND fault"
*>
fn TorrentPeer*? PeerPool.pick_best_candidate(&self) @public
{
    TorrentPeer* best = null;
    int best_rank = -999999;

    // Direct iteration - O(N) but simple and correct
    self.peers.@each(; common::SocketAddress addr, TorrentPeer* peer)
    {
        // Only consider eligible states (DISCOVERED or DISCONNECTED)
        if (peer.state == PeerState.DISCOVERED ||
            peer.state == PeerState.DISCONNECTED)
        {
            // Safety: Skip if already has connection (should never happen for eligible states)
            if (peer.connection == null)
            {
                // Calculate rank and track best
                int rank = calculate_peer_rank(self, peer);
                if (rank > best_rank)
                {
                    best = peer;
                    best_rank = rank;
                }
            }
        }
    };

    return (best == null) ? PEER_NOT_FOUND? : best;
}

<*
 Convert disconnect reason enum to string for logging.
*>
fn String disconnect_reason_to_string(peer_connection::DisconnectReason reason)
{
    switch (reason)
    {
        case peer_connection::DisconnectReason.TCP_CONNECT_FAILED:
            return "TCP_CONNECT_FAILED";
        case peer_connection::DisconnectReason.READ_START_FAILED:
            return "READ_START_FAILED";
        case peer_connection::DisconnectReason.HANDSHAKE_SEND_FAILED:
            return "HANDSHAKE_SEND_FAILED";
        case peer_connection::DisconnectReason.HANDSHAKE_WRITE_FAILED:
            return "HANDSHAKE_WRITE_FAILED";
        case peer_connection::DisconnectReason.REMOTE_CLOSED:
            return "REMOTE_CLOSED";
        case peer_connection::DisconnectReason.INVALID_HANDSHAKE:
            return "INVALID_HANDSHAKE";
        case peer_connection::DisconnectReason.WRONG_INFO_HASH:
            return "WRONG_INFO_HASH";
        case peer_connection::DisconnectReason.INVALID_MESSAGE:
            return "INVALID_MESSAGE";
        case peer_connection::DisconnectReason.USER_CLOSED:
            return "USER_CLOSED";
        default:
            return "UNKNOWN";
    }
}

<*
 Internal bridge: Called when peer_connection state changes.
 Routes to user's on_connected/on_disconnected callbacks with IP/port.
*>
fn void on_peer_state_internal(peer_connection::PeerConnection* conn,
                                 peer_connection::PeerState state,
                                 peer_connection::DisconnectReason reason,
                                 void* user_data)
{
    PeerPool* pool = (PeerPool*)user_data;

    // Find which peer this connection belongs to
    TorrentPeer* peer_info = null;
    pool.peers.@each(; common::SocketAddress addr, TorrentPeer* peer)
    {
        if (peer.connection == conn)
        {
            peer_info = peer;
            // Note: Don't use 'return' here - it exits the entire callback, not just @each!
        }
    };

    if (!peer_info)
    {
        return;
    }

    switch (state)
    {
        case peer_connection::PeerState.READY:
            // Peer handshake complete - transition from CONNECTING to CONNECTED
            // OWNERSHIP BOUNDARY: peer_pool owns ALL peer state
            peer_info.state = PeerState.CONNECTED;
            peer_info.handshake_ok = true;

            // Notify user
            if (pool.on_connected)
            {
                pool.on_connected(conn, &peer_info.addr, pool.user_data);
            }

            // Broadcast this new peer to all other connected peers via PEX
            // Note: PEX currently only supports IPv4 (BEP 11)
            if (!peer_info.addr.addr.is_ipv6)
            {
                // Extract IPv4 bytes for PEX
                common::Ipv4Addr ipv4_bytes = peer_info.addr.to_ipv4_bytes();
                broadcast_pex_update(pool, ipv4_bytes, peer_info.addr.port, true);
            }
            return;

        case peer_connection::PeerState.CLOSED:
            // Peer disconnected - increment failcount and possibly ban
            peer_info.failcount++;

            // Log disconnect with reason and failcount (BEP 7: format IPv4/IPv6)
            log::debug(
                "Peer %s disconnected (reason: %s, failcount: %d/%d)",
                peer_info.addr,
                disconnect_reason_to_string(reason),
                peer_info.failcount,
                pool.config.max_failcount);

            // Ban peer if too many failures
            if (peer_info.failcount >= pool.config.max_failcount)
            {
                peer_info.state = PeerState.BANNED;
                log::warn(
                    "Banned peer %s after %d failures",
                    peer_info.addr,
                    peer_info.failcount);
            }
            else
            {
                peer_info.state = PeerState.DISCONNECTED;
            }

            pool.num_active_connections--;

            // OWNERSHIP BOUNDARY: Reset all session state for clean reconnect
            peer_info.handshake_ok = false;
            peer_info.received_bitfield = false;
            peer_info.optimistically_unchoked = false;

            // Don't call close() from here - it causes recursion since close()
            // triggers this callback. The peer will be freed by disconnect_all()
            // or when the connection object is freed.
            // Call close() which handles refcounting and may free immediately
            if (peer_info.connection)
            {
                if (!peer_info.connection.is_closed)
                {
                    peer_info.connection.close();  // Decrements refcount, may free
                }
                peer_info.connection = null;  // Clear reference (close() may have freed it)
            }

            if (pool.on_disconnected)
            {
                pool.on_disconnected(&peer_info.addr, true, pool.user_data);
            }

            // Broadcast this peer drop to all other connected peers via PEX (BEP 11: IPv4 only)
            if (!peer_info.addr.addr.is_ipv6)
            {
                common::Ipv4Addr ipv4_bytes = peer_info.addr.to_ipv4_bytes();
                broadcast_pex_update(pool, ipv4_bytes, peer_info.addr.port, false);
            }

            // Try to replace this connection (unless we're shutting down or peer is banned)
            if (!pool.shutting_down && peer_info.state != PeerState.BANNED)
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
    pool.peers.@each(; common::SocketAddress addr, TorrentPeer* peer)
    {
        if (peer.connection == conn)
        {
            peer_info = peer;
            // Note: Don't use 'return' here - it exits the entire callback, not just @each!
        }
    };

    if (!peer_info) return;

    // BEP 21: Sync upload_only status from connection to peer info
    peer_info.upload_only = conn.peer_upload_only;

    // Forward to user callback with peer address
    if (pool.on_message)
    {
        pool.on_message(conn, msg, &peer_info.addr, pool.user_data);
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
        log::info( "[PEX] Received %d peers from peer",
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
 Add single peer from any source (deduplicates by address:port).
 BEP 7: Supports both IPv4 and IPv6 peers.

 @param addr : "Peer address (IPv4 or IPv6)"
 @param source : "Peer discovery source"
 @param pex_flags : "PEX flags (optional, only used for PEX peers)"
*>
fn void PeerPool.add_peer(&self, common::SocketAddress* addr, common::PeerSource source, char pex_flags = 0) @public
{
    // O(1) HashMap lookup to check if peer already exists
    TorrentPeer**? existing_ref = self.peers.get_ref(*addr);

    if (catch excuse = existing_ref)
    {
        // Peer doesn't exist - add new peer

        // Check capacity
        if (self.peers.len() >= self.config.max_peerlist_size)
        {
            // TODO: Enforce limit by removing lowest-ranked peer
            // For now, just don't add
            return;
        }

        // Create new peer using arena allocator (bump pointer, ~5 cycles)
        TorrentPeer* peer = allocator::new(&self.arena, TorrentPeer);
        peer.addr = *addr;
        peer.connection = null;
        peer.state = PeerState.DISCOVERED;
        peer.prev_amount_download = 0;
        peer.prev_amount_upload = 0;
        peer.hashfails = 0;
        peer.failcount = 0;
        peer.last_connected = 0;
        peer.seed = false;
        peer.upload_only = false;  // BEP 21: Will be set from extension handshake
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

        // O(1) HashMap insertion (HashMap entries also use arena allocator)
        self.peers.set(*addr, peer);
    }
    else
    {
        // Peer already exists - prioritize TRACKER source over others
        TorrentPeer* existing_peer = *existing_ref;
        if (source == common::PeerSource.TRACKER && existing_peer.source != common::PeerSource.TRACKER)
        {
            existing_peer.source = common::PeerSource.TRACKER;
        }
    }
}

<*
 Batch add peers from any source.

 @param peers : "Peers to add"
 @param source : "Peer discovery source"
*>
fn void PeerPool.add_peers(&self, common::SocketAddress[] peers, common::PeerSource source) @public
{
    for (usz i = 0; i < peers.len; i++)
    {
        // Skip peers with invalid port 0
        if (peers[i].port == 0) continue;

        self.add_peer(&peers[i], source);
    }
}

<*
 Batch add peers from tracker response.
 Convenience wrapper for add_peers() with TRACKER source.
 BEP 7: Supports both IPv4 and IPv6 peers.

 @param peers : "Peers from tracker"
*>
fn void PeerPool.add_peers_from_tracker(&self, common::SocketAddress[] peers) @public
{
    self.add_peers(peers, common::PeerSource.TRACKER);
}

<*
 Batch add peers from DHT get_peers response.
 Convenience wrapper for add_peers() with DHT source.

 @param peers : "Peers from DHT"
*>
fn void PeerPool.add_peers_from_dht(&self, common::SocketAddress[] peers) @public
{
    self.add_peers(peers, common::PeerSource.DHT);
}

<*
 Convenience wrapper for add_peers() with LSD source.
 Used by BEP 14 (Local Service Discovery) to add discovered peers.

 @param peers : "Array of peer addresses from LSD"
*>
fn void PeerPool.add_peers_from_lsd(&self, common::SocketAddress[] peers) @public
{
    self.add_peers(peers, common::PeerSource.LSD);
}

<*
 Find peer by address:port (BEP 7: dual-stack).

 @param addr : "Peer address (IPv4 or IPv6)"
 @return "Peer if found, fault if not found"
*>
fn TorrentPeer*? PeerPool.find_peer(&self, common::SocketAddress* addr) @public
{
    // O(1) HashMap lookup
    TorrentPeer**? peer_ref = self.peers.get_ref(*addr);
    if (catch excuse = peer_ref)
    {
        return PEER_NOT_FOUND?;
    }
    return *peer_ref;
}

<*
 Remove peer from pool.

 Uses tombstone pattern: Removes peer from HashMap but doesn't free memory
 (arena allocator handles bulk deallocation at shutdown).

 @param peer : "Peer to remove"
*>
fn void PeerPool.erase_peer(&self, TorrentPeer* peer) @public
{
    if (!peer) return;

    // Save address for HashMap removal
    common::SocketAddress addr = peer.addr;

    self.peers.remove(addr);
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
    *total_peers = self.peers.len();
    *candidates = 0;
    *connecting = 0;
    *connected = 0;

    // Iterate HashMap with @each macro
    self.peers.@each(; common::SocketAddress addr, TorrentPeer* peer)
    {
        switch (peer.state)
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
    };
}

// ===== Phase 3: Async Connection Management =====

<*
 Disconnect a specific peer by address:port (Phase 3, BEP 7: dual-stack).

 @param addr : "Peer address (IPv4 or IPv6)"
*>
fn void PeerPool.disconnect_peer(&self, common::SocketAddress* addr) @public
{
    // Find peer
    TorrentPeer*? peer_opt = self.find_peer(addr);
    if (catch err = peer_opt)
    {
        return; // Peer not found
    }

    TorrentPeer* peer = peer_opt;

    // Close connection if active
    if (peer.connection)
    {
        peer.connection.close();
        peer.connection = null;
        self.num_active_connections--;
    }

    // Update state
    peer.state = PeerState.DISCONNECTED;

    // Call user callback
    if (self.on_disconnected)
    {
        self.on_disconnected(&peer.addr, false, self.user_data);
    }
}

<*
 Disconnect all active peer connections (Phase 3).
*>
fn void PeerPool.disconnect_all(&self) @public
{
    // Iterate HashMap with @each macro
    self.peers.@each(; common::SocketAddress addr, TorrentPeer* peer)
    {
        if (peer.connection)
        {
            peer.connection.close();
            peer.connection = null;
            peer.state = PeerState.DISCONNECTED;
        }
    };

    self.num_active_connections = 0;
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
    self.peers.@each(; common::SocketAddress addr, TorrentPeer* peer)
    {
        if (peer.connection) connected_count++;
    };

    if (connected_count > 0)
    {
        log::info(
                     "[Shutdown] Gracefully disconnecting from %d peer%s",
                     connected_count, connected_count == 1 ? "" : "s");
    }

    // Gracefully disconnect each peer
    self.peers.@each(; common::SocketAddress addr, TorrentPeer* peer)
    {
        if (peer.connection)
        {
            peer.connection.graceful_close();
            // NOTE: Do NOT null out peer.connection here!
            // The pointer is needed in peer_pool.free() to free the PeerConnection struct
            // after close_all_handles() has drained the TCP close callbacks
            peer.state = PeerState.DISCONNECTED;
        }
    };

    self.num_active_connections = 0;
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

        // Format IP address for connection (BEP 7: dual-stack)
        DString ip_builder;
        ip_builder.appendf("%s", peer.addr.addr);
        String ip_str = ip_builder.copy_str(mem);
        defer std::core::mem::free(ip_str);

        // Create transport based on configuration
        network::Transport* transport;
        switch (self.config.transport)
        {
            case TransportType.TCP:
                transport = (network::Transport*)tcp::create(self.loop);
            case TransportType.UTP:
                // TODO: Implement μTP transport (BEP 29)
                log::error("μTP transport not yet implemented, falling back to TCP");
                transport = (network::Transport*)tcp::create(self.loop);
        }

        // Connect to peer with internal bridge callbacks
        // The bridge callbacks add IP/port and route to user callbacks
        peer_connection::PeerConnection*? conn_opt = peer_connection::connect(
            transport,
            ip_str,
            peer.addr.port,
            self.info_hash,
            self.our_peer_id,
            &on_peer_message_internal,  // Bridge: adds IP/port
            &on_peer_state_internal,    // Bridge: adds IP/port
            &on_pex_message_internal,   // Bridge: adds PEX peers to pool
            self.on_metadata,            // Metadata callback for magnet links (BEP 9)
            null,                        // BEP 52: Hash request callback (not implemented yet)
            null,                        // BEP 52: Hashes callback (not implemented yet)
            null,                        // BEP 52: Hash reject callback (not implemented yet)
            (PeerPool*)self,             // Pass pool as user_data for bridge
            self.is_private,             // BEP 27: Pass private flag
            self.upload_only             // BEP 21: Pass upload-only flag
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

            // Continue trying other candidates
            continue;
        }

        // Connection initiated successfully
        peer.connection = conn_opt;
        peer.state = PeerState.CONNECTING;
        self.num_active_connections++;

        io::printfn("[PEER_POOL] Peer %s: state → CONNECTING (conn=%p)",
            peer.addr, conn_opt);

        // Note: on_connected callback will be called from bridge when peer reaches READY state
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
    // BEP 27: Don't broadcast PEX for private torrents
    if (pool.is_private)
    {
        return;
    }

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
        // Convert IPv4 to SocketAddress for lookup (BEP 7)
        common::SocketAddress addr;
        addr.addr.is_ipv6 = false;
        addr.addr.ipv4.a = ip[0];
        addr.addr.ipv4.b = ip[1];
        addr.addr.ipv4.c = ip[2];
        addr.addr.ipv4.d = ip[3];
        addr.port = port;
        TorrentPeer*? peer_opt = pool.find_peer(&addr);
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
    pool.peers.@each(; common::SocketAddress addr, TorrentPeer* peer)
    {
        // Skip if not connected or no connection object
        if (peer.state != PeerState.CONNECTED || !peer.connection)
        {
            return; // Continue to next peer
        }

        // Don't broadcast a peer to itself (BEP 7: check IPv4 peers only, PEX is IPv4-only)
        if (!peer.addr.addr.is_ipv6 &&
            peer.addr.addr.ipv4.a == ip[0] && peer.addr.addr.ipv4.b == ip[1] &&
            peer.addr.addr.ipv4.c == ip[2] && peer.addr.addr.ipv4.d == ip[3] &&
            peer.addr.port == port)
        {
            return; // Continue to next peer
        }

        // Queue the PEX update for this peer
        if (added)
        {
            peer.connection.add_pex_peer(ip, port, flags);
        }
        else
        {
            peer.connection.drop_pex_peer(ip, port);
        }
        notified_count++;
    };

    if (notified_count > 0)
    {
        log::info( "[PEX] Queued peer %d.%d.%d.%d:%d (%s) for %d connected peers",
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
    self.peers.@each(; common::SocketAddress addr, TorrentPeer* peer)
    {
        if (peer.state == PeerState.CONNECTED && peer.connection)
        {
            // send_pex_message handles rate limiting internally
            // Ignore any errors (peer may have disconnected, etc.)
            (void)peer.connection.send_pex_message();
        }
    };
}

<*
 Send keepalive messages to all connected peers.

 Keepalive messages (BEP 3) are required to maintain connections during idle periods.
 Most BitTorrent clients will disconnect if they don't receive any message for 2-3 minutes.

 This should be called periodically (every ~120 seconds) via a timer.
*>
fn void PeerPool.send_keepalives(&self) @public
{
    self.peers.@each(; common::SocketAddress addr, TorrentPeer* peer)
    {
        if (peer.state == PeerState.CONNECTED && peer.connection)
        {
            // Ignore any errors (peer may have disconnected, etc.)
            (void)peer.connection.send_keepalive();
        }
    };
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

        // Convert PEX IPv4 peer to SocketAddress (BEP 7)
        common::SocketAddress addr;
        addr.addr.is_ipv6 = false;
        addr.addr.ipv4.a = pex_peer.ip[0];
        addr.addr.ipv4.b = pex_peer.ip[1];
        addr.addr.ipv4.c = pex_peer.ip[2];
        addr.addr.ipv4.d = pex_peer.ip[3];
        addr.port = pex_peer.port;

        // Add peer to pool (will be deduplicated if already exists)
        // Use PeerSource.PEX and pass flags for seed detection
        self.add_peer(&addr, common::PeerSource.PEX, pex_peer.flags);
        added_count++;

        // If the peer is marked as a seed, update our records
        if ((pex_peer.flags & (char)pex::PexFlags.SEED) != 0)
        {
            TorrentPeer*? peer_opt = self.find_peer(&addr);
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
        log::info( "[PEX] Added %d peers, rejected %d invalid peers",
                     added_count, rejected_count);
    }

    // After adding new peers, try to connect
    if (added_count > 0)
    {
        self.connect_to_peers();
    }
}

<*
 Recalculate and update a single peer's rank.

 Useful for tests that directly modify peer fields and need to
 trigger rank recalculation.

 @param peer : "Peer to update rank for"
*>
fn void PeerPool.update_peer_rank(&self, TorrentPeer* peer) @public
{
    peer.peer_rank = calculate_peer_rank(self, peer);
}

<*
 Update peer statistics after data transfer (BEP 7: dual-stack).

 Updates the download and upload byte counters for a peer and recalculates
 its rank. Should be called periodically during active transfers.

 @param addr : "Peer address (IPv4 or IPv6)"
 @param bytes_downloaded : "Bytes downloaded from this peer"
 @param bytes_uploaded : "Bytes uploaded to this peer"
 @return "Fault if peer not found"
*>
fn fault? PeerPool.update_peer_stats(&self, common::SocketAddress* addr,
                                      ulong bytes_downloaded, ulong bytes_uploaded) @public
{
    TorrentPeer*? peer_opt = self.find_peer(addr);
    if (catch err = peer_opt)
    {
        return err?;
    }

    TorrentPeer* peer = peer_opt;

    // Update statistics
    peer.prev_amount_download = bytes_downloaded;
    peer.prev_amount_upload = bytes_uploaded;

    // Recalculate rank based on new statistics
    self.update_peer_rank(peer);

    return {};
}

<*
 Mark a peer as having sent a bad piece (hash verification failed).

 Increments the hash failure counter and penalizes the peer's rank.
 Multiple hash failures will significantly reduce peer priority.

 @param addr : "Peer address (IPv4 or IPv6)"
 @return "Fault if peer not found"
*>
fn fault? PeerPool.mark_hash_failure(&self, common::SocketAddress* addr) @public
{
    TorrentPeer*? peer_opt = self.find_peer(addr);
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
    self.update_peer_rank(peer);

    return {};
}

<*
 Mark a peer as a seed (has all pieces).

 Sets the seed flag and boosts the peer's rank. Seed peers are prioritized
 for connections as they can provide any piece we need.

 @param addr : "Peer address (IPv4 or IPv6)"
 @return "Fault if peer not found"
*>
fn fault? PeerPool.mark_peer_seed(&self, common::SocketAddress* addr) @public
{
    TorrentPeer*? peer_opt = self.find_peer(addr);
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
    self.update_peer_rank(peer);

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

    // Format IP address (BEP 7: dual-stack IPv4/IPv6)
    // InetAddress implements Printable, so we can use %s directly
    DString ip_str;
    ip_str.appendf("%s", peer.addr.addr);
    info.ip_address = ip_str.copy_str(mem);
    info.port = peer.addr.port;

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
    if (self.peers.len() == 0)
    {
        PeerDisplayInfo[] empty;
        return empty;
    }

    // First pass: filter peers and build array of pointers
    // Use temp allocator since this is short-lived
    TorrentPeer*[] filtered_peers = mem::temp_array(TorrentPeer*, self.peers.len());

    usz filtered_count = 0;
    self.peers.@each(; common::SocketAddress addr, TorrentPeer* peer)
    {
        if (peer_passes_filter(peer, filter))
        {
            filtered_peers[filtered_count] = peer;
            filtered_count++;
        }
    };

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
