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
import libtorrent::bitfield;
import async::timer;
import libtorrent::peer_pool;
import libtorrent::dht_client;
import libtorrent::dht_get_peers;
import libtorrent::webseed;
import libtorrent::event_bus;
import libtorrent::event_types;
import libtorrent::speed_tracker;
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
    async::timer::Timer* announce_timer;     // Periodic announce timer
    async::timer::Timer* retry_timer;        // Tracker retry backoff timer
    async::timer::Timer* pex_timer;          // PEX update timer (every 60s)
    async::timer::Timer* keepalive_timer;    // Keepalive timer (every 120s)
    async::timer::Timer* flush_timer;        // File flush timer (configurable interval)
    async::timer::Timer* block_timeout_timer; // Block request timeout checker (every 10s)
    int announce_retry_count;               // For exponential backoff
    int announce_backoff_ms;                // Current backoff delay
    bool initial_announce_done;             // Has first announce succeeded?

    // Multi-tracker support (BEP 12)
    tracker_manager::TrackerManager* tracker_mgr;  // Manages tier-based tracker selection
    String current_tracker_url;                    // Currently active tracker URL (for logging)

    // Peer management
    peer_pool::PeerPool* peer_pool;

    // DHT peer discovery
    dht_client::DhtClient* dht_client;
    dht_get_peers::GetPeersSearch* dht_search;
    async::timer::Timer* dht_timer;         // Periodic DHT peer discovery
    async::timer::Timer* dht_check_timer;   // One-shot timer for checking DHT results
    async::timer::Timer* dht_tick_timer;    // RPC timeout processing timer
    bool dht_enabled;

    // Web seeding (BEP 19)
    webseed::WebSeedManager* webseed_mgr;   // HTTP/FTP web seed manager
    async::timer::Timer* webseed_timer;     // Periodic web seed piece requests

    // Download state
    bool download_complete;
    int exit_code;

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

<*
 Called when download is complete - closes all handles.
 Event loop will exit naturally once all handles are closed.
