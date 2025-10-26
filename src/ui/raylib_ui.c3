module raylib_gui;

import raylib5::rl;
import raygui::rg;
import async::event_loop;
import libtorrent::logger;
import std::io;

// ============================================================================
// Data Structures
// ============================================================================

<*
 Tab selection for the UI.
*>
enum Tab : int
{
    OVERVIEW,
    PEERS,
    FILES,
    LOGS
}

<*
 UI State - shared between download callbacks and rendering.
*>
struct UIState
{
    // Tab management
    Tab active_tab;

    // Window state
    int window_width;
    int window_height;
    bool window_should_close;

    // Download state (updated by callbacks)
    String torrent_name;
    long total_size;
    long downloaded;
    float download_speed;     // bytes/sec
    float upload_speed;       // bytes/sec
    uint pieces_total;
    uint pieces_complete;
    uint pieces_downloading;

    // Torrent info
    String save_path;
    String tracker_url;
    String tracker_status;
    long piece_length;
    int num_files;

    // Peer state
    int peers_connected;
    int peers_total;

    // Log messages (ring buffer)
    String[] log_messages;
    usz log_capacity;
    usz log_write_pos;
    bool log_auto_scroll;
}

// ============================================================================
// Initialization
// ============================================================================

<*
 Initialize the GUI window.

 @param torrent_name : "Name of torrent being downloaded"
 @param total_size : "Total size in bytes"
 @param pieces_total : "Total number of pieces"
 @param save_path : "Directory where files are being saved"
 @param tracker_url : "Primary tracker URL"
 @param piece_length : "Size of each piece in bytes"
 @return "UI state or null on error"
*>
fn UIState* init(String torrent_name, long total_size, uint pieces_total,
                String save_path, String tracker_url, long piece_length) @public
{
    // Initialize raylib
    rl::initWindow(1280, 720, "BitTorrent Client");
    rl::setWindowState(rl::FLAG_WINDOW_RESIZABLE);
    rl::setTargetFPS(60);

    // Create UI state
    UIState* state = mem::new(UIState);
    state.active_tab = Tab.OVERVIEW;
    state.window_width = 1280;
    state.window_height = 720;
    state.window_should_close = false;

    // Initialize download state
    state.torrent_name = torrent_name.copy(mem);
    state.total_size = total_size;
    state.downloaded = 0;
    state.download_speed = 0.0;
    state.upload_speed = 0.0;
    state.pieces_total = pieces_total;
    state.pieces_complete = 0;
    state.pieces_downloading = 0;

    // Initialize torrent info
    state.save_path = save_path.copy(mem);
    state.tracker_url = tracker_url.copy(mem);
    state.tracker_status = "Connecting...".copy(mem);
    state.piece_length = piece_length;
    state.num_files = 1;  // Single file for now

    // Initialize peer state
    state.peers_connected = 0;
    state.peers_total = 0;

    // Initialize log buffer (keep last 1000 messages)
    state.log_capacity = 1000;
    state.log_messages = mem::new_array(String, state.log_capacity);
    state.log_write_pos = 0;
    state.log_auto_scroll = true;

    return state;
}

// ============================================================================
// Main Loop
// ============================================================================

<*
 Run one frame of the GUI.
 Processes async events and renders the UI.

 @param state : "UI state"
 @param loop : "Event loop for async I/O"
 @return "True if should continue, false if window closed"
*>
fn bool run_frame(UIState* state, event_loop::EventLoop* loop) @public
{
    // Check for window close
    if (rl::windowShouldClose())
    {
        state.window_should_close = true;
        return false;
    }

    // Process async I/O events (non-blocking)
    // Use run_nowait() instead of run_once() to prevent blocking the GUI
    loop.run_nowait();

    // Flush log messages to UI
    logger::flush_logs();

    // Update window dimensions if resized
    if (rl::isWindowResized())
    {
        state.window_width = rl::getScreenWidth();
        state.window_height = rl::getScreenHeight();
    }

    // Render UI
    rl::beginDrawing();
    rl::clearBackground((rl::Color){240, 240, 240, 255});  // Light gray

    render_ui(state);

    rl::endDrawing();

    return true;
}

