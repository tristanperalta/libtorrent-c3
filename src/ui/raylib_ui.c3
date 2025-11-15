module raylib_gui;

import raylib5::rl;
import raygui::rg;
import async::event_loop;
import libtorrent::peer_pool;
import libtorrent::tracker_manager;
import libtorrent::piece_picker;
import libtorrent::common;
import std::io;

// ============================================================================
// Data Structures
// ============================================================================

// Callback types (BEP 21 Phase 3)
alias FileSelectionCallback = fn void(usz file_index, bool selected, void* user_data);

<*
 Tab selection for the UI.
*>
enum Tab : int
{
    OVERVIEW,
    PEERS,
    FILES,
    TRACKERS,
    LOGS
}

<*
 Tracker display information.
 Used for rendering tracker status in the Trackers tab.
*>
struct TrackerDisplayInfo
{
    String url;              // Tracker URL
    uint tier;               // Tier number (0-based)
    String status;           // Status: "Working", "Trying...", "Failed", "Idle"
    int peers_returned;      // Number of peers returned (-1 if not announced yet)
    bool is_active;          // Is this the currently active tracker?
}

<*
 File display information (BEP 21).
 Used for rendering file list in the Files tab.
*>
struct FileDisplayInfo
{
    String path;             // File path (relative to torrent root)
    long length;             // File size in bytes
    bool is_selected;        // Selected for download (BEP 21)
    bool is_complete;        // All pieces for this file are complete
    float progress;          // Download progress (0.0 - 1.0)
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
    piece_picker::PieceState[] piece_states;  // For piece-by-piece visualization

    // Torrent info
    String save_path;
    String tracker_url;
    String tracker_status;
    long piece_length;
    int num_files;

    // Peer state
    int peers_connected;
    int peers_total;
    peer_pool::PeerDisplayInfo[] peer_list;
    int peer_scroll_offset;

    // Tracker state (BEP 12 multi-tracker)
    TrackerDisplayInfo[] tracker_list;
    int tracker_scroll_offset;

    // File state (BEP 21 file selection)
    FileDisplayInfo[] file_list;
    int file_scroll_offset;
    void* file_selection_callback_data;  // User data for callback
    FileSelectionCallback file_selection_callback;  // Phase 3: File selection change callback

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
    peer_pool::PeerDisplayInfo[] empty_peers;
    state.peer_list = empty_peers;
    state.peer_scroll_offset = 0;

    // Initialize tracker state
    TrackerDisplayInfo[] empty_trackers;
    state.tracker_list = empty_trackers;
    state.tracker_scroll_offset = 0;

    // Initialize file state (BEP 21)
    FileDisplayInfo[] empty_files;
    state.file_list = empty_files;
    state.file_scroll_offset = 0;
    state.file_selection_callback = null;
    state.file_selection_callback_data = null;

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
    rl::Rectangle tab_rect_trackers = {(float)(margin + tab_width * 3), (float)tab_y, (float)tab_width, (float)tab_bar_height};
    rl::Rectangle tab_rect_logs = {(float)(margin + tab_width * 4), (float)tab_y, (float)tab_width, (float)tab_bar_height};

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
    if (rg::guiButton(tab_rect_trackers, "Trackers"))
    {
        state.active_tab = Tab.TRACKERS;
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
        case Tab.TRACKERS:
            render_trackers_tab(state, content_y, content_height);
        case Tab.LOGS:
            render_logs_tab(state, content_y, content_height);
    }

    // Status bar
    render_status_bar(state);
}

<*
 Render piece-by-piece progress bar showing download fragmentation.

 Groups pieces into vertical bars (1 pixel wide) for efficient rendering:
 - Blue: Complete pieces (verified)
 - Light blue: Downloading pieces (in progress)
 - Light gray: Not started

 For large torrents (9,150 pieces), groups ~10 pieces per pixel.
