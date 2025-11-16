module torrent_client;

import std::io;
import std::encoding::hex;
import std::collections::list;
import uv;
import libtorrent;
import libtorrent::common;
import libtorrent::tracker;
import libtorrent::tracker_manager;
import async::event_loop;
import libtorrent::torrent_loader;
import libtorrent::peer_connection;
import libtorrent::peer_wire;
import libtorrent::download_manager;
import libtorrent::block_manager;
import libtorrent::storage_manager;
import libtorrent::bitfield;
import async::timer;
import libtorrent::peer_pool;
import std::core::log;
import libtorrent::magnet_link;
import libtorrent::dht_client;
import libtorrent::dht_get_peers;
import libtorrent::event_bus;
import libtorrent::event_types;
import libtorrent::file_selection;
import libtorrent::ports::peer_discovery;
import libtorrent::adapters::composite_peer_discovery;
import torrent_client::log_outputs;
import libtorrent::session;
import libtorrent::magnet_download_session;
import libtorrent::adapters::fastresume_state_provider;
import raylib_gui;

// ============================================================================
// Configuration Constants
// ============================================================================

// Download configuration
const uint BLOCK_SIZE = 16384;             // 16KB standard block size (BEP 3)

// Peer pool configuration defaults
const int MAX_PEERLIST_SIZE = 1000;        // Track up to 1000 peers
const int MAX_ACTIVE_CONNECTIONS = 25;     // Maintain 25 concurrent connections
const int PEER_RETRY_FAILCOUNT = 3;        // Ban peer after 3 failures
const int MIN_RECONNECT_TIME_SECS = 60;    // Wait 60s before reconnecting

// GUI configuration
const int GUI_UPDATE_INTERVAL_FRAMES = 60; // Update peer list every 60 frames (~1s at 60 FPS)

// ============================================================================
// Main Entry Point
// ============================================================================

fn int main(int argc, ZString* argv)
{
    if (argc < 2)
    {
        io::eprintfn("Usage: torrent-client-gui <torrent-file> [save-path]");
        io::eprintfn("");
        io::eprintfn("Arguments:");
        io::eprintfn("  torrent-file    Path to .torrent file");
        io::eprintfn("  save-path       Directory to save files (default: current directory)");
        io::eprintfn("");
        io::eprintfn("Example:");
        io::eprintfn("  torrent-client-gui ubuntu.torrent ~/Downloads");
        return 1;
    }

    String torrent_path = (String)argv[1].str_view();
    String save_path = ".";  // Default to current directory

    if (argc >= 3)
    {
        save_path = (String)argv[2].str_view();
    }

    // Create event loop
    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        io::eprintfn("Error creating event loop");
        return 1;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Launch GUI mode
    return cmd_download_gui(&loop, torrent_path, save_path, tracker::DEFAULT_NUMWANT);
}

// ============================================================================
// GUI Helper Functions
// ============================================================================

/**
 * Build and update file list for GUI display (BEP 21).
 * Called to initialize or refresh the Files tab.
 */
fn void update_gui_file_list(session::Session* ctx)
{
    if (!ctx.gui_state) return;  // No GUI
    if (!ctx.sm) return;  // No storage manager yet

    // Build have_pieces bitfield from download manager
    bool[] have_pieces;
    if (ctx.dm)
    {
        have_pieces = mem::new_array(bool, ctx.sm.num_pieces);
        for (uint i = 0; i < ctx.sm.num_pieces; i++)
        {
            have_pieces[i] = ctx.dm.have_piece(i);
        }
    }
    else
    {
        // No download manager yet, assume no pieces
        have_pieces = mem::new_array(bool, ctx.sm.num_pieces);
    }
    defer mem::free(have_pieces.ptr);

    // Build file display list
    usz num_files = ctx.sm.files.len;
    if (num_files == 0) return;  // Single-file torrent or not initialized

    raylib_gui::FileDisplayInfo[] file_list = mem::new_array(raylib_gui::FileDisplayInfo, num_files);

    for (usz i = 0; i < num_files; i++)
    {
        storage_manager::FileInfo* file = &ctx.sm.files[i];

        file_list[i].path = file.path.copy(mem);
        file_list[i].length = (long)file.length;
        file_list[i].is_selected = file.is_selected;
        file_list[i].is_complete = file.is_complete;
        file_list[i].progress = ctx.sm.get_file_progress(i, &have_pieces);
    }

    // Update GUI
    raylib_gui::update_file_list(ctx.gui_state, file_list);
}