// ============================================================================
// Rendering
// ============================================================================

<*
 Render the entire UI.

 @param state : "UI state"
*>
fn void render_ui(UIState* state) @private
{
    int margin = 10;
    int tab_bar_height = 30;
    int status_bar_height = 30;

    // Title bar (manual - raygui doesn't have a built-in title bar)
    rl::drawRectangle(0, 0, state.window_width, tab_bar_height + 10, (rl::Color){50, 50, 50, 255});
    rl::drawText((ZString)state.torrent_name.ptr, margin, 10, 20, rl::WHITE);

    // Tab bar
    int tab_y = tab_bar_height + 10;
    int tab_width = 120;
    rl::Rectangle tab_rect_overview = {(float)margin, (float)tab_y, (float)tab_width, (float)tab_bar_height};
    rl::Rectangle tab_rect_peers = {(float)(margin + tab_width), (float)tab_y, (float)tab_width, (float)tab_bar_height};
    rl::Rectangle tab_rect_files = {(float)(margin + tab_width * 2), (float)tab_y, (float)tab_width, (float)tab_bar_height};
    rl::Rectangle tab_rect_logs = {(float)(margin + tab_width * 3), (float)tab_y, (float)tab_width, (float)tab_bar_height};

    // Tab buttons
    if (rg::guiButton(tab_rect_overview, "Overview"))
    {
        state.active_tab = Tab.OVERVIEW;
    }
    if (rg::guiButton(tab_rect_peers, "Peers"))
    {
        state.active_tab = Tab.PEERS;
    }
    if (rg::guiButton(tab_rect_files, "Files"))
    {
        state.active_tab = Tab.FILES;
    }
    if (rg::guiButton(tab_rect_logs, "Logs"))
    {
        state.active_tab = Tab.LOGS;
    }

    // Content area
    int content_y = tab_y + tab_bar_height + margin;
    int content_height = state.window_height - content_y - status_bar_height - margin;

    // Render active tab
    switch (state.active_tab)
    {
        case Tab.OVERVIEW:
            render_overview_tab(state, content_y, content_height);
        case Tab.PEERS:
            render_peers_tab(state, content_y, content_height);
        case Tab.FILES:
            render_files_tab(state, content_y, content_height);
        case Tab.LOGS:
            render_logs_tab(state, content_y, content_height);
    }

    // Status bar
    render_status_bar(state);
}

<*
 Format a file size in bytes to human-readable format.
*>
fn String format_size(long bytes) @private
{
    DString buf;
    if (bytes >= 1024L * 1024L * 1024L)
    {
        buf.appendf("%.2f GiB", (double)bytes / (1024.0 * 1024.0 * 1024.0));
    }
    else if (bytes >= 1024L * 1024L)
    {
        buf.appendf("%.2f MiB", (double)bytes / (1024.0 * 1024.0));
    }
    else if (bytes >= 1024L)
    {
        buf.appendf("%.2f KiB", (double)bytes / 1024.0);
    }
    else
    {
        buf.appendf("%d B", bytes);
    }
    return buf.str_view();
}

<*
 Render the Overview tab.
