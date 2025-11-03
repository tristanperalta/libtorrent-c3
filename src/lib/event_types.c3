module libtorrent::event_types;

import libtorrent::common;
import libtorrent::tracker_manager;

// Event type constants
const String EVENT_PROGRESS_UPDATED = "progress.updated";
const String EVENT_DOWNLOAD_STARTED = "download.started";
const String EVENT_DOWNLOAD_COMPLETE = "download.complete";
const String EVENT_DOWNLOAD_PAUSED = "download.paused";
const String EVENT_DOWNLOAD_RESUMED = "download.resumed";

const String EVENT_PIECE_COMPLETED = "piece.completed";
const String EVENT_PIECE_FAILED = "piece.failed";
const String EVENT_PIECE_DOWNLOADING = "piece.downloading";

const String EVENT_PEER_CONNECTED = "peer.connected";
const String EVENT_PEER_DISCONNECTED = "peer.disconnected";
const String EVENT_PEER_STATS_UPDATED = "peer.stats_updated";

const String EVENT_TRACKER_ANNOUNCE_STARTED = "tracker.announce_started";
const String EVENT_TRACKER_ANNOUNCE_SUCCESS = "tracker.announce_success";
const String EVENT_TRACKER_ANNOUNCE_FAILED = "tracker.announce_failed";
const String EVENT_TRACKER_NO_PEERS = "tracker.no_peers";
const String EVENT_TRACKER_STATUS_CHANGED = "tracker.status_changed";

const String EVENT_WEBSEED_DOWNLOAD_STARTED = "webseed.download_started";
const String EVENT_WEBSEED_DOWNLOAD_COMPLETE = "webseed.download_complete";
const String EVENT_WEBSEED_DOWNLOAD_FAILED = "webseed.download_failed";
const String EVENT_WEBSEED_URL_DISABLED = "webseed.url_disabled";

const String EVENT_DHT_STARTED = "dht.started";
const String EVENT_DHT_BOOTSTRAPPED = "dht.bootstrapped";
const String EVENT_DHT_PEERS_FOUND = "dht.peers_found";
const String EVENT_DHT_QUERY_COMPLETE = "dht.query_complete";

const String EVENT_STORAGE_INITIALIZED = "storage.initialized";
const String EVENT_STORAGE_VERIFICATION_STARTED = "storage.verification_started";
const String EVENT_STORAGE_VERIFICATION_PROGRESS = "storage.verification_progress";
const String EVENT_STORAGE_VERIFICATION_COMPLETE = "storage.verification_complete";

const String EVENT_ERROR_OCCURRED = "error.occurred";

// ============================================================================
// Event Payload Structures
// ============================================================================

/**
 * Progress event - overall download progress update
 */
struct ProgressEvent
{
    uint pieces_complete;      // Number of pieces completed
    uint pieces_downloading;   // Number of pieces currently downloading
    uint pieces_total;         // Total number of pieces in torrent
    ulong bytes_downloaded;    // Total bytes downloaded (all sources)
    float download_speed;      // Current download speed (bytes/sec)
    float upload_speed;        // Current upload speed (bytes/sec)
}

/**
 * Piece event - individual piece completion or failure
 */
struct PieceEvent
{
    uint piece_index;          // Which piece
    usz piece_size;            // Size in bytes
    bool success;              // true for completion, false for failure
    String source;             // "peer", "webseed", or null
}

/**
 * Peer event - peer connection state changes
 */
struct PeerEvent
{
    common::Ipv4Addr ip;       // Peer IP address
    ushort port;               // Peer port
    int peers_connected;       // Current number of connected peers
    int peers_total;           // Total peers in pool
    bool was_error;            // true if disconnect was due to error
}

/**
 * Tracker event - tracker announce results
 */
struct TrackerEvent
{
    String tracker_url;        // Tracker URL
    String status;             // "Working", "Trying...", "Failed", "Idle"
    int peers_returned;        // Number of peers returned (-1 if failed)
    String error_message;      // Error message (only for failures)
    tracker_manager::TrackerManager* tracker_mgr;  // Multi-tracker manager (can be null)
}

