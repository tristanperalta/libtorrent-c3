module torrent_ui;

import ncurses;
import libtorrent::common;
import std::io;
import std::core::string;

<*
 Terminal User Interface for BitTorrent Client

 Provides a professional ncurses-based TUI with:
 - Header showing torrent name
 - Progress bar with download statistics
 - Scrollable peer list
 - Event log panel
*>

// ============================================================================
// Data Structures
// ============================================================================

struct PeerDisplay
{
    common::Ipv4Addr ip;
    ushort port;
    bool is_seed;
    bool supports_pex;
    long bytes_downloaded;
    int pieces_received;
    int total_pieces;
}

struct TorrentUI
{
    // Windows
    ncurses::Window* header_win;
    ncurses::Window* progress_win;
    ncurses::Window* peers_win;
    ncurses::Window* events_win;

    // Data
    ZString torrent_name;  // Null-terminated for ncurses
    PeerDisplay[] peers;
    ZString[] event_log;   // Null-terminated for ncurses
    int max_events;

    // Async rendering queue
    ZString[] pending_events;  // Events queued for next flush

    // Dimensions
    int term_height;
    int term_width;
}

// ============================================================================
// Public API
// ============================================================================

<*
 Create and initialize the TUI.

 @param torrent_name : "Name of the torrent being downloaded"
 @return "Initialized TorrentUI or null on error"
*>
fn TorrentUI* create(String torrent_name) @public
{
    // Initialize ncurses
    ncurses::Window* stdscr = ncurses::initscr();
    if (!stdscr)
    {
        io::eprintfn("Failed to initialize ncurses");
        return null;
    }

    // Configure terminal
    ncurses::cbreak();       // Disable line buffering
    ncurses::noecho();       // Don't echo input
    ncurses::curs_set(0);    // Hide cursor

    // No colors - using plain ASCII mode for better compatibility

    TorrentUI* ui = mem::new(TorrentUI);

    // Copy torrent name as null-terminated string
    ui.torrent_name = torrent_name.zstr_copy(mem);

    ui.peers = {};
    ui.event_log = {};
    ui.pending_events = {};  // Initialize empty queue
    ui.max_events = 100;  // Keep last 100 events

    // Get terminal dimensions
    ui.term_height = ncurses::getmaxy(stdscr);
    ui.term_width = ncurses::getmaxx(stdscr);

    // Create windows
    create_windows(ui);

    // Initial display
    draw_static_content(ui);
    refresh_all_windows(ui);

    return ui;
}

<*
 Free the TUI and restore terminal.

 @param ui : "UI to free"
*>
fn void free(TorrentUI* ui) @public
{
    if (!ui) return;

    // Delete windows
    if (ui.header_win) ncurses::delwin(ui.header_win);
    if (ui.progress_win) ncurses::delwin(ui.progress_win);
    if (ui.peers_win) ncurses::delwin(ui.peers_win);
    if (ui.events_win) ncurses::delwin(ui.events_win);

    // Free torrent name
    if (ui.torrent_name)
    {
        mem::free((void*)ui.torrent_name);
    }

    // Free event log
    if (ui.event_log.len > 0)
    {
        foreach (event : ui.event_log)
        {
            mem::free((void*)event);
        }
        mem::free((void*)ui.event_log.ptr);
    }

    // Free peer list
    if (ui.peers.len > 0)
    {
        mem::free((void*)ui.peers.ptr);
    }

    // Restore terminal
    ncurses::endwin();

    mem::free((void*)ui);
}

<*
 Update the progress display.

 @param ui : "UI instance"
 @param pieces_done : "Number of pieces completed"
 @param total_pieces : "Total number of pieces"
 @param connected_peers : "Number of connected peers"
 @param candidate_peers : "Number of candidate peers"
*>
fn void update_progress(TorrentUI* ui, int pieces_done, int total_pieces,
                       int connected_peers, int candidate_peers) @public
{
    if (!ui || !ui.progress_win) return;

    ncurses::werase(ui.progress_win);
    ncurses::box(ui.progress_win, 0, 0);

    // Draw progress bar
    int percent = total_pieces > 0 ? (pieces_done * 100) / total_pieces : 0;
    int bar_width = 30;
    int filled = (percent * bar_width) / 100;

    ncurses::mvwprintw(ui.progress_win, 1, 2, "Progress: [");

    // Draw filled portion with ASCII '#'
    for (int i = 0; i < filled; i++)
    {
        ncurses::wprintw(ui.progress_win, "#");
    }

    // Draw empty portion with ASCII '-'
    for (int i = filled; i < bar_width; i++)
    {
        ncurses::wprintw(ui.progress_win, "-");
    }

    ncurses::wprintw(ui.progress_win, "] %d%% (%d/%d pieces)", percent, pieces_done, total_pieces);

    // Peer count
    ncurses::mvwprintw(ui.progress_win, 2, 2, "Peers: %d connected / %d total",
                  connected_peers, connected_peers + candidate_peers);

    ncurses::wrefresh(ui.progress_win);
}

