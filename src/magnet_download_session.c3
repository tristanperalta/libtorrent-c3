module torrent_client::magnet_download_session;

import std::io;
import std::encoding::hex;
import async::event_loop;
import async::timer;
import libtorrent::common;
import libtorrent::tracker;
import libtorrent::tracker_manager;
import libtorrent::metainfo;
import libtorrent::metadata_download;
import libtorrent::metadata_exchange;
import libtorrent::magnet_link;
import libtorrent::peer_pool;
import libtorrent::peer_connection;
import libtorrent::bencode;
import libtorrent::storage_manager;
import libtorrent::download_manager;
import torrent_client::download_session;

/**
 * Magnet Download Session (BEP 9)
 * ================================
 *
 * Handles the metadata download phase of magnet link downloads.
 * This module is responsible for:
 * - Announcing to trackers to discover peers
 * - Managing metadata piece downloads from peers
 * - Verifying and assembling complete metadata
 * - Transitioning to normal download mode once metadata is complete
 */

// ============================================================================
// Magnet Link Download Initialization
// ============================================================================

/**
 * Start a magnet link download by initializing metadata download.
 *
 * @param ctx : "Download context"
 * @param magnet_uri : "Magnet URI to download from"
 */
fn void start_magnet_download(download_session::DownloadContext* ctx, String magnet_uri) @public
{
    io::printfn("Parsing magnet link...");

    // Parse magnet URI
    magnet_link::MagnetLink*? magnet_opt = magnet_link::parse(magnet_uri);
    if (catch err = magnet_opt)
    {
        io::eprintfn("Error: Failed to parse magnet URI");
        io::eprintfn("  %s", err);
        ctx.exit_code = 1;
        ctx.download_complete = true;
        return;
    }

    magnet_link::MagnetLink* magnet = magnet_opt;
    defer magnet.free();

    // Display magnet link info
    String info_hash_hex = hex::encode(mem, magnet.info_hash[..]);
    defer free(info_hash_hex);
    io::printfn("Info Hash: %s", info_hash_hex);
    if (magnet.name.len > 0)
    {
        io::printfn("Name: %s", magnet.name);
    }
    io::printfn("Trackers: %d", magnet.trackers.len);
    io::printfn("");
    io::printfn("Downloading metadata from peers...");
    io::printfn("");

    // Initialize magnet download state
    ctx.is_magnet_download = true;
    ctx.metadata_dl = metadata_download::create(magnet.info_hash);

    // Create peer pool for connecting to peers
    common::PeerId our_peer_id = tracker::generate_peer_id();
    peer_pool::PeerPoolConfig pool_config = {
        .max_peerlist_size = 1000,
        .max_active_connections = 25,
        .max_failcount = 3,
        .min_reconnect_time = 60
    };
    ctx.peer_pool = peer_pool::create(ctx.loop, pool_config, &magnet.info_hash, &our_peer_id, false);

    // Set metadata callback for magnet download
    ctx.peer_pool.on_metadata = &on_metadata_message;
    ctx.peer_pool.user_data = ctx;

    // Initialize multi-tracker manager from magnet trackers
    if (magnet.trackers.len > 0)
    {
        // Convert magnet trackers to tracker tiers (all in tier 0)
        String[][] tiers = mem::new_array(String[], 1);
        tiers[0] = mem::new_array(String, magnet.trackers.len);

        foreach (i, tracker_url : magnet.trackers)
        {
            tiers[0][i] = tracker_url.copy(mem);
        }

        ctx.tracker_mgr = mem::new(tracker_manager::TrackerManager);
        *ctx.tracker_mgr = tracker_manager::initialize(tiers);
        io::printfn("Initialized multi-tracker support with %d trackers", magnet.trackers.len);

        // Start tracker announce to get peers for metadata download
        start_tracker_announce(ctx);
    }

    // Add peers from magnet link directly
    if (magnet.peers.len > 0)
    {
        io::printfn("Found %d peers in magnet link", magnet.peers.len);
        // TODO: Parse peer addresses (host:port format) and add to peer pool
        // For now, we'll rely on tracker announces to get peers
    }

    // Start metadata download timer
    async::timer::Timer*? metadata_timer_opt = async::timer::create(ctx.loop);
    if (catch err = metadata_timer_opt)
    {
        io::eprintfn("Error: Failed to create metadata timer");
        ctx.exit_code = 1;
        ctx.download_complete = true;
        return;
    }

    ctx.metadata_timer = metadata_timer_opt;
    ctx.metadata_timer.start(1000, 1000, &on_metadata_timer, ctx);

    io::printfn("Metadata download started");
    io::printfn("Waiting for peers from trackers...");
    io::printfn("");
}