*>
fn void on_complete_download(DownloadContext* ctx) @public
{
    io::printfn("");
    io::printfn("=== Download Complete! ===");
    io::printfn("All %d pieces verified successfully", ctx.num_pieces);
    io::printfn("Cleaning up...");

    // Stop announce timers
    if (ctx.announce_timer)
    {
        ctx.announce_timer.close();
        ctx.announce_timer = null;
    }
    if (ctx.retry_timer)
    {
        ctx.retry_timer.close();
        ctx.retry_timer = null;
    }
    if (ctx.pex_timer)
    {
        ctx.pex_timer.close();
        ctx.pex_timer = null;
    }
    if (ctx.keepalive_timer)
    {
        ctx.keepalive_timer.close();
        ctx.keepalive_timer = null;
    }
    if (ctx.flush_timer)
    {
        ctx.flush_timer.close();
        ctx.flush_timer = null;
    }
    if (ctx.block_timeout_timer)
    {
        ctx.block_timeout_timer.close();
        ctx.block_timeout_timer = null;
    }

    // Stop DHT timers
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
    if (ctx.dht_tick_timer)
    {
        ctx.dht_tick_timer.close();
        ctx.dht_tick_timer = null;
    }

    // Free DHT resources
    if (ctx.dht_search)
    {
        ctx.dht_search.free();
        ctx.dht_search = null;
    }
    if (ctx.dht_client)
    {
        ctx.dht_client.free();
        ctx.dht_client = null;
    }

    // Free speed tracker
    if (ctx.speed_tracker)
    {
        ctx.speed_tracker.free();
        ctx.speed_tracker = null;
    }

    // Free tracker manager resources
    if (ctx.tracker_mgr)
    {
        ctx.tracker_mgr.free();
        free(ctx.tracker_mgr);
        ctx.tracker_mgr = null;
    }
    if (ctx.current_tracker_url.len > 0 && ctx.current_tracker_url != ctx.torrent.announce)
    {
        // Only free if it's not pointing to torrent.announce
        // (current_tracker_url may be a reference to a tracker manager string)
        ctx.current_tracker_url = "";
    }

    // Gracefully disconnect from all peers
    if (ctx.peer_pool)
    {
        usz total_peers, candidates, connecting, connected;
        ctx.peer_pool.get_stats(&total_peers, &candidates, &connecting, &connected);
        if (connected > 0)
        {
            io::printfn("Gracefully disconnecting from %d peer%s...",
                       connected, connected == 1 ? "" : "s");
        }
        ctx.peer_pool.disconnect_all_gracefully();
    }

    // Event loop will exit naturally when all handles are closed
    ctx.download_complete = true;
    ctx.exit_code = 0;
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
        for (usz i = 0; i < ctx.peer_pool.peers.len; i++)
        {
            peer_pool::TorrentPeer* peer_info = ctx.peer_pool.peers[i];
            if (peer_info.state == peer_pool::PeerState.CONNECTED)
            {
                ctx.peer_pool.mark_hash_failure(peer_info.ip, peer_info.port)!!;
            }
        }

        // Mark piece as failed for retry
        ctx.dm.fail_piece(piece_index)!!;
        return;
    }

    io::printfn("✓ Piece %d verified (%d bytes)", piece_index, piece_data.len);

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

    // Check if download is complete
    if (ctx.dm.is_complete())
    {
        on_complete_download(ctx);
        return;
    }

    // Start downloading more pieces from available peers
    // Use actual peer bitfields to start new piece downloads
    for (usz i = 0; i < ctx.peer_pool.peers.len; i++)
    {
        peer_pool::TorrentPeer* peer_info = ctx.peer_pool.peers[i];
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
                break;
            }
            else
            {
                // Successfully started a new piece - try to fill more slots
            }
        }
    }

    // Continue requesting blocks
    request_blocks_from_peers(ctx);
}

<*
 Callback for peer message handling.