*>
fn void render_piece_bar(UIState* state, int x, int y, int width, int height) @private
{
    if (state.piece_states.len == 0) return;

    // Calculate how many pieces per pixel
    int bar_width = width;
    int pieces_per_bar = (state.pieces_total + bar_width - 1) / bar_width;

    // Draw each vertical bar
    for (int bar = 0; bar < bar_width; bar++)
    {
        uint start_piece = bar * pieces_per_bar;
        uint end_piece = ((bar + 1) * pieces_per_bar);
        if (end_piece > state.pieces_total) end_piece = state.pieces_total;

        // Count states in this bar's piece range
        uint complete = 0;
        uint downloading = 0;

        for (uint i = start_piece; i < end_piece; i++)
        {
            switch (state.piece_states[i])
            {
                case piece_picker::PieceState.COMPLETE:
                    complete++;
                case piece_picker::PieceState.DOWNLOADING:
                    downloading++;
                default:
                    // FREE state - not started
            }
        }

        // Calculate completion percentage for gradient coloring
        uint pieces_in_bar = end_piece - start_piece;
        float completion_pct = (float)complete / (float)pieces_in_bar;

        // Determine bar color using gradient based on completion percentage
        rl::Color color;
        if (completion_pct == 0.0)
        {
            // 0% - Dark gray (no pieces downloaded)
            color = (rl::Color){180, 180, 180, 255};
        }
        else if (completion_pct < 0.25)
        {
            // 1-24% - Light gray (very few pieces)
            color = (rl::Color){200, 200, 200, 255};
        }
        else if (completion_pct < 0.50)
        {
            // 25-49% - Light blue (some progress)
            color = (rl::Color){140, 180, 255, 255};
        }
        else if (completion_pct < 0.75)
        {
            // 50-74% - Medium blue (majority complete)
            color = (rl::Color){80, 140, 240, 255};
        }
        else if (completion_pct < 1.00)
        {
            // 75-99% - Blue (almost all complete)
            color = (rl::Color){40, 100, 200, 255};
        }
        else
        {
            // 100% - Dark blue (all pieces complete)
            color = (rl::Color){0, 80, 160, 255};
        }

        // Draw 1-pixel wide vertical bar
        rl::drawRectangle(x + bar, y, 1, height, color);
    }
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
    y += 50;

    // Piece-by-piece fragmentation bar
    int piece_bar_width = state.window_width - margin * 2;
    int piece_bar_height = 20;
    render_piece_bar(state, margin, y, piece_bar_width, piece_bar_height);
    y += piece_bar_height + 20;

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
    String downloaded_str = common::format_size(state.downloaded);
    defer mem::free(downloaded_str);
    stats_text.appendf("Downloaded: %s", downloaded_str);
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
    String piece_size_str = common::format_size(state.piece_length);
    defer mem::free(piece_size_str);
    stats_text.appendf("Pieces: %d x %s", state.pieces_total, piece_size_str);
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
    String total_size_str = common::format_size(state.total_size);
    defer mem::free(total_size_str);
    info_text.appendf("Total Size: %s", total_size_str);
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
    int margin = 10;
    int row_height = 25;
    int header_height = 30;

    // Table columns
    int col1_x = margin;                    // IP:Port
    int col1_width = 180;
    int col2_x = col1_x + col1_width;       // Client
    int col2_width = 150;
    int col3_x = col2_x + col2_width;       // % Complete
    int col3_width = 100;
    int col4_x = col3_x + col3_width;       // Down Speed
    int col4_width = 110;
    int col5_x = col4_x + col4_width;       // Up Speed
    int col5_width = 110;
    int col6_x = col5_x + col5_width;       // State
    int col6_width = 120;

    int y = content_y;

    // Draw header background
    rl::drawRectangle(margin, y, state.window_width - margin * 2, header_height,
                      (rl::Color){220, 220, 220, 255});

    // Draw column headers
    rl::drawText("IP Address", col1_x + 5, y + 8, 18, rl::DARKGRAY);
    rl::drawText("Client", col2_x + 5, y + 8, 18, rl::DARKGRAY);
    rl::drawText("% Complete", col3_x + 5, y + 8, 18, rl::DARKGRAY);
    rl::drawText("Down Speed", col4_x + 5, y + 8, 18, rl::DARKGRAY);
    rl::drawText("Up Speed", col5_x + 5, y + 8, 18, rl::DARKGRAY);
    rl::drawText("State", col6_x + 5, y + 8, 18, rl::DARKGRAY);

    y += header_height;

    // Calculate how many rows we can display
    int table_height = content_height - header_height - 40;  // Reserve 40px for status bar
    int max_rows = table_height / row_height;

    // Draw peer rows
    int row_count = 0;
    foreach (i, peer : state.peer_list)
    {
        // Skip rows that are scrolled out of view
        if (i < (usz)state.peer_scroll_offset) continue;

        // Stop if we've filled the visible area
        if (row_count >= max_rows) break;

        // Alternating row colors
        rl::Color row_color = (row_count % 2 == 0) ?
            (rl::Color){255, 255, 255, 255} :  // White
            (rl::Color){245, 245, 245, 255};   // Light gray

        rl::drawRectangle(margin, y, state.window_width - margin * 2, row_height, row_color);

        // Column 1: IP:Port
        DString ip_port;
        ip_port.appendf("%s:%d", peer.ip_address, peer.port);
        rl::drawText(ip_port.zstr_view(), col1_x + 5, y + 5, 16, rl::DARKGRAY);

        // Column 2: Client
        rl::drawText((ZString)peer.client.ptr, col2_x + 5, y + 5, 16, rl::DARKGRAY);

        // Column 3: % Complete
        DString percent;
        percent.appendf("%.1f%%", peer.percent_complete);
        rl::drawText(percent.zstr_view(), col3_x + 5, y + 5, 16, rl::DARKGRAY);

        // Column 4: Down Speed
        DString down_speed;
        if (peer.download_speed > 0.0)
        {
            down_speed.appendf("%.1f KiB/s", peer.download_speed / 1024.0);
        }
        else
        {
            down_speed.append("-");
        }
        rl::drawText(down_speed.zstr_view(), col4_x + 5, y + 5, 16, rl::DARKGRAY);

        // Column 5: Up Speed
        DString up_speed;
        if (peer.upload_speed > 0.0)
        {
            up_speed.appendf("%.1f KiB/s", peer.upload_speed / 1024.0);
        }
        else
        {
            up_speed.append("-");
        }
        rl::drawText(up_speed.zstr_view(), col5_x + 5, y + 5, 16, rl::DARKGRAY);

        // Column 6: State
        rl::drawText((ZString)peer.state.ptr, col6_x + 5, y + 5, 16, rl::DARKGRAY);

        y += row_height;
        row_count++;
    }

    // Draw status bar at bottom of table
    int status_y = content_y + content_height - 35;
    rl::drawRectangle(margin, status_y, state.window_width - margin * 2, 30,
                      (rl::Color){230, 230, 230, 255});

    DString status_text;
    status_text.appendf("Connections: %d (%d)  |  Down Speed: %.1f KiB/s  |  Up Speed: %.1f KiB/s",
                       state.peers_connected,
                       state.peers_total,
                       state.download_speed / 1024.0,
                       state.upload_speed / 1024.0);
    rl::drawText(status_text.zstr_view(), margin + 10, status_y + 8, 16, rl::DARKGRAY);

    // TODO: Add scrollbar if peer_list.len > max_rows
}

