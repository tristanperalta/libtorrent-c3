module libtorrent::session;

import std::io;
import std::time;
import std::encoding::hex;
import std::core::log;
import uv;
import libtorrent;
import libtorrent::common;
import libtorrent::trackers;
import libtorrent::tracker_manager;
import async::event_loop;
import libtorrent::metainfo;
import libtorrent::peer_connection;
import libtorrent::peer_wire;
import libtorrent::download_manager;
import libtorrent::block_manager;
import libtorrent::piece_assembler;
import libtorrent::storage_manager;
import libtorrent::file_selection;
import libtorrent::storage;
import libtorrent::storage::fastresume;
import libtorrent::upload_manager;
import libtorrent::upload_handler;
import libtorrent::bitfield;
import async::timer;
import libtorrent::peer_pool;
import libtorrent::dht_client;
import libtorrent::dht_get_peers;
import libtorrent::lsd;
import libtorrent::discovery;
import libtorrent::discovery::tracker;
import libtorrent::discovery::dht;
import libtorrent::discovery::lsd;
import libtorrent::discovery::pex;
import libtorrent::discovery::composite;
import libtorrent::webseed;
import libtorrent::httpseed;
import libtorrent::event_bus;
import libtorrent::event_types;
import libtorrent::speed_tracker;
import libtorrent::metadata_download;
import libtorrent::metadata_exchange;
import libtorrent::fast_extension;
import libtorrent::torrent_manager;
import libtorrent::magnet_download_session;
import libtorrent::session_message_handler;

// Maximum concurrent piece verifications during resume check
// Default: 100 pieces - optimized for systems with 12+ threads
// Balances CPU utilization with memory usage and system responsiveness
const int VERIFICATION_BATCH_SIZE = 100;

// File flush interval (default: 5000ms = 5 seconds)
// Flushes all pending writes to disk periodically for data safety
const int FILE_FLUSH_INTERVAL_MS = 5000;

// Block request timeout check interval (default: 10000ms = 10 seconds)
// Checks for stuck block requests and resets them for retry
const int BLOCK_TIMEOUT_CHECK_INTERVAL_MS = 10000;

// Default maximum concurrent piece downloads
// Default: 30 pieces - good balance for typical torrents (256KB-1MB pieces)
// Allows full utilization of available peers while avoiding excessive memory usage
// Library users can override this via Session.max_concurrent_pieces
const int DEFAULT_MAX_CONCURRENT_PIECES = 30;

// ============================================================================
// Event Type Constants (for EventBus)
// ============================================================================

// Session state events
const String SESSION_STARTED = "session.started";
const String SESSION_PAUSED = "session.paused";
const String SESSION_RESUMED = "session.resumed";
const String SESSION_COMPLETED = "session.completed";
const String SESSION_STOPPED = "session.stopped";
const String SESSION_ERROR = "session.error";

// Progress events
const String PIECE_COMPLETED = "piece.completed";
const String PIECE_HASH_FAILED = "piece.hash_failed";

// Peer events
const String PEER_CONNECTED = "peer.connected";
const String PEER_DISCONNECTED = "peer.disconnected";

// Tracker events
const String TRACKER_ANNOUNCE_SUCCESS = "tracker.success";
const String TRACKER_ANNOUNCE_FAILED = "tracker.failed";

// Statistics events
const String STATS_UPDATE = "stats.update";

// ============================================================================
// Event Data Structures (for EventBus)
// ============================================================================

// Session state change event data
struct SessionStateEvent {
    common::InfoHash info_hash;
    String message;  // Optional description
}

// Piece completion event data
struct PieceCompletedEvent {
    uint piece_index;
    usz piece_size;
    uint pieces_complete;
    uint total_pieces;
}

// Peer connection event data
struct PeerEvent {
    common::SocketAddress peer_addr;
}

// Tracker event data
struct TrackerEvent {
    String tracker_url;
    int peer_count;      // For success
    String error_message;  // For failure
}

// Statistics update event data
struct StatsUpdateEvent {
    long downloaded;
    long uploaded;
    int download_rate;
    int upload_rate;
    int connected_peers;
    float progress;
}

// Session error event data
struct SessionErrorEvent {
    String error_message;
    int error_code;
}

// ============================================================================
// Helper Structures
// ============================================================================

<*
 Context for async piece write operations.
*>
struct PieceWriteContext
{
    Session* session;
    char[] piece_data;  // Must be freed after write completes
}

<*
 Context for web seed piece verification.
*>
struct WebSeedVerifyContext
{
    Session* session;
    uint piece_index;
    char[] piece_data;  // Must be freed after verification
}

struct HttpSeedVerifyContext
{
    Session* session;
    uint piece_index;
    char[] piece_data;  // Must be freed after verification
}

// ============================================================================
// Session Configuration (inspired by libtorrent-rasterbar session_params)
// ============================================================================

<*
 * SessionOptions - Configuration for creating a new BitTorrent session.
 *
 * This structure provides a clean, type-safe way to configure session behavior
 * before creating a Session. Inspired by libtorrent-rasterbar's session_params.
 *
 * Use preset factory functions for common scenarios:
 * - create_default_session_options()         - Balanced default settings
 * - create_min_memory_session_options()      - Optimized for low memory usage
 * - create_high_performance_session_options() - Optimized for maximum throughput
 *
 * Example usage:
 * ```
 * SessionOptions options = create_default_session_options("/downloads", "ubuntu.torrent");
 * options.max_concurrent_pieces = 50;  // Override specific settings
 * Session* session = create_session(mgr, options);
 * ```
 *>
struct SessionOptions
{
    // ========================================================================
    // Network Settings
    // ========================================================================

    // Listen interfaces (comma-separated list of interface:port pairs)
    // Default: "0.0.0.0:6881,[::]:6881" (IPv4 and IPv6 on port 6881)
    // Examples: "0.0.0.0:6881", "192.168.1.100:8080", "eth0:6881"
    String listen_interfaces;

    // Maximum number of peer connections
    // Default: 200
    // Range: 10-1000 (min_memory: 50, high_performance: 500)
    int connections_limit;

    // Maximum retries for binding to listen port (increments port on failure)
    // Default: 10
    int max_retry_port_bind;

    // Transport protocol to use for peer connections (BEP 29)
    // Default: TCP
    // Options: TCP (traditional), UTP (μTP - low latency, congestion-friendly)
    peer_pool::TransportType transport;

    // ========================================================================
    // Performance Settings
    // ========================================================================

    // Maximum number of unchoked peers (upload slots)
    // Default: 8 (-1 for unlimited)
    // Range: 2-50 (min_memory: 4, high_performance: 20)
    int unchoke_slots_limit;

    // Maximum number of pieces to download concurrently
    // Default: 30 pieces (good balance for 256KB-1MB piece sizes)
    // Range: 5-100 (min_memory: 10, high_performance: 50)
    int max_concurrent_pieces;

    // Maximum connection attempts per second
    // Default: 50 connections/sec
    // Range: 10-200 (min_memory: 20, high_performance: 100)
    int connection_speed;

    // ========================================================================
    // Download Settings
    // ========================================================================

    // Number of peers to request from tracker
    // Default: 50 peers
    // Range: 20-200 (min_memory: 30, high_performance: 100)
    int numwant;

    // Directory where downloaded files will be saved (REQUIRED)
    String save_path;

    // Comma-separated list of file indices to download (BEP 21 selective download)
    // Default: "" (empty = download all files)
    // Example: "0,2,4" (download only files at indices 0, 2, and 4)
    String select_files_str;

    // ========================================================================
    // Tracker Settings
    // ========================================================================

    // Tracker announce timeout in seconds
    // Default: 60 seconds
    // Range: 15-180 seconds
    int tracker_timeout;

    // Prefer UDP trackers over HTTP trackers
    // Default: true (UDP is more efficient)
    bool prefer_udp_trackers;

    // Tracker parallel announce configuration
    // Controls multi-tracker announce behavior (BEP 12)
    tracker::TrackerConfig tracker_config;

    // ========================================================================
    // DHT Settings (BEP 5)
    // ========================================================================

    // Enable DHT for trackerless peer discovery
    // Default: true
    bool enable_dht;

    // DHT listen port
    // Default: 6881 (same as peer protocol port)
    int dht_port;

    // ========================================================================
    // Resume Data Settings (BEP 21)
    // ========================================================================

    // State provider for persisting download state (FastResume/SQLite/NoOp)
    // Set to null to disable state persistence
    storage::StateProvider state_provider;

    // Path to .torrent file (REQUIRED for fastresume and metadata)
    String torrent_path;

    // ========================================================================
    // Advanced Settings
    // ========================================================================

    // Upload-only mode (seeding without downloading)
    // Default: false
    // Set to true for dedicated seeders
    bool upload_only;
}

<*
 Download session context for managing the download workflow.
*>
struct Session
{
    // Manager that owns this session (ALWAYS borrowed, never owned)
    torrent_manager::TorrentManager* manager;  // Replaces SharedResources

    // Torrent-specific resources
    libtorrent::metainfo::TorrentFile* torrent;
    download_manager::DownloadManager* dm;
    storage_manager::StorageManager* sm;

    // Tracker state
    bool tracker_completed;
    trackers::TrackerResponse* tracker_response;
    async::timer::Timer* pex_timer;          // PEX update timer (every 60s)
    async::timer::Timer* keepalive_timer;    // Keepalive timer (every 120s)
    async::timer::Timer* flush_timer;        // File flush timer (configurable interval)
    async::timer::Timer* block_timeout_timer; // Block request timeout checker (every 10s)

    // Multi-tracker support (BEP 12)
    tracker_manager::TrackerManager* tracker_mgr;  // Manages tier-based tracker selection
    String current_tracker_url;                    // Currently active tracker URL (for logging)
    trackers::Tracker current_tracker;             // Currently active tracker instance (for magnet links)
    bool has_current_tracker;                      // Track if current_tracker is valid
    tracker::TrackerConfig tracker_config;  // Parallel announce configuration

    // Peer discovery composite (hexagonal architecture)
    composite::CompositePeerDiscovery* peer_discovery_composite;

    // Tracker peer discovery (stored separately for tracker-specific methods like trigger_event_announce)
    tracker::TrackerPeerDiscovery* tracker_discovery;

    // Peer management
    peer_pool::PeerPool* peer_pool;

    // Upload/seeding
    upload_manager::UploadManager* upload_mgr;  // Upload request queue manager
    async::timer::Timer* upload_timer;          // Upload request processor (every 1s)

    // DHT search (session-specific, not shared)
    dht_get_peers::GetPeersSearch* dht_search;  // Per-torrent DHT peer search
    async::timer::Timer* dht_timer;         // DHT search maintenance timer
    async::timer::Timer* dht_check_timer;   // DHT search check timer
    // Note: dht_tick_timer moved to SharedResources (DHT-wide RPC timeout processing)
    // Note: lsd_timer moved to SharedResources (LSD announces for all torrents)

    // Web seeding (BEP 19)
    webseed::WebSeedManager* webseed_mgr;   // HTTP/FTP web seed manager
    async::timer::Timer* webseed_timer;     // Periodic web seed piece requests

    // HTTP seeding (BEP 17)
    httpseed::HttpSeedManager* httpseed_mgr;  // Hoffman-style HTTP seed manager
    async::timer::Timer* httpseed_timer;      // Periodic httpseed piece requests

    // Magnet link support (BEP 9)
    bool is_magnet_download;                         // True if started from magnet link
    metadata_download::MetadataDownload* metadata_dl; // Metadata download manager
    async::timer::Timer* metadata_timer;             // Periodic metadata request/timeout check

    // Download state
    bool download_complete;
    bool is_partial_seed;       // BEP 21: We are a partial seed (multi-file, selective download)
    int exit_code;
    String torrent_path;        // Path to .torrent file (for resume data)
    storage::StateProvider state_provider;  // BEP 21: State persistence (FastResume/SQLite/NoOp)