/**
 * File selection callback (BEP 21 Phase 3).
 * Called when user clicks checkbox in Files tab.
 */
fn void on_file_selection_toggled(usz file_index, bool selected, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    session::toggle_file_selection(ctx, file_index, selected);

    // Refresh GUI file list to reflect the change
    update_gui_file_list(ctx);
}

// ============================================================================
// GUI Event Handlers - Subscribe to EventBus events
// ============================================================================

/**
 * Event handler: Progress updated
 * Updates GUI progress bar and peer stats display
 */
fn void on_progress_updated_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;  // No GUI to update

    event_types::ProgressEvent* evt = (event_types::ProgressEvent*)event_data;

    // Get current peer stats for display
    usz connected_peers, total_peers, candidates, connecting;
    ctx.peer_pool.get_stats(&total_peers, &candidates, &connecting, &connected_peers);

    raylib_gui::update_progress(ctx.gui_state, evt.pieces_complete, evt.pieces_downloading,
                                (long)evt.bytes_downloaded, evt.download_speed, evt.upload_speed);
    raylib_gui::update_peers(ctx.gui_state, (int)connected_peers, (int)total_peers);

    // Update piece states for visualization
    if (ctx.dm)
    {
        // Extract current piece states from picker
        piece_picker::PieceState[] piece_states = mem::new_array(piece_picker::PieceState, ctx.dm.picker.num_pieces);
        for (uint i = 0; i < ctx.dm.picker.num_pieces; i++)
        {
            piece_states[i] = ctx.dm.picker.pieces[i].state;
        }
        raylib_gui::update_piece_states(ctx.gui_state, piece_states);
    }

    // Phase 1 removed: update_gui_file_list(ctx) moved to dedicated event handler
}

/**
 * Event handler: File progress updated (BEP 21 Phase 2)
 * Updates GUI file list display with current download progress
 */
fn void on_file_progress_updated_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;  // No GUI to update

    // Rebuild and update the entire file list
    // This is triggered once per second (same debounce as progress updates)
    update_gui_file_list(ctx);
}

/**
 * Event handler: File completed (BEP 21 Phase 2)
 * Shows notification when a file finishes downloading
 */
fn void on_file_completed_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;

    event_types::FileProgressEvent* evt = (event_types::FileProgressEvent*)event_data;

    // Show completion message in GUI log
    if (evt.file_index < ctx.sm.files.len)
    {
        DString msg;
        msg.appendf("[File] Completed: %s", ctx.sm.files[evt.file_index].path);
        raylib_gui::add_log(ctx.gui_state, msg.str_view());
    }

    // Refresh file list to show completion status
    update_gui_file_list(ctx);
}

/**
 * Event handler: Tracker announce failed
 * Updates GUI tracker status with error message
 */
fn void on_tracker_announce_failed_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;

    event_types::TrackerEvent* evt = (event_types::TrackerEvent*)event_data;
    raylib_gui::update_tracker_status(ctx.gui_state, evt.error_message);
}

/**
 * Event handler: Tracker returned no peers
 * Updates GUI tracker status with "no peers" message
 */
fn void on_tracker_no_peers_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;

    raylib_gui::update_tracker_status(ctx.gui_state, "No peers available");
}

/**
 * Event handler: Tracker announce success
 * Updates GUI tracker status with success message
 */
fn void on_tracker_announce_success_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;

    event_types::TrackerEvent* evt = (event_types::TrackerEvent*)event_data;

    // Build success message showing peer count
    DString msg;
    msg.appendf("Tracker OK (%d peers)", evt.peers_returned);
    raylib_gui::update_tracker_status(ctx.gui_state, msg.str_view());
}

/**
 * Event handler: Peer stats updated
 * Updates GUI peer connection display
 */
fn void on_peer_stats_updated_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;

    event_types::PeerEvent* evt = (event_types::PeerEvent*)event_data;
    raylib_gui::update_peers(ctx.gui_state, evt.peers_connected, evt.peers_total);
}

/**
 * Event handler: Tracker status changed (multi-tracker)
 * Updates GUI tracker list display
 */
fn void on_tracker_status_changed_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;

    event_types::TrackerEvent* evt = (event_types::TrackerEvent*)event_data;
    raylib_gui::update_tracker_list(ctx.gui_state, evt.tracker_mgr,
                                     evt.tracker_url, evt.status, evt.peers_returned);
}