*>
fn void render_overview_tab(UIState* state, int content_y, int content_height) @private
{
    int margin = 20;
    int y = content_y;

    // Progress section (full width)
    rl::drawText("Download Progress", margin, y, 20, rl::DARKGRAY);
    y += 30;

    // Calculate progress
    float progress = 0.0;
    if (state.pieces_total > 0)
    {
        progress = (float)state.pieces_complete / (float)state.pieces_total;
    }

    // Progress bar
    float progress_min = 0.0;
    float progress_max = 1.0;
    rl::Rectangle progress_rect = {(float)margin, (float)y, (float)(state.window_width - margin * 2), 40.0};
    DString progress_label;
    progress_label.appendf("%.1f%%", progress * 100.0);
    rg::guiProgressBar(progress_rect, null, progress_label.zstr_view(), &progress, progress_min, progress_max);
    y += 60;

    // Two-column layout: Statistics (left) | Torrent Info (right)
    int column_width = (state.window_width - margin * 3) / 2;
    int left_x = margin;
    int right_x = margin * 2 + column_width;
    int stats_y = y;

    // Left column: Statistics
    rl::drawText("Statistics", left_x, stats_y, 18, rl::DARKGRAY);
    stats_y += 30;

    DString stats_text;

    // Downloaded
    stats_text.clear();
    stats_text.appendf("Downloaded: %s", format_size(state.downloaded));
    rl::drawText(stats_text.zstr_view(), left_x, stats_y, 16, rl::DARKGRAY);
    stats_y += 25;

    // Speed
    stats_text.clear();
    stats_text.appendf("Download Speed: %.2f MB/s", state.download_speed / (1024.0 * 1024.0));
    rl::drawText(stats_text.zstr_view(), left_x, stats_y, 16, rl::DARKGRAY);
    stats_y += 25;

    stats_text.clear();
    stats_text.appendf("Upload Speed: %.2f MB/s", state.upload_speed / (1024.0 * 1024.0));
    rl::drawText(stats_text.zstr_view(), left_x, stats_y, 16, rl::DARKGRAY);
    stats_y += 25;

    // Peers
    stats_text.clear();
    stats_text.appendf("Peers: %d (%d)", state.peers_connected, state.peers_total);
    rl::drawText(stats_text.zstr_view(), left_x, stats_y, 16, rl::DARKGRAY);
    stats_y += 25;

    // Pieces
    stats_text.clear();
    stats_text.appendf("Pieces: %d x %s", state.pieces_total, format_size(state.piece_length));
    rl::drawText(stats_text.zstr_view(), left_x, stats_y, 16, rl::DARKGRAY);
    stats_y += 25;

    stats_text.clear();
    stats_text.appendf("Complete: %d  Downloading: %d", state.pieces_complete, state.pieces_downloading);
    rl::drawText(stats_text.zstr_view(), left_x, stats_y, 16, rl::DARKGRAY);

    // Right column: Torrent Info
    int info_y = y;
    rl::drawText("Torrent Info", right_x, info_y, 18, rl::DARKGRAY);
    info_y += 30;

    DString info_text;

    // Name
    info_text.clear();
    info_text.appendf("Name: %s", state.torrent_name);
    rl::drawText(info_text.zstr_view(), right_x, info_y, 16, rl::DARKGRAY);
    info_y += 25;

    // Path
    info_text.clear();
    info_text.appendf("Path: %s", state.save_path);
    rl::drawText(info_text.zstr_view(), right_x, info_y, 16, rl::DARKGRAY);
    info_y += 25;

    // Total Size
    info_text.clear();
    info_text.appendf("Total Size: %s", format_size(state.total_size));
    rl::drawText(info_text.zstr_view(), right_x, info_y, 16, rl::DARKGRAY);
    info_y += 25;

    // # of files
    info_text.clear();
    info_text.appendf("# of files: %d", state.num_files);
    rl::drawText(info_text.zstr_view(), right_x, info_y, 16, rl::DARKGRAY);
    info_y += 25;

    // Tracker
    info_text.clear();
    info_text.appendf("Tracker: %s", state.tracker_url);
    rl::drawText(info_text.zstr_view(), right_x, info_y, 16, rl::DARKGRAY);
    info_y += 25;

    // Tracker Status
    info_text.clear();
    info_text.appendf("Status: %s", state.tracker_status);
    rl::drawText(info_text.zstr_view(), right_x, info_y, 16, rl::DARKGRAY);
}

<*
 Render the Peers tab.
*>
fn void render_peers_tab(UIState* state, int content_y, int content_height) @private
{
    int margin = 20;
    int y = content_y;

    DString peers_text;
    peers_text.appendf("Connected Peers: %d / %d", state.peers_connected, state.peers_total);
    rl::drawText(peers_text.zstr_view(), margin, y, 20, rl::DARKGRAY);
    y += 40;

    rl::drawText("Peer list will be implemented next...", margin, y, 18, rl::LIGHTGRAY);
}