<*
 Update or add a peer to the display.

 @param ui : "UI instance"
 @param ip : "Peer IP address"
 @param port : "Peer port"
 @param is_seed : "Whether peer is a seed"
 @param supports_pex : "Whether peer supports PEX"
 @param bytes_downloaded : "Total bytes downloaded from peer"
 @param pieces_received : "Number of pieces received"
 @param total_pieces : "Total pieces in torrent"
*>
fn void update_peer(TorrentUI* ui, common::Ipv4Addr ip, ushort port,
                   bool is_seed, bool supports_pex, long bytes_downloaded,
                   int pieces_received, int total_pieces) @public
{
    if (!ui) return;

    // Find existing peer
    for (usz i = 0; i < ui.peers.len; i++)
    {
        if (ui.peers[i].ip[0] == ip[0] && ui.peers[i].ip[1] == ip[1] &&
            ui.peers[i].ip[2] == ip[2] && ui.peers[i].ip[3] == ip[3] &&
            ui.peers[i].port == port)
        {
            // Update existing
            ui.peers[i].is_seed = is_seed;
            ui.peers[i].supports_pex = supports_pex;
            ui.peers[i].bytes_downloaded = bytes_downloaded;
            ui.peers[i].pieces_received = pieces_received;
            ui.peers[i].total_pieces = total_pieces;

            redraw_peers(ui);
            return;
        }
    }

    // Add new peer
    PeerDisplay new_peer;
    new_peer.ip = ip;
    new_peer.port = port;
    new_peer.is_seed = is_seed;
    new_peer.supports_pex = supports_pex;
    new_peer.bytes_downloaded = bytes_downloaded;
    new_peer.pieces_received = pieces_received;
    new_peer.total_pieces = total_pieces;

    PeerDisplay[] new_peers = mem::new_array(PeerDisplay, ui.peers.len + 1);
    foreach (i, peer : ui.peers)
    {
        new_peers[i] = peer;
    }
    new_peers[ui.peers.len] = new_peer;

    if (ui.peers.len > 0) mem::free((void*)ui.peers.ptr);
    ui.peers = new_peers;

    redraw_peers(ui);
}

<*
 Remove a peer from the display.

 @param ui : "UI instance"
 @param ip : "Peer IP address"
 @param port : "Peer port"
*>
fn void remove_peer(TorrentUI* ui, common::Ipv4Addr ip, ushort port) @public
{
    if (!ui) return;

    // Find peer index
    usz found_index = ui.peers.len;
    for (usz i = 0; i < ui.peers.len; i++)
    {
        if (ui.peers[i].ip[0] == ip[0] && ui.peers[i].ip[1] == ip[1] &&
            ui.peers[i].ip[2] == ip[2] && ui.peers[i].ip[3] == ip[3] &&
            ui.peers[i].port == port)
        {
            found_index = i;
            break;
        }
    }

    if (found_index >= ui.peers.len) return;

    // Create new array without this peer
    PeerDisplay[] new_peers = mem::new_array(PeerDisplay, ui.peers.len - 1);
    usz write_idx = 0;
    for (usz i = 0; i < ui.peers.len; i++)
    {
        if (i != found_index)
        {
            new_peers[write_idx++] = ui.peers[i];
        }
    }

    mem::free((void*)ui.peers.ptr);
    ui.peers = new_peers;

    redraw_peers(ui);
}

<*
 Queue an event message for async rendering (non-blocking).

 The message is copied to the heap and added to pending_events queue.
 Call flush_ui() from event loop to actually render the queued events.

 @param ui : "UI instance"
 @param message : "Event message to log"
*>
fn void add_event(TorrentUI* ui, String message) @public
{
    if (!ui) return;

    // IMPORTANT: Copy message to heap IMMEDIATELY
    // Manually copy byte-by-byte to ensure we get the data before temp allocator frees it
    usz len = message.len;
    if (len == 0) return;

    // Allocate on heap with extra byte for null terminator
    char[] heap_copy = mem::new_array(char, len + 1);
    for (usz i = 0; i < len; i++)
    {
        heap_copy[i] = message[i];
    }
    heap_copy[len] = 0; // Null terminate

    ZString event = (ZString)heap_copy.ptr;

    // Add to pending queue (not to event_log yet - that happens in flush_ui)
    ZString[] new_queue = mem::new_array(ZString, ui.pending_events.len + 1);
    foreach (i, old_event : ui.pending_events)
    {
        new_queue[i] = old_event;
    }
    new_queue[ui.pending_events.len] = event;

    if (ui.pending_events.len > 0) mem::free((void*)ui.pending_events.ptr);
    ui.pending_events = new_queue;
}