// ============================================================================
// Tracker Announces for Magnet Links
// ============================================================================

/**
 * Start tracker announces for magnet link (for peer discovery).
 *
 * @param ctx : "Download context"
 */
fn void start_tracker_announce(download_session::DownloadContext* ctx) @private
{
    // Get next tracker from tracker manager
    String tracker_url = ctx.tracker_mgr.get_next_tracker();
    if (tracker_url.len == 0)
    {
        io::eprintfn("No trackers available for magnet link");
        return;
    }

    ctx.current_tracker_url = tracker_url;
    io::printfn("Announcing to tracker: %s", tracker_url);

    // For magnet links, we don't have a complete TorrentFile yet
    // But tracker::announce_to_url needs one. For now, we'll announce
    // to get peers, but the real metadata download will happen once we
    // connect to peers.

    // Create a minimal fake torrent just for the announce
    // This is a workaround - ideally tracker module should support info_hash-only announces
    metainfo::TorrentFile* fake_torrent = mem::new(metainfo::TorrentFile);
    fake_torrent.announce = tracker_url;
    fake_torrent.announce_list = {};
    fake_torrent.info_hash[..] = ctx.metadata_dl.info_hash[..];
    fake_torrent.info.name = "";
    fake_torrent.info.piece_length = 262144;  // Dummy value
    fake_torrent.info.length = 0;  // Unknown until we get metadata
    fake_torrent.info.pieces = {};
    fake_torrent.info.private = false;
    fake_torrent.info.is_multi_file = false;
    fake_torrent.info.files = {};

    ctx.torrent = fake_torrent;

    // Announce with "started" event
    tracker::announce_to_url(ctx.loop, ctx.torrent, tracker_url, 6881, "started",
                             &on_announce_complete, ctx);
}

/**
 * Callback for magnet link tracker announce completion.
 */
fn void on_announce_complete(tracker::TrackerResponse* response, int status, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    if (status != 0)
    {
        io::eprintfn("Tracker announce failed (status=%d)", status);
        // Try next tracker
        bool has_more = ctx.tracker_mgr.mark_failure();
        if (has_more)
        {
            String next_tracker = ctx.tracker_mgr.get_next_tracker();
            ctx.current_tracker_url = next_tracker;
            io::printfn("Trying next tracker: %s", next_tracker);
            tracker::announce_to_url(ctx.loop, ctx.torrent, next_tracker, 6881, "started",
                                     &on_announce_complete, ctx);
        }
        else
        {
            io::eprintfn("All trackers failed for magnet link");
            ctx.download_complete = true;
            ctx.exit_code = 1;
        }
        return;
    }

    io::printfn("Tracker announce successful! Found %d peers", response.peers.len);

    // Add peers to peer pool (BEP 7: convert Peer[] to PeerAddr[])
    if (response.peers.len > 0)
    {
        // Add peers to pool (already SocketAddress[] from tracker)
        ctx.peer_pool.add_peers_from_tracker(response.peers);

        // Connect to peers
        ctx.peer_pool.connect_to_peers();

        io::printfn("Connecting to peers for metadata download...");
    }
    else
    {
        io::printfn("No peers returned from tracker");
    }

    // Don't free the response - it's managed by the tracker module
}

// ============================================================================
// Metadata Completion and Transition
// ============================================================================

/**
 * Handle metadata download completion - parse and transition to content download.
 *
 * @param ctx : "Download context"
 */