/**
 * Web seed event - web seed download events
 */
struct WebSeedEvent
{
    uint piece_index;          // Which piece
    String url;                // Web seed URL
    bool success;              // true for success, false for failure
    int http_status_code;      // HTTP status code (200, 404, 503, etc.) or 0 if N/A
    String error_message;      // Error message (only for failures)
    ulong bytes_downloaded;    // Total bytes downloaded from this URL (for stats)
}

/**
 * DHT event - DHT peer discovery events
 */
struct DhtEvent
{
    int peers_found;           // Number of peers found
    int routing_table_size;    // Number of nodes in routing table
    String status;             // Status message
}

/**
 * Storage event - storage and verification events
 */
struct StorageEvent
{
    uint pieces_verified;      // Number of pieces verified so far
    uint pieces_total;         // Total number of pieces
    bool complete;             // true when verification complete
}

/**
 * Error event - generic error notification
 */
struct ErrorEvent
{
    String message;            // Error message
    int error_code;            // Error code (0 = no specific code)
}

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Create a progress event.
 */
fn ProgressEvent create_progress_event(uint complete, uint downloading, uint total,
                                       ulong bytes, float dl_speed, float ul_speed) @public
{
    ProgressEvent evt;
    evt.pieces_complete = complete;
    evt.pieces_downloading = downloading;
    evt.pieces_total = total;
    evt.bytes_downloaded = bytes;
    evt.download_speed = dl_speed;
    evt.upload_speed = ul_speed;
    return evt;
}

/**
 * Create a piece event.
 */
fn PieceEvent create_piece_event(uint index, usz size, bool success, String source) @public
{
    PieceEvent evt;
    evt.piece_index = index;
    evt.piece_size = size;
    evt.success = success;
    evt.source = source;
    return evt;
}

/**
 * Create a peer event.
 */
fn PeerEvent create_peer_event(common::Ipv4Addr ip, ushort port,
                               int connected, int total, bool was_error) @public
{
    PeerEvent evt;
    evt.ip = ip;
    evt.port = port;
    evt.peers_connected = connected;
    evt.peers_total = total;
    evt.was_error = was_error;
    return evt;
}

/**
 * Create a tracker event.
 */
fn TrackerEvent create_tracker_event(String url, String status, int peers_returned,
                                     String error_msg, tracker_manager::TrackerManager* mgr) @public
{
    TrackerEvent evt;
    evt.tracker_url = url;
    evt.status = status;
    evt.peers_returned = peers_returned;
    evt.error_message = error_msg;
    evt.tracker_mgr = mgr;
    return evt;
}

/**
 * Create a web seed event.
 */
fn WebSeedEvent create_webseed_event(uint piece_index, String url, bool success,
                                     int http_status, String error_msg, ulong bytes_total) @public
{
    WebSeedEvent evt;
    evt.piece_index = piece_index;
    evt.url = url;
    evt.success = success;
    evt.http_status_code = http_status;
    evt.error_message = error_msg;
    evt.bytes_downloaded = bytes_total;
    return evt;
}

/**
 * Create a storage event.
 */
fn StorageEvent create_storage_event(uint verified, uint total, bool complete) @public
{
    StorageEvent evt;
    evt.pieces_verified = verified;
    evt.pieces_total = total;
    evt.complete = complete;
    return evt;
}

/**
 * Create a DHT event.
 */
fn DhtEvent create_dht_event(int peers_found, int routing_table_size, String status) @public
{
    DhtEvent evt;
    evt.peers_found = peers_found;
    evt.routing_table_size = routing_table_size;
    evt.status = status;
    return evt;
}

/**
 * Create an error event.
 */
fn ErrorEvent create_error_event(String message, int code) @public
{
    ErrorEvent evt;
    evt.message = message;
    evt.error_code = code;
    return evt;
}