<*
 Update the torrent name in the header.

 @param ui : "UI instance"
 @param torrent_name : "New torrent name to display"
*>
fn void update_header(TorrentUI* ui, String torrent_name) @public
{
    if (!ui || !ui.header_win) return;

    // Free old torrent name
    if (ui.torrent_name)
    {
        mem::free((void*)ui.torrent_name);
    }

    // Copy new torrent name
    ui.torrent_name = torrent_name.zstr_copy(mem);

    // Redraw header (plain text, no colors)
    ncurses::werase(ui.header_win);
    ncurses::box(ui.header_win, 0, 0);
    ncurses::mvwprintw(ui.header_win, 1, 2, "BitTorrent Client - %s", ui.torrent_name);
    ncurses::wrefresh(ui.header_win);
}

<*
 Handle terminal resize - recreate windows with new dimensions.

 @param ui : "UI instance"
*>
fn void handle_resize(TorrentUI* ui) @public
{
    if (!ui) return;

    // Notify ncurses of resize
    ncurses::endwin();
    ncurses::refresh();

    // Get new terminal dimensions
    ncurses::Window* stdscr = ncurses::initscr();
    ui.term_height = ncurses::getmaxy(stdscr);
    ui.term_width = ncurses::getmaxx(stdscr);

    // Delete old windows
    if (ui.header_win) ncurses::delwin(ui.header_win);
    if (ui.progress_win) ncurses::delwin(ui.progress_win);
    if (ui.peers_win) ncurses::delwin(ui.peers_win);
    if (ui.events_win) ncurses::delwin(ui.events_win);

    // Recreate windows with new dimensions
    create_windows(ui);

    // Redraw all content
    draw_static_content(ui);
    redraw_peers(ui);
    redraw_events(ui);
    refresh_all_windows(ui);
}

<*
 Check if terminal has been resized and handle it.
 Call this periodically (e.g., every few seconds).

 @param ui : "UI instance"
*>
fn void check_and_handle_resize(TorrentUI* ui) @public
{
    if (!ui) return;

    // Check current terminal size
    ncurses::Window* stdscr = ncurses::initscr();
    int current_height = ncurses::getmaxy(stdscr);
    int current_width = ncurses::getmaxx(stdscr);

    // If size changed, trigger resize
    if (current_height != ui.term_height || current_width != ui.term_width)
    {
        handle_resize(ui);
    }
}

<*
 Refresh the entire display.

 @param ui : "UI instance"
*>
fn void refresh_display(TorrentUI* ui) @public
{
    if (!ui) return;

    refresh_all_windows(ui);
}

<*
 Flush pending events to the display (async rendering).

 This drains the pending_events queue and updates the ncurses display.
 Should be called periodically from the event loop (e.g., every 500ms-2s).

 @param ui : "UI instance"
*>
fn void flush_ui(TorrentUI* ui) @public
{
    if (!ui || ui.pending_events.len == 0) return;

    // Process all pending events
    for (usz i = 0; i < ui.pending_events.len; i++)
    {
        ZString event = ui.pending_events[i];

        // Add to event_log
        ZString[] new_log = mem::new_array(ZString, ui.event_log.len + 1);
        foreach (j, old_event : ui.event_log)
        {
            new_log[j] = old_event;
        }
        new_log[ui.event_log.len] = event;

        if (ui.event_log.len > 0) mem::free((void*)ui.event_log.ptr);
        ui.event_log = new_log;

        // Trim to max events
        if (ui.event_log.len > (usz)ui.max_events)
        {
            // Free oldest event
            mem::free((void*)ui.event_log[0]);

            // Shift array
            ZString[] trimmed = mem::new_array(ZString, ui.max_events);
            for (usz k = 0; k < (usz)ui.max_events; k++)
            {
                trimmed[k] = ui.event_log[k + 1];
            }

            mem::free((void*)ui.event_log.ptr);
            ui.event_log = trimmed;
        }
    }

    // Clear pending queue
    if (ui.pending_events.len > 0)
    {
        mem::free((void*)ui.pending_events.ptr);
        ui.pending_events = {};
    }

    // Update ncurses display
    redraw_events(ui);
}

// ============================================================================
// Private Helper Functions
// ============================================================================