fn void on_metadata_complete(download_session::DownloadContext* ctx) @private
{
    io::printfn("[Metadata] Parsing downloaded metadata...");

    // Get completed metadata bytes (this is the info dictionary)
    char[]? metadata_opt = ctx.metadata_dl.get_metadata();
    if (catch err = metadata_opt)
    {
        io::eprintfn("[Metadata] ERROR: Failed to get completed metadata");
        ctx.download_complete = true;
        ctx.exit_code = 1;
        return;
    }
    char[] metadata = metadata_opt;

    // Parse info dictionary from bencode
    bencode::BencodeValue*? info_dict_opt = bencode::decode((String)metadata);
    if (catch err = info_dict_opt)
    {
        io::eprintfn("[Metadata] ERROR: Failed to decode metadata bencode");
        ctx.download_complete = true;
        ctx.exit_code = 1;
        return;
    }
    bencode::BencodeValue* info_dict = info_dict_opt;
    defer info_dict.free();

    // Parse into TorrentInfo struct
    metainfo::TorrentInfo* info = mem::new(metainfo::TorrentInfo);
    fault? parse_err = metainfo::parse_info(info, info_dict);
    if (catch err = parse_err)
    {
        io::eprintfn("[Metadata] ERROR: Failed to parse info dictionary: %s", err);
        free(info);
        ctx.download_complete = true;
        ctx.exit_code = 1;
        return;
    }

    io::printfn("[Metadata] Successfully parsed! Name: %s, Size: %s",
                info.name, download_session::format_size(info.length));

    // Create real TorrentFile (replacing fake one used for tracker announces)
    metainfo::TorrentFile* real_torrent = mem::new(metainfo::TorrentFile);
    real_torrent.announce = ctx.torrent.announce;
    real_torrent.announce_list = ctx.torrent.announce_list;
    real_torrent.info = *info;  // Copy the struct
    real_torrent.info_hash[..] = ctx.metadata_dl.info_hash[..];

    // Free the temporary info struct (contents are now copied to real_torrent)
    free(info);

    // Free fake torrent and replace with real one
    free(ctx.torrent);
    ctx.torrent = real_torrent;

    // Calculate piece counts
    uint num_pieces = (uint)((real_torrent.info.length + real_torrent.info.piece_length - 1) / real_torrent.info.piece_length);
    uint last_piece_length = (uint)(real_torrent.info.length % real_torrent.info.piece_length);
    if (last_piece_length == 0) last_piece_length = (uint)real_torrent.info.piece_length;

    io::printfn("[Metadata] Pieces: %d x %s", num_pieces, download_session::format_size(real_torrent.info.piece_length));
    io::printfn("");

    // Build storage path (for multi-file torrents, append torrent name)
    String storage_path = ctx.save_path;
    bool need_free_path = false;
    if (real_torrent.info.is_multi_file)
    {
        DString path_builder;
        path_builder.append(ctx.save_path);
        if (ctx.save_path.len > 0 && ctx.save_path[ctx.save_path.len - 1] != '/')
        {
            path_builder.append("/");
        }
        path_builder.append(real_torrent.info.name);
        storage_path = path_builder.copy_str(mem);
        need_free_path = true;
    }
    defer if (need_free_path) free(storage_path);

    // Create storage manager
    io::printfn("[Metadata] Initializing storage...");
    storage_manager::StorageManager? sm_opt = storage_manager::create(
        ctx.loop, &real_torrent.info, storage_path);
    if (catch err = sm_opt)
    {
        io::eprintfn("[Metadata] ERROR: Failed to create storage manager: %s", err);
        ctx.download_complete = true;
        ctx.exit_code = 1;
        return;
    }
    ctx.sm = mem::new(storage_manager::StorageManager);
    *ctx.sm = sm_opt;

    // Create download manager
    ctx.dm = mem::new(download_manager::DownloadManager);
    *ctx.dm = download_manager::create(
        ctx.loop,
        num_pieces,
        (uint)real_torrent.info.piece_length,
        last_piece_length,
        real_torrent.info.pieces,
        (usz)ctx.max_concurrent_pieces,
        16384  // 16KB blocks
    );

    // Store num_pieces for resume verification
    ctx.num_pieces = num_pieces;
    ctx.pieces_verified_count = 0;
    ctx.next_piece_to_verify = 0;

    // Initialize storage (will trigger on_storage_initialized callback)
    io::printfn("[Metadata] Starting storage initialization and piece verification...");
    io::printfn("");
    ctx.sm.initialize(&download_session::on_storage_initialized, ctx);
}