<*
 Render the Files tab (BEP 21 file selection).
*>
fn void render_files_tab(UIState* state, int content_y, int content_height) @private
{
    int margin = 10;
    int row_height = 25;
    int header_height = 30;

    // Table columns
    int col0_x = margin;                    // Checkbox (BEP 21 Phase 3)
    int col0_width = 30;
    int col1_x = col0_x + col0_width;       // File name/path
    int col1_width = 370;                   // Reduced to make room for checkbox
    int col2_x = col1_x + col1_width;       // Size
    int col2_width = 120;
    int col3_x = col2_x + col2_width;       // Progress bar
    int col3_width = 200;
    int col4_x = col3_x + col3_width;       // Status
    int col4_width = 120;

    int y = content_y;

    // Check if we have files to display
    if (state.file_list.len == 0)
    {
        rl::drawText("No files to display (single-file torrent or not yet loaded)",
                     margin, y + 20, 18, rl::DARKGRAY);
        return;
    }

    // Draw header background
    rl::drawRectangle(margin, y, state.window_width - margin * 2, header_height,
                      (rl::Color){220, 220, 220, 255});

    // Draw column headers
    rl::drawText("☑", col0_x + 8, y + 8, 18, rl::DARKGRAY);  // Checkbox column
    rl::drawText("File Path", col1_x + 5, y + 8, 18, rl::DARKGRAY);
    rl::drawText("Size", col2_x + 5, y + 8, 18, rl::DARKGRAY);
    rl::drawText("Progress", col3_x + 5, y + 8, 18, rl::DARKGRAY);
    rl::drawText("Status", col4_x + 5, y + 8, 18, rl::DARKGRAY);

    y += header_height;

    // Calculate how many rows we can display
    int table_height = content_height - header_height - 40;  // Reserve 40px for status bar
    int max_rows = table_height / row_height;

    // Draw file rows
    int row_count = 0;
    foreach (i, file : state.file_list)
    {
        // Skip rows that are scrolled out of view
        if (i < (usz)state.file_scroll_offset) continue;

        // Stop if we've filled the visible area
        if (row_count >= max_rows) break;

        // Alternating row colors
        rl::Color row_color = (row_count % 2 == 0) ?
            (rl::Color){255, 255, 255, 255} :  // White
            (rl::Color){245, 245, 245, 255};   // Light gray

        rl::drawRectangle(margin, y, state.window_width - margin * 2, row_height, row_color);

        // Column 0: Checkbox (BEP 21 Phase 3)
        rl::Rectangle checkbox_rect = { (float)(col0_x + 5), (float)(y + 3), 18.0, 18.0 };
        bool old_checked = file.is_selected;
        bool checked = file.is_selected;
        rg::guiCheckBox(checkbox_rect, null, &checked);

        // Check if value changed
        if (checked != old_checked)
        {
            // Checkbox was clicked - invoke callback to toggle selection
            if (state.file_selection_callback)
            {
                usz file_index = i;  // Actual file index in the full list
                state.file_selection_callback(file_index, checked, state.file_selection_callback_data);
            }
        }

        // Column 1: File path (truncate if too long)
        String display_path = file.path;
        if (display_path.len > 50)
        {
            DString truncated;
            truncated.append("...");
            truncated.append(display_path[display_path.len - 47..]);
            rl::drawText(truncated.zstr_view(), col1_x + 5, y + 5, 16, rl::DARKGRAY);
        }
        else
        {
            rl::drawText((ZString)file.path.ptr, col1_x + 5, y + 5, 16, rl::DARKGRAY);
        }

        // Column 2: Size (human-readable)
        DString size_str;
        if (file.length >= 1073741824)  // >= 1 GiB
        {
            size_str.appendf("%.2f GiB", (double)file.length / 1073741824.0);
        }
        else if (file.length >= 1048576)  // >= 1 MiB
        {
            size_str.appendf("%.2f MiB", (double)file.length / 1048576.0);
        }
        else if (file.length >= 1024)  // >= 1 KiB
        {
            size_str.appendf("%.2f KiB", (double)file.length / 1024.0);
        }
        else
        {
            size_str.appendf("%d B", file.length);
        }
        rl::drawText(size_str.zstr_view(), col2_x + 5, y + 5, 16, rl::DARKGRAY);

        // Column 3: Progress bar
        int progress_bar_width = col3_width - 20;
        int progress_bar_height = 16;
        int progress_bar_x = col3_x + 10;
        int progress_bar_y = y + 5;

        // Background (gray)
        rl::drawRectangle(progress_bar_x, progress_bar_y, progress_bar_width, progress_bar_height,
                          (rl::Color){200, 200, 200, 255});

        // Progress fill (green if complete, blue if downloading, gray if not selected)
        rl::Color progress_color;
        if (file.is_complete)
        {
            progress_color = (rl::Color){0, 180, 0, 255};  // Green
        }
        else if (file.is_selected)
        {
            progress_color = (rl::Color){0, 120, 215, 255};  // Blue
        }
        else
        {
            progress_color = (rl::Color){150, 150, 150, 255};  // Gray (not selected)
        }

        int filled_width = (int)(progress_bar_width * file.progress);
        if (filled_width > 0)
        {
            rl::drawRectangle(progress_bar_x, progress_bar_y, filled_width, progress_bar_height,
                              progress_color);
        }

        // Progress percentage text
        DString progress_text;
        progress_text.appendf("%.1f%%", file.progress * 100.0);
        rl::drawText(progress_text.zstr_view(), progress_bar_x + progress_bar_width + 5, y + 5, 16, rl::DARKGRAY);

        // Column 4: Status
        String status_text;
        if (file.is_complete)
        {
            status_text = "Complete";
        }
        else if (file.is_selected)
        {
            status_text = "Downloading";
        }
        else
        {
            status_text = "Skipped";
        }
        rl::drawText((ZString)status_text.ptr, col4_x + 5, y + 5, 16, rl::DARKGRAY);

        y += row_height;
        row_count++;
    }

    // Draw status bar at bottom of table
    int status_y = content_y + content_height - 35;
    rl::drawRectangle(margin, status_y, state.window_width - margin * 2, 30,
                      (rl::Color){230, 230, 230, 255});

    // Count selected and complete files
    usz selected_count = 0;
    usz complete_count = 0;
    long total_selected_size = 0;

    foreach (file : state.file_list)
    {
        if (file.is_selected)
        {
            selected_count++;
            total_selected_size += file.length;
        }
        if (file.is_complete) complete_count++;
    }

    DString status_text;
    status_text.appendf("Files: %d total  |  %d selected  |  %d complete",
                       state.file_list.len,
                       selected_count,
                       complete_count);
    rl::drawText(status_text.zstr_view(), margin + 10, status_y + 8, 16, rl::DARKGRAY);

    // TODO: Add scrollbar if file_list.len > max_rows
    // TODO: Add checkboxes for file selection (Phase 3)
}