    // Download statistics
    ulong total_bytes_downloaded;       // Total bytes downloaded (all sources)
    ulong webseed_bytes_downloaded;     // Bytes from web seeds only
    long last_speed_update_time;        // Unix timestamp for speed calculation
    float current_download_speed;       // Current speed in bytes/sec
    speed_tracker::SpeedTracker* speed_tracker;  // Speed tracking with sliding window
    long last_gui_update_ms;            // Last GUI update time (for debouncing)

    // Resume verification
    uint num_pieces;                        // Total number of pieces
    uint pieces_verified_count;             // Resume verification progress
    uint next_piece_to_verify;              // Index of next piece to verify (for batching)

    // Options
    int numwant;
    String save_path;
    int max_concurrent_pieces;          // Max pieces to download simultaneously
    String select_files_str;            // BEP 21: File selection string (e.g., "0,2,4")

    // Network options
    String listen_interfaces;            // Listen interfaces (e.g., "0.0.0.0:6881,[::]:6881")
    int connections_limit;               // Maximum peer connections
    int max_retry_port_bind;             // Max port bind retries
    peer_pool::TransportType transport;  // Transport protocol (TCP or μTP) (BEP 29)

    // Performance options
    int unchoke_slots_limit;             // Maximum upload slots
    int connection_speed;                // Max connections per second

    // Tracker options
    int tracker_timeout;                 // Tracker announce timeout (seconds)
    bool prefer_udp_trackers;            // Prefer UDP over HTTP trackers

    // DHT options
    int dht_port;                        // DHT listen port

    // Advanced options
    bool upload_only;                    // Upload-only (seeding) mode

    // GUI integration (null in CLI mode, cast to GUI type in GUI code)
    void* gui_state;

    // Event bus for pub/sub (decouples GUI from download logic)
    event_bus::EventBus* event_bus;
}

// ============================================================================
// SessionOptions Factory Functions
// ============================================================================

<*
 * Create default SessionOptions with balanced settings.
 *
 * This preset provides a good balance between performance and resource usage,
 * suitable for most use cases.
 *
 * @param save_path "Directory where files will be saved"
 * @param torrent_path "Path to .torrent file (or magnet link)"
 * @return "SessionOptions with default settings"
 *>
fn SessionOptions create_default_session_options(String save_path, String torrent_path) @public
{
    SessionOptions options;

    // Network settings
    options.listen_interfaces = "0.0.0.0:6881,[::]:6881";
    options.connections_limit = 200;
    options.max_retry_port_bind = 10;

    // Performance settings
    options.unchoke_slots_limit = 8;
    options.max_concurrent_pieces = DEFAULT_MAX_CONCURRENT_PIECES;  // 30
    options.connection_speed = 50;

    // Download settings
    options.numwant = 50;
    options.save_path = save_path;
    options.select_files_str = "";

    // Tracker settings
    options.tracker_timeout = 60;
    options.prefer_udp_trackers = true;
    options.tracker_config = tracker::default_tracker_config();

    // DHT settings
    options.enable_dht = true;
    options.dht_port = 6881;

    // Resume settings
    options.state_provider = (storage::StateProvider)fastresume::create();
    options.torrent_path = torrent_path;

    // Advanced settings
    options.upload_only = false;

    return options;
}

<*
 * Create SessionOptions optimized for minimal memory usage.
 *
 * This preset reduces memory consumption at the cost of some performance.
 * Suitable for:
 * - Systems with limited RAM
 * - Running many simultaneous torrents
 * - Low-priority background downloads
 *
 * @param save_path "Directory where files will be saved"
 * @param torrent_path "Path to .torrent file (or magnet link)"
 * @return "SessionOptions optimized for low memory"
 *>
fn SessionOptions create_min_memory_session_options(String save_path, String torrent_path) @public
{
    SessionOptions options;

    // Network settings - reduced connections
    options.listen_interfaces = "0.0.0.0:6881,[::]:6881";
    options.connections_limit = 50;
    options.max_retry_port_bind = 10;

    // Performance settings - conservative limits
    options.unchoke_slots_limit = 4;
    options.max_concurrent_pieces = 10;  // Fewer concurrent pieces = less memory
    options.connection_speed = 20;       // Slower connection rate

    // Download settings - fewer peers
    options.numwant = 30;
    options.save_path = save_path;
    options.select_files_str = "";

    // Tracker settings
    options.tracker_timeout = 60;
    options.prefer_udp_trackers = true;
    options.tracker_config = tracker::default_tracker_config();

    // DHT settings
    options.enable_dht = true;
    options.dht_port = 6881;

    // Resume settings
    options.state_provider = (storage::StateProvider)fastresume::create();
    options.torrent_path = torrent_path;

    // Advanced settings
    options.upload_only = false;

    return options;
}

<*
 * Create SessionOptions optimized for maximum performance.
 *
 * This preset maximizes download speed and throughput at the cost of higher
 * resource usage. Suitable for:
 * - High-bandwidth connections
 * - Systems with plenty of RAM and CPU
 * - Priority downloads that need maximum speed
 * - Dedicated seeders
 *
 * @param save_path "Directory where files will be saved"
 * @param torrent_path "Path to .torrent file (or magnet link)"
 * @return "SessionOptions optimized for high performance"
 *>
fn SessionOptions create_high_performance_session_options(String save_path, String torrent_path) @public
{
    SessionOptions options;

    // Network settings - maximum connections
    options.listen_interfaces = "0.0.0.0:6881,[::]:6881";
    options.connections_limit = 500;
    options.max_retry_port_bind = 10;
    options.transport = peer_pool::TransportType.UTP;  // Use μTP for testing (BEP 29)

    // Performance settings - aggressive limits
    options.unchoke_slots_limit = 20;    // More upload slots
    options.max_concurrent_pieces = 50;  // More concurrent downloads
    options.connection_speed = 100;      // Faster connection rate

    // Download settings - request more peers
    options.numwant = 100;
    options.save_path = save_path;
    options.select_files_str = "";

    // Tracker settings
    options.tracker_timeout = 60;
    options.prefer_udp_trackers = true;
    options.tracker_config = tracker::default_tracker_config();

    // DHT settings
    options.enable_dht = true;
    options.dht_port = 6881;

    // Resume settings
    options.state_provider = (storage::StateProvider)fastresume::create();
    options.torrent_path = torrent_path;

    // Advanced settings
    options.upload_only = false;

    return options;
}

// ============================================================================
// Session Factory Methods
// ============================================================================

<*
 * Create a new BitTorrent session with the given configuration.
 *
 * This factory method creates and initializes a Session from SessionOptions,
 * encapsulating all the boilerplate initialization logic in one place.
 *
 * The created session is heap-allocated and must be freed by the caller using
 * Session.free() when done.
 *
 * Example usage:
 * ```
 * SessionOptions options = create_default_session_options("/downloads", "ubuntu.torrent");
 * options.max_concurrent_pieces = 50;  // Override if needed
 *
 * TorrentManager* mgr = torrent_manager::create(loop, 1);
 * Session* session = create_session(mgr, options);
 *
 * // ... use session ...
 *
 * free(session);
 * mgr.free();
 * ```
 *
 * @param manager "TorrentManager that owns this session"
 * @param options "Configuration options for the session"
 * @return "Newly created Session pointer (must be freed)"
 *>
fn Session* create_session(torrent_manager::TorrentManager* manager, SessionOptions options) @public
{
    Session* ctx = mem::new(Session);

    // Set manager (borrowed reference)
    ctx.manager = manager;

    // Initialize torrent-specific resources (null until torrent loads)
    ctx.torrent = null;
    ctx.dm = null;
    ctx.sm = null;

    // Initialize tracker state
    ctx.tracker_completed = false;
    ctx.tracker_response = null;
    ctx.pex_timer = null;
    ctx.keepalive_timer = null;
    ctx.flush_timer = null;
    ctx.block_timeout_timer = null;

    // Initialize multi-tracker support
    ctx.tracker_mgr = null;
    ctx.current_tracker_url = "";
    ctx.has_current_tracker = false;
    ctx.tracker_config = options.tracker_config;

    // Initialize peer discovery
    ctx.peer_discovery_composite = null;
    ctx.tracker_discovery = null;

    // Initialize peer management
    ctx.peer_pool = null;

    // Initialize upload/seeding
    ctx.upload_mgr = null;
    ctx.upload_timer = null;

    // Initialize DHT search
    ctx.dht_search = null;
    ctx.dht_timer = null;
    ctx.dht_check_timer = null;

    // Initialize web seeding
    ctx.webseed_mgr = null;
    ctx.webseed_timer = null;

    // Initialize HTTP seeding
    ctx.httpseed_mgr = null;
    ctx.httpseed_timer = null;

    // Initialize magnet link support
    ctx.is_magnet_download = false;
    ctx.metadata_dl = null;
    ctx.metadata_timer = null;

    // Initialize download state
    ctx.download_complete = false;
    ctx.is_partial_seed = false;
    ctx.exit_code = 0;
    ctx.torrent_path = options.torrent_path;

    // Set state provider (dependency injection)
    ctx.state_provider = options.state_provider;

    // Initialize download statistics
    ctx.total_bytes_downloaded = 0;
    ctx.webseed_bytes_downloaded = 0;
    ctx.last_speed_update_time = 0;
    ctx.current_download_speed = 0.0;
    ctx.speed_tracker = null;  // Created later during torrent setup
    ctx.last_gui_update_ms = 0;

    // Initialize resume verification
    ctx.num_pieces = 0;
    ctx.pieces_verified_count = 0;
    ctx.next_piece_to_verify = 0;

    // Set options from SessionOptions
    ctx.numwant = options.numwant;
    ctx.save_path = options.save_path;
    ctx.max_concurrent_pieces = options.max_concurrent_pieces;
    ctx.select_files_str = options.select_files_str;

    // Network options
    ctx.listen_interfaces = options.listen_interfaces;
    ctx.connections_limit = options.connections_limit;
    ctx.max_retry_port_bind = options.max_retry_port_bind;
    ctx.transport = options.transport;  // BEP 29: Transport protocol

    // Performance options
    ctx.unchoke_slots_limit = options.unchoke_slots_limit;
    ctx.connection_speed = options.connection_speed;

    // Tracker options
    ctx.tracker_timeout = options.tracker_timeout;
    ctx.prefer_udp_trackers = options.prefer_udp_trackers;

    // DHT options
    ctx.dht_port = options.dht_port;

    // Advanced options
    ctx.upload_only = options.upload_only;

    // Initialize GUI integration (null by default, set later if needed)
    ctx.gui_state = null;

    // Create event bus for pub/sub
    ctx.event_bus = event_bus::create(ctx.get_loop());

    return ctx;
}

// ============================================================================
// Session Accessor Methods (for cleaner access to shared resources)
// ============================================================================

/**
 * Get the event loop from the manager.
 * Convenience method for ctx.manager.loop
 */
fn event_loop::EventLoop* Session.get_loop(&self) @inline @public
{
    return self.manager.loop;
}

/**
 * Get the DHT client from the manager.
 * Convenience method for ctx.manager.dht
 */
fn dht_client::DhtClient* Session.get_dht(&self) @inline @public
{
    return self.manager.dht;
}

/**
 * Check if DHT is enabled.
 * Convenience method for ctx.manager.dht_enabled
 */
fn bool Session.is_dht_enabled(&self) @inline @public
{
    return self.manager.dht_enabled && self.manager.dht != null;
}

/**
 * Get the LSD manager from the manager.
 * Convenience method for ctx.manager.lsd_mgr
 */
fn lsd::LsdManager* Session.get_lsd_mgr(&self) @inline @public
{
    return self.manager.lsd_mgr;
}

/**
 * Check if LSD is enabled.
 * Convenience method for ctx.manager.lsd_enabled
 */
fn bool Session.is_lsd_enabled(&self) @inline @public
{
    return self.manager.lsd_enabled && self.manager.lsd_mgr != null;
}

// ============================================================================
// Utility Functions
// ============================================================================

