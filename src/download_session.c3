module torrent_client::download_session;

import std::io;
import std::time;
import std::encoding::hex;
import uv;
import libtorrent;
import libtorrent::common;
import libtorrent::tracker;
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
import libtorrent::download_state_provider;
import libtorrent::upload_manager;
import libtorrent::upload_handler;
import libtorrent::bitfield;
import async::timer;
import libtorrent::peer_pool;
import libtorrent::dht_client;
import libtorrent::dht_get_peers;
import libtorrent::lsd;
import libtorrent::webseed;
import libtorrent::httpseed;
import libtorrent::event_bus;
import libtorrent::event_types;
import libtorrent::speed_tracker;
import libtorrent::metadata_download;
import libtorrent::metadata_exchange;
import libtorrent::fast_extension;
import torrent_client::magnet_download_session;
import torrent_client::session_message_handler;
import torrent_client::session_tracker_coordinator;
import raylib_gui;

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
// Library users can override this via DownloadContext.max_concurrent_pieces
const int DEFAULT_MAX_CONCURRENT_PIECES = 30;

<*
 Context for async piece write operations.
*>
struct PieceWriteContext
{
    DownloadContext* download_ctx;
    char[] piece_data;  // Must be freed after write completes
}

<*
 Context for web seed piece verification.
*>
struct WebSeedVerifyContext
{
    DownloadContext* download_ctx;
    uint piece_index;
    char[] piece_data;  // Must be freed after verification
}

struct HttpSeedVerifyContext
{
    DownloadContext* download_ctx;
    uint piece_index;
    char[] piece_data;  // Must be freed after verification
}

<*
 Download session context for managing the download workflow.
*>
struct DownloadContext
{
    event_loop::EventLoop* loop;
    libtorrent::metainfo::TorrentFile* torrent;
    download_manager::DownloadManager* dm;
    storage_manager::StorageManager* sm;

    // Tracker state
    bool tracker_completed;
    tracker::TrackerResponse* tracker_response;
    session_tracker_coordinator::TrackerCoordinator* tracker_coord;  // Tracker announce coordinator
    async::timer::Timer* pex_timer;          // PEX update timer (every 60s)
    async::timer::Timer* keepalive_timer;    // Keepalive timer (every 120s)
    async::timer::Timer* flush_timer;        // File flush timer (configurable interval)
    async::timer::Timer* block_timeout_timer; // Block request timeout checker (every 10s)

    // Multi-tracker support (BEP 12)
    tracker_manager::TrackerManager* tracker_mgr;  // Manages tier-based tracker selection
    String current_tracker_url;                    // Currently active tracker URL (for logging)

    // Peer management
    peer_pool::PeerPool* peer_pool;

    // Upload/seeding
    upload_manager::UploadManager* upload_mgr;  // Upload request queue manager
    async::timer::Timer* upload_timer;          // Upload request processor (every 1s)

    // DHT peer discovery
    dht_client::DhtClient* dht_client;
    dht_get_peers::GetPeersSearch* dht_search;
    async::timer::Timer* dht_timer;         // Periodic DHT peer discovery
    async::timer::Timer* dht_check_timer;   // One-shot timer for checking DHT results
    async::timer::Timer* dht_tick_timer;    // RPC timeout processing timer
    bool dht_enabled;

    // LSD peer discovery (BEP 14)
    libtorrent::lsd::LsdManager* lsd_mgr;   // Local Service Discovery manager
    async::timer::Timer* lsd_timer;         // Periodic LSD announcements (every 5 minutes)
    bool lsd_enabled;

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
    download_state_provider::StateProvider* state_provider;  // BEP 21: Pluggable state persistence

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

    // GUI integration (null in CLI mode)
    raylib_gui::UIState* gui_state;

    // Event bus for pub/sub (decouples GUI from download logic)
    event_bus::EventBus* event_bus;
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

<*
 Format byte size in human-readable format.