<*
 Render the Trackers tab (BEP 12 multi-tracker support).
*>
fn void render_trackers_tab(UIState* state, int content_y, int content_height) @private
{
    int margin = 10;
    int row_height = 25;
    int header_height = 30;

    // Table columns
    int col1_x = margin;                    // Tier
    int col1_width = 60;
    int col2_x = col1_x + col1_width;       // Tracker URL
    int col2_width = 500;
    int col3_x = col2_x + col2_width;       // Status
    int col3_width = 120;
    int col4_x = col3_x + col3_width;       // Peers
    int col4_width = 80;

    int y = content_y;

    // Draw header background
    rl::drawRectangle(margin, y, state.window_width - margin * 2, header_height,
                      (rl::Color){220, 220, 220, 255});

    // Draw column headers
    rl::drawText("Tier", col1_x + 5, y + 8, 18, rl::DARKGRAY);
    rl::drawText("Tracker URL", col2_x + 5, y + 8, 18, rl::DARKGRAY);
    rl::drawText("Status", col3_x + 5, y + 8, 18, rl::DARKGRAY);
    rl::drawText("Peers", col4_x + 5, y + 8, 18, rl::DARKGRAY);

    y += header_height;

    // Calculate how many rows we can display
    int table_height = content_height - header_height - 40;  // Reserve 40px for status bar
    int max_rows = table_height / row_height;

    // Draw tracker rows
    int row_count = 0;
    foreach (i, tracker : state.tracker_list)
    {
        // Skip rows that are scrolled out of view
        if (i < (usz)state.tracker_scroll_offset) continue;

        // Stop if we've filled the visible area
        if (row_count >= max_rows) break;

        // Alternating row colors with highlight for active tracker
        rl::Color row_color;
        if (tracker.is_active)
        {
            row_color = (rl::Color){220, 255, 220, 255};  // Light green for active
        }
        else
        {
            row_color = (row_count % 2 == 0) ?
                (rl::Color){255, 255, 255, 255} :  // White
                (rl::Color){245, 245, 245, 255};   // Light gray
        }

        rl::drawRectangle(margin, y, state.window_width - margin * 2, row_height, row_color);

        // Column 1: Tier
        DString tier_str;
        tier_str.appendf("%d", tracker.tier);
        rl::drawText(tier_str.zstr_view(), col1_x + 15, y + 5, 16, rl::DARKGRAY);

        // Column 2: Tracker URL (truncate if too long)
        String display_url = tracker.url;
        if (display_url.len > 60)
        {
            DString truncated;
            truncated.append(display_url[:57]);
            truncated.append("...");
            rl::drawText(truncated.zstr_view(), col2_x + 5, y + 5, 16, rl::DARKGRAY);
        }
        else
        {
            rl::drawText((ZString)display_url.ptr, col2_x + 5, y + 5, 16, rl::DARKGRAY);
        }

        // Column 3: Status with color coding
        rl::Color status_color;
        if (tracker.status == "Working")
        {
            status_color = (rl::Color){34, 139, 34, 255};  // Green
        }
        else if (tracker.status == "Trying...")
        {
            status_color = (rl::Color){255, 140, 0, 255};  // Orange
        }
        else if (tracker.status == "Failed")
        {
            status_color = (rl::Color){220, 20, 60, 255};  // Red
        }
        else  // Idle
        {
            status_color = rl::DARKGRAY;
        }
        rl::drawText((ZString)tracker.status.ptr, col3_x + 5, y + 5, 16, status_color);

        // Column 4: Peers returned
        DString peers_str;
        if (tracker.peers_returned >= 0)
        {
            peers_str.appendf("%d", tracker.peers_returned);
        }
        else
        {
            peers_str.append("-");
        }
        rl::drawText(peers_str.zstr_view(), col4_x + 15, y + 5, 16, rl::DARKGRAY);

        y += row_height;
        row_count++;
    }

    // Draw status bar at bottom of table
    int status_y = content_y + content_height - 35;
    rl::drawRectangle(margin, status_y, state.window_width - margin * 2, 30,
                      (rl::Color){230, 230, 230, 255});

    DString status_text;
    if (state.tracker_list.len == 0)
    {
        status_text.append("No trackers configured");
    }
    else
    {
        int working_count = 0;
        foreach (tracker : state.tracker_list)
        {
            if (tracker.status == "Working") working_count++;
        }
        status_text.appendf("Total trackers: %d  |  Working: %d",
                           state.tracker_list.len, working_count);
    }
    rl::drawText(status_text.zstr_view(), margin + 10, status_y + 8, 16, rl::DARKGRAY);
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
 Update piece states for visualization.
 Called from progress event handler with current piece states.
*>
fn void update_piece_states(UIState* state, piece_picker::PieceState[] states) @public
{
    // Free old piece states
    if (state.piece_states.len > 0)
    {
        mem::free(state.piece_states.ptr);
    }

    // Store new piece states
    state.piece_states = states;
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
 Update peer list.
 Called periodically to refresh peer table.
 Takes ownership of the peer_list array.
*>
fn void update_peer_list(UIState* state, peer_pool::PeerDisplayInfo[] new_peer_list) @public
{
    // Free old peer list
    if (state.peer_list.len > 0)
    {
        foreach (peer : state.peer_list)
        {
            if (peer.ip_address.len > 0) mem::free(peer.ip_address.ptr);
            if (peer.client.len > 0) mem::free(peer.client.ptr);
            if (peer.state.len > 0) mem::free(peer.state.ptr);
        }
        mem::free(state.peer_list.ptr);
    }

    // Store new peer list
    state.peer_list = new_peer_list;
}

<*
 Update tracker list from tracker manager (BEP 12).
 Called after tracker announces to refresh the Trackers tab.

 @param state : "UI state"
 @param tracker_mgr : "Tracker manager (or null for single tracker mode)"
 @param current_tracker_url : "Currently active tracker URL"
 @param last_status : "Last announce status (for fallback to single tracker)"
 @param last_peers : "Number of peers from last announce (-1 if failed)"
*>
fn void update_tracker_list(UIState* state,
                             tracker_manager::TrackerManager* tracker_mgr,
                             String current_tracker_url,
                             String last_status,
                             int last_peers) @public
{
    // Free old tracker list
    if (state.tracker_list.len > 0)
    {
        foreach (tracker : state.tracker_list)
        {
            if (tracker.url.len > 0) mem::free(tracker.url.ptr);
            if (tracker.status.len > 0) mem::free(tracker.status.ptr);
        }
        mem::free(state.tracker_list.ptr);
    }

    // Build new tracker list
    if (tracker_mgr && tracker_mgr.has_trackers())
    {
        // Multi-tracker mode (BEP 12)
        usz total_trackers = 0;

        // Count total trackers across all tiers
        for (uint tier = 0; tier < tracker_mgr.get_tier_count(); tier++)
        {
            total_trackers += tracker_mgr.get_tracker_count(tier);
        }

        if (total_trackers > 0)
        {
            TrackerDisplayInfo[] new_list = mem::new_array(TrackerDisplayInfo, total_trackers);
            usz index = 0;

            String active_tracker = tracker_mgr.get_active_tracker();

            // Iterate through all tiers and trackers
            for (uint tier = 0; tier < tracker_mgr.get_tier_count(); tier++)
            {
                uint tracker_count = tracker_mgr.get_tracker_count(tier);
                for (uint i = 0; i < tracker_count; i++)
                {
                    String tracker_url = tracker_mgr.get_tracker_url(tier, i);

                    TrackerDisplayInfo info;
                    info.tier = tier;
                    info.url = tracker_url.copy(mem);

                    // Determine status
                    if (tracker_url == active_tracker)
                    {
                        info.status = "Working".copy(mem);
                        info.peers_returned = last_peers;
                        info.is_active = true;
                    }
                    else if (tracker_url == current_tracker_url)
                    {
                        info.status = "Trying...".copy(mem);
                        info.peers_returned = -1;
                        info.is_active = false;
                    }
                    else
                    {
                        info.status = "Idle".copy(mem);
                        info.peers_returned = -1;
                        info.is_active = false;
                    }

                    new_list[index++] = info;
                }
            }

            state.tracker_list = new_list;
        }
        else
        {
            TrackerDisplayInfo[] empty;
            state.tracker_list = empty;
        }
    }
    else
    {
        // Single tracker fallback mode
        TrackerDisplayInfo[] new_list = mem::new_array(TrackerDisplayInfo, 1);

        TrackerDisplayInfo info;
        info.tier = 0;
        info.url = current_tracker_url.copy(mem);
        info.status = last_status.copy(mem);
        info.peers_returned = last_peers;
        info.is_active = true;

        new_list[0] = info;
        state.tracker_list = new_list;
    }
}

<*
 Update file list from storage manager (BEP 21).
 Called to refresh the Files tab with current file download status.

 @param state : "UI state"
 @param new_file_list : "New file list (ownership transferred to UIState)"
*>
fn void update_file_list(UIState* state, FileDisplayInfo[] new_file_list) @public
{
    // Free old file list
    if (state.file_list.len > 0)
    {
        foreach (file : state.file_list)
        {
            if (file.path.len > 0) mem::free(file.path.ptr);
        }
        mem::free(state.file_list.ptr);
    }

    // Store new file list
    state.file_list = new_file_list;
}

<*
 Set file selection callback (BEP 21 Phase 3).
 Called by main.c3 to register callback for file selection changes.

 @param state : "UI state"
 @param callback : "Callback function (file_index, selected, user_data)"
 @param user_data : "User data passed to callback"
*>
fn void set_file_selection_callback(UIState* state,
                                      FileSelectionCallback callback,
                                      void* user_data) @public
{
    state.file_selection_callback = callback;
    state.file_selection_callback_data = user_data;
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

    // Free peer list
    if (state.peer_list.len > 0)
    {
        foreach (peer : state.peer_list)
        {
            if (peer.ip_address.len > 0) mem::free(peer.ip_address.ptr);
            if (peer.client.len > 0) mem::free(peer.client.ptr);
            if (peer.state.len > 0) mem::free(peer.state.ptr);
        }
        mem::free(state.peer_list.ptr);
    }

    // Free tracker list
    if (state.tracker_list.len > 0)
    {
        foreach (tracker : state.tracker_list)
        {
            if (tracker.url.len > 0) mem::free(tracker.url.ptr);
            if (tracker.status.len > 0) mem::free(tracker.status.ptr);
        }
        mem::free(state.tracker_list.ptr);
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

    // Free piece states
    if (state.piece_states.len > 0)
    {
        mem::free(state.piece_states.ptr);
    }

    // Close raylib window
    rl::closeWindow();

    mem::free(state);
}