<*
 Get error description string from tracker status code.

 @param status : "Tracker error status code"
 @return "Human-readable error description"
*>
fn String tracker_error_string(int status) @public
{
    switch (status)
    {
        // HTTP tracker errors
        case -1: return "HTTP request failed";
        case -2: return "Invalid response format";
        case -3: return "Invalid tracker URL";

        // UDP tracker specific errors
        case -4: return "Invalid response format";
        case -5: return "DNS lookup failed";
        case -6: return "Invalid tracker URL";

        default: return "Unknown error";
    }
}

// ============================================================================
// Download Session Callbacks and Helper Functions
// ============================================================================

// ============================================================================
// BEP 21: Partial Seed Support Functions
// ============================================================================

<*
 * Check if writing a piece completed any files (BEP 21).
 * A file is complete when all pieces that touch it are complete.
 *
 * @param ctx "Download context"
 * @param piece_index "Piece that was just written"
 *>
fn void check_file_completion(Session* ctx, uint piece_index)
{
    if (!ctx.torrent.info.is_multi_file) return;  // Single file torrents handled differently

    // Get piece location
    ulong piece_offset = (ulong)piece_index * (ulong)ctx.torrent.info.piece_length;
    ulong piece_len = (piece_index == ctx.num_pieces - 1)
                     ? (ulong)(ctx.torrent.info.length % (ulong)ctx.torrent.info.piece_length)
                     : (ulong)ctx.torrent.info.piece_length;
    if (piece_len == 0) piece_len = (ulong)ctx.torrent.info.piece_length;  // Last piece might be full size

    // Check each file to see if this piece was its last missing piece
    for (usz i = 0; i < ctx.sm.files.len; i++)
    {
        if (ctx.sm.files[i].is_complete) continue;  // Already marked complete
        if (!ctx.sm.files[i].is_selected) continue; // Not selected, skip

        // Check if this file is now complete
        if (is_file_complete_now(ctx, i))
        {
            ctx.sm.mark_file_complete(i);
            io::printfn("  [BEP 21] File %d complete: %s", i, ctx.sm.files[i].path);

            // Publish file completed event (BEP 21 Phase 2)
            event_types::FileProgressEvent file_evt = event_types::create_file_progress_event(
                (uint)i, 1.0,
                ctx.sm.files[i].length, ctx.sm.files[i].length,
                true, ctx.sm.files[i].is_selected
            );
            ctx.event_bus.publish(event_types::EVENT_FILE_COMPLETED, &file_evt, event_types::FileProgressEvent.sizeof);
        }
    }
}

<*
 * Check if all pieces for a file are complete.
 *
 * @param ctx "Download context"
 * @param file_index "File index to check"
 * @return "True if all pieces for this file are complete"
 *>
fn bool is_file_complete_now(Session* ctx, usz file_index)
{
    // Get file byte range
    ulong file_start = ctx.sm.files[file_index].offset;
    ulong file_end = file_start + ctx.sm.files[file_index].length;

    // Calculate which pieces touch this file
    uint first_piece = (uint)(file_start / (ulong)ctx.torrent.info.piece_length);
    uint last_piece = (uint)((file_end - 1) / (ulong)ctx.torrent.info.piece_length);

    // Check if all pieces are complete
    for (uint p = first_piece; p <= last_piece; p++)
    {
        if (!ctx.dm.have_piece(p)) return false;
    }

    return true;
}

<*
 * Called when selected files are complete - enters partial seed mode (BEP 21).
 * Stops downloading unwanted pieces, continues uploading to peers.
 *
 * @param ctx "Download context"
 *>
fn void on_partial_seed_complete(Session* ctx) @public
{
    io::printfn("");
    io::printfn("=== Selected Files Complete! ===");
    io::printfn("Entering partial seed mode (BEP 21)...");
    io::printfn("Will continue uploading but won't download remaining pieces.");
    io::printfn("");

    // Mark as partial seed
    ctx.is_partial_seed = true;

    // BEP 21: Tell peer pool to advertise upload_only in extension handshake
    if (ctx.peer_pool)
    {
        ctx.peer_pool.set_upload_only(true);
    }

    // Send "completed" event to tracker
    trigger_completed_announce(ctx);

    // FastResume: Only save if partial seed (BEP 21 - selective file download)
    // No point saving resume data for complete downloads - nothing to resume!
    if (ctx.is_partial_seed && ctx.state_provider && ctx.torrent_path.len > 0)
    {
        storage::DownloadState state = build_download_state(ctx);
        defer state.free();

        if (catch err = ctx.state_provider.save_state(ctx.torrent_path, &state))
        {
            io::eprintfn("Warning: Failed to save fastresume data: %s", err);
        }
        else
        {
            io::printfn("Saved partial seed state to fastresume file");
        }
    }

    // Stop download-only timers
    if (ctx.block_timeout_timer)
    {
        ctx.block_timeout_timer.close();
        ctx.block_timeout_timer = null;
    }

    if (ctx.webseed_timer)
    {
        ctx.webseed_timer.close();
        ctx.webseed_timer = null;
    }
    if (ctx.webseed_mgr)
    {
        ctx.webseed_mgr.free();
        ctx.webseed_mgr = null;
    }

    if (ctx.httpseed_timer)
    {
        ctx.httpseed_timer.close();
        ctx.httpseed_timer = null;
    }
    if (ctx.httpseed_mgr)
    {
        ctx.httpseed_mgr.free();
        ctx.httpseed_mgr = null;
    }

    if (ctx.metadata_timer)
    {
        ctx.metadata_timer.close();
        ctx.metadata_timer = null;
    }

    if (ctx.dht_timer)
    {
        ctx.dht_timer.close();
        ctx.dht_timer = null;
    }
    if (ctx.dht_check_timer)
    {
        ctx.dht_check_timer.close();
        ctx.dht_check_timer = null;
    }
    if (ctx.dht_search)
    {
        ctx.dht_search.free();
        ctx.dht_search = null;
    }

    // Note: lsd_timer moved to SharedResources (cleaned up on shared.release())

    // Keep these running for seeding:
    // - keepalive_timer: Keep peer connections alive
    // - upload_timer: Process upload requests from peers
    // - pex_timer: Share peer information (BEP 11)
    // - flush_timer: Periodic file flush
    // - tracker_coord: Periodic announces

    io::printfn("Partial seed mode active. Will continue seeding selected files.");
    io::printfn("Press Ctrl+C to stop and exit.");
}

// ============================================================================
// Download Completion Handlers
// ============================================================================

<*
 Called when download is complete - enters seeding mode.
 Keeps peer connections and upload manager running to serve pieces.
*>
fn void on_complete_download(Session* ctx) @public
{
    io::printfn("");
    io::printfn("=== Download Complete! ===");
    io::printfn("All %d pieces verified successfully", ctx.num_pieces);
    io::printfn("Entering seeding mode - will continue uploading to peers...");
    io::printfn("");

    // Mark download as complete
    ctx.download_complete = true;

    // Publish SESSION_COMPLETED event
    if (ctx.event_bus)
    {
        SessionStateEvent evt = {
            .info_hash = ctx.torrent.info_hash,
            .message = "Download completed"
        };
        ctx.event_bus.publish(SESSION_COMPLETED, &evt, SessionStateEvent.sizeof);
    }

    // Send "completed" event to tracker (announces we're now seeding)
    trigger_completed_announce(ctx);

    // Stop download-only timers
    if (ctx.block_timeout_timer)
    {
        ctx.block_timeout_timer.close();
        ctx.block_timeout_timer = null;
    }

    // Stop web seeding (only needed during download)
    if (ctx.webseed_timer)
    {
        ctx.webseed_timer.close();
        ctx.webseed_timer = null;
    }
    if (ctx.webseed_mgr)
    {
        ctx.webseed_mgr.free();
        ctx.webseed_mgr = null;
    }

    // Stop HTTP seeding (only needed during download)
    if (ctx.httpseed_timer)
    {
        ctx.httpseed_timer.close();
        ctx.httpseed_timer = null;
    }
    if (ctx.httpseed_mgr)
    {
        ctx.httpseed_mgr.free();
        ctx.httpseed_mgr = null;
    }

    // Stop metadata download timer (if magnet link)
    if (ctx.metadata_timer)
    {
        ctx.metadata_timer.close();
        ctx.metadata_timer = null;
    }

    // Keep these running for seeding:
    // - keepalive_timer: Keep peer connections alive
    // - upload_timer: Process upload requests from peers
    // - pex_timer: Share peer information (BEP 11)
    // - flush_timer: Periodic file flush
    // - tracker_coord: Periodic announces (tells tracker we're seeding)
    // - dht_client: DHT operations continue

    io::printfn("Seeding mode active. Press Ctrl+C to stop seeding and exit.");

    // Stop DHT peer discovery (no longer needed - we have enough peers)
    if (ctx.dht_timer)
    {
        ctx.dht_timer.close();
        ctx.dht_timer = null;
    }
    if (ctx.dht_check_timer)
    {
        ctx.dht_check_timer.close();
        ctx.dht_check_timer = null;
    }

    // Free the DHT search (but keep dht_client and dht_tick_timer for DHT operations)
    if (ctx.dht_search)
    {
        ctx.dht_search.free();
        ctx.dht_search = null;
    }

    // Stop LSD announcements (no longer needed in seeding mode)
    // Note: lsd_timer is shared across sessions - don't stop it here
    // Keep LSD manager active to respond to announcements from other peers

    // Event loop continues running - client now seeds until user presses Ctrl+C
}

<*
 * Build file selection string from storage manager (BEP 21 Phase 3).
 * Returns comma-separated list of selected file indices (e.g., "0,2,4").
 *
 * @param sm : "Storage manager"
 * @return "File selection string (caller must free)"
 *>
fn String build_file_selection_string(storage_manager::StorageManager* sm) @private
{
    DString result;
    bool first = true;
    for (usz i = 0; i < sm.files.len; i++)
    {
        if (sm.files[i].is_selected)
        {
            if (!first) result.append(",");
            result.appendf("%d", i);
            first = false;
        }
    }
    return result.copy_str(mem);
}

<*
 * Toggle file selection (BEP 21 Phase 3).
 * Called from GUI when user clicks file checkbox.
 *
 * @param ctx : "Download context"
 * @param file_index : "Index of file to toggle"
 * @param selected : "New selection state"
 *>
fn void toggle_file_selection(Session* ctx, usz file_index, bool selected) @public
{
    if (!ctx.sm || file_index >= ctx.sm.files.len) return;

    // Update storage manager
    ctx.sm.files[file_index].is_selected = selected;

    // Save to fastresume (file selection will be saved via file_priority in next periodic save)
    // Note: We don't trigger an immediate save here to avoid excessive I/O on rapid file selection changes
    // The periodic save in on_event_tick() will capture the updated file selection

    // Publish selection change event
    event_types::FileProgressEvent evt = event_types::create_file_progress_event(
        (uint)file_index, 0.0, 0, 0, false, selected
    );
    ctx.event_bus.publish(event_types::EVENT_FILE_SELECTION_CHANGED, &evt, event_types::FileProgressEvent.sizeof);

    io::printfn("[BEP 21] File %d selection changed: %s -> %s",
                file_index,
                selected ? "selected" : "deselected",
                ctx.sm.files[file_index].path);
}

<*
 Callback for piece completion - write to disk.