/**
 * Event handler: DHT started
 * Logs DHT initialization to GUI
 */
fn void on_dht_started_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;

    raylib_gui::add_log(ctx.gui_state, "[DHT] Started");
}

/**
 * Event handler: DHT bootstrapped
 * Logs when DHT has enough nodes to function
 */
fn void on_dht_bootstrapped_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;

    event_types::DhtEvent* evt = (event_types::DhtEvent*)event_data;

    DString msg;
    msg.appendf("[DHT] Bootstrapped (%d nodes)", evt.routing_table_size);
    raylib_gui::add_log(ctx.gui_state, msg.str_view());
}

/**
 * Event handler: DHT peers found
 * Logs when DHT returns peers for a torrent
 */
fn void on_dht_peers_found_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;

    event_types::DhtEvent* evt = (event_types::DhtEvent*)event_data;

    DString msg;
    msg.appendf("[DHT] Found %d peers", evt.peers_found);
    raylib_gui::add_log(ctx.gui_state, msg.str_view());
}

/**
 * Event handler: DHT query complete
 * Logs DHT query results (success or timeout)
 */
fn void on_dht_query_complete_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;

    event_types::DhtEvent* evt = (event_types::DhtEvent*)event_data;

    DString msg;
    msg.appendf("[DHT] %s", evt.status);
    raylib_gui::add_log(ctx.gui_state, msg.str_view());
}

/**
 * Event handler: WebSeed download started
 * Logs when a piece download begins from a web seed
 */
fn void on_webseed_download_started_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;

    event_types::WebSeedEvent* evt = (event_types::WebSeedEvent*)event_data;

    DString msg;
    msg.appendf("[WebSeed] Downloading piece %d", evt.piece_index);
    raylib_gui::add_log(ctx.gui_state, msg.str_view());
}

/**
 * Event handler: WebSeed download complete
 * Logs successful piece download from web seed
 */
fn void on_webseed_download_complete_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;

    event_types::WebSeedEvent* evt = (event_types::WebSeedEvent*)event_data;

    DString msg;
    msg.appendf("[WebSeed] Completed piece %d (total: %.2f MB)",
                evt.piece_index, (float)evt.bytes_downloaded / 1048576.0);
    raylib_gui::add_log(ctx.gui_state, msg.str_view());
}

/**
 * Event handler: WebSeed download failed
 * Logs failed web seed downloads with error details
 */
fn void on_webseed_download_failed_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;

    event_types::WebSeedEvent* evt = (event_types::WebSeedEvent*)event_data;

    DString msg;
    if (evt.http_status_code > 0)
    {
        msg.appendf("[WebSeed] Failed piece %d (HTTP %d)", evt.piece_index, evt.http_status_code);
    }
    else
    {
        msg.appendf("[WebSeed] Failed piece %d: %s", evt.piece_index, evt.error_message);
    }
    raylib_gui::add_log(ctx.gui_state, msg.str_view());
}

/**
 * Event handler: WebSeed URL disabled
 * Logs when a web seed URL is permanently disabled
 */
fn void on_webseed_url_disabled_event(String event_type, void* event_data, void* user_data)
{
    session::Session* ctx = (session::Session*)user_data;
    if (!ctx.gui_state) return;

    event_types::WebSeedEvent* evt = (event_types::WebSeedEvent*)event_data;

    DString msg;
    msg.appendf("[WebSeed] URL disabled: %s", evt.error_message);
    raylib_gui::add_log(ctx.gui_state, msg.str_view());
}

// ============================================================================
// GUI Download Command - Full torrent download with GUI interface
// ============================================================================

<*
 GUI download: Full torrent download with graphical interface.
 Runs until user closes the window.

 @param loop : "Event loop"
 @param torrent_path : "Path to torrent file"
 @param save_path : "Directory to save files"
 @param numwant : "Number of peers to request from tracker"
 @return "Exit code (0 = success, 1 = error)"