fn void create_windows(TorrentUI* ui) @private
{
    int y = 0;

    // Header window (3 lines)
    ui.header_win = ncurses::newwin(3, ui.term_width, y, 0);
    y += 3;

    // Progress window (4 lines)
    ui.progress_win = ncurses::newwin(4, ui.term_width, y, 0);
    y += 4;

    // Calculate remaining space
    int remaining = ui.term_height - y;
    int peers_height = remaining / 2;
    int events_height = remaining - peers_height;

    // Peers window
    ui.peers_win = ncurses::newwin(peers_height, ui.term_width, y, 0);
    y += peers_height;

    // Events window
    ui.events_win = ncurses::newwin(events_height, ui.term_width, y, 0);
}

fn void draw_static_content(TorrentUI* ui) @private
{
    // Draw header (plain text, no colors)
    ncurses::box(ui.header_win, 0, 0);
    ncurses::mvwprintw(ui.header_win, 1, 2, "BitTorrent Client - %s", ui.torrent_name);

    // Draw progress window border
    ncurses::box(ui.progress_win, 0, 0);

    // Draw peers window border and header
    ncurses::box(ui.peers_win, 0, 0);
    ncurses::mvwprintw(ui.peers_win, 0, 2, " Peers ");

    // Draw events window border and header
    ncurses::box(ui.events_win, 0, 0);
    ncurses::mvwprintw(ui.events_win, 0, 2, " Events ");
}

fn void redraw_peers(TorrentUI* ui) @private
{
    if (!ui.peers_win) return;

    ncurses::werase(ui.peers_win);
    ncurses::box(ui.peers_win, 0, 0);
    ncurses::mvwprintw(ui.peers_win, 0, 2, " Peers ");

    int max_lines = ncurses::getmaxy(ui.peers_win) - 2;
    int line = 1;

    foreach (i, peer : ui.peers)
    {
        if (line >= max_lines) break;

        // Format: "IP:Port  STATUS  Downloaded" (plain text, no colors)
        ncurses::mvwprintw(ui.peers_win, line, 2, "%d.%d.%d.%d:%d",
                      peer.ip[0], peer.ip[1], peer.ip[2], peer.ip[3], peer.port);

        // Status
        if (peer.is_seed)
        {
            ncurses::wprintw(ui.peers_win, " SEED");
        }
        else
        {
            ncurses::wprintw(ui.peers_win, " LEECHER");
        }

        // PEX indicator
        if (peer.supports_pex)
        {
            ncurses::wprintw(ui.peers_win, " [PEX]");
        }

        // Downloaded bytes
        ncurses::wprintw(ui.peers_win, "  %ld bytes", peer.bytes_downloaded);

        line++;
    }

    ncurses::wrefresh(ui.peers_win);
}

fn void redraw_events(TorrentUI* ui) @private
{
    if (!ui.events_win) return;

    ncurses::werase(ui.events_win);
    ncurses::box(ui.events_win, 0, 0);
    ncurses::mvwprintw(ui.events_win, 0, 2, " Events ");

    int max_lines = ncurses::getmaxy(ui.events_win) - 2;
    int start_idx = 0;

    // Show most recent events (scroll from bottom)
    if ((int)ui.event_log.len > max_lines)
    {
        start_idx = (int)ui.event_log.len - max_lines;
    }

    int line = 1;
    int max_width = ncurses::getmaxx(ui.events_win) - 4; // Leave 2 chars on each side for borders

    for (usz i = (usz)start_idx; i < ui.event_log.len; i++)
    {
        // Safety check - skip null or invalid strings
        ZString event_str = ui.event_log[i];
        if (event_str && event_str[0] != 0)
        {
            // Calculate actual string length
            usz str_len = 0;
            while (event_str[str_len] != 0) str_len++;

            // If string is too long, truncate it for display
            if ((int)str_len > max_width)
            {
                // Print truncated directly without copying
                // ncurses mvwprintw with precision specifier
                ncurses::mvwprintw(ui.events_win, line, 2, "%.*s", max_width, event_str);
            }
            else
            {
                // String fits, print as-is
                ncurses::mvwprintw(ui.events_win, line, 2, "%s", event_str);
            }

            line++;
        }
    }

    ncurses::wrefresh(ui.events_win);
}

fn void refresh_all_windows(TorrentUI* ui) @private
{
    if (ui.header_win) ncurses::wrefresh(ui.header_win);
    if (ui.progress_win) ncurses::wrefresh(ui.progress_win);
    if (ui.peers_win) ncurses::wrefresh(ui.peers_win);
    if (ui.events_win) ncurses::wrefresh(ui.events_win);
}