*>
fn void on_download_piece_complete(uint piece_index, char[] piece_data, bool success, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    if (!success)
    {
        io::eprintfn("Piece %d verification failed!", piece_index);

        // Mark all peers who sent blocks for this piece as having hash failure
        // TODO: Track which specific peer sent which block (requires per-block tracking)
        // For now, we penalize all connected peers slightly
        ctx.peer_pool.peers.@each(; common::SocketAddress addr, peer_pool::TorrentPeer* peer_info)
        {
            if (peer_info.state == peer_pool::PeerState.CONNECTED)
            {
                ctx.peer_pool.mark_hash_failure(&peer_info.addr)!!;
            }
        };

        // Mark piece as failed for retry
        // Note: This can fail if the piece was already cancelled/cleaned up (race condition)
        // This is fine - just log and continue
        if (catch excuse = ctx.dm.fail_piece(piece_index))
        {
            io::eprintfn("  Note: Could not mark piece %d as failed (already cleaned up)", piece_index);
        }
        return;
    }

    io::printfn("✓ Piece %d verified (%d bytes)", piece_index, piece_data.len);

    // Broadcast HAVE message to all connected peers (BEP 3)
    // This informs peers we now have this piece available for upload
    ctx.peer_pool.peers.@each(; common::SocketAddress addr, peer_pool::TorrentPeer* peer_info)
    {
        if (peer_info.state == peer_pool::PeerState.CONNECTED && peer_info.connection)
        {
            (void)peer_info.connection.send_have(piece_index);  // Best effort
        }
    };

    // Update speed tracker with downloaded bytes (smooth sliding window calculation)
    if (ctx.speed_tracker)
    {
        ctx.speed_tracker.add_bytes((ulong)piece_data.len, speed_tracker::DownloadSource.PEER);

        // Calculate speed - will return valid value once enough time has passed
        float new_speed = ctx.speed_tracker.get_speed();
        if (new_speed > 0.0)
        {
            ctx.current_download_speed = new_speed;
        }
    }

    // Track total downloaded for cumulative stats
    ctx.total_bytes_downloaded += piece_data.len;

    // Publish piece completion event to EventBus
    event_types::PieceEvent piece_evt = event_types::create_piece_event(
        piece_index, (usz)piece_data.len, true, "peer"
    );
    ctx.event_bus.publish(event_types::EVENT_PIECE_COMPLETED, &piece_evt, event_types::PieceEvent.sizeof);

    // Display speed in human-readable format
    if (ctx.current_download_speed > 1024.0 * 1024.0)
    {
        io::printfn("    [DM] Download speed: %.2f MB/s", ctx.current_download_speed / (1024.0 * 1024.0));
    }
    else if (ctx.current_download_speed > 1024.0)
    {
        io::printfn("    [DM] Download speed: %.2f KB/s", ctx.current_download_speed / 1024.0);
    }
    else
    {
        io::printfn("    [DM] Download speed: %.2f B/s", ctx.current_download_speed);
    }

    // Write piece to disk via storage_manager
    // Create context to manage piece_data lifecycle
    PieceWriteContext* write_ctx = mem::new(PieceWriteContext);
    write_ctx.session = ctx;
    write_ctx.piece_data = piece_data;
    ctx.sm.write_piece(piece_index, piece_data, &on_piece_written, write_ctx);

    // Check progress
    usz total, complete, downloading;
    ctx.dm.get_progress(&total, &complete, &downloading);

    // Debounce GUI updates - only update once per second for readability
    long now_ms = (long)(time::now().to_seconds() * 1000);
    bool should_update_gui = (now_ms - ctx.last_gui_update_ms) >= 1000;  // 1 second

    if (should_update_gui)
    {
        ctx.last_gui_update_ms = now_ms;

        // Publish progress event to EventBus (async dispatch)
        event_types::ProgressEvent progress_evt = event_types::create_progress_event(
            (uint)complete, (uint)downloading, (uint)total,
            ctx.total_bytes_downloaded, ctx.current_download_speed, 0.0
        );
        ctx.event_bus.publish(event_types::EVENT_PROGRESS_UPDATED, &progress_evt, event_types::ProgressEvent.sizeof);

        // Publish file progress update (BEP 21 Phase 2)
        // Signal GUI to refresh all file progress (file_index = -1 means "all files")
        event_types::FileProgressEvent file_evt = event_types::create_file_progress_event(
            (uint)-1, 0.0, 0, 0, false, true
        );
        ctx.event_bus.publish(event_types::EVENT_FILE_PROGRESS_UPDATED, &file_evt, event_types::FileProgressEvent.sizeof);
    }

    if (complete % 100 == 0 || complete == total)
    {
        double percent = (complete * 100.0) / total;
        io::printfn("Progress: %d/%d pieces (%.1f%%)", complete, total, percent);
    }

    // BEP 21: Check for partial seed completion BEFORE full completion
    if (!ctx.is_partial_seed && !ctx.download_complete)
    {
        if (ctx.sm.are_selected_files_complete())
        {
            on_partial_seed_complete(ctx);
            return;
        }
    }

    // Check if download is complete
    if (ctx.dm.is_complete())
    {
        on_complete_download(ctx);
        return;
    }

    // BEP 21: Don't start new downloads in partial seed mode
    if (ctx.is_partial_seed)
    {
        return;
    }

    // Start downloading more pieces from available peers
    // Use actual peer bitfields to start new piece downloads
    ctx.peer_pool.peers.@each(; common::SocketAddress addr, peer_pool::TorrentPeer* peer_info)
    {
        if (peer_info.state == peer_pool::PeerState.CONNECTED && peer_info.handshake_ok)
        {
            // Convert peer's Bitfield to bool[] for piece picker
            bool[] peer_pieces = mem::new_array(bool, total);
            defer free(peer_pieces);

            for (usz j = 0; j < total; j++)
            {
                peer_pieces[j] = peer_info.pieces.has_piece(j);
            }

            // Try to start a new piece download with this peer's actual pieces
            if (catch excuse = ctx.dm.start_piece_download(peer_pieces))
            {
                // No more slots available or no pieces this peer has that we need
                // Continue to try with other peers instead of exiting @each
            }
            else
            {
                // Successfully started a new piece - try to fill more slots
            }
        }
    };

    // Continue requesting blocks
    request_blocks_from_peers(ctx);
}

<*
 Callback for peer message handling.
*>
/**
 * Callback for peer wire protocol messages.
 * Delegates to session_message_handler module.
 */
fn void on_download_peer_message(peer_connection::PeerConnection* peer,
                                  peer_wire::Message* msg,
                                  common::SocketAddress* addr,
                                  void* user_data) @public
{
    session_message_handler::handle_peer_message(peer, msg, addr, user_data);
}

/**
 * Request blocks from ready peers.
 * Delegates to session_message_handler module.
 */
fn void request_blocks_from_peers(Session* ctx) @public
{
    session_message_handler::request_blocks_from_peers(ctx);
}

<*
 Callback when peer successfully connects.
*>
fn void on_download_peer_connected(peer_connection::PeerConnection* peer,
                                    common::SocketAddress* addr,
                                    void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    // Peer connected and ready (BEP 7: dual-stack)
    io::printfn("  Peer %s connected and ready", addr);

    // Publish PEER_CONNECTED event
    if (ctx.event_bus)
    {
        PeerEvent evt = {
            .peer_addr = *addr
        };
        ctx.event_bus.publish(PEER_CONNECTED, &evt, PeerEvent.sizeof);
    }

    // Get peer from pool
    peer_pool::TorrentPeer*? peer_opt = ctx.peer_pool.find_peer(addr);
    if (catch err = peer_opt) return;

    peer_pool::TorrentPeer* peer_info = peer_opt;

    // OWNERSHIP BOUNDARY: download_session is stateless
    // peer_pool owns peer state - we only read and send messages

    // BEP 6: Generate and send allowed_fast set if peer supports Fast Extension
    if (peer_info.connection.supports_fast)
    {
        usz num_pieces = (usz)((ctx.torrent.info.length + ctx.torrent.info.piece_length - 1) /
                               ctx.torrent.info.piece_length);

        // BEP 6 requires IPv4 address for allowed_fast calculation
        // For IPv6 peers, we skip allowed_fast (BEP 6 doesn't define IPv6 behavior)
        if (!addr.addr.is_ipv6)
        {
            common::Ipv4Addr ipv4_bytes = addr.to_ipv4_bytes();
            uint[] allowed_fast = fast_extension::generate_default_allowed_fast_set(
                ipv4_bytes, ctx.torrent.info_hash, (uint)num_pieces);
            defer free(allowed_fast);

            // Send ALLOWED_FAST message for each piece
            foreach (piece_index : allowed_fast)
            {
                if (catch excuse = peer.send_allowed_fast(piece_index))
                {
                    // Failed to send, but continue with others
                }
            }

            // Store the allowed_fast set we sent to this peer
            peer_info.connection.peer_allowed_fast.free();
            peer_info.connection.peer_allowed_fast.init(mem);
            foreach (piece_index : allowed_fast)
            {
                peer_info.connection.peer_allowed_fast.push(piece_index);
            }

            io::printfn("  Sent %d ALLOWED_FAST pieces to peer %s", allowed_fast.len, addr);
        }
    }

    // Send INTERESTED message to the peer
    if (catch err = peer.send_interested())
    {
        io::eprintfn("Failed to send INTERESTED to peer %s: %s", addr, err);
        return;
    }
    io::printfn("  Sent INTERESTED to peer %s", addr);

    // DON'T start piece downloads yet - wait for BITFIELD first
    // The BITFIELD message handler will start downloads
}

<*
 Callback when peer disconnects.
*>
fn void on_download_peer_disconnected(common::SocketAddress* addr,
                                       bool was_error,
                                       void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    // Peer disconnected (BEP 7: dual-stack)
    io::printfn("  Peer %s disconnected%s",
                addr,
                was_error ? " (error)" : "");

    // Publish PEER_DISCONNECTED event
    if (ctx.event_bus)
    {
        PeerEvent evt = {
            .peer_addr = *addr
        };
        ctx.event_bus.publish(PEER_DISCONNECTED, &evt, PeerEvent.sizeof);
    }

    // Log state before completion check
    int shutting_down_val = ctx.peer_pool ? (int)ctx.peer_pool.shutting_down : -1;
    log::debug("Peer disconnected. download_complete=%d, is_complete=%d, shutting_down=%d",
               ctx.download_complete, ctx.dm.is_complete(), shutting_down_val);

    // Peer pool automatically tries to replace failed connections
    // Check if download is complete (and we haven't already handled completion)
    if (!ctx.download_complete && ctx.dm.is_complete())
    {
        io::printfn("");
        io::printfn("Download complete!");
        log::debug("Calling on_complete_download() - setting download_complete=true");
        on_complete_download(ctx);
        log::debug("Returned from on_complete_download() - download_complete should be %d",
                   ctx.download_complete);
        return;
    }

    log::debug("Skipping completion (already handled or not complete yet)");

    // Check if all peers are disconnected
    usz total_peers, candidates, connecting, connected;
    ctx.peer_pool.get_stats(&total_peers, &candidates, &connecting, &connected);

    if (connected == 0 && connecting == 0)
    {
        io::printfn("");
        io::printfn("All peers disconnected - waiting for periodic announce to find more peers...");
        // Note: The announce_timer will automatically bring fresh peers
        // No manual re-announce needed - the timer handles it
    }
}

<*
 Callback when storage manager initialization completes.
*>
fn void on_storage_initialized(int status, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    if (status < 0)
    {
        io::eprintfn("Error: Failed to initialize storage manager (error %d)", status);
        ctx.exit_code = 1;
        ctx.download_complete = true;
        return;
    }

    io::printfn("Storage initialized successfully");
    io::printfn("");

    // Create speed tracker if not already initialized
    if (!ctx.speed_tracker)
    {
        ctx.speed_tracker = speed_tracker::create();
    }

    // Try loading fastresume data first to skip verification
    io::printfn("Checking for resume data...");
    bool resume_loaded = try_load_fastresume_data(ctx);

    if (resume_loaded)
    {
        io::printfn("Resume data loaded - skipping verification!");
        io::printfn("  Verified pieces loaded from fastresume file");

        // Skip verification, go straight to download
        on_all_pieces_verified(ctx);
    }
    else
    {
        // No resume data - verify all pieces
        io::printfn("No resume data found - verifying existing pieces...");
        verify_all_existing_pieces_async(ctx);
    }
}

<*
 Callback when a piece has been written to disk.