*>
fn void on_download_peer_message(peer_connection::PeerConnection* peer,
                                  peer_wire::Message* msg,
                                  common::Ipv4Addr ip, ushort port,
                                  void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    // Get peer from pool
    peer_pool::TorrentPeer*? peer_opt = ctx.peer_pool.find_peer(ip, port);
    if (catch err = peer_opt)
    {
        io::eprintfn("  [ERROR] Message from unknown peer %d.%d.%d.%d:%d",
                     ip[0], ip[1], ip[2], ip[3], port);
        return;
    }
    peer_pool::TorrentPeer* peer_info = peer_opt;

    switch (msg.type)
    {
        case peer_wire::MessageType.BITFIELD:
            // Peer sent their bitfield - update piece availability
            if (msg.payload.len > 0)
            {
                peer_info.received_bitfield = true;

                // Convert bitfield bytes to bool array
                usz num_pieces = (usz)((ctx.torrent.info.length + ctx.torrent.info.piece_length - 1) /
                                       ctx.torrent.info.piece_length);
                bool[] has_pieces = mem::new_array(bool, num_pieces);

                // Parse bitfield
                for (usz i = 0; i < num_pieces; i++)
                {
                    usz byte_index = i / 8;
                    usz bit_index = 7 - (i % 8);
                    if (byte_index < msg.payload.len)
                    {
                        has_pieces[i] = (msg.payload[byte_index] & (1 << bit_index)) != 0;
                    }
                }

                // Update download manager
                ctx.dm.update_peer_bitfield(has_pieces)!!;

                // Store the bitfield in the peer's struct (critical for piece selection later!)
                if (peer_info.pieces.data.len > 0)
                {
                    peer_info.pieces.free();
                }
                peer_info.pieces = bitfield::from_bytes(msg.payload, num_pieces);

                io::printfn("  Peer %d.%d.%d.%d:%d sent bitfield",
                            ip[0], ip[1], ip[2], ip[3], port);

                // Count how many pieces the peer has
                int peer_piece_count = 0;
                for (usz i = 0; i < num_pieces; i++)
                {
                    if (has_pieces[i]) peer_piece_count++;
                }
                io::printfn("    Peer has %d/%d pieces", peer_piece_count, (int)num_pieces);

                // Start piece downloads based on peer availability
                // Try to fill all available download slots (up to max_concurrent_pieces)

                int pieces_started = 0;
                for (int i = 0; i < ctx.max_concurrent_pieces; i++)
                {
                    if (catch excuse = ctx.dm.start_piece_download(has_pieces))
                    {
                        // No more pieces to download or no slots available (both are fine)
                        break;
                    }
                    pieces_started++;
                }

                if (pieces_started > 0)
                {
                    io::printfn("    Started downloading %d piece%s",
                               pieces_started, pieces_started == 1 ? "" : "s");
                }

                free(has_pieces);

                // Check if peer is a seed
                if (peer_piece_count == (int)num_pieces)
                {
                    ctx.peer_pool.mark_peer_seed(ip, port)!!;
                }
            }

        case peer_wire::MessageType.HAVE:
            // Peer has a new piece
            if (msg.payload.len >= 4)
            {
                uint piece_index = peer_wire::read_u32_be(msg.payload, 0);
                ctx.dm.peer_has_piece(piece_index)!!;

                // Initialize peer's bitfield if not already done
                if (peer_info.pieces.data.len == 0)
                {
                    usz num_pieces = (usz)((ctx.torrent.info.length + ctx.torrent.info.piece_length - 1) /
                                           ctx.torrent.info.piece_length);
                    peer_info.pieces = bitfield::create(num_pieces);
                }

                // Update peer's bitfield
                peer_info.pieces.set_piece((usz)piece_index);
            }

        case peer_wire::MessageType.PIECE:
            // Received a piece block!
            peer_wire::PieceMsg? piece_msg = peer_wire::decode_piece(msg.payload);
            if (catch err = piece_msg) return;

            // Add block to download manager
            // Note: Piece may no longer be active if it completed while blocks were queued
            if (catch excuse = ctx.dm.receive_block(piece_msg.index, piece_msg.begin, piece_msg.block))
            {
                // Piece not downloading anymore (completed or failed) - ignore late block
                // This is normal when piece completes while blocks are queued in event loop
                return;
            }

            // Track download statistics
            ctx.peer_pool.update_peer_stats(ip, port, (ulong)piece_msg.block.len, 0)!!;

            // Check if piece is complete
            usz total_blocks, received_blocks;
            if (catch excuse = ctx.dm.get_piece_progress(piece_msg.index, &total_blocks, &received_blocks))
            {
                // Piece not downloading, ignore
            }
            else if (received_blocks == total_blocks)
            {
                // Piece complete - verify and write to disk
                ctx.dm.complete_piece(piece_msg.index, &on_download_piece_complete, ctx);
            }

            // Keep the request pipeline full
            request_blocks_from_peers(ctx);

        case peer_wire::MessageType.UNCHOKE:
            io::printfn("  Peer %d.%d.%d.%d:%d unchoked us",
                        ip[0], ip[1], ip[2], ip[3], port);

            // If we haven't received BITFIELD yet, assume peer has all pieces
            if (!peer_info.received_bitfield)
            {
                io::printfn("    No BITFIELD received - assuming peer has all pieces");

                usz num_pieces = (usz)((ctx.torrent.info.length + ctx.torrent.info.piece_length - 1) /
                                       ctx.torrent.info.piece_length);
                bool[] has_all_pieces = mem::new_array(bool, num_pieces);

                // Set all pieces to true (assume peer has everything)
                for (usz i = 0; i < num_pieces; i++)
                {
                    has_all_pieces[i] = true;
                }

                // Update download manager
                ctx.dm.update_peer_bitfield(has_all_pieces)!!;

                // Store the bitfield in the peer's struct (all pieces = seed)
                if (peer_info.pieces.data.len > 0)
                {
                    peer_info.pieces.free();
                }
                peer_info.pieces = bitfield::create(num_pieces);
                peer_info.pieces.set_all();

                // Start piece downloads
                int pieces_started = 0;
                for (int i = 0; i < ctx.max_concurrent_pieces; i++)
                {
                    if (catch excuse = ctx.dm.start_piece_download(has_all_pieces))
                    {
                        break;
                    }
                    pieces_started++;
                }

                if (pieces_started > 0)
                {
                    io::printfn("    Started downloading %d piece%s",
                               pieces_started, pieces_started == 1 ? "" : "s");
                }

                free(has_all_pieces);
                peer_info.received_bitfield = true;  // Mark as handled

                // Mark as seed if has all pieces
                ctx.peer_pool.mark_peer_seed(ip, port)!!;
            }

            // Try to start new pieces if we have available slots
            usz total, complete, downloading;
            ctx.dm.get_progress(&total, &complete, &downloading);
            if (downloading < (usz)ctx.max_concurrent_pieces)  // We have free slots
            {
                // Convert peer's Bitfield to bool[] for piece picker
                bool[] peer_pieces = mem::new_array(bool, total);
                defer free(peer_pieces);

                for (usz j = 0; j < total; j++)
                {
                    peer_pieces[j] = peer_info.pieces.has_piece(j);
                }

                // Try to fill available slots
                int pieces_started = 0;
                for (int i = 0; i < (ctx.max_concurrent_pieces - (int)downloading); i++)
                {
                    if (catch excuse = ctx.dm.start_piece_download(peer_pieces))
                    {
                        break;
                    }
                    pieces_started++;
                }

                if (pieces_started > 0)
                {
                    io::printfn("    Started %d new piece%s (slots: %d/%d)",
                               pieces_started, pieces_started == 1 ? "" : "s",
                               downloading + pieces_started, ctx.max_concurrent_pieces);
                }
            }

            // Now we can start requesting blocks!
            io::printfn("    Starting block requests...");
            request_blocks_from_peers(ctx);

        case peer_wire::MessageType.CHOKE:
            io::printfn("  Peer %d.%d.%d.%d:%d choked us",
                        ip[0], ip[1], ip[2], ip[3], port);

        default:
            // Ignore other message types for now
    }
}