 @param bytes : "Number of bytes"
 @return "Formatted string (e.g., \"1.5 GB\")"
*>
fn String format_size(long bytes) @public
{
    DString result;

    if (bytes < 1024)
    {
        result.appendf("%d bytes", bytes);
    }
    else if (bytes < 1024 * 1024)
    {
        double kb = (double)bytes / 1024.0;
        result.appendf("%.2f KB", kb);
    }
    else if (bytes < 1024 * 1024 * 1024)
    {
        double mb = (double)bytes / (1024.0 * 1024.0);
        result.appendf("%.2f MB", mb);
    }
    else
    {
        double gb = (double)bytes / (1024.0 * 1024.0 * 1024.0);
        result.appendf("%.2f GB", gb);
    }

    return result.copy_str(mem);
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
fn void check_file_completion(DownloadContext* ctx, uint piece_index)
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
fn bool is_file_complete_now(DownloadContext* ctx, usz file_index)
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
fn void on_partial_seed_complete(DownloadContext* ctx) @public
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
    if (ctx.tracker_coord)
    {
        ctx.tracker_coord.start_announce("completed");
    }

    // BEP 21: Save resume data with file selection
    if (ctx.state_provider && ctx.torrent_path.len > 0 && ctx.select_files_str.len > 0)
    {
        download_state_provider::DownloadState state;
        state.file_selection = ctx.select_files_str;
        state.version = 1;

        if (catch err = ctx.state_provider.save_state(ctx.torrent_path, &state))
        {
            io::eprintfn("[BEP 21] Warning: Failed to save resume data");
        }
        else
        {
            io::printfn("[BEP 21] Saved file selection to resume data");
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

    if (ctx.lsd_timer)
    {
        ctx.lsd_timer.close();
        ctx.lsd_timer = null;
    }

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
fn void on_complete_download(DownloadContext* ctx) @public
{
    io::printfn("");
    io::printfn("=== Download Complete! ===");
    io::printfn("All %d pieces verified successfully", ctx.num_pieces);
    io::printfn("Entering seeding mode - will continue uploading to peers...");
    io::printfn("");

    // Mark download as complete
    ctx.download_complete = true;

    // Send "completed" event to tracker (announces we're now seeding)
    if (ctx.tracker_coord)
    {
        ctx.tracker_coord.start_announce("completed");
    }

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
    if (ctx.lsd_timer)
    {
        ctx.lsd_timer.close();
        ctx.lsd_timer = null;
    }
    // Keep LSD manager active to respond to announcements from other peers

    // Event loop continues running - client now seeds until user presses Ctrl+C
}

<*
 Callback for piece completion - write to disk.
*>
fn void on_download_piece_complete(uint piece_index, char[] piece_data, bool success, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

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
        ctx.dm.fail_piece(piece_index)!!;
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
    download_session::PieceWriteContext* write_ctx = mem::new(download_session::PieceWriteContext);
    write_ctx.download_ctx = ctx;
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
                return; // Exit @each early (was break)
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
fn void request_blocks_from_peers(download_session::DownloadContext* ctx) @public
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
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    // Peer connected and ready (BEP 7: dual-stack)
    io::printfn("  Peer %s connected and ready", addr);

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
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    // Peer disconnected (BEP 7: dual-stack)
    io::printfn("  Peer %s disconnected%s",
                addr,
                was_error ? " (error)" : "");

    // Log state before completion check
    int shutting_down_val = ctx.peer_pool ? (int)ctx.peer_pool.shutting_down : -1;
    logger::logf(logger::LogLevel.DEBUG,
                 "Peer disconnected. download_complete=%d, is_complete=%d, shutting_down=%d",
                 ctx.download_complete, ctx.dm.is_complete(), shutting_down_val);

    // Peer pool automatically tries to replace failed connections
    // Check if download is complete (and we haven't already handled completion)
    if (!ctx.download_complete && ctx.dm.is_complete())
    {
        io::printfn("");
        io::printfn("Download complete!");
        logger::logf(logger::LogLevel.DEBUG,
                     "Calling on_complete_download() - setting download_complete=true");
        on_complete_download(ctx);
        logger::logf(logger::LogLevel.DEBUG,
                     "Returned from on_complete_download() - download_complete should be %d",
                     ctx.download_complete);
        return;
    }

    logger::log(logger::LogLevel.DEBUG,
                "Skipping completion (already handled or not complete yet)");

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
 Callback for tracker announce completion.
*>
fn void on_download_tracker_complete(tracker::TrackerResponse* response, int status, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;
    ctx.tracker_completed = true;
    // Note: Don't save response pointer - it becomes invalid after this callback returns

    if (status != 0 || !response)
    {
        String error_desc = download_session::tracker_error_string(status);
        io::eprintfn("Error announcing to tracker: %s (status=%d)", error_desc, status);

        // Publish tracker error event
        DString error_msg;
        error_msg.appendf("Error: %s", error_desc);
        event_types::TrackerEvent tracker_evt = event_types::create_tracker_event(
            "", "Failed", -1, error_msg.str_view(), null
        );
        ctx.event_bus.publish(event_types::EVENT_TRACKER_ANNOUNCE_FAILED, &tracker_evt, event_types::TrackerEvent.sizeof);

        ctx.exit_code = 1;
        ctx.download_complete = true;
        return;
    }

    if (response.failure_reason.len > 0)
    {
        io::eprintfn("Tracker error: %s", response.failure_reason);

        // Publish tracker failure event
        DString error_msg;
        error_msg.appendf("Error: %s", response.failure_reason);
        event_types::TrackerEvent tracker_evt = event_types::create_tracker_event(
            "", "Failed", -1, response.failure_reason, null
        );
        ctx.event_bus.publish(event_types::EVENT_TRACKER_ANNOUNCE_FAILED, &tracker_evt, event_types::TrackerEvent.sizeof);

        ctx.exit_code = 1;
        ctx.download_complete = true;
        return;
    }

    int num_peers = (int)response.peers.len;
    if (num_peers == 0)
    {
        io::printfn("No peers returned by tracker - will retry later");

        // Publish no peers event
        event_types::TrackerEvent tracker_evt = event_types::create_tracker_event(
            "", "No peers available", 0, "", null
        );
        ctx.event_bus.publish(event_types::EVENT_TRACKER_NO_PEERS, &tracker_evt, event_types::TrackerEvent.sizeof);

        // Don't stop download, just wait for next re-announce
        return;
    }

    io::printfn("Tracker returned %d peers", num_peers);

    // Publish tracker success event
    DString success_msg;
    success_msg.appendf("Announce OK (%d peers)", num_peers);
    event_types::TrackerEvent tracker_evt = event_types::create_tracker_event(
        "", "Working", num_peers, "", null
    );
    ctx.event_bus.publish(event_types::EVENT_TRACKER_ANNOUNCE_SUCCESS, &tracker_evt, event_types::TrackerEvent.sizeof);

    // Add all peers to peer pool (already SocketAddress[] from tracker)
    ctx.peer_pool.add_peers_from_tracker(response.peers);

    // Show peer pool stats
    usz total_peers, candidates, connecting, connected;
    ctx.peer_pool.get_stats(&total_peers, &candidates, &connecting, &connected);

    // Publish peer stats updated event
    event_types::PeerEvent peer_evt = event_types::create_peer_event(
        (common::Ipv4Addr){0,0,0,0}, 0, (int)connected, (int)total_peers, false
    );
    ctx.event_bus.publish(event_types::EVENT_PEER_STATS_UPDATED, &peer_evt, event_types::PeerEvent.sizeof);

    io::printfn("  Peer pool now has %d total peers (%d candidates, %d connecting, %d connected)",
                total_peers, candidates, connecting, connected);

    // Automatically connect to best peers
    io::printfn("Connecting to best peers...");
    ctx.peer_pool.connect_to_peers();

    // Show updated stats
    ctx.peer_pool.get_stats(&total_peers, &candidates, &connecting, &connected);
    io::printfn("  Started %d new connections (total: %d connecting)", connecting - connected, connecting);

    io::printfn("");
    io::printfn("Download in progress...");
    io::printfn("(Download will continue until complete or Ctrl+C)");
    io::printfn("");
}

<*
 Callback when storage manager initialization completes.
*>
fn void on_storage_initialized(int status, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

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

    // Now we can safely verify existing pieces (resume support)
    io::printfn("Checking for existing pieces...");
    verify_all_existing_pieces_async(ctx);
}

<*
 Callback when a piece has been written to disk.
*>
fn void on_piece_written(uint piece_index, int status, void* user_data) @public
{
    download_session::PieceWriteContext* write_ctx = (download_session::PieceWriteContext*)user_data;
    download_session::DownloadContext* ctx = write_ctx.download_ctx;

    if (status == 0)
    {
        io::printfn("  Piece %d written to disk", piece_index);

        // BEP 21: Check if this piece completes any files
        check_file_completion(ctx, piece_index);
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
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;
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
fn void start_piece_verification(download_session::DownloadContext* ctx, uint piece_index) @public
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
 Verify all existing pieces on disk (resume support).
 Calls verify_piece() for each piece asynchronously.
*>
fn void verify_all_existing_pieces_async(download_session::DownloadContext* ctx) @public
{
    if (ctx.num_pieces == 0)
    {
        // No pieces to verify, start announce immediately
        on_all_pieces_verified(ctx);
        return;
    }

    // Start first batch of pieces (limited by download_session::VERIFICATION_BATCH_SIZE)
    // This prevents overwhelming the system with too many concurrent verifications
    uint batch_end = ctx.num_pieces < download_session::VERIFICATION_BATCH_SIZE ? ctx.num_pieces : download_session::VERIFICATION_BATCH_SIZE;

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
// Tracker Coordinator Callbacks
// ============================================================================

<*
 Callback when tracker coordinator receives peers.
*>
fn void on_tracker_peers_received(tracker::TrackerResponse* response, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    // NOTE: Do NOT store or free the response pointer - it points to stack-allocated memory
    // in http_tracker that will be automatically freed when AnnounceContext is freed

    // Get current tracker URL from coordinator
    String active_tracker = ctx.tracker_coord.get_current_tracker();
    if (active_tracker.len > 0)
    {
        ctx.current_tracker_url = active_tracker;
    }

    // Publish tracker success event
    int peer_count = response ? (int)response.peers.len : -1;
    event_types::TrackerEvent tracker_evt = event_types::create_tracker_event(
        ctx.current_tracker_url, "Working", peer_count, "", ctx.tracker_mgr
    );
    ctx.event_bus.publish(event_types::EVENT_TRACKER_STATUS_CHANGED, &tracker_evt, event_types::TrackerEvent.sizeof);

    // Start PEX timer if not already running (every 60 seconds)
    if (!ctx.pex_timer)
    {
        async::timer::Timer*? timer_opt = async::timer::create(ctx.loop);
        if (catch err = timer_opt)
        {
            io::eprintfn("  Warning: Failed to create PEX timer");
        }
        else
        {
            ctx.pex_timer = timer_opt;
            // Start after 60 seconds, then repeat every 60 seconds
            ctx.pex_timer.start(60000, 60000,
                                &on_pex_timer_tick, ctx);
        }
    }

    // Start keepalive timer if not already running (every 120 seconds per BEP 3)
    if (!ctx.keepalive_timer)
    {
        async::timer::Timer*? timer_opt = async::timer::create(ctx.loop);
        if (catch err = timer_opt)
        {
            io::eprintfn("  Warning: Failed to create keepalive timer");
        }
        else
        {
            ctx.keepalive_timer = timer_opt;
            // Start after 120 seconds, then repeat every 120 seconds
            ctx.keepalive_timer.start(120000, 120000,
                                      &on_keepalive_timer_tick, ctx);
        }
    }

    // Start file flush timer if not already running and interval is configured
    if (!ctx.flush_timer && download_session::FILE_FLUSH_INTERVAL_MS > 0)
    {
        async::timer::Timer*? timer_opt = async::timer::create(ctx.loop);
        if (catch err = timer_opt)
        {
            io::eprintfn("  Warning: Failed to create flush timer");
        }
        else
        {
            ctx.flush_timer = timer_opt;
            // Start with configured interval
            ctx.flush_timer.start(download_session::FILE_FLUSH_INTERVAL_MS, download_session::FILE_FLUSH_INTERVAL_MS,
                                  &on_flush_timer_tick, ctx);
        }
    }

    // Start block timeout check timer if not already running
    if (!ctx.block_timeout_timer && download_session::BLOCK_TIMEOUT_CHECK_INTERVAL_MS > 0)
    {
        async::timer::Timer*? timer_opt = async::timer::create(ctx.loop);
        if (catch err = timer_opt)
        {
            io::eprintfn("  Warning: Failed to create block timeout timer");
        }
        else
        {
            ctx.block_timeout_timer = timer_opt;
            // Start with configured interval (10 seconds)
            ctx.block_timeout_timer.start(download_session::BLOCK_TIMEOUT_CHECK_INTERVAL_MS,
                                          download_session::BLOCK_TIMEOUT_CHECK_INTERVAL_MS,
                                          &on_block_timeout_timer_tick, ctx);
        }
    }

    // Call existing tracker completion handler
    on_download_tracker_complete(response, 0, ctx);
}

<*
 Callback when tracker coordinator fails after all retries.
*>
fn void on_tracker_failed(String error_msg, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    io::eprintfn("Tracker failed after all retries: %s", error_msg);

    // Publish tracker failure event
    event_types::TrackerEvent tracker_evt = event_types::create_tracker_event(
        ctx.current_tracker_url, "Failed", -1, error_msg, ctx.tracker_mgr
    );
    ctx.event_bus.publish(event_types::EVENT_TRACKER_STATUS_CHANGED, &tracker_evt, event_types::TrackerEvent.sizeof);

    // Continue with DHT and web seeds if available
    io::printfn("Continuing with DHT and web seeds...");
}


<*
 PEX timer callback - sends queued PEX updates to all connected peers.
 Runs every 60 seconds per BEP 11 rate limiting.
*>
fn void on_pex_timer_tick(async::timer::Timer* timer, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

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
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

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
*>
fn void on_flush_timer_tick(async::timer::Timer* timer, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

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
}

<*
 Timer callback for checking block request timeouts.
 Runs every 10 seconds to check for blocks stuck in REQUESTED state.
*>
fn void on_block_timeout_timer_tick(async::timer::Timer* timer, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

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
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

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
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

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
    verify_ctx.download_ctx = ctx;
    verify_ctx.piece_index = piece_index;
    verify_ctx.piece_data = piece_data_copy;

    // Start async verification
    piece_assembler::verify_data(ctx.loop, piece_index, piece_data_copy,
                                 expected_hash, &on_webseed_piece_verified, verify_ctx);
}

<*
 Web seed piece verification callback.
 Called after async hash verification of web seed piece completes.
*>
fn void on_webseed_piece_verified(uint piece_index, bool verified, void* user_data) @public
{
    WebSeedVerifyContext* verify_ctx = (WebSeedVerifyContext*)user_data;
    DownloadContext* ctx = verify_ctx.download_ctx;

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
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

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
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

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
    verify_ctx.download_ctx = ctx;
    verify_ctx.piece_index = piece_index;
    verify_ctx.piece_data = piece_data_copy;

    // Start async verification
    piece_assembler::verify_data(ctx.loop, piece_index, piece_data_copy,
                                 expected_hash, &on_httpseed_piece_verified, verify_ctx);
}

<*
 * HTTP seed piece verification callback.
 * Called after async hash verification of httpseed piece completes.
 *>
fn void on_httpseed_piece_verified(uint piece_index, bool verified, void* user_data) @public
{
    HttpSeedVerifyContext* verify_ctx = (HttpSeedVerifyContext*)user_data;
    DownloadContext* ctx = verify_ctx.download_ctx;

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
 Start tracker announce with retry support.
 Uses multi-tracker manager (BEP 12) if available.
*>
fn void announce_with_retry(download_session::DownloadContext* ctx) @public
{
    // Check if tracker coordinator is initialized
    if (!ctx.tracker_coord)
    {
        io::eprintfn("Error: Tracker coordinator not initialized");
        return;
    }

    // Use tracker coordinator for announces with retry support
    // Determine event type based on whether this is initial announce
    String event = ctx.tracker_coord.is_initial_announce_done() ? "" : "started";

    // Reset tracker manager to beginning of tier for new announce cycle
    if (ctx.tracker_mgr && ctx.tracker_mgr.has_trackers())
    {
        ctx.tracker_mgr.reset();
    }

    // Start announce with automatic retry and failover
    ctx.tracker_coord.start_announce(event);
}

<*
 Called when all existing pieces have been verified.
 Starts the tracker announce process.
*>
fn void on_all_pieces_verified(download_session::DownloadContext* ctx) @public
{
    usz total, complete, downloading;
    ctx.dm.get_progress(&total, &complete, &downloading);

    if (complete > 0)
    {
        double percent = (complete * 100.0) / total;
        io::printfn("  Found %d/%d existing pieces (%.1f%%)", complete, total, percent);
    }
    else
    {
        io::printfn("  No existing pieces found - starting from scratch");
    }
    io::printfn("");

    // Now start tracker announce (if we have trackers)
    if (ctx.tracker_mgr && ctx.tracker_mgr.has_trackers())
    {
        io::printfn("Announcing to trackers (%d tiers available)...", ctx.tracker_mgr.get_tier_count());
        announce_with_retry(ctx);
    }
    else if (ctx.torrent.announce.len > 0)
    {
        io::printfn("Announcing to tracker: %s", ctx.torrent.announce);
        announce_with_retry(ctx);
    }
    else
    {
        io::printfn("Skipping tracker announce (no trackers configured)");
    }

    // Start DHT peer discovery if enabled
    if (ctx.dht_enabled && ctx.dht_client)
    {
        io::printfn("Starting DHT peer discovery...");
        start_dht_peer_discovery(ctx);
    }
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
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

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
// DHT Peer Discovery
// ============================================================================

<*
 Timer callback for periodic DHT peer discovery.
 Re-queries DHT for peers every 5 minutes.
*>
fn void on_dht_timer_tick(async::timer::Timer* timer, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    // Free previous search if exists
    if (ctx.dht_search)
    {
        ctx.dht_search.free();
        ctx.dht_search = null;
    }

    // Start new DHT peer discovery
    start_dht_peer_discovery(ctx);
}

<*
 DHT tick timer callback - processes RPC timeouts.
 Called every 1 second.
*>
fn void on_dht_tick(async::timer::Timer* timer, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    if (ctx.dht_client)
    {
        ctx.dht_client.tick();
    }
}

<*
 Start DHT peer discovery for the torrent's info hash.
*>
fn void start_dht_peer_discovery(download_session::DownloadContext* ctx) @public
{
    if (!ctx.dht_client || !ctx.torrent) return;

    // Create get_peers search if it doesn't exist
    if (!ctx.dht_search)
    {
        ctx.dht_search = dht_get_peers::create_search(ctx.torrent.info_hash);
    }

    // BEP 32: Query both IPv4 and IPv6 routing tables for closest nodes
    dht_routing_table::NodeEntry[] ipv4_nodes =
        ctx.dht_client.routing_table_ipv4.find_closest_nodes(ctx.torrent.info_hash, 8);
    defer free(ipv4_nodes);

    dht_routing_table::NodeEntry[] ipv6_nodes =
        ctx.dht_client.routing_table_ipv6.find_closest_nodes(ctx.torrent.info_hash, 8);
    defer free(ipv6_nodes);

    // Merge results from both tables
    usz total_nodes = ipv4_nodes.len + ipv6_nodes.len;
    if (total_nodes == 0)
    {
        io::printfn("[DHT] No nodes in routing tables yet, will retry later");
        return;
    }

    dht_routing_table::NodeEntry[] nodes = mem::new_array(dht_routing_table::NodeEntry, total_nodes);
    defer free(nodes);

    // Copy IPv4 nodes
    for (usz i = 0; i < ipv4_nodes.len; i++)
    {
        nodes[i] = ipv4_nodes[i];
    }

    // Copy IPv6 nodes
    for (usz i = 0; i < ipv6_nodes.len; i++)
    {
        nodes[ipv4_nodes.len + i] = ipv6_nodes[i];
    }

    io::printfn("[DHT] Querying %d DHT nodes for peers (%d IPv4, %d IPv6)...",
        nodes.len, ipv4_nodes.len, ipv6_nodes.len);

    // Send get_peers query to each node
    for (int i = 0; i < (int)nodes.len; i++)
    {
        ctx.dht_client.send_get_peers(
            nodes[i].id,
            nodes[i].addr,
            ctx.torrent.info_hash,
            ctx.dht_search
        );
    }

    // Schedule check for results in 5 seconds
    // Close any existing check timer first
    if (ctx.dht_check_timer)
    {
        ctx.dht_check_timer.close();
        ctx.dht_check_timer = null;
    }

    async::timer::Timer*? check_timer_opt = async::timer::create(ctx.loop);
    if (catch err = check_timer_opt)
    {
        io::eprintfn("[DHT] Warning: Failed to create check timer");
    }
    else
    {
        ctx.dht_check_timer = check_timer_opt;
        ctx.dht_check_timer.start(5000, 0, &on_dht_check_results, ctx);
    }
}

<*
 Timer callback to check DHT peer discovery results.
 Called 5 seconds after sending get_peers queries.
*>
fn void on_dht_check_results(async::timer::Timer* timer, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    if (!ctx.dht_search)
    {
        timer.close();
        ctx.dht_check_timer = null;
        return;
    }

    // Check if we found any peers
    if (dht_get_peers::found_peers(ctx.dht_search))
    {
        on_dht_peers_found(ctx);
    }
    else
    {
        io::printfn("[DHT] No peers found yet, will retry on next timer");
    }

    // Close timer (one-shot) and clear reference
    timer.close();
    ctx.dht_check_timer = null;
}

<*
 Process DHT peer discovery results and add peers to peer pool.
*>
fn void on_dht_peers_found(download_session::DownloadContext* ctx) @public
{
    if (!ctx.dht_search) return;

    // Get discovered peers from DHT (already SocketAddress[])
    common::SocketAddress[] dht_peers = ctx.dht_search.get_peers();
    defer free(dht_peers);

    if (dht_peers.len == 0)
    {
        io::printfn("[DHT] No peers found");
        return;
    }

    io::printfn("[DHT] Found %d peers", dht_peers.len);
    ctx.peer_pool.add_peers_from_dht(dht_peers);

    // Show updated peer pool stats
    usz total_peers, candidates, connecting, connected;
    ctx.peer_pool.get_stats(&total_peers, &candidates, &connecting, &connected);
    io::printfn("  Peer pool now has %d total peers (%d candidates)",
                total_peers, candidates);

    // Try to connect to new peers
    ctx.peer_pool.connect_to_peers();
}

<*
 Initialize DHT client for peer discovery.
*>
fn void init_dht(download_session::DownloadContext* ctx, ushort dht_port) @public
{
    // Generate DHT node ID (similar to peer ID)
    common::NodeId our_node_id = tracker::generate_peer_id();

    // Create DHT client
    ctx.dht_client = dht_client::create_dht_client(our_node_id, ctx.loop, dht_port, ctx.event_bus);
    if (!ctx.dht_client)
    {
        io::eprintfn("[DHT] Failed to create DHT client");
        ctx.dht_enabled = false;
        return;
    }

    io::printfn("[DHT] Starting DHT on port %d", dht_port);

    // Add default bootstrap nodes
    ctx.dht_client.add_default_bootstrap_nodes();

    // Start bootstrap process
    ctx.dht_client.bootstrap();

    ctx.dht_enabled = true;

    // Set up periodic DHT query timer (every 5 minutes)
    async::timer::Timer*? timer_opt = async::timer::create(ctx.loop);
    if (catch err = timer_opt)
    {
        io::eprintfn("[DHT] Warning: Failed to create DHT timer");
    }
    else
    {
        ctx.dht_timer = timer_opt;
        ctx.dht_timer.start(300000, 300000,
                            &on_dht_timer_tick, ctx);
    }

    // Set up DHT tick timer for RPC timeout processing (every 1 second)
    async::timer::Timer*? tick_timer_opt = async::timer::create(ctx.loop);
    if (catch err = tick_timer_opt)
    {
        io::eprintfn("[DHT] Warning: Failed to create DHT tick timer");
    }
    else
    {
        ctx.dht_tick_timer = tick_timer_opt;
        ctx.dht_tick_timer.start(1000, 1000,
                                 &on_dht_tick, ctx);
    }
}

<*
 Callback for LSD peer discovery.
 Called when LSD discovers peers on the local network.

 @param infohash : "Info hash of the torrent"
 @param peers : "Array of discovered peer addresses"
 @param user_data : "DownloadContext pointer"
*>
fn void on_lsd_peers_discovered(common::InfoHash* infohash, common::SocketAddress[] peers, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    io::printfn("[LSD] Discovered %d peer(s) on local network", peers.len);

    // Add peers to the peer pool
    ctx.peer_pool.add_peers_from_lsd(peers);

    // Try to connect to new peers
    ctx.peer_pool.connect_to_peers();
}

<*
 Timer callback for periodic LSD announcements (every 5 minutes).

 @param timer : "Timer that fired"
 @param user_data : "DownloadContext pointer"
*>
fn void on_lsd_timer_tick(async::timer::Timer* timer, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    if (!ctx.lsd_enabled || !ctx.lsd_mgr) return;

    // Announce this torrent on the LAN
    // Note: Port should be the BitTorrent listening port (6881 is typical)
    // In a real implementation, this should come from configuration
    ushort bt_port = 6881;

    ctx.lsd_mgr.announce(&ctx.torrent.info_hash, bt_port);

    io::printfn("[LSD] Announced torrent on local network");
}

<*
 Initialize LSD (Local Service Discovery) for peer discovery.
 BEP 14: Discovers peers on the local network via UDP multicast.

 @param ctx : "Download context"
*>
fn void init_lsd(download_session::DownloadContext* ctx) @public
{
    // Check if torrent is private (BEP 27: private torrents must not use LSD)
    if (ctx.torrent.info.private)
    {
        io::printfn("[LSD] Torrent is private - LSD disabled per BEP 27");
        ctx.lsd_enabled = false;
        return;
    }

    // Create LSD manager
    lsd::LsdManager*? mgr_opt = lsd::create(&on_lsd_peers_discovered, ctx);
    if (catch err = mgr_opt)
    {
        io::eprintfn("[LSD] Failed to create LSD manager");
        ctx.lsd_enabled = false;
        return;
    }

    ctx.lsd_mgr = mgr_opt;
    ctx.lsd_enabled = true;

    io::printfn("[LSD] Starting Local Service Discovery (BEP 14)");

    // Start LSD
    ctx.lsd_mgr.start(ctx.loop);

    // Set up periodic announce timer (every 5 minutes per BEP 14)
    async::timer::Timer*? timer_opt = async::timer::create(ctx.loop);
    if (catch err = timer_opt)
    {
        io::eprintfn("[LSD] Warning: Failed to create LSD timer");
    }
    else
    {
        ctx.lsd_timer = timer_opt;
        // 300000ms = 5 minutes (BEP 14 spec)
        ctx.lsd_timer.start(300000, 300000, &on_lsd_timer_tick, ctx);
    }

    // Do initial announce
    ushort bt_port = 6881;
    ctx.lsd_mgr.announce(&ctx.torrent.info_hash, bt_port);
    io::printfn("[LSD] Initial announce sent");
}

<*
 Callback for torrent file load completion.
*>
fn void on_download_load_complete(String data, int status, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

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
    io::printfn("Size: %s", download_session::format_size(torrent.info.length));
    io::printfn("Pieces: %d x %s", num_pieces, download_session::format_size(torrent.info.piece_length));
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
        ctx.loop, &torrent.info, storage_path);
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
        download_state_provider::DownloadState? state_opt = ctx.state_provider.load_state(ctx.torrent_path);
        if (catch err = state_opt)
        {
            // No resume data - that's fine
        }
        else
        {
            download_state_provider::DownloadState state = state_opt;
            defer state.free();

            if (state.file_selection.len > 0)
            {
                file_sel_to_apply = state.file_selection;
                loaded_from_resume = true;
                io::printfn("[BEP 21] Loaded file selection from resume data: %s", file_sel_to_apply);
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
        ctx.loop,
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
    common::PeerId our_peer_id = tracker::generate_peer_id();
    peer_pool::PeerPoolConfig pool_config = {
        .max_peerlist_size = 1000,     // Track up to 1000 peers (vs old limit of 10)
        .max_active_connections = 25,   // Future: Phase 3 will manage connections
        .max_failcount = 3,             // Future: Phase 3 will track failures
        .min_reconnect_time = 60        // Future: Phase 3 will handle retries
    };
    ctx.peer_pool = peer_pool::create(ctx.loop, pool_config, &torrent.info_hash, &our_peer_id, torrent.info.private);
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
    io::printfn("");

    // Create upload manager
    ctx.upload_mgr = upload_manager::create();
    io::printfn("Created upload manager");

    // Create upload timer (process upload requests every 1 second)
    async::timer::Timer*? upload_timer_opt = async::timer::create(ctx.loop);
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

    // Initialize multi-tracker manager (BEP 12)
    if (torrent.announce_list.len > 0)
    {
        // Use announce-list for multi-tracker support
        ctx.tracker_mgr = mem::new(tracker_manager::TrackerManager);
        *ctx.tracker_mgr = tracker_manager::initialize(torrent.announce_list);
        io::printfn("Multi-tracker support: %d tiers, %d total trackers",
                    ctx.tracker_mgr.get_tier_count(),
                    torrent.announce_list[0].len + (torrent.announce_list.len > 1 ? torrent.announce_list[1].len : 0));
        ctx.current_tracker_url = "";

        // Publish tracker status changed event (initialization)
        event_types::TrackerEvent tracker_evt = event_types::create_tracker_event(
            ctx.current_tracker_url, "Idle", -1, "", ctx.tracker_mgr
        );
        ctx.event_bus.publish(event_types::EVENT_TRACKER_STATUS_CHANGED, &tracker_evt, event_types::TrackerEvent.sizeof);
    }
    else
    {
        // Fallback to single tracker
        ctx.tracker_mgr = null;
        ctx.current_tracker_url = torrent.announce;

        // If announce is empty, this is likely a DHT-only/web seed-only torrent
        if (ctx.current_tracker_url.len == 0)
        {
            io::printfn("No trackers found - will use DHT and web seeds only");
        }

        // Publish tracker status changed event (initialization)
        String display_url = ctx.current_tracker_url.len > 0 ? ctx.current_tracker_url : "(none - DHT only)";
        event_types::TrackerEvent tracker_evt = event_types::create_tracker_event(
            display_url, "Idle", -1, "", null
        );
        ctx.event_bus.publish(event_types::EVENT_TRACKER_STATUS_CHANGED, &tracker_evt, event_types::TrackerEvent.sizeof);
    }

    // Initialize tracker coordinator
    ctx.tracker_coord = session_tracker_coordinator::create(
        ctx.loop, ctx.torrent, ctx.tracker_mgr, ctx.current_tracker_url
    );
    ctx.tracker_coord.set_peers_received_callback(&on_tracker_peers_received, ctx);
    ctx.tracker_coord.set_failed_callback(&on_tracker_failed, ctx);

    // Initialize DHT for peer discovery (skip for private torrents per BEP 27)
    if (!ctx.torrent.info.private)
    {
        init_dht(ctx, 6881);  // Use same port as BitTorrent protocol
    }
    else
    {
        io::printfn("[DHT] Skipping DHT initialization for private torrent (BEP 27)");
        ctx.dht_enabled = false;
    }
    io::printfn("");

    // Initialize LSD for local peer discovery (BEP 14)
    // Also skipped for private torrents per BEP 27
    init_lsd(ctx);
    io::printfn("");

    // Initialize web seeding (BEP 19)
    if (torrent.url_list.len > 0)
    {
        ctx.webseed_mgr = webseed::create(ctx.loop, torrent, ctx.event_bus);  // Uses default: 20 concurrent downloads
        if (ctx.webseed_mgr)
        {
            io::printfn("Web seed support: %d URLs available", torrent.url_list.len);

            // Start web seed timer immediately (web seeds work independently of trackers)
            async::timer::Timer*? timer_opt = async::timer::create(ctx.loop);
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
    if (torrent.httpseeds.len > 0)
    {
        ctx.httpseed_mgr = httpseed::create(ctx.loop, torrent, ctx.event_bus);  // Uses default: 20 concurrent downloads
        if (ctx.httpseed_mgr)
        {
            io::printfn("HTTP seed support: %d URLs available", torrent.httpseeds.len);

            // Start HTTP seed timer immediately (httpseeds work independently of trackers)
            async::timer::Timer*? timer_opt = async::timer::create(ctx.loop);
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