*>
fn void on_piece_written(uint piece_index, int status, void* user_data) @public
{
    PieceWriteContext* write_ctx = (PieceWriteContext*)user_data;
    Session* ctx = write_ctx.session;

    if (status == 0)
    {
        io::printfn("  Piece %d written to disk", piece_index);

        // BEP 21: Check if this piece completes any files
        check_file_completion(ctx, piece_index);

        // Publish PIECE_COMPLETED event
        if (ctx.event_bus)
        {
            usz total, complete, downloading;
            ctx.dm.get_progress(&total, &complete, &downloading);

            PieceCompletedEvent evt = {
                .piece_index = piece_index,
                .piece_size = (usz)ctx.torrent.info.piece_length,
                .pieces_complete = (uint)complete,
                .total_pieces = (uint)total
            };
            ctx.event_bus.publish(PIECE_COMPLETED, &evt, PieceCompletedEvent.sizeof);
        }
    }
    else
    {
        io::eprintfn("  Failed to write piece %d to disk (error %d)", piece_index, status);
        // Mark piece as failed for retry
        ctx.dm.fail_piece(piece_index)!!;
    }

    // Free piece data now that write is complete
    free(write_ctx.piece_data);
    free(write_ctx);
}

<*
 Callback for each piece verification during resume check.
*>
fn void on_verify_existing_piece(uint piece_index, bool verified, int status, void* user_data) @public
{
    Session* ctx = (Session*)user_data;
    ctx.pieces_verified_count++;

    if (status == 0 && verified)
    {
        // Piece exists and is valid - mark as complete
        ctx.dm.picker.mark_complete(piece_index)!!;
    }

    // Show progress every 1000 pieces
    if (ctx.pieces_verified_count % 1000 == 0)
    {
        io::printfn("  Verified %d/%d pieces...", ctx.pieces_verified_count, ctx.num_pieces);
    }

    // Start next piece verification to maintain batch concurrency
    if (ctx.next_piece_to_verify < ctx.num_pieces)
    {
        start_piece_verification(ctx, ctx.next_piece_to_verify);
        ctx.next_piece_to_verify++;
    }

    // All pieces verified?
    if (ctx.pieces_verified_count == ctx.num_pieces)
    {
        on_all_pieces_verified(ctx);
    }
}

<*
 Start verification for a single piece.
 Extracts the expected hash and queues the verification.
*>
fn void start_piece_verification(Session* ctx, uint piece_index) @public
{
    // Get expected hash for this piece
    common::InfoHash expected_hash;
    usz hash_offset = (usz)piece_index * 20;
    for (usz j = 0; j < 20; j++)
    {
        expected_hash[j] = ctx.torrent.info.pieces[hash_offset + j];
    }

    // Verify piece asynchronously
    ctx.sm.verify_piece(piece_index, expected_hash, &on_verify_existing_piece, ctx);
}

<*
 Build DownloadState from current download context for saving.
 Caller must call state.free() when done.
*>
fn storage::DownloadState build_download_state(Session* ctx) @public
{
    storage::DownloadState state;
    state.version = storage::STATE_VERSION;

    // Build have_pieces bitfield
    uint num_bytes = (ctx.num_pieces + 7) / 8;
    state.have_pieces = mem::new_array(char, num_bytes);

    for (uint i = 0; i < ctx.num_pieces; i++)
    {
        if (ctx.dm.have_piece(i))
        {
            uint byte_index = i / 8;
            uint bit_index = i % 8;
            state.have_pieces[byte_index] |= (char)(1 << bit_index);
        }
    }

    // File selection
    state.file_selection = ctx.select_files_str.len > 0 ? ctx.select_files_str.copy(mem) : "";

    // Statistics
    state.total_downloaded = ctx.total_bytes_downloaded;
    state.total_uploaded = 0;  // TODO: Track upload stats when upload manager supports it
    state.added_time = 0;  // TODO: Track when torrent was added
    state.completed_time = ctx.download_complete ? (long)time::now() : 0;
    state.active_time = 0;  // TODO: Track active time
    state.seeding_time = 0;
    state.last_seen_complete = 0;

    // Unfinished pieces - TODO: Implement when download_manager supports it
    state.unfinished = {};

    // File priority: Convert from storage_manager file selection to priority array
    // Priority 0 = don't download (unselected), Priority 4 = normal (selected)
    if (ctx.sm && ctx.sm.files.len > 0)
    {
        state.file_priority = mem::new_array(char, ctx.sm.files.len);
        for (usz i = 0; i < ctx.sm.files.len; i++)
        {
            state.file_priority[i] = ctx.sm.files[i].is_selected ? (char)4 : (char)0;
        }
    }
    else
    {
        state.file_priority = {};
    }

    // File validation data (mtime + size for FastResume validation)
    if (ctx.sm)
    {
        state.file_resume = ctx.sm.get_file_validation_data();
    }
    else
    {
        state.file_resume = {};
    }

    // Optional fields (use defaults for now)
    state.upload_rate_limit = 0;
    state.download_rate_limit = 0;
    state.max_connections = 0;
    state.max_uploads = 0;
    state.paused = false;
    state.auto_managed = false;
    state.sequential_download = false;
    state.seed_mode = false;
    state.save_path = ctx.save_path.copy(mem);

    // Transmission-specific fields
    state.activity_date = (long)time::now();
    state.corrupt = 0;
    state.bandwidth_priority = 0;
    state.ratio_limit = 0.0;
    state.idle_limit = 0;
    state.speed_limit_up_enabled = false;
    state.speed_limit_down_enabled = false;

    return state;
}

<*
 Try to load fastresume data and restore verified pieces.
 Returns true if resume data was successfully loaded and pieces restored.
*>
fn bool try_load_fastresume_data(Session* ctx) @public
{
    if (!ctx.state_provider || ctx.torrent_path.len == 0) return false;

    io::printfn("  Torrent path: %s", ctx.torrent_path);

    storage::DownloadState? state_opt = ctx.state_provider.load_state(ctx.torrent_path);
    if (catch err = state_opt)
    {
        io::printfn("  Warning: Failed to load resume data: %s", err);
        return false;
    }

    storage::DownloadState state = state_opt;
    defer state.free();

    // Validate version
    if (state.version != storage::STATE_VERSION)
    {
        io::printfn("  Warning: Resume data version mismatch (expected %d, got %d)",
                   storage::STATE_VERSION, state.version);
        return false;
    }

    // Check if we have piece data
    if (state.have_pieces.len == 0)
    {
        io::printfn("  Warning: Resume data has no piece information");
        return false;
    }

    // Validate piece bitfield size
    uint expected_bytes = (ctx.num_pieces + 7) / 8;
    if (state.have_pieces.len != expected_bytes)
    {
        io::printfn("  Warning: Resume data piece bitfield size mismatch (expected %d bytes, got %d bytes)",
                   expected_bytes, state.have_pieces.len);
        return false;
    }

    // Validate files (libtorrent-rasterbar compatible mtime + size checking)
    if (state.file_resume.len > 0)
    {
        io::printfn("  Validating files (mtime + size check)...");

        bool[] file_valid = ctx.sm.validate_files(state.file_resume);
        defer free(file_valid);

        bool all_files_valid = true;
        uint files_changed = 0;

        for (usz i = 0; i < file_valid.len; i++)
        {
            if (!file_valid[i])
            {
                io::printfn("  Warning: File %d changed (mtime/size mismatch)", i);
                all_files_valid = false;
                files_changed++;
            }
        }

        if (!all_files_valid)
        {
            io::printfn("  %d file(s) changed since resume - full verification required", files_changed);
            return false;  // Trigger full piece verification
        }

        io::printfn("  All files unchanged - trusting FastResume");
    }
    else
    {
        // Backward compatibility: Old resume files without file_resume data
        // For safety, require full verification
        io::printfn("  Warning: Resume data has no file validation metadata");
        io::printfn("  Full verification required for safety");
        return false;
    }

    // Restore verified pieces to download manager
    uint pieces_restored = 0;
    for (uint i = 0; i < ctx.num_pieces; i++)
    {
        // Check if piece bit is set
        uint byte_index = i / 8;
        uint bit_index = i % 8;
        bool has_piece = (state.have_pieces[byte_index] & (1 << bit_index)) != 0;

        if (has_piece)
        {
            ctx.dm.picker.mark_complete(i)!!;
            pieces_restored++;
        }
    }

    io::printfn("  Restored %d verified pieces from resume data", pieces_restored);

    // Restore statistics
    if (state.total_downloaded > 0)
    {
        ctx.total_bytes_downloaded = state.total_downloaded;
        io::printfn("  Restored download stats: %s downloaded",
                   common::format_size((long)state.total_downloaded));
    }

    if (state.total_uploaded > 0)
    {
        // TODO: Restore upload stats when upload manager supports it
        io::printfn("  Note: Resume data contains upload stats: %s uploaded",
                   common::format_size((long)state.total_uploaded));
    }

    // Restore unfinished pieces (partially downloaded)
    if (state.unfinished.len > 0)
    {
        io::printfn("  Note: %d partially downloaded pieces found (will be re-downloaded)", state.unfinished.len);
        // TODO: Restore block bitmask to download manager
        // This requires download_manager API enhancement to support partial piece resume
    }

    return true;
}

<*
 Verify all existing pieces on disk (resume support).
 Calls verify_piece() for each piece asynchronously.
*>
fn void verify_all_existing_pieces_async(Session* ctx) @public
{
    if (ctx.num_pieces == 0)
    {
        // No pieces to verify, start announce immediately
        on_all_pieces_verified(ctx);
        return;
    }

    // Start first batch of pieces (limited by VERIFICATION_BATCH_SIZE)
    // This prevents overwhelming the system with too many concurrent verifications
    uint batch_end = ctx.num_pieces < VERIFICATION_BATCH_SIZE ? ctx.num_pieces : VERIFICATION_BATCH_SIZE;

    io::printfn("  Starting batched verification: %d pieces at a time (total: %d)",
                batch_end, ctx.num_pieces);

    for (uint i = 0; i < batch_end; i++)
    {
        start_piece_verification(ctx, i);
    }

    // Track next piece to verify
    ctx.next_piece_to_verify = batch_end;
}

// ============================================================================
// Peer Discovery Callbacks (Hexagonal Architecture)
// ============================================================================

<*
 Callback when peer discovery finds peers.
 Called by any discovery source (tracker, DHT, LSD, PEX).
*>
fn void on_peer_discovery_peers(common::SocketAddress[] peers, String discovery_source, void* user_data)
{
    Session* ctx = (Session*)user_data;

    io::printfn("[PeerDiscovery] Discovered %d peers from %s", peers.len, discovery_source);

    // Determine peer source based on discovery source name
    common::PeerSource source;
    switch (discovery_source)
    {
        case "tracker": source = common::PeerSource.TRACKER;
        case "dht":     source = common::PeerSource.DHT;
        case "lsd":     source = common::PeerSource.LSD;
        case "pex":     source = common::PeerSource.PEX;
        default:        source = common::PeerSource.TRACKER;  // Fallback
    }

    // Add peers to peer pool
    ctx.peer_pool.add_peers(peers, source);

    // Trigger connection attempts
    ctx.peer_pool.connect_to_peers();
}

<*
 Callback when peer discovery completes (or fails).
*>
fn void on_peer_discovery_complete(bool success, String error_message, void* user_data)
{
    Session* ctx = (Session*)user_data;

    if (!success)
    {
        io::printfn("[PeerDiscovery] Discovery failed: %s", error_message);
    }
}

<*
 PEX timer callback - sends queued PEX updates to all connected peers.
 Runs every 60 seconds per BEP 11 rate limiting.
*>
fn void on_pex_timer_tick(async::timer::Timer* timer, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    if (ctx.dm.is_complete())
    {
        // Download complete - stop timer
        timer.stop();
        return;
    }

    // Send queued PEX updates to all connected peers
    ctx.peer_pool.send_pex_updates();
}

<*
 Keepalive timer callback - sends keepalive messages to all connected peers.
 Runs every 120 seconds per BEP 3 specification to prevent timeout disconnections.