// ============================================================================
// Metadata Message Handling
// ============================================================================

/**
 * Handle metadata messages from peers (BEP 9).
 */
fn void on_metadata_message(peer_connection::PeerConnection* peer,
                            peer_connection::MetadataMessage* metadata_msg,
                            void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    // Only handle metadata messages if we're doing a magnet download
    if (!ctx.is_magnet_download || !ctx.metadata_dl)
    {
        return;
    }

    switch (metadata_msg.msg_type)
    {
        case metadata_exchange::MetadataMessageType.REQUEST:
            // Peer is requesting a metadata piece from us
            // For now, we don't serve metadata (we're downloading it)
            // Send REJECT
            (void)peer.send_metadata_message(
                metadata_exchange::MetadataMessageType.REJECT,
                metadata_msg.piece,
                0,
                {}
            );

        case metadata_exchange::MetadataMessageType.DATA:
            // Peer sent us a metadata piece
            io::printfn("[Metadata] Received piece %d from peer", metadata_msg.piece);

            bool complete = ctx.metadata_dl.handle_data(metadata_msg.piece, metadata_msg.data);

            if (complete)
            {
                io::printfn("[Metadata] Download complete!");
                on_metadata_complete(ctx);
            }
            else
            {
                // Request more pieces
                int next_piece = ctx.metadata_dl.get_next_piece_to_request();
                if (next_piece >= 0)
                {
                    ctx.metadata_dl.mark_piece_requested((uint)next_piece);
                    (void)peer.send_metadata_message(
                        metadata_exchange::MetadataMessageType.REQUEST,
                        (uint)next_piece,
                        0,
                        {}
                    );
                }
            }

        case metadata_exchange::MetadataMessageType.REJECT:
            // Peer rejected our request
            io::printfn("[Metadata] Peer rejected piece %d request", metadata_msg.piece);
            ctx.metadata_dl.handle_reject(metadata_msg.piece);
    }
}

/**
 * Timer callback for metadata download requests and timeout checking (BEP 9).
 *
 * Periodically requests metadata pieces from peers and checks for timeouts.
 */
fn void on_metadata_timer(async::timer::Timer* timer, void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    if (!ctx.is_magnet_download || !ctx.metadata_dl || ctx.metadata_dl.is_complete())
    {
        return;
    }

    // Check for timed-out requests
    ctx.metadata_dl.check_timeouts();

    // Request pieces from connected peers
    // Get next piece to request
    int next_piece = ctx.metadata_dl.get_next_piece_to_request();
    if (next_piece < 0)
    {
        // No pieces to request (either all requested or download complete)
        return;
    }

    // Iterate through connected peers and request metadata
    if (!ctx.peer_pool) return;

    // Try to find a peer that supports metadata
    foreach (peer_info : ctx.peer_pool.peers)
    {
        // Skip if not connected or no connection object
        if (!peer_info.connection) continue;
        if (peer_info.state != peer_pool::PeerState.CONNECTED) continue;
        if (!peer_info.connection.supports_metadata) continue;

        // Initialize metadata size from first peer that has it
        if (ctx.metadata_dl.num_pieces == 0 && peer_info.connection.peer_metadata_size > 0)
        {
            ctx.metadata_dl.set_metadata_size(peer_info.connection.peer_metadata_size);
            io::printfn("[Metadata] Initialized download: %d bytes from peer",
                        peer_info.connection.peer_metadata_size);
        }

        // Request the next piece from this peer
        (void)peer_info.connection.send_metadata_message(
            metadata_exchange::MetadataMessageType.REQUEST,
            (uint)next_piece,
            0,
            {}
        );

        // Mark as requested after sending
        ctx.metadata_dl.mark_piece_requested((uint)next_piece);

        io::printfn("[Metadata] Requested piece %d from peer %s", next_piece, peer_info.addr);

        // Only request from one peer at a time to avoid duplicates
        break;
    }
}