*>
fn int cmd_download_gui(event_loop::EventLoop* loop, String torrent_path,
                        String save_path, int numwant)
{
    // Load and parse torrent file
    libtorrent::metainfo::TorrentFile*? torrent = libtorrent::torrent_loader::load_torrent_sync(torrent_path);
    if (catch err = torrent)
    {
        io::eprintfn("Error loading torrent: %s", err);
        return 1;
    }

    // Calculate pieces
    uint num_pieces = torrent.info.calculate_num_pieces();
    uint last_piece_length = torrent.info.calculate_last_piece_length();

    // Initialize GUI
    raylib_gui::UIState* ui = raylib_gui::init(
        torrent.info.name,
        torrent.info.length,
        num_pieces,
        save_path,
        torrent.announce,
        torrent.info.piece_length
    );
    if (!ui)
    {
        io::eprintfn("Failed to initialize GUI");
        torrent.free();
        return 1;
    }

    // Set up GUI logging
    log::Logger logger = log_outputs::setup_gui_logging(ui);
    log::set_logger(logger);

    // WORKAROUND: std::core::log has initialization issues
    // Suppress library logging to avoid null function pointer crashes
    log::set_priority_all(log::LogPriority.CRITICAL);

    // Create download context
    // Create TorrentManager for managing this torrent
    libtorrent::torrent_manager::TorrentManager* mgr = libtorrent::torrent_manager::create(loop, 1);

    Session ctx;
    ctx.manager = mgr;
    ctx.torrent = torrent;
    ctx.dm = null;
    ctx.sm = null;
    ctx.tracker_completed = false;
    ctx.pex_timer = null;
    ctx.keepalive_timer = null;
    ctx.flush_timer = null;
    ctx.block_timeout_timer = null;
    ctx.peer_pool = null;
    ctx.upload_mgr = null;
    ctx.upload_timer = null;
    ctx.dht_search = null;
    ctx.dht_timer = null;
    ctx.dht_check_timer = null;
    // Note: dht_tick_timer and lsd_timer moved to SharedResources
    ctx.download_complete = false;
    ctx.is_partial_seed = false;  // BEP 21: TODO - set true if selective download
    ctx.exit_code = 0;
    ctx.num_pieces = num_pieces;
    ctx.pieces_verified_count = 0;
    ctx.next_piece_to_verify = 0;
    ctx.numwant = numwant;
    ctx.save_path = save_path;
    ctx.max_concurrent_pieces = session::DEFAULT_MAX_CONCURRENT_PIECES;
    ctx.torrent_path = torrent_path;  // BEP 21: Torrent file path for resume data
    ctx.select_files_str = "";  // BEP 21: File selection loaded from resume data if available
    ctx.gui_state = (void*)ui;
    ctx.webseed_mgr = null;
    ctx.webseed_timer = null;
    ctx.total_bytes_downloaded = 0;
    ctx.webseed_bytes_downloaded = 0;
    ctx.last_speed_update_time = 0;
    ctx.current_download_speed = 0.0;
    ctx.last_gui_update_ms = 0;

    // Initialize event bus for pub/sub
    ctx.event_bus = libtorrent::event_bus::create(loop);

    // FastResume: Create download state provider (libtorrent-compatible fastresume format)
    ctx.state_provider = fastresume_state_provider::create();

    // Subscribe GUI event handlers to EventBus
    ctx.event_bus.subscribe(event_types::EVENT_PROGRESS_UPDATED, &on_progress_updated_event, &ctx);
    ctx.event_bus.subscribe(event_types::EVENT_TRACKER_ANNOUNCE_FAILED, &on_tracker_announce_failed_event, &ctx);
    ctx.event_bus.subscribe(event_types::EVENT_TRACKER_NO_PEERS, &on_tracker_no_peers_event, &ctx);
    ctx.event_bus.subscribe(event_types::EVENT_TRACKER_ANNOUNCE_SUCCESS, &on_tracker_announce_success_event, &ctx);
    ctx.event_bus.subscribe(event_types::EVENT_PEER_STATS_UPDATED, &on_peer_stats_updated_event, &ctx);
    ctx.event_bus.subscribe(event_types::EVENT_TRACKER_STATUS_CHANGED, &on_tracker_status_changed_event, &ctx);

    // Subscribe DHT event handlers
    ctx.event_bus.subscribe(event_types::EVENT_DHT_STARTED, &on_dht_started_event, &ctx);
    ctx.event_bus.subscribe(event_types::EVENT_DHT_BOOTSTRAPPED, &on_dht_bootstrapped_event, &ctx);
    ctx.event_bus.subscribe(event_types::EVENT_DHT_PEERS_FOUND, &on_dht_peers_found_event, &ctx);
    ctx.event_bus.subscribe(event_types::EVENT_DHT_QUERY_COMPLETE, &on_dht_query_complete_event, &ctx);

    // Subscribe WebSeed event handlers
    ctx.event_bus.subscribe(event_types::EVENT_WEBSEED_DOWNLOAD_STARTED, &on_webseed_download_started_event, &ctx);
    ctx.event_bus.subscribe(event_types::EVENT_WEBSEED_DOWNLOAD_COMPLETE, &on_webseed_download_complete_event, &ctx);
    ctx.event_bus.subscribe(event_types::EVENT_WEBSEED_DOWNLOAD_FAILED, &on_webseed_download_failed_event, &ctx);
    ctx.event_bus.subscribe(event_types::EVENT_WEBSEED_URL_DISABLED, &on_webseed_url_disabled_event, &ctx);

    // Subscribe to file progress events (BEP 21 Phase 2)
    ctx.event_bus.subscribe(event_types::EVENT_FILE_PROGRESS_UPDATED, &on_file_progress_updated_event, &ctx);
    ctx.event_bus.subscribe(event_types::EVENT_FILE_COMPLETED, &on_file_completed_event, &ctx);

    // Register file selection callback (BEP 21 Phase 3)
    raylib_gui::set_file_selection_callback(ui, &on_file_selection_toggled, &ctx);

    // Initialize tracker configuration (parallel announce settings)
    ctx.tracker_config = tracker_peer_discovery::default_tracker_config();

    // Initialize multi-tracker manager (BEP 12)
    if (torrent.announce_list.len > 0)
    {
        // Use announce-list for multi-tracker support
        ctx.tracker_mgr = mem::new(tracker_manager::TrackerManager);
        *ctx.tracker_mgr = tracker_manager::initialize(torrent.announce_list);

        // Get first tracker from tier 0 for initial display
        ctx.current_tracker_url = ctx.tracker_mgr.get_next_tracker();

        io::printfn("Multi-tracker support: %d tiers, %d total trackers",
                    ctx.tracker_mgr.get_tier_count(),
                    torrent.announce_list[0].len + (torrent.announce_list.len > 1 ? torrent.announce_list[1].len : 0));

        // Populate GUI tracker list immediately
        raylib_gui::update_tracker_list(ui, ctx.tracker_mgr,
                                         ctx.current_tracker_url, "Idle", -1);
    }
    else if (torrent.announce.len > 0)
    {
        // Single tracker - create a TrackerManager with one tier containing one tracker
        String[][] single_tracker_list = mem::new_array(String[], 1);
        single_tracker_list[0] = mem::new_array(String, 1);
        single_tracker_list[0][0] = torrent.announce;

        ctx.tracker_mgr = mem::new(tracker_manager::TrackerManager);
        *ctx.tracker_mgr = tracker_manager::initialize(single_tracker_list[..]);
        ctx.current_tracker_url = torrent.announce;

        io::printfn("Single tracker: %s", torrent.announce);

        // Populate GUI with single tracker
        raylib_gui::update_tracker_list(ui, ctx.tracker_mgr,
                                         ctx.current_tracker_url, "Idle", -1);
    }
    else
    {
        // No trackers at all - DHT-only/web seed-only torrent
        ctx.tracker_mgr = null;
        ctx.current_tracker_url = "";
        io::printfn("No trackers found - will use DHT and web seeds only");
    }

    // Build storage path (for multi-file torrents, append torrent name)
    String storage_path = save_path;
    bool need_free_path_gui = false;
    if (torrent.info.is_multi_file)
    {
        DString path_builder_gui;
        path_builder_gui.append(save_path);
        if (save_path.len > 0 && save_path[save_path.len - 1] != '/')
        {
            path_builder_gui.append("/");
        }
        path_builder_gui.append(torrent.info.name);
        storage_path = path_builder_gui.copy_str(mem);
        need_free_path_gui = true;
    }
    defer if (need_free_path_gui) free(storage_path);

    // Create storage manager
    storage_manager::StorageManager? sm_opt = storage_manager::create(
        loop, &torrent.info, storage_path);
    if (catch err = sm_opt)
    {
        raylib_gui::add_log(ui, "Error creating storage manager");
        raylib_gui::free(ui);
        torrent.free();
        return 1;
    }
    ctx.sm = mem::new(storage_manager::StorageManager);
    *ctx.sm = sm_opt;

    // Create download manager
    ctx.dm = mem::new(download_manager::DownloadManager);
    *ctx.dm = download_manager::create(
        loop,
        num_pieces,
        (uint)torrent.info.piece_length,
        last_piece_length,
        torrent.info.pieces,
        (usz)ctx.max_concurrent_pieces,
        BLOCK_SIZE
    );

    // Initialize file list in GUI (BEP 21)
    // Call after both storage and download managers are created
    update_gui_file_list(&ctx);

    // Create peer pool
    common::PeerId our_peer_id = tracker::generate_peer_id();
    peer_pool::PeerPoolConfig pool_config = peer_pool::get_default_config();
    ctx.peer_pool = peer_pool::create(loop, pool_config, &torrent.info_hash, &our_peer_id, torrent.info.private);

    // Set peer pool callbacks
    ctx.peer_pool.set_callbacks(
        &session::on_download_peer_connected,
        &session::on_download_peer_message,
        &session::on_download_peer_disconnected,
        &ctx
    );

    // Create upload manager
    ctx.upload_mgr = upload_manager::create();
    raylib_gui::add_log(ui, "Created upload manager");

    // Create upload timer (process upload requests every 1 second)
    async::timer::Timer*? upload_timer_opt = async::timer::create(loop);
    if (catch err = upload_timer_opt)
    {
        raylib_gui::add_log(ui, "Warning: Failed to create upload timer");
    }
    else
    {
        ctx.upload_timer = upload_timer_opt;
        ctx.upload_timer.start(1000, 1000, &session::on_upload_timer_tick, &ctx);
        raylib_gui::add_log(ui, "Started upload request processor (1s interval)");
    }

    // Create flush timer (sync files and save fastresume every 30 seconds)
    async::timer::Timer*? flush_timer_opt = async::timer::create(loop);
    if (catch err = flush_timer_opt)
    {
        raylib_gui::add_log(ui, "Warning: Failed to create flush timer");
    }
    else
    {
        ctx.flush_timer = flush_timer_opt;
        ctx.flush_timer.start(30000, 30000, &session::on_flush_timer_tick, &ctx);
        raylib_gui::add_log(ui, "Started periodic file sync and fastresume saves (30s interval)");
    }

    // Initialize DHT for peer discovery
    raylib_gui::add_log(ui, "Starting DHT on port 6881...");
    session::init_dht(&ctx, 6881);

    // Initialize unified peer discovery (Hexagonal Architecture - Composite Pattern)
    raylib_gui::add_log(ui, "Initializing peer discovery...");

    // Build composite with all applicable discovery sources
    ctx.peer_discovery_composite = session::build_peer_discovery_composite(&ctx);

    // Start unified discovery through composite
    peer_discovery::DiscoveryOptions options = peer_discovery::default_options();
    ctx.peer_discovery_composite.start_discovery(
        &ctx.torrent.info_hash,
        &options,
        &session::on_peer_discovery_peers,
        &session::on_peer_discovery_complete,
        &ctx
    );

    usz source_count = ctx.peer_discovery_composite.get_source_count();
    DString discovery_msg;
    discovery_msg.appendf("[PeerDiscovery] Started discovery with %d sources", source_count);
    raylib_gui::add_log(ui, discovery_msg.str_view());
    discovery_msg.free();

    // Initialize web seeding (BEP 19)
    if (torrent.url_list.len > 0)
    {
        ctx.webseed_mgr = libtorrent::webseed::create(loop, torrent, ctx.event_bus);  // Uses default: 20 concurrent
        if (ctx.webseed_mgr)
        {
            DString msg;
            msg.appendf("Web seed support: %d URLs available", torrent.url_list.len);
            raylib_gui::add_log(ui, msg.str_view());

            // Start web seed timer
            async::timer::Timer*? timer_opt = async::timer::create(loop);
            if (catch err = timer_opt)
            {
                raylib_gui::add_log(ui, "Warning: Failed to create web seed timer");
            }
            else
            {
                ctx.webseed_timer = timer_opt;
                ctx.webseed_timer.start(2000, 2000, &session::on_webseed_timer_tick, &ctx);
                raylib_gui::add_log(ui, "Web seed timer started");
            }
        }
    }

    // Initialize storage manager (create directories, open files)
    raylib_gui::add_log(ui, "Initializing storage...");
    ctx.sm.initialize(&session::on_storage_initialized, &ctx);

    // Main GUI loop - run until window closes
    // Continue running after download completes for seeding
    int frame_count = 0;
    while (raylib_gui::run_frame(ui, loop))
    {
        // Event loop and rendering handled in run_frame()

        // Update peer list periodically
        frame_count++;
        if (frame_count % GUI_UPDATE_INTERVAL_FRAMES == 0 && ctx.peer_pool)
        {
            // Filter to show only active/connecting peers, sorted by state (CONNECTED first)
            peer_pool::PeerFilter filter = peer_pool::create_default_filter();
            filter.state_flags = (char)(peer_pool::PeerStateFlag.DISCOVERED |
                                         peer_pool::PeerStateFlag.CANDIDATE |
                                         peer_pool::PeerStateFlag.CONNECTING |
                                         peer_pool::PeerStateFlag.CONNECTED);
            peer_pool::PeerDisplayInfo[] peer_info = ctx.peer_pool.get_peer_display_info_filtered(
                &filter,
                peer_pool::PeerSortOrder.SORT_BY_STATE
            );
            raylib_gui::update_peer_list(ui, peer_info);
        }
    }

    // Cleanup - stop all async operations first
    io::printfn("Cleaning up...");

    // Close timers properly (registers cleanup callbacks)
    // This must be done BEFORE close_all_handles() which drains the callbacks
    io::printfn("Closing timers...");
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
    if (ctx.upload_timer)
    {
        ctx.upload_timer.close();
        ctx.upload_timer = null;
    }

    // Close DHT timers
    io::printfn("Closing DHT timers...");
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
    // Note: dht_tick_timer moved to SharedResources (cleaned up on shared.release())

    // Close event bus timer
    io::printfn("Closing event bus timer...");
    if (ctx.event_bus && ctx.event_bus.dispatch_timer)
    {
        ctx.event_bus.dispatch_timer.close();
        ctx.event_bus.dispatch_timer = null;
    }

    // Close DHT UDP socket (if managed by manager)
    io::printfn("Closing DHT socket...");
    if (ctx.get_dht() && ctx.get_dht().socket)
    {
        ctx.get_dht().socket.close();
        ctx.get_dht().socket = null;
    }

    // Disconnect all peers before freeing peer pool
    io::printfn("Gracefully disconnecting peers...");
    if (ctx.peer_pool)
    {
        // Set shutdown flag BEFORE disconnecting to prevent reconnection attempts
        ctx.peer_pool.shutting_down = true;
        ctx.peer_pool.disconnect_all_gracefully();
    }

    // Close all event loop handles FIRST (fires all async close callbacks)
    // This ensures TCP/timer handles and PeerConnection structs are freed by callbacks
    // BEFORE we try to free the peer pool data structures
    io::printfn("Closing all event loop handles...");
    loop.close_all_handles();

    // Now safe to free resources (connections already freed by callbacks above)
    io::printfn("Freeing peer pool...");
    if (ctx.peer_pool)
    {
        ctx.peer_pool.free();
    }

    // Free DHT resources
    io::printfn("Freeing DHT resources...");
    if (ctx.dht_search)
    {
        ctx.dht_search.free();
    }

    io::printfn("Freeing download manager...");
    if (ctx.dm)
    {
        ctx.dm.free();
        free(ctx.dm);
    }

    if (ctx.sm)
    {
        ctx.sm.free();
        free(ctx.sm);
    }

    if (ctx.torrent)
    {
        ctx.torrent.free();
    }

    // Note: tracker_response is NOT freed here - it's stack-allocated by http_tracker
    // and automatically freed when AnnounceContext is freed

    if (ctx.tracker_mgr)
    {
        ctx.tracker_mgr.free();
    }

    if (ctx.upload_mgr)
    {
        ctx.upload_mgr.free();
    }

    if (ctx.webseed_mgr)
    {
        ctx.webseed_mgr.free();
    }

    if (ctx.metadata_dl)
    {
        ctx.metadata_dl.free();
    }

    if (ctx.speed_tracker)
    {
        ctx.speed_tracker.free();
    }

    // Free event bus
    if (ctx.event_bus)
    {
        ctx.event_bus.free();
    }

    // Release shared resources (auto-frees when ref_count reaches 0)
    io::printfn("Freeing torrent manager...");
    if (mgr)
    {
        mgr.free();
    }

    // No logging cleanup needed for std::core::log

    // Free GUI (this also closes the window)
    io::printfn("Freeing GUI...");
    raylib_gui::free(ui);

    io::printfn("Cleanup complete");
    return ctx.exit_code;
}