*>
fn void on_keepalive_timer_tick(async::timer::Timer* timer, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    if (ctx.dm.is_complete())
    {
        // Download complete - stop timer
        timer.stop();
        return;
    }

    // Send keepalive to all connected peers
    if (ctx.peer_pool)
    {
        ctx.peer_pool.send_keepalives();
    }
}

<*
 File flush timer callback - syncs all downloaded data to disk.
 Runs at configurable interval (default: every 5 seconds) to ensure data persistence.
 Also saves fastresume data periodically.
*>
fn void on_flush_timer_tick(async::timer::Timer* timer, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    if (ctx.dm.is_complete())
    {
        // Download complete - stop timer
        timer.stop();
        return;
    }

    // Flush all downloaded data to disk
    if (ctx.sm)
    {
        ctx.sm.sync_all_files();
    }

    // Save fastresume data periodically (allows resume even if client crashes)
    if (ctx.state_provider && ctx.torrent_path.len > 0)
    {
        storage::DownloadState state = build_download_state(ctx);
        defer state.free();

        // Silently save - don't spam logs every flush
        // Ignore errors to avoid log spam
        (void)ctx.state_provider.save_state(ctx.torrent_path, &state);
    }
}

<*
 Timer callback for checking block request timeouts.
 Runs every 10 seconds to check for blocks stuck in REQUESTED state.
*>
fn void on_block_timeout_timer_tick(async::timer::Timer* timer, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    if (ctx.dm.is_complete())
    {
        // Download complete - stop timer
        timer.stop();
        return;
    }

    // Check for timed-out blocks and reset them
    ctx.dm.check_block_timeouts();

    // Try to fill the request pipeline with the newly freed blocks
    request_blocks_from_peers(ctx);
}

<*
 Web seed timer callback - attempts to download pieces from HTTP/FTP web seeds.
 Fires every 5 seconds to check for web seed opportunities.
*>
fn void on_webseed_timer_tick(async::timer::Timer* timer, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    if (ctx.dm.is_complete())
    {
        // Download complete - stop timer
        timer.stop();
        return;
    }

    // Only try web seeds if we have a manager
    if (!ctx.webseed_mgr) return;

    // Check if we have active web seed downloads or free slots
    uint active = ctx.webseed_mgr.get_active_count();
    uint enabled = ctx.webseed_mgr.get_enabled_count();

    if (enabled == 0)
    {
        // All URLs disabled - stop trying
        io::printfn("[WebSeed] All URLs disabled, stopping web seed timer");
        timer.stop();
        return;
    }

    // Try to fill ALL available web seed slots aggressively
    usz max_concurrent = ctx.webseed_mgr.max_concurrent;
    while (active < max_concurrent)
    {
        // Pick a piece using gap-based selection (BEP 19)
        uint? piece_opt = ctx.dm.picker.pick_piece_for_webseed();
        if (catch piece_opt)
        {
            // No pieces available for web seeds
            return;
        }

        uint piece_index = piece_opt;

        // Mark piece as downloading
        ctx.dm.picker.mark_downloading(piece_index)!!;

        // Start web seed download
        if (catch err = ctx.webseed_mgr.start_piece_download(
            piece_index,
            &on_webseed_piece_complete,
            ctx))
        {
            // Failed to start - mark piece as free again
            ctx.dm.picker.mark_free(piece_index)!!;
            io::printfn("[WebSeed] Failed to start piece %d download: %s", piece_index, err);
            break;  // Stop trying if we failed
        }

        // Successfully started - increment counter and continue filling slots
        active++;
    }
}

<*
 Web seed piece completion callback.
 Called when a piece download from a web seed completes (success or failure).
*>
fn void on_webseed_piece_complete(uint piece_index, char[] piece_data, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    if (piece_data.len == 0)
    {
        // Download failed - mark piece as free for retry from peers
        io::printfn("[WebSeed] Piece %d download failed, will retry from peers", piece_index);
        ctx.dm.picker.mark_free(piece_index)!!;
        return;
    }

    // Get expected hash for verification
    char[20] expected_hash;
    usz hash_offset = (usz)piece_index * 20;
    for (usz k = 0; k < 20; k++)
    {
        expected_hash[k] = ctx.torrent.info.pieces[hash_offset + k];
    }

    // Create a copy of piece data for async verification
    char[] piece_data_copy = mem::new_array(char, piece_data.len);
    for (usz j = 0; j < piece_data.len; j++)
    {
        piece_data_copy[j] = piece_data[j];
    }

    // Create context for web seed verification callback
    WebSeedVerifyContext* verify_ctx = mem::new(WebSeedVerifyContext);
    verify_ctx.session = ctx;
    verify_ctx.piece_index = piece_index;
    verify_ctx.piece_data = piece_data_copy;

    // Start async verification
    piece_assembler::verify_data(ctx.get_loop(), piece_index, piece_data_copy,
                                 expected_hash, &on_webseed_piece_verified, verify_ctx);
}

<*
 Web seed piece verification callback.
 Called after async hash verification of web seed piece completes.
*>
fn void on_webseed_piece_verified(uint piece_index, bool verified, void* user_data) @public
{
    WebSeedVerifyContext* verify_ctx = (WebSeedVerifyContext*)user_data;
    Session* ctx = verify_ctx.session;

    if (!verified)
    {
        // Hash mismatch - permanently blacklist the web seed URL (BEP 19 requirement)
        io::eprintfn("[WebSeed] Piece %d hash mismatch - permanently disabling web seed URL!", piece_index);

        // TODO: Track which URL was used for this piece and blacklist it
        // For now, we mark the piece as free for retry
        ctx.dm.picker.mark_free(piece_index)!!;

        // Free the piece data copy
        free(verify_ctx.piece_data);
        free(verify_ctx);
        return;
    }

    // Success! Pass to the standard piece completion handler
    on_download_piece_complete(piece_index, verify_ctx.piece_data, true, ctx);

    // Note: piece_data is freed by on_download_piece_complete -> on_piece_written
    free(verify_ctx);
}

<*
 * HTTP seed timer callback (BEP 17).
 * Periodically requests pieces from httpseeds using Hoffman-style protocol.
 *>
fn void on_httpseed_timer_tick(async::timer::Timer* timer, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    if (ctx.dm.is_complete())
    {
        // Download complete - stop timer
        timer.stop();
        return;
    }

    // Only try httpseeds if we have a manager
    if (!ctx.httpseed_mgr) return;

    // Check if we have active httpseed downloads or free slots
    uint active = ctx.httpseed_mgr.get_active_count();
    uint available = ctx.httpseed_mgr.get_available_url_count();

    if (available == 0)
    {
        // All URLs disabled - stop trying
        io::printfn("[HttpSeed] All URLs disabled, stopping httpseed timer");
        timer.stop();
        return;
    }

    // Try to fill ALL available httpseed slots aggressively
    usz max_concurrent = ctx.httpseed_mgr.max_concurrent;
    while (active < max_concurrent)
    {
        // Pick a piece using gap-based selection (BEP 17)
        uint? piece_opt = ctx.dm.picker.pick_piece_for_webseed();
        if (catch piece_opt)
        {
            // No pieces available for httpseeds
            return;
        }

        uint piece_index = piece_opt;

        // Mark piece as downloading
        ctx.dm.picker.mark_downloading(piece_index)!!;

        // Start httpseed download
        if (catch err = ctx.httpseed_mgr.start_piece_download(
            piece_index,
            &on_httpseed_piece_complete,
            ctx))
        {
            // Failed to start - mark piece as free again
            ctx.dm.picker.mark_free(piece_index)!!;
            io::printfn("[HttpSeed] Failed to start piece %d download: %s", piece_index, err);
            break;  // Stop trying if we failed
        }

        // Successfully started - increment counter and continue filling slots
        active++;
    }
}

<*
 * HTTP seed piece completion callback.
 * Called when a piece download from an httpseed completes (success or failure).
 *>
fn void on_httpseed_piece_complete(uint piece_index, char[] piece_data, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    if (piece_data.len == 0)
    {
        // Download failed - mark piece as free for retry from peers
        io::printfn("[HttpSeed] Piece %d download failed, will retry from peers", piece_index);
        ctx.dm.picker.mark_free(piece_index)!!;
        return;
    }

    // Get expected hash for verification
    char[20] expected_hash;
    usz hash_offset = (usz)piece_index * 20;
    for (usz k = 0; k < 20; k++)
    {
        expected_hash[k] = ctx.torrent.info.pieces[hash_offset + k];
    }

    // Create a copy of piece data for async verification
    char[] piece_data_copy = mem::new_array(char, piece_data.len);
    for (usz j = 0; j < piece_data.len; j++)
    {
        piece_data_copy[j] = piece_data[j];
    }

    // Create context for httpseed verification callback
    HttpSeedVerifyContext* verify_ctx = mem::new(HttpSeedVerifyContext);
    verify_ctx.session = ctx;
    verify_ctx.piece_index = piece_index;
    verify_ctx.piece_data = piece_data_copy;

    // Start async verification
    piece_assembler::verify_data(ctx.get_loop(), piece_index, piece_data_copy,
                                 expected_hash, &on_httpseed_piece_verified, verify_ctx);
}

<*
 * HTTP seed piece verification callback.
 * Called after async hash verification of httpseed piece completes.
 *>
fn void on_httpseed_piece_verified(uint piece_index, bool verified, void* user_data) @public
{
    HttpSeedVerifyContext* verify_ctx = (HttpSeedVerifyContext*)user_data;
    Session* ctx = verify_ctx.session;

    if (!verified)
    {
        // Hash mismatch - permanently blacklist the httpseed URL (BEP 17 requirement)
        io::eprintfn("[HttpSeed] Piece %d hash mismatch - permanently disabling httpseed URL!", piece_index);

        // TODO: Track which URL was used for this piece and blacklist it
        // For now, we mark the piece as free for retry
        ctx.dm.picker.mark_free(piece_index)!!;

        // Free the piece data copy
        free(verify_ctx.piece_data);
        free(verify_ctx);
        return;
    }

    // Success! Pass to the standard piece completion handler
    on_download_piece_complete(piece_index, verify_ctx.piece_data, true, ctx);

    // Note: piece_data is freed by on_download_piece_complete -> on_piece_written
    free(verify_ctx);
}

<*
 * Trigger "completed" announce to all trackers.
 * Called when download finishes to notify trackers.
 *>
fn void trigger_completed_announce(Session* ctx) @public
{
    if (!ctx.tracker_discovery)
    {
        io::eprintfn("[Session] No tracker discovery - skipping completed announce");
        return;
    }

    // Use stored concrete type reference (avoids C3 interface vtable bug)
    ctx.tracker_discovery.trigger_event_announce("completed");
}

<*
 Called when all existing pieces have been verified.
*>
fn void on_all_pieces_verified(Session* ctx) @public
{
    usz total, complete, downloading;
    ctx.dm.get_progress(&total, &complete, &downloading);

    if (complete > 0)
    {
        double percent = (complete * 100.0) / total;
        io::printfn("  Found %d/%d existing pieces (%.1f%%)", complete, total, percent);

        // Save initial fastresume after verification completes
        // This captures verified pieces so we can skip verification on next run
        if (ctx.state_provider && ctx.torrent_path.len > 0)
        {
            storage::DownloadState state = build_download_state(ctx);
            defer state.free();

            if (catch err = ctx.state_provider.save_state(ctx.torrent_path, &state))
            {
                io::printfn("  Warning: Failed to save initial fastresume: %s", err);
            }
            else
            {
                io::printfn("  Saved initial fastresume (%d pieces verified)", complete);
            }
        }
    }
    else
    {
        io::printfn("  No existing pieces found - starting from scratch");
    }
    io::printfn("");

    // NOTE: Tracker announces now happen automatically via PeerDiscovery system
    // when start_discovery() is called on CompositePeerDiscovery later in setup

    // Publish SESSION_STARTED event
    if (ctx.event_bus)
    {
        SessionStateEvent evt = {
            .info_hash = ctx.torrent.info_hash,
            .message = "Session started"
        };
        ctx.event_bus.publish(SESSION_STARTED, &evt, SessionStateEvent.sizeof);
    }

    // Note: Peer discovery (DHT, Tracker, LSD, PEX) is now handled through
    // CompositePeerDiscovery in the unified initialization flow
}