<*
 Render the Files tab.
*>
fn void render_files_tab(UIState* state, int content_y, int content_height) @private
{
    int margin = 20;
    int y = content_y;

    rl::drawText("Files", margin, y, 20, rl::DARKGRAY);
    y += 40;

    rl::drawText("File list will be implemented next...", margin, y, 18, rl::LIGHTGRAY);
}

<*
 Render the Logs tab.
*>
fn void render_logs_tab(UIState* state, int content_y, int content_height) @private
{
    int margin = 20;
    int y = content_y;

    rl::drawText("Event Log", margin, y, 20, rl::DARKGRAY);
    y += 40;

    rl::drawText("Logs will be displayed here...", margin, y, 18, rl::LIGHTGRAY);
}

<*
 Render the status bar at the bottom.
*>
fn void render_status_bar(UIState* state) @private
{
    int status_bar_height = 30;
    int status_y = state.window_height - status_bar_height;

    // Background
    rl::drawRectangle(0, status_y, state.window_width, status_bar_height,
                           (rl::Color){200, 200, 200, 255});

    // Status text
    DString status_text;
    status_text.appendf("Status: Downloading  |  ↓ %.2f MB/s  ↑ %.2f MB/s  |  Peers: %d",
                       state.download_speed / (1024.0 * 1024.0),
                       state.upload_speed / (1024.0 * 1024.0),
                       state.peers_connected);

    rl::drawText(status_text.zstr_view(), 10, status_y + 8, 16, rl::DARKGRAY);
}

// ============================================================================
// State Update Methods
// ============================================================================

<*
 Update download progress.
 Called from download callbacks.
*>
fn void update_progress(UIState* state, uint pieces_complete, uint pieces_downloading,
                       long downloaded, float download_speed, float upload_speed) @public
{
    state.pieces_complete = pieces_complete;
    state.pieces_downloading = pieces_downloading;
    state.downloaded = downloaded;
    state.download_speed = download_speed;
    state.upload_speed = upload_speed;
}

<*
 Update peer stats.
 Called from peer connection callbacks.
*>
fn void update_peers(UIState* state, int peers_connected, int peers_total) @public
{
    state.peers_connected = peers_connected;
    state.peers_total = peers_total;
}

<*
 Update tracker status.
 Called from tracker announce callbacks.
*>
fn void update_tracker_status(UIState* state, String status) @public
{
    // Free old status
    if (state.tracker_status.len > 0)
    {
        mem::free(state.tracker_status.ptr);
    }

    // Copy new status
    state.tracker_status = status.copy(mem);
}

<*
 Add a log message.
 Called from logger flush callback.
*>
fn void add_log(UIState* state, String message) @public
{
    // Copy message to ring buffer
    usz index = state.log_write_pos % state.log_capacity;

    // Free old message if exists
    if (state.log_messages[index].len > 0)
    {
        mem::free(state.log_messages[index].ptr);
    }

    // Store new message
    state.log_messages[index] = message.copy(mem);
    state.log_write_pos++;
}

// ============================================================================
// Cleanup
// ============================================================================

<*
 Free UI state and close window.

 @param state : "UI state to free"
*>
fn void free(UIState* state) @public
{
    if (!state) return;

    // Free torrent name
    if (state.torrent_name.len > 0)
    {
        mem::free(state.torrent_name.ptr);
    }

    // Free torrent info strings
    if (state.save_path.len > 0)
    {
        mem::free(state.save_path.ptr);
    }
    if (state.tracker_url.len > 0)
    {
        mem::free(state.tracker_url.ptr);
    }
    if (state.tracker_status.len > 0)
    {
        mem::free(state.tracker_status.ptr);
    }

    // Free log messages
    for (usz i = 0; i < state.log_capacity; i++)
    {
        if (state.log_messages[i].len > 0)
        {
            mem::free(state.log_messages[i].ptr);
        }
    }
    if (state.log_messages.len > 0)
    {
        mem::free(state.log_messages.ptr);
    }

    // Close raylib window
    rl::closeWindow();

    mem::free(state);
}