<*
 Request blocks from ready peers.
*>
fn void request_blocks_from_peers(download_session::DownloadContext* ctx) @public
{
    // Try to fill the pipeline with block requests
    int requests_sent = 0;
    for (int attempts = 0; attempts < 100; attempts++)
    {
        // Get next block to request
        block_manager::BlockRequest? req = ctx.dm.get_next_block_request();
        if (catch err = req)
        {
            // No more blocks available right now
            break;
        }

        // Find a ready peer to request from (iterate through peer pool)
        bool requested = false;
        usz total_peers, candidates, connecting, connected;
        ctx.peer_pool.get_stats(&total_peers, &candidates, &connecting, &connected);

        // Count valid peers for debugging
        usz valid_peer_count = 0;
        usz has_connection_count = 0;
        usz is_connected_count = 0;
        usz handshake_ok_count = 0;

        // Get all peers from pool and find one that's READY
        for (usz i = 0; i < ctx.peer_pool.peers.len; i++)
        {
            peer_pool::TorrentPeer* peer_info = ctx.peer_pool.peers[i];

            if (peer_info.connection) has_connection_count++;
            if (peer_info.state == peer_pool::PeerState.CONNECTED) is_connected_count++;
            if (peer_info.handshake_ok) handshake_ok_count++;

            if (peer_info.connection &&
                peer_info.state == peer_pool::PeerState.CONNECTED &&
                peer_info.handshake_ok)
            {
                valid_peer_count++;

                // Send REQUEST message
                peer_info.connection.send_request(req.piece_index, req.offset, req.length)!!;

                // Mark block as requested (handle race where piece completes)
                if (catch excuse = ctx.dm.mark_block_requested(req.piece_index, req.offset))
                {
                    // Piece no longer downloading (race condition) - ignore this request
                    break;
                }

                requests_sent++;
                requested = true;
                break;
            }
        }

        if (!requested)
        {
            break;
        }
    }

    if (requests_sent > 0)
    {
        io::printfn("  Sent %d block requests", requests_sent);
    }
}