// ============================================================================
// Upload Request Processing
// ============================================================================

<*
 Timer callback for processing upload requests.
 Runs every second to process pending upload requests from all peers.
*>
fn void on_upload_timer_tick(async::timer::Timer* timer, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    // Process upload requests for all connected peers
    ctx.peer_pool.peers.@each(; common::SocketAddress addr, peer_pool::TorrentPeer* peer_info)
    {
        // Only process for connected peers
        if (peer_info.state != peer_pool::PeerState.CONNECTED) return;
        if (!peer_info.connection) return;

        // Check if peer is unchoked (we allow them to download from us)
        if (peer_info.connection.am_choking) return;

        // Process pending uploads for this peer (max 10 requests per tick)
        upload_handler::process_pending_uploads(
            ctx.upload_mgr,
            ctx.sm,
            peer_info.connection,
            &addr,
            10  // Max requests per peer per tick
        );
    };
}

// ============================================================================
// DHT Tick Processing
// ============================================================================

<*
 DHT tick timer callback - processes RPC timeouts.
 Called every 1 second.
*>
fn void on_dht_tick(async::timer::Timer* timer, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    if (ctx.get_dht())
    {
        ctx.get_dht().tick();
    }
}

// ============================================================================
// Peer Discovery Composite Builder (Hexagonal Architecture)
// ============================================================================

<*
 Build a CompositePeerDiscovery that aggregates all available discovery sources.
 Respects BEP 27 (private torrents should not use DHT/LSD/PEX).

 @param ctx : "Download context"
 @return "CompositePeerDiscovery instance with all applicable sources"
*>
fn composite::CompositePeerDiscovery* build_peer_discovery_composite(Session* ctx) @public
{
    // Create composite aggregator
    composite::CompositePeerDiscovery* composite =
        composite::create();

    // Always add tracker discovery (works for both private and public torrents)
    if (ctx.tracker_mgr)
    {
        // Store concrete type for direct access to tracker-specific methods
        ctx.tracker_discovery = tracker::create(ctx.get_loop(), ctx.torrent, ctx.tracker_mgr, ctx.event_bus, &ctx.tracker_config);

        // Add to composite (cast to interface fat pointer)
        discovery::PeerDiscovery tracker_disc =
            (discovery::PeerDiscovery)ctx.tracker_discovery;
        composite.add_source(tracker_disc);
        io::printfn("[PeerDiscovery] Added tracker discovery");
    }

    // Only add DHT/LSD/PEX for non-private torrents (BEP 27)
    if (!ctx.torrent.info.private)
    {
        // Add DHT discovery if DHT client is available
        if (ctx.get_dht())
        {
            discovery::PeerDiscovery dht_disc =
                (discovery::PeerDiscovery)dht::create(ctx.get_dht(), ctx.get_loop());
            composite.add_source(dht_disc);
            io::printfn("[PeerDiscovery] Added DHT discovery");
        }

        // Add LSD discovery if LSD manager is available
        if (ctx.get_lsd_mgr())
        {
            discovery::PeerDiscovery lsd_disc =
                (discovery::PeerDiscovery)libtorrent::discovery::lsd::create(ctx.get_lsd_mgr(), ctx.get_loop());
            composite.add_source(lsd_disc);
            io::printfn("[PeerDiscovery] Added LSD discovery");
        }

        // Add PEX discovery if peer pool is available
        if (ctx.peer_pool)
        {
            discovery::PeerDiscovery pex_disc =
                (discovery::PeerDiscovery)pex::create(ctx.peer_pool);
            composite.add_source(pex_disc);
            io::printfn("[PeerDiscovery] Added PEX discovery");
        }
    }
    else
    {
        io::printfn("[PeerDiscovery] Skipping DHT/LSD/PEX for private torrent (BEP 27)");
    }

    usz source_count = composite.get_source_count();
    io::printfn("[PeerDiscovery] Composite initialized with %d sources", source_count);

    return composite;  // Return concrete type (no cast needed)
}

// ============================================================================
// DHT Initialization
// ============================================================================

<*
 Initialize DHT client for peer discovery.
*>
fn void init_dht(Session* ctx, ushort dht_port) @public
{
    // Generate DHT node ID (similar to peer ID)
    common::NodeId our_node_id = trackers::generate_peer_id();

    // Create DHT client
    ctx.manager.dht = dht_client::create_dht_client(our_node_id, ctx.get_loop(), dht_port, ctx.event_bus);
    if (!ctx.get_dht())
    {
        io::eprintfn("[DHT] Failed to create DHT client");
        ctx.manager.dht_enabled = false;
        return;
    }

    io::printfn("[DHT] Starting DHT on port %d", dht_port);

    // Add default bootstrap nodes
    ctx.get_dht().add_default_bootstrap_nodes();

    // Start bootstrap process
    ctx.get_dht().bootstrap();

    ctx.manager.dht_enabled = true;

    // Note: Periodic DHT peer discovery is now handled by DhtPeerDiscovery adapter
    // through the CompositePeerDiscovery pattern

    // Set up DHT tick timer for RPC timeout processing (every 1 second)
    // Only create if not already created by another session
    if (!ctx.manager.dht_tick_timer)
    {
        async::timer::Timer*? tick_timer_opt = async::timer::create(ctx.get_loop());
        if (catch err = tick_timer_opt)
        {
            io::eprintfn("[DHT] Warning: Failed to create DHT tick timer");
        }
        else
        {
            ctx.manager.dht_tick_timer = tick_timer_opt;
            ctx.manager.dht_tick_timer.start(1000, 1000,
                                     &on_dht_tick, ctx);
        }
    }
}

<*
 Callback for LSD peer discovery.
 Called when LSD discovers peers on the local network.

 @param infohash : "Info hash of the torrent"
 @param peers : "Array of discovered peer addresses"
 @param user_data : "Session pointer"
*>
fn void on_lsd_peers_discovered(common::InfoHash* infohash, common::SocketAddress[] peers, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    io::printfn("[LSD] Discovered %d peer(s) on local network", peers.len);

    // Add peers to the peer pool
    ctx.peer_pool.add_peers_from_lsd(peers);

    // Try to connect to new peers
    ctx.peer_pool.connect_to_peers();
}

<*
 Timer callback for periodic LSD announcements (every 5 minutes).

 @param timer : "Timer that fired"
 @param user_data : "Session pointer"
*>
fn void on_lsd_timer_tick(async::timer::Timer* timer, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    if (!ctx.is_lsd_enabled() || !ctx.get_lsd_mgr()) return;

    // Announce this torrent on the LAN using shared listen port
    ctx.get_lsd_mgr().announce(&ctx.torrent.info_hash, ctx.manager.listen_port);

    io::printfn("[LSD] Announced torrent on local network");
}

<*
 Initialize LSD (Local Service Discovery) for peer discovery.
 BEP 14: Discovers peers on the local network via UDP multicast.

 @param ctx : "Download context"
*>
fn void init_lsd(Session* ctx) @public
{
    // Check if torrent is private (BEP 27: private torrents must not use LSD)
    if (ctx.torrent.info.private)
    {
        io::printfn("[LSD] Torrent is private - LSD disabled per BEP 27");
        ctx.manager.lsd_enabled = false;
        return;
    }

    // Create LSD manager
    lsd::LsdManager*? mgr_opt = libtorrent::lsd::create(&on_lsd_peers_discovered, ctx);
    if (catch err = mgr_opt)
    {
        io::eprintfn("[LSD] Failed to create LSD manager");
        ctx.manager.lsd_enabled = false;
        return;
    }

    ctx.manager.lsd_mgr = mgr_opt;
    ctx.manager.lsd_enabled = true;

    io::printfn("[LSD] Starting Local Service Discovery (BEP 14)");

    // Start LSD
    ctx.get_lsd_mgr().start(ctx.get_loop());

    // Set up periodic announce timer (every 5 minutes per BEP 14)
    // Only create if not already created by another session
    if (!ctx.manager.lsd_timer)
    {
        async::timer::Timer*? timer_opt = async::timer::create(ctx.get_loop());
        if (catch err = timer_opt)
        {
            io::eprintfn("[LSD] Warning: Failed to create LSD timer");
        }
        else
        {
            ctx.manager.lsd_timer = timer_opt;
            // 300000ms = 5 minutes (BEP 14 spec)
            ctx.manager.lsd_timer.start(300000, 300000, &on_lsd_timer_tick, ctx);
        }
    }

    // Do initial announce
    ctx.get_lsd_mgr().announce(&ctx.torrent.info_hash, ctx.manager.listen_port);
    io::printfn("[LSD] Initial announce sent");
}

<*
 Callback for torrent file load completion.
*>
fn void on_download_load_complete(String data, int status, void* user_data) @public
{
    Session* ctx = (Session*)user_data;

    if (status != 0)
    {
        ZString error_str = (ZString)uv::strerror(status);
        io::eprintfn("Error loading file: %s (status=%d)", error_str, status);
        ctx.exit_code = 1;
        ctx.download_complete = true;
        return;
    }
    defer free(data);

    // Parse torrent
    libtorrent::metainfo::TorrentFile*? torrent = libtorrent::metainfo::parse(data);
    if (catch err = torrent)
    {
        io::eprintfn("Error parsing torrent: %s", err);
        ctx.exit_code = 1;
        ctx.download_complete = true;
        return;
    }

    ctx.torrent = torrent;

    // Calculate number of pieces
    uint num_pieces = (uint)((torrent.info.length + torrent.info.piece_length - 1) / torrent.info.piece_length);
    uint last_piece_length = (uint)(torrent.info.length % torrent.info.piece_length);
    if (last_piece_length == 0) last_piece_length = (uint)torrent.info.piece_length;

    // Display torrent info
    io::printfn("Name: %s", torrent.info.name);
    io::printfn("Size: %s", common::format_size(torrent.info.length));
    io::printfn("Pieces: %d x %s", num_pieces, common::format_size(torrent.info.piece_length));
    io::printfn("");

    // Build storage path (for multi-file torrents, append torrent name)
    String storage_path = ctx.save_path;
    bool need_free_path = false;
    if (torrent.info.is_multi_file)
    {
        DString path_builder;
        path_builder.append(ctx.save_path);
        if (ctx.save_path.len > 0 && ctx.save_path[ctx.save_path.len - 1] != '/')
        {
            path_builder.append("/");
        }
        path_builder.append(torrent.info.name);
        storage_path = path_builder.copy_str(mem);
        need_free_path = true;
    }
    defer if (need_free_path) free(storage_path);

    // Create storage manager
    storage_manager::StorageManager? sm_opt = storage_manager::create(
        ctx.get_loop(), &torrent.info, storage_path);
    if (catch err = sm_opt)
    {
        io::eprintfn("Error creating storage manager: %s", err);
        ctx.exit_code = 1;
        ctx.download_complete = true;
        return;
    }
    ctx.sm = mem::new(storage_manager::StorageManager);
    *ctx.sm = sm_opt;

    // BEP 21: Apply file selection (from CLI or resume data)
    String file_sel_to_apply = ctx.select_files_str;
    bool loaded_from_resume = false;

    // Try loading from resume data if no CLI selection
    if (file_sel_to_apply.len == 0 && ctx.state_provider && ctx.torrent_path.len > 0 && torrent.info.is_multi_file)
    {
        storage::DownloadState? state_opt = ctx.state_provider.load_state(ctx.torrent_path);
        if (catch err = state_opt)
        {
            // No resume data - that's fine
        }
        else
        {
            storage::DownloadState state = state_opt;
            defer state.free();

            if (state.file_selection.len > 0)
            {
                file_sel_to_apply = state.file_selection;
                loaded_from_resume = true;
                io::printfn("[BEP 21] Loaded file selection from resume data: %s", file_sel_to_apply);
            }
            // Also check file_priority if file_selection is empty (standard fastresume format)
            else if (state.file_priority.len > 0)
            {
                // Convert file_priority to file_selection string
                // Priority 0 = unselected, Priority > 0 = selected
                DString file_sel_buf;
                bool first = true;
                for (usz i = 0; i < state.file_priority.len; i++)
                {
                    if (state.file_priority[i] > 0)  // Any priority > 0 means selected
                    {
                        if (!first) file_sel_buf.append(",");
                        file_sel_buf.appendf("%d", i);
                        first = false;
                    }
                }
                if (file_sel_buf.str_view().len > 0)
                {
                    file_sel_to_apply = file_sel_buf.copy_str(mem);
                    loaded_from_resume = true;
                    io::printfn("[BEP 21] Loaded file selection from file_priority (%d files)", state.file_priority.len);
                }
            }
        }
    }

    // Apply file selection
    if (file_sel_to_apply.len > 0 && torrent.info.is_multi_file)
    {
        file_selection::FileSelection? selection_opt =
            file_selection::create_from_string(file_sel_to_apply, ctx.sm.files.len);

        if (catch err = selection_opt)
        {
            io::eprintfn("Error: Invalid file selection '%s'", file_sel_to_apply);
            io::eprintfn("Please specify valid file indices (e.g., '0,2,4')");
            ctx.exit_code = 1;
            ctx.download_complete = true;
            return;
        }

        file_selection::FileSelection selection = selection_opt;
        defer selection.free();

        // Apply selection to storage manager
        for (usz i = 0; i < ctx.sm.files.len; i++)
        {
            ctx.sm.files[i].is_selected = selection.is_file_selected(i);
        }

        // Update ctx.select_files_str for later use (save resume data on completion)
        if (loaded_from_resume)
        {
            ctx.select_files_str = file_sel_to_apply.copy(mem);
        }

        io::printfn("[BEP 21] File selection applied: %s", file_sel_to_apply);
        io::printfn("[BEP 21] Selected %d of %d files for download",
                   selection.count_selected(), selection.total_files);
    }
    else if (ctx.select_files_str.len > 0 && !torrent.info.is_multi_file)
    {
        io::printfn("[BEP 21] Warning: File selection ignored for single-file torrent");
    }

    // Create download manager (BEP 21: pass storage for file selection)
    ctx.dm = mem::new(download_manager::DownloadManager);
    *ctx.dm = download_manager::create(
        ctx.get_loop(),
        num_pieces,
        (uint)torrent.info.piece_length,
        last_piece_length,
        torrent.info.pieces,
        (usz)ctx.max_concurrent_pieces,  // Configurable concurrent pieces
        16384,  // 16KB blocks
        ctx.sm  // BEP 21: Storage manager for selective piece downloading
    );

    // Store num_pieces for resume verification
    ctx.num_pieces = num_pieces;
    ctx.pieces_verified_count = 0;
    ctx.next_piece_to_verify = 0;

    // Create speed tracker with default 5-second sliding window
    ctx.speed_tracker = speed_tracker::create();

    // Create peer pool
    common::PeerId our_peer_id = trackers::generate_peer_id();
    peer_pool::PeerPoolConfig pool_config = {
        .max_peerlist_size = 1000,                          // Track up to 1000 peers (vs old limit of 10)
        .max_active_connections = (usz)ctx.connections_limit,  // From SessionOptions
        .max_failcount = 3,                                 // Future: Phase 3 will track failures
        .min_reconnect_time = 60,                           // Future: Phase 3 will handle retries
        .transport = ctx.transport                          // Use transport from SessionOptions (BEP 29)
    };
    ctx.peer_pool = peer_pool::create(ctx.get_loop(), pool_config, &torrent.info_hash, &our_peer_id, torrent.info.private);
    io::printfn("Created peer pool (capacity: %d peers)", pool_config.max_peerlist_size);
    if (torrent.info.private)
    {
        io::printfn("⚠️  Private torrent detected - DHT and PEX will be disabled (BEP 27)");
    }

    // Set peer pool callbacks
    ctx.peer_pool.set_callbacks(
        &on_download_peer_connected,
        &on_download_peer_message,
        &on_download_peer_disconnected,
        ctx
    );

    // Set upload-only mode if requested (for dedicated seeders)
    if (ctx.upload_only)
    {
        ctx.peer_pool.set_upload_only(true);
        io::printfn("Upload-only mode enabled (dedicated seeding)");
    }
    io::printfn("");

    // Create upload manager
    ctx.upload_mgr = upload_manager::create(ctx.unchoke_slots_limit);
    io::printfn("Created upload manager (unchoke slots: %d)", ctx.unchoke_slots_limit);

    // Create upload timer (process upload requests every 1 second)
    async::timer::Timer*? upload_timer_opt = async::timer::create(ctx.get_loop());
    if (catch err = upload_timer_opt)
    {
        io::eprintfn("  Warning: Failed to create upload timer");
    }
    else
    {
        ctx.upload_timer = upload_timer_opt;
        ctx.upload_timer.start(1000, 1000, &on_upload_timer_tick, ctx);
        io::printfn("Started upload request processor (1s interval)");
    }

    // Create flush timer (sync files and save fastresume every 30 seconds)
    async::timer::Timer*? flush_timer_opt = async::timer::create(ctx.get_loop());
    if (catch err = flush_timer_opt)
    {
        io::eprintfn("  Warning: Failed to create flush timer");
    }
    else
    {
        ctx.flush_timer = flush_timer_opt;
        ctx.flush_timer.start(30000, 30000, &on_flush_timer_tick, ctx);
        io::printfn("Started periodic file sync and fastresume saves (30s interval)");
    }

    // Initialize tracker configuration (parallel announce settings)
    ctx.tracker_config = tracker::default_tracker_config();

    // Initialize multi-tracker manager (BEP 12)
    if (torrent.announce_list.len > 0)
    {
        // Use announce-list for multi-tracker support
        ctx.tracker_mgr = mem::new(tracker_manager::TrackerManager);
        *ctx.tracker_mgr = tracker_manager::initialize(torrent.announce_list);
        io::printfn("Multi-tracker support: %d tiers, %d total trackers",
                    ctx.tracker_mgr.get_tier_count(),
                    torrent.announce_list[0].len + (torrent.announce_list.len > 1 ? torrent.announce_list[1].len : 0));

        // Get first tracker from tier 0 for initial display
        ctx.current_tracker_url = ctx.tracker_mgr.get_next_tracker();

        // Publish tracker status changed event (initialization)
        event_types::TrackerEvent tracker_evt = event_types::create_tracker_event(
            ctx.current_tracker_url, "Idle", -1, "", ctx.tracker_mgr
        );
        ctx.event_bus.publish(event_types::EVENT_TRACKER_STATUS_CHANGED, &tracker_evt, event_types::TrackerEvent.sizeof);
    }
    else if (torrent.announce.len > 0)
    {
        // Single tracker - create a TrackerManager with one tier containing one tracker
        String[][] single_tracker_list = mem::new_array(String[], 1);
        single_tracker_list[0] = mem::new_array(String, 1);
        single_tracker_list[0][0] = torrent.announce;

        ctx.tracker_mgr = mem::new(tracker_manager::TrackerManager);
        *ctx.tracker_mgr = tracker_manager::initialize(single_tracker_list[..]);
        io::printfn("Single tracker: %s", torrent.announce);
        ctx.current_tracker_url = torrent.announce;

        // Publish tracker status changed event (initialization)
        event_types::TrackerEvent tracker_evt = event_types::create_tracker_event(
            ctx.current_tracker_url, "Idle", -1, "", ctx.tracker_mgr
        );
        ctx.event_bus.publish(event_types::EVENT_TRACKER_STATUS_CHANGED, &tracker_evt, event_types::TrackerEvent.sizeof);
    }
    else
    {
        // No trackers at all - DHT-only/web seed-only torrent
        ctx.tracker_mgr = null;
        ctx.current_tracker_url = "";
        io::printfn("No trackers found - will use DHT and web seeds only");

        // Publish tracker status changed event (initialization)
        event_types::TrackerEvent tracker_evt = event_types::create_tracker_event(
            "(none - DHT only)", "Idle", -1, "", null
        );
        ctx.event_bus.publish(event_types::EVENT_TRACKER_STATUS_CHANGED, &tracker_evt, event_types::TrackerEvent.sizeof);
    }

    // Initialize DHT for peer discovery (skip for private torrents per BEP 27)
    if (!ctx.torrent.info.private)
    {
        init_dht(ctx, (ushort)ctx.dht_port);  // From SessionOptions
    }
    else
    {
        io::printfn("[DHT] Skipping DHT initialization for private torrent (BEP 27)");
        ctx.manager.dht_enabled = false;
    }
    io::printfn("");

    // Initialize LSD for local peer discovery (BEP 14)
    // Also skipped for private torrents per BEP 27
    init_lsd(ctx);
    io::printfn("");

    // Initialize unified peer discovery (Hexagonal Architecture - Composite Pattern)
    io::printfn("Initializing peer discovery...");

    // Build composite with all applicable discovery sources
    ctx.peer_discovery_composite = build_peer_discovery_composite(ctx);

    // Start unified discovery through composite
    discovery::DiscoveryOptions options = discovery::default_options();
    ctx.peer_discovery_composite.start_discovery(
        &ctx.torrent.info_hash,
        &options,
        &on_peer_discovery_peers,
        &on_peer_discovery_complete,
        ctx
    );
    io::printfn("");

    // Initialize web seeding (BEP 19)
    // Only create if download is not already complete (optimization + prevents race conditions)
    if (torrent.url_list.len > 0 && !ctx.download_complete)
    {
        ctx.webseed_mgr = webseed::create(ctx.get_loop(), torrent, ctx.event_bus);  // Uses default: 20 concurrent downloads
        if (ctx.webseed_mgr)
        {
            io::printfn("Web seed support: %d URLs available", torrent.url_list.len);

            // Start web seed timer immediately (web seeds work independently of trackers)
            async::timer::Timer*? timer_opt = async::timer::create(ctx.get_loop());
            if (catch err = timer_opt)
            {
                io::eprintfn("Warning: Failed to create web seed timer");
            }
            else
            {
                ctx.webseed_timer = timer_opt;
                ctx.webseed_timer.start(2000, 2000, &on_webseed_timer_tick, ctx);
                io::printfn("Web seed timer started (checking every 2 seconds)");
            }
        }
    }
    else
    {
        ctx.webseed_mgr = null;
    }

    // Initialize HTTP seeding (BEP 17)
    // Only create if download is not already complete (optimization + prevents race conditions)
    if (torrent.httpseeds.len > 0 && !ctx.download_complete)
    {
        ctx.httpseed_mgr = httpseed::create(ctx.get_loop(), torrent, ctx.event_bus);  // Uses default: 20 concurrent downloads
        if (ctx.httpseed_mgr)
        {
            io::printfn("HTTP seed support: %d URLs available", torrent.httpseeds.len);

            // Start HTTP seed timer immediately (httpseeds work independently of trackers)
            async::timer::Timer*? timer_opt = async::timer::create(ctx.get_loop());
            if (catch err = timer_opt)
            {
                io::eprintfn("Warning: Failed to create HTTP seed timer");
            }
            else
            {
                ctx.httpseed_timer = timer_opt;
                ctx.httpseed_timer.start(2000, 2000, &on_httpseed_timer_tick, ctx);
                io::printfn("HTTP seed timer started (checking every 2 seconds)");
            }
        }
    }
    else
    {
        ctx.httpseed_mgr = null;
    }
    io::printfn("");

    // Initialize storage manager (create directories, open files)
    io::printfn("Initializing storage...");
    ctx.sm.initialize(&on_storage_initialized, ctx);
}