<*
 Callback when peer successfully connects.
*>
fn void on_download_peer_connected(peer_connection::PeerConnection* peer,
                                    common::Ipv4Addr ip, ushort port,
                                    void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    io::printfn("  Peer %d.%d.%d.%d:%d connected and ready",
                ip[0], ip[1], ip[2], ip[3], port);

    // Get peer from pool
    peer_pool::TorrentPeer*? peer_opt = ctx.peer_pool.find_peer(ip, port);
    if (catch err = peer_opt) return;

    peer_pool::TorrentPeer* peer_info = peer_opt;
    peer_info.handshake_ok = true;
    peer_info.state = peer_pool::PeerState.CONNECTED;

    // Send INTERESTED message to the peer
    peer.send_interested()!!;
    io::printfn("  Sent INTERESTED to peer %d.%d.%d.%d:%d",
                ip[0], ip[1], ip[2], ip[3], port);

    // DON'T start piece downloads yet - wait for BITFIELD first
    // The BITFIELD message handler will start downloads
}

<*
 Callback when peer disconnects.
*>
fn void on_download_peer_disconnected(common::Ipv4Addr ip, ushort port,
                                       bool was_error,
                                       void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    io::printfn("  Peer %d.%d.%d.%d:%d disconnected%s",
                ip[0], ip[1], ip[2], ip[3], port,
                was_error ? " (error)" : "");

    // Peer pool automatically tries to replace failed connections
    // Check if download is complete
    if (ctx.dm.is_complete())
    {
        io::printfn("");
        io::printfn("Download complete!");
        on_complete_download(ctx);
        return;
    }

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

    // Add all peers to peer pool
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

<*
 Retry timer callback - retries tracker announce after backoff delay.
*>
fn void on_announce_retry_timer(async::timer::Timer* timer, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    io::printfn("  Retrying tracker announce (attempt %d)...", ctx.announce_retry_count + 1);

    // Close retry timer
    timer.close();
    ctx.retry_timer = null;

    // Retry announce
    tracker::announce(ctx.loop, ctx.torrent, 6881,
                      ctx.initial_announce_done ? "" : "started",
                      &on_announce_complete_with_retry, ctx);
}

<*
 Tracker announce completion callback with retry support.
 Implements exponential backoff on failure.
*>
fn void on_announce_complete_with_retry(tracker::TrackerResponse* response, int status, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    if (status != 0 || !response || response.failure_reason.len > 0)
    {
        // Failed - try next tracker or use exponential backoff
        if (status != 0)
        {
            String error_desc = download_session::tracker_error_string(status);
            io::eprintfn("  Tracker announce failed: %s (status=%d)", error_desc, status);
        }
        else if (response && response.failure_reason.len > 0)
        {
            io::eprintfn("  Tracker error: %s", response.failure_reason);
        }

        // BEP 12: Try next tracker if available
        if (ctx.tracker_mgr && ctx.tracker_mgr.has_trackers())
        {
            // Mark current tracker as failed and get next one
            ctx.tracker_mgr.mark_failure();
            String next_tracker = ctx.tracker_mgr.get_next_tracker();

            if (next_tracker.len > 0)
            {
                // Try next tracker immediately (no backoff for different tracker)
                io::printfn("  Trying next tracker in tier...");
                ctx.current_tracker_url = next_tracker;

                // Publish tracker status changed event
                event_types::TrackerEvent tracker_evt = event_types::create_tracker_event(
                    ctx.current_tracker_url, "Trying...", -1, "", ctx.tracker_mgr
                );
                ctx.event_bus.publish(event_types::EVENT_TRACKER_STATUS_CHANGED, &tracker_evt, event_types::TrackerEvent.sizeof);

                tracker::announce_to_url(ctx.loop, ctx.torrent, next_tracker, 6881,
                                          ctx.initial_announce_done ? "" : "started",
                                          &on_announce_complete_with_retry, ctx);
                return;
            }
            else
            {
                // All trackers exhausted - use exponential backoff and try again
                io::printfn("  All trackers failed - will retry from beginning");

                // Publish tracker status changed event
                event_types::TrackerEvent tracker_evt = event_types::create_tracker_event(
                    ctx.current_tracker_url, "Failed", -1, "", ctx.tracker_mgr
                );
                ctx.event_bus.publish(event_types::EVENT_TRACKER_STATUS_CHANGED, &tracker_evt, event_types::TrackerEvent.sizeof);
            }
        }

        // Exponential backoff for retry
        ctx.announce_retry_count++;

        // Calculate backoff: 1s, 2s, 4s, 8s, 16s, 30s (cap at 30s)
        int backoff_ms = 1000 * (1 << (ctx.announce_retry_count - 1));
        if (backoff_ms > 30000) backoff_ms = 30000;
        ctx.announce_backoff_ms = backoff_ms;

        io::printfn("  Retrying in %d seconds...", backoff_ms / 1000);

        // Create retry timer (one-shot)
        async::timer::Timer*? timer_opt = async::timer::create(ctx.loop);
        if (catch err = timer_opt)
        {
            io::eprintfn("  Failed to create retry timer - giving up");
            ctx.download_complete = true;
            ctx.exit_code = 1;
            return;
        }

        ctx.retry_timer = timer_opt;
        ctx.retry_timer.start((ulong)backoff_ms, 0,
                              &on_announce_retry_timer, ctx);
        return;
    }

    // Success - mark tracker as successful (BEP 12: move to front of tier)
    if (ctx.tracker_mgr && ctx.tracker_mgr.has_trackers())
    {
        ctx.tracker_mgr.mark_success(ctx.current_tracker_url);
        io::printfn("  Tracker announce successful: %s", ctx.current_tracker_url);
    }
    else
    {
        io::printfn("  Tracker announce successful");
    }

    ctx.announce_retry_count = 0;
    ctx.initial_announce_done = true;

    // Publish tracker status changed event
    int peer_count = response ? (int)response.peers.len : -1;
    event_types::TrackerEvent tracker_evt = event_types::create_tracker_event(
        ctx.current_tracker_url, "Working", peer_count, "", ctx.tracker_mgr
    );
    ctx.event_bus.publish(event_types::EVENT_TRACKER_STATUS_CHANGED, &tracker_evt, event_types::TrackerEvent.sizeof);

    // Start periodic announce timer if not already running
    if (!ctx.announce_timer && response.interval > 0)
    {
        ulong interval_ms = (ulong)(response.interval * 1000);
        io::printfn("  Setting up periodic announce every %d seconds", response.interval);

        async::timer::Timer*? timer_opt = async::timer::create(ctx.loop);
        if (catch err = timer_opt)
        {
            io::eprintfn("  Warning: Failed to create announce timer");
        }
        else
        {
            ctx.announce_timer = timer_opt;
            ctx.announce_timer.start(interval_ms, interval_ms,
                                     &on_announce_timer_tick, ctx);
        }
    }

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
    on_download_tracker_complete(response, status, ctx);
}

<*
 Periodic announce timer callback - fires every interval seconds.
 Re-announces to the active (successful) tracker.
*>
fn void on_announce_timer_tick(async::timer::Timer* timer, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    if (ctx.dm.is_complete())
    {
        // Download complete - stop timer
        timer.stop();
        return;
    }

    io::printfn("Periodic tracker re-announce...");

    // BEP 12: Use the active tracker (the one that succeeded)
    if (ctx.tracker_mgr && ctx.tracker_mgr.has_trackers())
    {
        String active_tracker = ctx.tracker_mgr.get_active_tracker();
        if (active_tracker.len > 0)
        {
            // Re-announce to successful tracker
            tracker::announce_to_url(ctx.loop, ctx.torrent, active_tracker, 6881, "",
                                      &on_download_tracker_complete, ctx);
        }
        else
        {
            // No active tracker yet - use tracker manager's next tracker
            tracker::announce_to_url(ctx.loop, ctx.torrent, ctx.current_tracker_url, 6881, "",
                                      &on_download_tracker_complete, ctx);
        }
    }
    else
    {
        // Fallback: Use primary tracker
        tracker::announce(ctx.loop, ctx.torrent, 6881, "",
                          &on_download_tracker_complete, ctx);
    }
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
 Start tracker announce with retry support.
 Uses multi-tracker manager (BEP 12) if available.
*>
fn void announce_with_retry(download_session::DownloadContext* ctx) @public
{
    ctx.announce_retry_count = 0;
    ctx.announce_backoff_ms = 0;

    // Determine which tracker URL to use
    String tracker_url;
    if (ctx.tracker_mgr && ctx.tracker_mgr.has_trackers())
    {
        // BEP 12: Use tracker manager for multi-tracker support
        // Reset to beginning of tier for new announce cycle
        ctx.tracker_mgr.reset();
        tracker_url = ctx.tracker_mgr.get_next_tracker();

        if (tracker_url.len == 0)
        {
            io::eprintfn("No valid trackers available");
            return;
        }

        ctx.current_tracker_url = tracker_url;
        tracker::announce_to_url(ctx.loop, ctx.torrent, tracker_url, 6881,
                                  ctx.initial_announce_done ? "" : "started",
                                  &on_announce_complete_with_retry, ctx);
    }
    else
    {
        // Fallback: Use primary announce URL
        tracker_url = ctx.torrent.announce;
        ctx.current_tracker_url = tracker_url;
        tracker::announce(ctx.loop, ctx.torrent, 6881,
                          ctx.initial_announce_done ? "" : "started",
                          &on_announce_complete_with_retry, ctx);
    }
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

    // Get 8 closest nodes from routing table for this info_hash
    dht_routing_table::NodeEntry[] nodes =
        ctx.dht_client.routing_table.find_closest_nodes(
            ctx.torrent.info_hash,
            8
        );
    defer free(nodes);

    if (nodes.len == 0)
    {
        io::printfn("[DHT] No nodes in routing table yet, will retry later");
        return;
    }

    io::printfn("[DHT] Querying %d DHT nodes for peers...", nodes.len);

    // Send get_peers query to each node
    for (int i = 0; i < (int)nodes.len; i++)
    {
        ctx.dht_client.send_get_peers(
            nodes[i].id,
            nodes[i].ip,
            nodes[i].port,
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

    // Get discovered peers from DHT
    common::Peer[] dht_peers = ctx.dht_search.get_peers();
    defer free(dht_peers);

    if (dht_peers.len == 0)
    {
        io::printfn("[DHT] No peers found");
        return;
    }

    io::printfn("[DHT] Found %d peers", dht_peers.len);

    // Add DHT peers to peer pool
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

    // Create download manager
    ctx.dm = mem::new(download_manager::DownloadManager);
    *ctx.dm = download_manager::create(
        ctx.loop,
        num_pieces,
        (uint)torrent.info.piece_length,
        last_piece_length,
        torrent.info.pieces,
        (usz)ctx.max_concurrent_pieces,  // Configurable concurrent pieces
        16384  // 16KB blocks
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
    io::printfn("");

    // Initialize storage manager (create directories, open files)
    io::printfn("Initializing storage...");
    ctx.sm.initialize(&on_storage_initialized, ctx);
}
