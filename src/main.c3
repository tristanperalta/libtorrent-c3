module torrent_client;

import std::io;
import std::encoding::hex;
import uv;
import libtorrent;
import libtorrent::tracker;
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
import libtorrent::logger;
import torrent_client::log_outputs;
import raylib_gui;

// ============================================================================
// Configuration Constants
// ============================================================================

// File flush interval in milliseconds (how often to sync downloaded data to disk)
// Default: 5000ms (5 seconds) - balances data safety with performance
// Set to 0 to disable periodic flushing (only flush on exit)
const int FILE_FLUSH_INTERVAL_MS = 5000;

// ============================================================================
// Main Entry Point
// ============================================================================

fn int main(int argc, ZString* argv)
{
    if (argc < 2)
    {
        print_usage();
        return 1;
    }

    String command = (String)argv[1].str_view();

    // Create event loop early (needed for async operations)
    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        io::eprintfn("Error creating event loop");
        return 1;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Check for commands
    if (command == "info")
    {
        if (argc < 3)
        {
            io::eprintfn("Error: 'info' command requires a torrent file path");
            print_usage();
            return 1;
        }
        String torrent_path = (String)argv[2].str_view();
        return cmd_info(&loop, torrent_path);
    }
    else if (command == "announce")
    {
        if (argc < 3)
        {
            io::eprintfn("Error: 'announce' command requires a torrent file path");
            print_usage();
            return 1;
        }
        String torrent_path = (String)argv[2].str_view();
        return cmd_announce(&loop, torrent_path);
    }
    else if (command == "connect")
    {
        if (argc < 3)
        {
            io::eprintfn("Error: 'connect' command requires a torrent file path");
            print_usage();
            return 1;
        }
        String torrent_path = (String)argv[2].str_view();
        return cmd_connect(&loop, torrent_path);
    }
    else if (command == "download")
    {
        if (argc < 3)
        {
            io::eprintfn("Error: 'download' command requires a torrent file path");
            print_usage();
            return 1;
        }
        String torrent_path = (String)argv[2].str_view();

        // Parse optional arguments
        int numwant = tracker::DEFAULT_NUMWANT;
        String save_path = ".";  // Default to current directory
        String log_file_path = "";  // No file logging by default
        bool debug_mode = false;
        bool gui_mode = false;

        for (usz i = 3; i < (usz)argc; i++)
        {
            String arg = (String)argv[i].str_view();
            if (arg == "--numwant" && i + 1 < (usz)argc)
            {
                // Parse numwant value
                String val = (String)argv[i + 1].str_view();
                numwant = (int)val.to_long() ?? tracker::DEFAULT_NUMWANT;
                i++; // Skip next arg
            }
            else if (arg == "--save-path" && i + 1 < (usz)argc)
            {
                save_path = (String)argv[i + 1].str_view();
                i++; // Skip next arg
            }
            else if (arg == "--log-file" && i + 1 < (usz)argc)
            {
                log_file_path = (String)argv[i + 1].str_view();
                i++; // Skip next arg
            }
            else if (arg == "--debug")
            {
                debug_mode = true;
            }
            else if (arg == "--gui")
            {
                gui_mode = true;
            }
        }

        return cmd_download(&loop, torrent_path, save_path, numwant, log_file_path, debug_mode, gui_mode);
    }
    else
    {
        // Legacy behavior: treat first arg as file path
        return cmd_info(&loop, command);
    }
}

// Context for info command
struct InfoContext
{
    bool completed;
    int exit_code;
}

fn void on_info_load_complete(String data, int status, void* user_data)
{
    InfoContext* ctx = (InfoContext*)user_data;
    ctx.completed = true;

    if (status != 0)
    {
        ZString error_str = (ZString)uv::strerror(status);
        io::eprintfn("Error loading file: %s (status=%d)", error_str, status);
        ctx.exit_code = 1;
        return;
    }
    defer free(data);

    // Parse torrent
    libtorrent::metainfo::TorrentFile*? torrent = libtorrent::metainfo::parse(data);
    if (catch err = torrent)
    {
        io::eprintfn("Error parsing torrent: %s", err);
        ctx.exit_code = 1;
        return;
    }
    defer libtorrent::metainfo::free_torrent_file(torrent);

    // Display metadata
    display_torrent_info(torrent);
    ctx.exit_code = 0;
}

<*
 Info command: load and display torrent metadata (async).

 @param loop : "Event loop"
 @param torrent_path : "Path to torrent file"
 @return "Exit code (0 = success, 1 = error)"
*>
fn int cmd_info(event_loop::EventLoop* loop, String torrent_path)
{
    InfoContext ctx;
    ctx.completed = false;
    ctx.exit_code = 0;

    // Start async load
    torrent_loader::load_file_async(loop, torrent_path,
                                     &on_info_load_complete, &ctx);

    // Run event loop until load completes
    while (!ctx.completed && loop.is_alive())
    {
        loop.run_once();
    }

    return ctx.exit_code;
}

fn void print_usage()
{
    io::printfn("Usage: torrent-client [COMMAND] <torrent-file> [OPTIONS]");
    io::printfn("");
    io::printfn("Commands:");
    io::printfn("  info <file>          Display torrent metadata (default)");
    io::printfn("  announce <file>      Announce to tracker and show peer list");
    io::printfn("  connect <file>       Announce and connect to peers with handshake");
    io::printfn("  download <file>      Download torrent to disk");
    io::printfn("");
    io::printfn("Download Options:");
    io::printfn("  --save-path <path>   Directory to save files (default: current directory)");
    io::printfn("  --numwant <n>        Number of peers to request from tracker (default: 50)");
    io::printfn("  --log-file <path>    Log to file");
    io::printfn("  --debug              Enable debug output to stderr");
    io::printfn("  --gui                Launch graphical user interface");
    io::printfn("");
    io::printfn("Examples:");
    io::printfn("  torrent-client info ubuntu.torrent");
    io::printfn("  torrent-client announce ubuntu.torrent");
    io::printfn("  torrent-client connect ubuntu.torrent");
    io::printfn("  torrent-client download ubuntu.torrent");
    io::printfn("  torrent-client download ubuntu.torrent --save-path ~/Downloads --numwant 100");
    io::printfn("  torrent-client download ubuntu.torrent --log-file download.log --debug");
    io::printfn("  torrent-client download ubuntu.torrent --gui");
    io::printfn("  torrent-client ubuntu.torrent          # Same as 'info'");
}

<*
 Convert tracker error status code to descriptive string.

 @param status : "Tracker error status code"
 @return "Descriptive error message"
*>
fn String tracker_error_string(int status)
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

fn void display_torrent_info(libtorrent::metainfo::TorrentFile* torrent)
{
    io::printfn("=== Torrent Information ===");
    io::printfn("");

    // Basic info
    io::printfn("Name: %s", torrent.info.name);
    io::printfn("Size: %s (%d bytes)", format_size(torrent.info.length), torrent.info.length);

    // Info hash (convert to hex)
    String hash_hex = hex::encode(mem, &torrent.info_hash);
    defer free(hash_hex);
    io::printfn("Info Hash: %s", hash_hex);
    io::printfn("");

    // Trackers
    io::printfn("Trackers:");
    if (torrent.announce.len > 0)
    {
        io::printfn("  [Primary] %s", torrent.announce);
    }

    if (torrent.announce_list.len > 0)
    {
        foreach (tier_idx, tier : torrent.announce_list)
        {
            io::printfn("  [Tier %d]", tier_idx);
            foreach (tracker : tier)
            {
                io::printfn("    %s", tracker);
            }
        }
    }
    io::printfn("");

    // Files
    io::printfn("Files:");
    if (torrent.info.is_multi_file)
    {
        io::printfn("  Multi-file torrent (%d files)", torrent.info.files.len);
        foreach (idx, file : torrent.info.files)
        {
            // Build full path from components
            DString path;
            foreach (i, component : file.path)
            {
                if (i > 0) path.append_char('/');
                path.append(component);
            }
            io::printfn("    [%d] %s (%s)", idx + 1, path.str_view(), format_size(file.length));
        }
    }
    else
    {
        io::printfn("  Single file torrent");
    }
    io::printfn("");

    // Piece info
    io::printfn("Piece Info:");
    io::printfn("  Piece length: %s", format_size(torrent.info.piece_length));
    long num_pieces = torrent.info.pieces.len / 20;
    io::printfn("  Total pieces: %d", num_pieces);
    io::printfn("");

    // Web seeds
    if (torrent.url_list.len > 0)
    {
        io::printfn("Web Seeds:");
        foreach (idx, url : torrent.url_list)
        {
            io::printfn("  [%d] %s", idx + 1, url);
        }
        io::printfn("");
    }

    if (torrent.httpseeds.len > 0)
    {
        io::printfn("HTTP Seeds:");
        foreach (idx, url : torrent.httpseeds)
        {
            io::printfn("  [%d] %s", idx + 1, url);
        }
        io::printfn("");
    }

    // Optional metadata
    bool has_optional = false;

    if (torrent.created_by.len > 0)
    {
        if (!has_optional)
        {
            io::printfn("Optional Info:");
            has_optional = true;
        }
        io::printfn("  Created by: %s", torrent.created_by);
    }

    if (torrent.creation_date > 0)
    {
        if (!has_optional)
        {
            io::printfn("Optional Info:");
            has_optional = true;
        }
        io::printfn("  Creation date: %d (Unix timestamp)", torrent.creation_date);
    }
}

fn String format_size(long bytes)
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

<*
 Format IP address from 4-byte array to string.

 @param ip : "4-byte IP address"
 @return "Formatted IP string (xxx.xxx.xxx.xxx)"
*>
fn String format_ip_address(char[4] ip)
{
    DString result;
    result.appendf("%d.%d.%d.%d",
                   (int)ip[0] & 0xFF,
                   (int)ip[1] & 0xFF,
                   (int)ip[2] & 0xFF,
                   (int)ip[3] & 0xFF);
    return result.copy_str(mem);
}

<*
 Display tracker response in formatted output.

 @param response : "Tracker response to display"
*>
fn void display_tracker_response(tracker::TrackerResponse* response)
{
    io::printfn("=== Tracker Response ===");
    io::printfn("");

    // Check for failure
    if (response.failure_reason.len > 0)
    {
        io::printfn("Status: FAILED");
        io::printfn("Failure reason: %s", response.failure_reason);
        return;
    }

    io::printfn("Status: SUCCESS");
    io::printfn("");

    // Display tracker metadata
    io::printfn("Tracker Info:");
    io::printfn("  Re-announce interval: %d seconds", response.interval);
    if (response.min_interval > 0)
    {
        io::printfn("  Minimum interval: %d seconds", response.min_interval);
    }
    io::printfn("  Seeders (complete): %d", response.complete);
    io::printfn("  Leechers (incomplete): %d", response.incomplete);
    io::printfn("");

    // Display warning if present
    if (response.warning_message.len > 0)
    {
        io::printfn("Warning: %s", response.warning_message);
        io::printfn("");
    }

    // Display peer list
    io::printfn("Peers (%d total):", response.peers.len);
    if (response.peers.len == 0)
    {
        io::printfn("  (no peers returned)");
    }
    else
    {
        foreach (idx, peer : response.peers)
        {
            String ip = format_ip_address(peer.ip);
            defer free(ip);
            io::printfn("  [%d] %s:%d", idx + 1, ip, peer.port);
        }
    }
}

// Context for announce command (includes both load and announce state)
struct CmdAnnounceContext
{
    event_loop::EventLoop* loop;
    bool completed;
    tracker::TrackerResponse* response;
    int tracker_status;
    int exit_code;
    libtorrent::metainfo::TorrentFile* torrent;
}

fn void on_tracker_announce_complete(tracker::TrackerResponse* response, int status, void* user_data)
{
    CmdAnnounceContext* ctx = (CmdAnnounceContext*)user_data;
    ctx.completed = true;
    ctx.response = response;
    ctx.tracker_status = status;
}

fn void on_announce_load_complete(String data, int status, void* user_data)
{
    CmdAnnounceContext* ctx = (CmdAnnounceContext*)user_data;

    if (status != 0)
    {
        ZString error_str = (ZString)uv::strerror(status);
        io::eprintfn("Error loading file: %s (status=%d)", error_str, status);
        ctx.exit_code = 1;
        ctx.completed = true;
        return;
    }
    defer free(data);

    // Parse torrent
    libtorrent::metainfo::TorrentFile*? torrent = libtorrent::metainfo::parse(data);
    if (catch err = torrent)
    {
        io::eprintfn("Error parsing torrent: %s", err);
        ctx.exit_code = 1;
        ctx.completed = true;
        return;
    }

    // Store torrent (will be freed by caller)
    ctx.torrent = torrent;

    // Check if torrent has tracker
    String tracker_url = torrent.announce;
    if (tracker_url.len == 0)
    {
        // Try announce-list if available
        if (torrent.announce_list.len > 0 && torrent.announce_list[0].len > 0)
        {
            tracker_url = torrent.announce_list[0][0];
        }
        else
        {
            io::eprintfn("Error: Torrent has no tracker URL");
            io::eprintfn("This torrent uses DHT or peer exchange only");
            ctx.exit_code = 1;
            ctx.completed = true;
            return;
        }
    }

    io::printfn("Announcing to tracker: %s", tracker_url);
    io::printfn("");

    // Reset completion flag for announce phase
    ctx.completed = false;

    // Announce to tracker (non-blocking)
    ushort our_port = 6881;
    tracker::announce(ctx.loop, torrent, our_port, "started",
                      &on_tracker_announce_complete, ctx);
}

<*
 Announce command: contact tracker and display peer list.
 Uses async file loading and async tracker (fully non-blocking).

 @param loop : "Event loop"
 @param torrent_path : "Path to torrent file"
 @return "Exit code (0 = success, 1 = error)"
*>
fn int cmd_announce(event_loop::EventLoop* loop, String torrent_path)
{
    CmdAnnounceContext ctx;
    ctx.loop = loop;
    ctx.completed = false;
    ctx.response = null;
    ctx.tracker_status = 0;
    ctx.exit_code = 0;
    ctx.torrent = null;

    // Start async load
    torrent_loader::load_file_async(loop, torrent_path,
                                     &on_announce_load_complete, &ctx);

    // Run event loop until load completes
    while (!ctx.completed && loop.is_alive())
    {
        loop.run_once();
    }

    // Check if load/parse failed
    if (ctx.exit_code != 0 || !ctx.torrent)
    {
        if (ctx.torrent)
        {
            libtorrent::metainfo::free_torrent_file(ctx.torrent);
        }
        return ctx.exit_code;
    }

    // Run event loop until announce completes
    while (!ctx.completed && loop.is_alive())
    {
        loop.run_once();
    }

    // Free torrent (must be done before returning)
    if (ctx.torrent)
    {
        libtorrent::metainfo::free_torrent_file(ctx.torrent);
    }

    if (!ctx.completed || ctx.tracker_status != 0 || !ctx.response)
    {
        // Check if response has a failure reason from tracker
        if (ctx.response && ctx.response.failure_reason.len > 0)
        {
            io::eprintfn("Tracker error: %s", ctx.response.failure_reason);
        }
        else if (ctx.tracker_status != 0)
        {
            // Show descriptive error based on status code
            String error_desc = tracker_error_string(ctx.tracker_status);
            io::eprintfn("Error announcing to tracker: %s (status=%d)", error_desc, ctx.tracker_status);
        }
        else
        {
            io::eprintfn("Error announcing to tracker: Unknown error");
        }

        io::eprintfn("");
        io::eprintfn("Note: Some trackers may reject announces if you're not");
        io::eprintfn("actually downloading/seeding the torrent.");
        return 1;
    }

    // Display response
    display_tracker_response(ctx.response);

    // Free allocated strings in response
    if (ctx.response.failure_reason.len > 0)
    {
        free(ctx.response.failure_reason);
    }
    if (ctx.response.warning_message.len > 0)
    {
        free(ctx.response.warning_message);
    }
    if (ctx.response.peers.len > 0)
    {
        free(ctx.response.peers);
    }

    return 0;
}

// ============================================================================
// Connect Command - Announce and connect to peers with handshake
// ============================================================================

<*
 Peer connection tracking for connect command.
*>
struct PeerConnectionInfo
{
    String ip_str;           // IP address string
    ushort port;             // Port number
    peer_connection::PeerConnection* conn;  // Connection handle
    peer_connection::PeerState state;       // Current state
    char[20] remote_peer_id; // Peer ID from handshake
    bool handshake_ok;       // Handshake completed successfully
}

<*
 Context for connect command.
*>
struct ConnectContext
{
    event_loop::EventLoop* loop;
    libtorrent::metainfo::TorrentFile* torrent;
    tracker::TrackerResponse* tracker_response;

    // Connection tracking
    int total_peers;
    int connections_attempted;
    int connections_succeeded;
    int connections_failed;
    bool tracker_completed;
    bool all_completed;

    // Peer connections
    PeerConnectionInfo[] peer_infos;

    // Peer pool (Phase 1 - storage only)
    peer_pool::PeerPool* peer_pool;

    int exit_code;
}

fn void on_connect_peer_state(peer_connection::PeerConnection* peer,
                               peer_connection::PeerState state,
                               void* user_data)
{
    ConnectContext* ctx = (ConnectContext*)user_data;

    // Find which peer this is
    for (usz i = 0; i < ctx.peer_infos.len; i++)
    {
        if (ctx.peer_infos[i].conn == peer)
        {
            ctx.peer_infos[i].state = state;

            if (state == peer_connection::PeerState.READY)
            {
                // Handshake succeeded
                ctx.peer_infos[i].handshake_ok = true;
                ctx.peer_infos[i].remote_peer_id = peer.remote_peer_id;
                ctx.connections_succeeded++;
            }
            else if (state == peer_connection::PeerState.CLOSED)
            {
                // Connection failed or closed
                if (!ctx.peer_infos[i].handshake_ok)
                {
                    ctx.connections_failed++;
                }
            }

            // Check if all connections done
            if (ctx.connections_succeeded + ctx.connections_failed >= ctx.connections_attempted)
            {
                ctx.all_completed = true;
            }

            return;
        }
    }
}

fn void on_connect_peer_message(peer_connection::PeerConnection* peer,
                                 peer_wire::Message* msg,
                                 void* user_data)
{
    // For now, we just establish connection and handshake
    // Don't need to handle messages yet
}

fn void on_connect_tracker_complete(tracker::TrackerResponse* response, int status, void* user_data)
{
    ConnectContext* ctx = (ConnectContext*)user_data;
    ctx.tracker_completed = true;
    ctx.tracker_response = response;

    if (status != 0 || !response)
    {
        // Show descriptive error based on status code
        if (status != 0)
        {
            String error_desc = tracker_error_string(status);
            io::eprintfn("Error announcing to tracker: %s (status=%d)", error_desc, status);
        }
        else
        {
            io::eprintfn("Error announcing to tracker: No response received");
        }
        ctx.exit_code = 1;
        ctx.all_completed = true;
        return;
    }

    // Check for tracker failure
    if (response.failure_reason.len > 0)
    {
        io::eprintfn("Tracker failure: %s", response.failure_reason);
        ctx.exit_code = 1;
        ctx.all_completed = true;
        return;
    }

    // Get peer list
    ctx.total_peers = (int)response.peers.len;

    if (ctx.total_peers == 0)
    {
        io::printfn("No peers returned by tracker");
        ctx.exit_code = 0;
        ctx.all_completed = true;
        return;
    }

    io::printfn("Tracker returned %d peers", ctx.total_peers);

    // Add all peers to peer pool (Phase 1 integration)
    ctx.peer_pool.add_peers_from_tracker(response.peers);

    // Show peer pool stats
    usz total_peers, candidates, connecting, connected;
    ctx.peer_pool.get_stats(&total_peers, &candidates, &connecting, &connected);
    io::printfn("  Peer pool now has %d total peers", total_peers);

    io::printfn("Attempting to connect to first %d peers...", ctx.total_peers < 5 ? ctx.total_peers : 5);
    io::printfn("");

    // Connect to first N peers (max 5)
    int max_connections = ctx.total_peers < 5 ? ctx.total_peers : 5;
    ctx.connections_attempted = max_connections;
    ctx.peer_infos = mem::new_array(PeerConnectionInfo, max_connections);

    // Generate our peer ID
    char[20] our_peer_id = tracker::generate_peer_id();

    for (int i = 0; i < max_connections; i++)
    {
        tracker::Peer peer = response.peers[i];

        // Format IP address
        DString ip_buf;
        ip_buf.appendf("%d.%d.%d.%d",
                       (int)peer.ip[0] & 0xFF,
                       (int)peer.ip[1] & 0xFF,
                       (int)peer.ip[2] & 0xFF,
                       (int)peer.ip[3] & 0xFF);
        ctx.peer_infos[i].ip_str = ip_buf.copy_str(mem);
        ctx.peer_infos[i].port = peer.port;
        ctx.peer_infos[i].state = peer_connection::PeerState.CONNECTING;
        ctx.peer_infos[i].handshake_ok = false;

        // Initiate connection
        peer_connection::PeerConnection*? conn = peer_connection::connect(
            ctx.loop,
            ctx.peer_infos[i].ip_str,
            peer.port,
            ctx.torrent.info_hash,
            our_peer_id,
            &on_connect_peer_message,
            &on_connect_peer_state,
            null,  // No PEX callback for simple client
            ctx
        );

        if (catch err = conn)
        {
            io::printfn("[%d] %s:%d - Connection failed immediately",
                        i + 1, ctx.peer_infos[i].ip_str, peer.port);
            ctx.connections_failed++;
            ctx.peer_infos[i].conn = null;
            ctx.peer_infos[i].state = peer_connection::PeerState.CLOSED;
        }
        else
        {
            ctx.peer_infos[i].conn = conn;
        }
    }

    // Check if all failed immediately
    if (ctx.connections_failed >= ctx.connections_attempted)
    {
        ctx.all_completed = true;
    }
}

fn void on_connect_load_complete(String data, int status, void* user_data)
{
    ConnectContext* ctx = (ConnectContext*)user_data;

    if (status != 0)
    {
        ZString error_str = (ZString)uv::strerror(status);
        io::eprintfn("Error loading file: %s (status=%d)", error_str, status);
        ctx.exit_code = 1;
        ctx.all_completed = true;
        return;
    }
    defer free(data);

    // Parse torrent
    libtorrent::metainfo::TorrentFile*? torrent = libtorrent::metainfo::parse(data);
    if (catch err = torrent)
    {
        io::eprintfn("Error parsing torrent: %s", err);
        ctx.exit_code = 1;
        ctx.all_completed = true;
        return;
    }

    ctx.torrent = torrent;

    // Create peer pool (Phase 1 - storage only)
    char[20] our_peer_id = tracker::generate_peer_id();
    peer_pool::PeerPoolConfig pool_config = {
        .max_peerlist_size = 1000,
        .max_active_connections = 25,
        .max_failcount = 3,
        .min_reconnect_time = 60
    };
    ctx.peer_pool = peer_pool::create(ctx.loop, pool_config, &torrent.info_hash, &our_peer_id);

    // Get tracker URL
    String tracker_url = torrent.announce;
    if (tracker_url.len == 0)
    {
        if (torrent.announce_list.len > 0 && torrent.announce_list[0].len > 0)
        {
            tracker_url = torrent.announce_list[0][0];
        }
        else
        {
            io::eprintfn("Error: Torrent has no tracker URL");
            ctx.exit_code = 1;
            ctx.all_completed = true;
            return;
        }
    }

    io::printfn("Announcing to tracker: %s", tracker_url);

    // Announce to tracker
    ushort our_port = 6881;
    ctx.tracker_completed = false;
    tracker::announce(ctx.loop, torrent, our_port, "started",
                      &on_connect_tracker_complete, ctx);
}

fn void display_connection_results(ConnectContext* ctx)
{
    io::printfn("");
    io::printfn("=== Peer Connection Results ===");
    io::printfn("");
    io::printfn("Connected to %d/%d peers:", ctx.connections_succeeded, ctx.connections_attempted);
    io::printfn("");

    for (usz i = 0; i < ctx.peer_infos.len; i++)
    {
        PeerConnectionInfo* info = &ctx.peer_infos[i];

        if (info.handshake_ok)
        {
            // Convert peer ID to hex for display
            String peer_id_hex = hex::encode(mem, &info.remote_peer_id);
            defer free(peer_id_hex);

            io::printfn("  [%d] %s:%d - SUCCESS (peer_id: %s...)",
                        i + 1, info.ip_str, info.port, peer_id_hex[:20]);
        }
        else
        {
            String status_str;
            if (info.state == peer_connection::PeerState.CLOSED)
            {
                status_str = "FAILED (connection refused or timeout)";
            }
            else if (info.state == peer_connection::PeerState.HANDSHAKING)
            {
                status_str = "FAILED (handshake timeout)";
            }
            else
            {
                status_str = "FAILED (unknown error)";
            }

            io::printfn("  [%d] %s:%d - %s", i + 1, info.ip_str, info.port, status_str);
        }
    }
}

<*
 Connect command: announce to tracker, connect to peers, perform handshake.

 @param loop : "Event loop"
 @param torrent_path : "Path to torrent file"
 @return "Exit code (0 = success, 1 = error)"
*>
fn int cmd_connect(event_loop::EventLoop* loop, String torrent_path)
{
    ConnectContext ctx;
    ctx.loop = loop;
    ctx.torrent = null;
    ctx.tracker_response = null;
    ctx.peer_pool = null;
    ctx.total_peers = 0;
    ctx.connections_attempted = 0;
    ctx.connections_succeeded = 0;
    ctx.connections_failed = 0;
    ctx.tracker_completed = false;
    ctx.all_completed = false;
    ctx.exit_code = 0;

    // Start async load
    torrent_loader::load_file_async(loop, torrent_path,
                                     &on_connect_load_complete, &ctx);

    // Run event loop until complete
    int timeout_iterations = 0;
    const int MAX_ITERATIONS = 1000;  // ~10 seconds at ~10ms per iteration

    while (!ctx.all_completed && loop.is_alive() && timeout_iterations < MAX_ITERATIONS)
    {
        loop.run_once();
        timeout_iterations++;
    }

    // Check for timeout
    if (timeout_iterations >= MAX_ITERATIONS && !ctx.all_completed)
    {
        io::eprintfn("Operation timed out");
        ctx.exit_code = 1;
    }

    // Display results if we got to peer connections
    if (ctx.connections_attempted > 0)
    {
        display_connection_results(&ctx);
    }

    // Cleanup
    if (ctx.torrent)
    {
        libtorrent::metainfo::free_torrent_file(ctx.torrent);
    }

    if (ctx.tracker_response)
    {
        if (ctx.tracker_response.failure_reason.len > 0)
        {
            free(ctx.tracker_response.failure_reason);
        }
        if (ctx.tracker_response.warning_message.len > 0)
        {
            free(ctx.tracker_response.warning_message);
        }
        if (ctx.tracker_response.peers.len > 0)
        {
            free(ctx.tracker_response.peers);
        }
    }

    // Close peer connections
    if (ctx.peer_infos.len > 0)
    {
        for (usz i = 0; i < ctx.peer_infos.len; i++)
        {
            if (ctx.peer_infos[i].conn)
            {
                peer_connection::close(ctx.peer_infos[i].conn);
            }
        }

        // Give event loop time to finish closing connections
        // Run a few iterations to let async close operations complete
        for (int i = 0; i < 10 && loop.is_alive(); i++)
        {
            loop.run_once();
        }

        // Now free the peer info structures
        for (usz i = 0; i < ctx.peer_infos.len; i++)
        {
            if (ctx.peer_infos[i].ip_str.len > 0)
            {
                free(ctx.peer_infos[i].ip_str);
            }
        }
        free(ctx.peer_infos);
    }

    // Free peer pool
    if (ctx.peer_pool)
    {
        peer_pool::free(ctx.peer_pool);
    }

    return ctx.exit_code;
}

// ============================================================================
// Download Command - Full torrent download with piece management
// ============================================================================

<*
 Context for piece write operations (to manage piece_data lifecycle).
*>
struct PieceWriteContext
{
    DownloadContext* download_ctx;
    char[] piece_data;  // Must be freed after write completes
}

<*
 Download context for managing the download workflow.
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
    int announce_retry_count;               // For exponential backoff
    int announce_backoff_ms;                // Current backoff delay
    bool initial_announce_done;             // Has first announce succeeded?

    // Peer management (Phase 6 - using peer pool)
    peer_pool::PeerPool* peer_pool;

    // Download state
    bool download_complete;
    int exit_code;

    // Resume verification
    uint num_pieces;                        // Total number of pieces
    uint pieces_verified_count;             // Resume verification progress

    // Options
    int numwant;
    String save_path;

    // GUI integration (null in CLI mode)
    raylib_gui::UIState* gui_state;
}

<*
 Called when download is complete - closes all handles.
 Event loop will exit naturally once all handles are closed.
*>
fn void on_complete_download(DownloadContext* ctx)
{
    io::printfn("");
    io::printfn("=== Download Complete! ===");
    io::printfn("All %d pieces verified successfully", ctx.num_pieces);
    io::printfn("Cleaning up...");

    // Stop announce timers
    if (ctx.announce_timer)
    {
        async::timer::close(ctx.announce_timer);
        ctx.announce_timer = null;
    }
    if (ctx.retry_timer)
    {
        async::timer::close(ctx.retry_timer);
        ctx.retry_timer = null;
    }
    if (ctx.pex_timer)
    {
        async::timer::close(ctx.pex_timer);
        ctx.pex_timer = null;
    }
    if (ctx.keepalive_timer)
    {
        async::timer::close(ctx.keepalive_timer);
        ctx.keepalive_timer = null;
    }
    if (ctx.flush_timer)
    {
        async::timer::close(ctx.flush_timer);
        ctx.flush_timer = null;
    }

    // Close all peer connections (peer pool handles this)
    if (ctx.peer_pool)
    {
        ctx.peer_pool.disconnect_all();
    }

    // Event loop will exit naturally when all handles are closed
    ctx.download_complete = true;
    ctx.exit_code = 0;
}

<*
 Callback for piece completion - write to disk.
*>
fn void on_download_piece_complete(uint piece_index, char[] piece_data, bool success, void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;

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

    // Write piece to disk via storage_manager
    // Create context to manage piece_data lifecycle
    PieceWriteContext* write_ctx = mem::new(PieceWriteContext);
    write_ctx.download_ctx = ctx;
    write_ctx.piece_data = piece_data;
    ctx.sm.write_piece(piece_index, piece_data, &on_piece_written, write_ctx);

    // Check progress
    usz total, complete, downloading;
    ctx.dm.get_progress(&total, &complete, &downloading);

    // Update GUI if present
    if (ctx.gui_state)
    {
        usz connected_peers, total_peers, candidates, connecting;
        ctx.peer_pool.get_stats(&total_peers, &candidates, &connecting, &connected_peers);

        raylib_gui::update_progress(ctx.gui_state, (uint)complete, (uint)downloading,
                                    0, 0.0, 0.0);  // TODO: Calculate actual downloaded bytes and speeds
        raylib_gui::update_peers(ctx.gui_state, (int)connected_peers, (int)total_peers);
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
                                  char[4] ip, ushort port,
                                  void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;

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
            io::printfn("  [DEBUG] === BITFIELD HANDLER ENTERED ===");
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
                    bitfield::free(&peer_info.pieces);
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

                // Debug: Check download manager state
                usz total, complete, downloading;
                ctx.dm.get_progress(&total, &complete, &downloading);
                io::printfn("    [DEBUG] DM state: total=%d, complete=%d, downloading=%d",
                           total, complete, downloading);

                int pieces_started = 0;
                for (int i = 0; i < 5; i++)
                {
                    if (catch excuse = ctx.dm.start_piece_download(has_pieces))
                    {
                        // No more pieces to download or no slots available (both are fine)
                        if (i == 0 && pieces_started == 0)
                        {
                            io::printfn("    [DEBUG] Failed to start piece: %s", excuse);
                        }
                        break;
                    }
                    pieces_started++;
                }

                if (pieces_started > 0)
                {
                    io::printfn("    Started downloading %d piece%s",
                               pieces_started, pieces_started == 1 ? "" : "s");
                }
                else
                {
                    io::printfn("    [DEBUG] Could not start any new pieces (may be normal if slots full)");
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
            ctx.dm.receive_block(piece_msg.index, piece_msg.begin, piece_msg.block)!!;

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
                    bitfield::free(&peer_info.pieces);
                }
                peer_info.pieces = bitfield::create(num_pieces);
                peer_info.pieces.set_all();

                // Start piece downloads
                int pieces_started = 0;
                for (int i = 0; i < 5; i++)
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
            if (downloading < 5)  // We have free slots
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
                for (int i = 0; i < (5 - (int)downloading); i++)
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
                               downloading + pieces_started, 5);
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
fn void request_blocks_from_peers(DownloadContext* ctx)
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
            if (attempts == 0)
            {
                io::printfn("  [DEBUG] No blocks available from download manager");
            }
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
                if (requests_sent == 0)
                {
                    io::printfn("  [DEBUG] First request: piece=%d offset=%d length=%d",
                               req.piece_index, req.offset, req.length);
                }
                peer_info.connection.send_request(req.piece_index, req.offset, req.length)!!;
                ctx.dm.mark_block_requested(req.piece_index, req.offset)!!;
                requests_sent++;
                requested = true;
                break;
            }
        }

        if (!requested)
        {
            if (attempts == 0)
            {
                io::printfn("  [DEBUG] No valid peers: total=%d, has_conn=%d, connected=%d, handshake_ok=%d, valid=%d",
                           ctx.peer_pool.peers.len, has_connection_count, is_connected_count,
                           handshake_ok_count, valid_peer_count);
            }
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
                                    char[4] ip, ushort port,
                                    void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;

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
fn void on_download_peer_disconnected(char[4] ip, ushort port,
                                       bool was_error,
                                       void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;

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
fn void on_download_tracker_complete(tracker::TrackerResponse* response, int status, void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;
    ctx.tracker_completed = true;
    // Note: Don't save response pointer - it becomes invalid after this callback returns

    if (status != 0 || !response)
    {
        String error_desc = tracker_error_string(status);
        io::eprintfn("Error announcing to tracker: %s (status=%d)", error_desc, status);

        // Update GUI if present
        if (ctx.gui_state)
        {
            DString status_msg;
            status_msg.appendf("Error: %s", error_desc);
            raylib_gui::update_tracker_status(ctx.gui_state, status_msg.str_view());
        }

        ctx.exit_code = 1;
        ctx.download_complete = true;
        return;
    }

    if (response.failure_reason.len > 0)
    {
        io::eprintfn("Tracker error: %s", response.failure_reason);

        // Update GUI if present
        if (ctx.gui_state)
        {
            DString status_msg;
            status_msg.appendf("Error: %s", response.failure_reason);
            raylib_gui::update_tracker_status(ctx.gui_state, status_msg.str_view());
        }

        ctx.exit_code = 1;
        ctx.download_complete = true;
        return;
    }

    int num_peers = (int)response.peers.len;
    if (num_peers == 0)
    {
        io::printfn("No peers returned by tracker - will retry later");

        // Update GUI if present
        if (ctx.gui_state)
        {
            raylib_gui::update_tracker_status(ctx.gui_state, "No peers available");
        }

        // Don't stop download, just wait for next re-announce
        return;
    }

    io::printfn("Tracker returned %d peers", num_peers);

    // Update GUI if present
    if (ctx.gui_state)
    {
        DString status_msg;
        status_msg.appendf("Announce OK (%d peers)", num_peers);
        raylib_gui::update_tracker_status(ctx.gui_state, status_msg.str_view());
    }

    // Add all peers to peer pool (Phase 1 integration)
    ctx.peer_pool.add_peers_from_tracker(response.peers);

    // Show peer pool stats
    usz total_peers, candidates, connecting, connected;
    ctx.peer_pool.get_stats(&total_peers, &candidates, &connecting, &connected);

    // Update GUI if present
    if (ctx.gui_state)
    {
        raylib_gui::update_peers(ctx.gui_state, (int)connected, (int)total_peers);
    }

    io::printfn("  Peer pool now has %d total peers (%d candidates, %d connecting, %d connected)",
                total_peers, candidates, connecting, connected);

    // Automatically connect to best peers (Phase 6 - peer pool manages connections)
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
fn void on_storage_initialized(int status, void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;

    if (status < 0)
    {
        io::eprintfn("Error: Failed to initialize storage manager (error %d)", status);
        ctx.exit_code = 1;
        ctx.download_complete = true;
        return;
    }

    io::printfn("Storage initialized successfully");
    io::printfn("");

    // Now we can safely verify existing pieces (resume support)
    io::printfn("Checking for existing pieces...");
    verify_all_existing_pieces_async(ctx);
}

<*
 Callback when a piece has been written to disk.
*>
fn void on_piece_written(uint piece_index, int status, void* user_data)
{
    PieceWriteContext* write_ctx = (PieceWriteContext*)user_data;
    DownloadContext* ctx = write_ctx.download_ctx;

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
fn void on_verify_existing_piece(uint piece_index, bool verified, int status, void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;
    ctx.pieces_verified_count++;

    if (status == 0 && verified)
    {
        // Piece exists and is valid - mark as complete
        ctx.dm.picker.mark_complete(piece_index)!!;
        if (ctx.pieces_verified_count <= 5)
        {
            io::printfn("  [DEBUG] Piece %d verified and marked complete", piece_index);
        }
    }
    else
    {
        if (ctx.pieces_verified_count <= 5)
        {
            io::printfn("  [DEBUG] Piece %d NOT verified (status=%d, verified=%s)",
                       piece_index, status, verified ? "true" : "false");
        }
    }

    // Show progress every 1000 pieces
    if (ctx.pieces_verified_count % 1000 == 0)
    {
        io::printfn("  Verified %d/%d pieces...", ctx.pieces_verified_count, ctx.num_pieces);
    }

    // All pieces verified?
    if (ctx.pieces_verified_count == ctx.num_pieces)
    {
        on_all_pieces_verified(ctx);
    }
}

<*
 Verify all existing pieces on disk (resume support).
 Calls verify_piece() for each piece asynchronously.
*>
fn void verify_all_existing_pieces_async(DownloadContext* ctx)
{
    if (ctx.num_pieces == 0)
    {
        // No pieces to verify, start announce immediately
        on_all_pieces_verified(ctx);
        return;
    }

    // Verify each piece
    for (uint i = 0; i < ctx.num_pieces; i++)
    {
        // Get expected hash for this piece
        char[20] expected_hash;
        usz hash_offset = (usz)i * 20;
        for (usz j = 0; j < 20; j++)
        {
            expected_hash[j] = ctx.torrent.info.pieces[hash_offset + j];
        }

        // Verify piece asynchronously
        ctx.sm.verify_piece(i, expected_hash, &on_verify_existing_piece, ctx);
    }
}

<*
 Retry timer callback - retries tracker announce after backoff delay.
*>
fn void on_announce_retry_timer(async::timer::Timer* timer, void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;

    io::printfn("  Retrying tracker announce (attempt %d)...", ctx.announce_retry_count + 1);

    // Close retry timer
    async::timer::close(timer);
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
fn void on_announce_complete_with_retry(tracker::TrackerResponse* response, int status, void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;

    if (status != 0 || !response || response.failure_reason.len > 0)
    {
        // Failed - schedule retry with exponential backoff
        ctx.announce_retry_count++;

        // Calculate backoff: 1s, 2s, 4s, 8s, 16s, 30s (cap at 30s)
        int backoff_ms = 1000 * (1 << (ctx.announce_retry_count - 1));
        if (backoff_ms > 30000) backoff_ms = 30000;
        ctx.announce_backoff_ms = backoff_ms;

        if (status != 0)
        {
            String error_desc = tracker_error_string(status);
            io::eprintfn("  Tracker announce failed: %s (status=%d)", error_desc, status);
        }
        else if (response && response.failure_reason.len > 0)
        {
            io::eprintfn("  Tracker error: %s", response.failure_reason);
        }

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
        async::timer::start(ctx.retry_timer, (ulong)backoff_ms, 0,
                          &on_announce_retry_timer, ctx);
        return;
    }

    // Success - reset retry counter
    ctx.announce_retry_count = 0;
    ctx.initial_announce_done = true;

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
            async::timer::start(ctx.announce_timer, interval_ms, interval_ms,
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
            async::timer::start(ctx.pex_timer, 60000, 60000,
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
            async::timer::start(ctx.keepalive_timer, 120000, 120000,
                              &on_keepalive_timer_tick, ctx);
        }
    }

    // Start file flush timer if not already running and interval is configured
    if (!ctx.flush_timer && FILE_FLUSH_INTERVAL_MS > 0)
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
            async::timer::start(ctx.flush_timer, FILE_FLUSH_INTERVAL_MS, FILE_FLUSH_INTERVAL_MS,
                              &on_flush_timer_tick, ctx);
        }
    }

    // Call existing tracker completion handler
    on_download_tracker_complete(response, status, ctx);
}

<*
 Periodic announce timer callback - fires every interval seconds.
*>
fn void on_announce_timer_tick(async::timer::Timer* timer, void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;

    if (ctx.dm.is_complete())
    {
        // Download complete - stop timer
        async::timer::stop(timer);
        return;
    }

    io::printfn("Periodic tracker re-announce...");

    // Don't use retry logic for periodic announces - just try once
    tracker::announce(ctx.loop, ctx.torrent, 6881, "",
                      &on_download_tracker_complete, ctx);
}

<*
 PEX timer callback - sends queued PEX updates to all connected peers.
 Runs every 60 seconds per BEP 11 rate limiting.
*>
fn void on_pex_timer_tick(async::timer::Timer* timer, void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;

    if (ctx.dm.is_complete())
    {
        // Download complete - stop timer
        async::timer::stop(timer);
        return;
    }

    // Send queued PEX updates to all connected peers
    ctx.peer_pool.send_pex_updates();
}

<*
 Keepalive timer callback - sends keepalive messages to all connected peers.
 Runs every 120 seconds per BEP 3 specification to prevent timeout disconnections.
*>
fn void on_keepalive_timer_tick(async::timer::Timer* timer, void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;

    if (ctx.dm.is_complete())
    {
        // Download complete - stop timer
        async::timer::stop(timer);
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
fn void on_flush_timer_tick(async::timer::Timer* timer, void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;

    if (ctx.dm.is_complete())
    {
        // Download complete - stop timer
        async::timer::stop(timer);
        return;
    }

    // Flush all downloaded data to disk
    if (ctx.sm)
    {
        ctx.sm.sync_all_files();
    }
}

<*
 Start tracker announce with retry support.
*>
fn void announce_with_retry(DownloadContext* ctx)
{
    ctx.announce_retry_count = 0;
    ctx.announce_backoff_ms = 0;

    tracker::announce(ctx.loop, ctx.torrent, 6881,
                      ctx.initial_announce_done ? "" : "started",
                      &on_announce_complete_with_retry, ctx);
}

<*
 Called when all existing pieces have been verified.
 Starts the tracker announce process.
*>
fn void on_all_pieces_verified(DownloadContext* ctx)
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

    // Now start tracker announce
    io::printfn("Announcing to tracker: %s", ctx.torrent.announce);
    announce_with_retry(ctx);
}

<*
 Callback for torrent file load completion.
*>
fn void on_download_load_complete(String data, int status, void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;

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
    io::printfn("Size: %s", format_size(torrent.info.length));
    io::printfn("Pieces: %d x %s", num_pieces, format_size(torrent.info.piece_length));
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
        5,  // Max 5 concurrent pieces
        16384  // 16KB blocks
    );

    // Store num_pieces for resume verification
    ctx.num_pieces = num_pieces;
    ctx.pieces_verified_count = 0;

    // Create peer pool (Phase 1 - storage only, Phase 3 will add connection management)
    char[20] our_peer_id = tracker::generate_peer_id();
    peer_pool::PeerPoolConfig pool_config = {
        .max_peerlist_size = 1000,     // Track up to 1000 peers (vs old limit of 10)
        .max_active_connections = 25,   // Future: Phase 3 will manage connections
        .max_failcount = 3,             // Future: Phase 3 will track failures
        .min_reconnect_time = 60        // Future: Phase 3 will handle retries
    };
    ctx.peer_pool = peer_pool::create(ctx.loop, pool_config, &torrent.info_hash, &our_peer_id);
    io::printfn("Created peer pool (capacity: %d peers)", pool_config.max_peerlist_size);

    // Set peer pool callbacks (Phase 6 integration)
    ctx.peer_pool.set_callbacks(
        &on_download_peer_connected,
        &on_download_peer_message,
        &on_download_peer_disconnected,
        ctx
    );
    io::printfn("");

    // Initialize storage manager (create directories, open files)
    io::printfn("Initializing storage...");
    ctx.sm.initialize(&on_storage_initialized, ctx);
}

// ============================================================================
// Download Command (GUI Mode) - Graphical interface with raylib
// ============================================================================

<*
 Download command with GUI.

 @param loop : "Event loop"
 @param torrent_path : "Path to torrent file"
 @param save_path : "Directory to save downloaded files"
 @param numwant : "Number of peers to request from tracker"
 @return "Exit code (0 = success, 1 = error)"
*>
fn int cmd_download_gui(event_loop::EventLoop* loop, String torrent_path,
                        String save_path, int numwant)
{
    // Load torrent file synchronously
    File file = file::open(torrent_path, "rb")!!;
    defer (void)file.close();

    usz file_size = (usz)file.seek(0, io::Seek.END)!!;
    file.seek(0, io::Seek.SET)!!;

    char[] data = mem::new_array(char, file_size);
    defer free(data);

    usz bytes_read = (usz)file.read(data)!!;
    if (bytes_read != file_size)
    {
        io::eprintfn("Error: Read %d bytes but expected %d", bytes_read, file_size);
        return 1;
    }

    // Parse torrent
    libtorrent::metainfo::TorrentFile*? torrent = libtorrent::metainfo::parse((String)data);
    if (catch err = torrent)
    {
        io::eprintfn("Error parsing torrent: %s", err);
        return 1;
    }

    // Calculate pieces
    uint num_pieces = (uint)((torrent.info.length + torrent.info.piece_length - 1) / torrent.info.piece_length);
    uint last_piece_length = (uint)(torrent.info.length % torrent.info.piece_length);
    if (last_piece_length == 0) last_piece_length = (uint)torrent.info.piece_length;

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
        libtorrent::metainfo::free_torrent_file(torrent);
        return 1;
    }

    // Set up GUI logging
    log_outputs::LogSink log_sink;
    log_outputs::GuiLogOutput* gui_out = mem::new(log_outputs::GuiLogOutput);
    gui_out.ui = ui;
    log_sink.outputs = mem::new_array(logger::LogOutput, 1);
    log_sink.outputs[0] = gui_out;
    logger::set_log_callback(&log_outputs::on_log_message, &log_sink);

    // Create download context
    DownloadContext ctx;
    ctx.loop = loop;
    ctx.torrent = torrent;
    ctx.dm = null;
    ctx.sm = null;
    ctx.tracker_completed = false;
    ctx.announce_timer = null;
    ctx.retry_timer = null;
    ctx.pex_timer = null;
    ctx.keepalive_timer = null;
    ctx.flush_timer = null;
    ctx.announce_retry_count = 0;
    ctx.announce_backoff_ms = 0;
    ctx.initial_announce_done = false;
    ctx.peer_pool = null;
    ctx.download_complete = false;
    ctx.exit_code = 0;
    ctx.num_pieces = num_pieces;
    ctx.pieces_verified_count = 0;
    ctx.numwant = numwant;
    ctx.save_path = save_path;
    ctx.gui_state = ui;

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
        libtorrent::metainfo::free_torrent_file(torrent);
        free(log_sink.outputs);
        free(gui_out);
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
        5,  // Max 5 concurrent pieces
        16384  // 16KB blocks
    );

    // Create peer pool
    char[20] our_peer_id = tracker::generate_peer_id();
    peer_pool::PeerPoolConfig pool_config = {
        .max_peerlist_size = 1000,
        .max_active_connections = 25,
        .max_failcount = 3,
        .min_reconnect_time = 60
    };
    ctx.peer_pool = peer_pool::create(loop, pool_config, &torrent.info_hash, &our_peer_id);

    // Set peer pool callbacks
    ctx.peer_pool.set_callbacks(
        &on_download_peer_connected,
        &on_download_peer_message,
        &on_download_peer_disconnected,
        &ctx
    );

    // Initialize storage manager (create directories, open files)
    raylib_gui::add_log(ui, "Initializing storage...");
    ctx.sm.initialize(&on_storage_initialized, &ctx);

    // Main GUI loop - run until window closes or download completes
    int frame_count = 0;
    while (!ctx.download_complete && raylib_gui::run_frame(ui, loop))
    {
        // Event loop and rendering handled in run_frame()

        // Update peer list periodically (every 60 frames = ~1 second)
        frame_count++;
        if (frame_count % 60 == 0 && ctx.peer_pool)
        {
            peer_pool::PeerDisplayInfo[] peer_info = ctx.peer_pool.get_peer_display_info();
            raylib_gui::update_peer_list(ui, peer_info);
        }
    }

    // Cleanup - stop all async operations first
    io::printfn("Cleaning up...");

    // Stop and close timers (prevents callbacks from firing during cleanup)
    io::printfn("Stopping timers...");
    if (ctx.announce_timer)
    {
        async::timer::stop(ctx.announce_timer);
        async::timer::close(ctx.announce_timer);
    }
    if (ctx.retry_timer)
    {
        async::timer::stop(ctx.retry_timer);
        async::timer::close(ctx.retry_timer);
    }
    if (ctx.pex_timer)
    {
        async::timer::stop(ctx.pex_timer);
        async::timer::close(ctx.pex_timer);
    }
    if (ctx.keepalive_timer)
    {
        async::timer::stop(ctx.keepalive_timer);
        async::timer::close(ctx.keepalive_timer);
    }
    if (ctx.flush_timer)
    {
        async::timer::stop(ctx.flush_timer);
        async::timer::close(ctx.flush_timer);
    }

    // Disconnect all peers before freeing peer pool
    io::printfn("Disconnecting peers...");
    if (ctx.peer_pool)
    {
        ctx.peer_pool.disconnect_all();
    }

    // Process any remaining async cleanup callbacks
    // Keep running until all handles are closed (with limit to prevent infinite loop)
    io::printfn("Processing pending events...");
    int cleanup_iterations = 0;
    while (loop.is_alive() && cleanup_iterations < 200)
    {
        loop.run_nowait();
        cleanup_iterations++;
    }
    io::printfn("Processed %d cleanup iterations", cleanup_iterations);

    // Now safe to free resources
    io::printfn("Freeing peer pool...");
    if (ctx.peer_pool)
    {
        peer_pool::free(ctx.peer_pool);
    }

    io::printfn("Freeing download manager...");
    if (ctx.dm)
    {
        download_manager::free(ctx.dm);
        free(ctx.dm);
    }

    io::printfn("Freeing storage manager...");
    if (ctx.sm)
    {
        storage_manager::free(ctx.sm);
        free(ctx.sm);
    }

    io::printfn("Freeing torrent...");
    if (ctx.torrent)
    {
        libtorrent::metainfo::free_torrent_file(ctx.torrent);
    }

    // Note: tracker_response is managed by the tracker module and already freed
    // Don't try to free it here

    // Cleanup logging
    io::printfn("Cleaning up logging...");
    logger::flush_logs();
    if (log_sink.outputs.len > 0)
    {
        free(log_sink.outputs);
    }
    free(gui_out);

    // Free GUI (this also closes the window)
    io::printfn("Freeing GUI...");
    raylib_gui::free(ui);

    io::printfn("Cleanup complete");
    return ctx.exit_code;
}

// ============================================================================
// Download Command - Full torrent download with piece management
// ============================================================================

<*
 Download command: Download a complete torrent to disk.

 @param loop : "Event loop"
 @param torrent_path : "Path to torrent file"
 @param save_path : "Directory to save downloaded files"
 @param numwant : "Number of peers to request from tracker"
 @param log_file_path : "Path to log file (empty string = no file logging)"
 @param debug_mode : "Enable debug output to stderr"
 @param gui_mode : "Launch graphical user interface"
 @return "Exit code (0 = success, 1 = error)"
*>
fn int cmd_download(event_loop::EventLoop* loop, String torrent_path,
                    String save_path, int numwant, String log_file_path, bool debug_mode, bool gui_mode)
{
    // GUI mode - launch graphical interface
    if (gui_mode)
    {
        return cmd_download_gui(loop, torrent_path, save_path, numwant);
    }

    // Console mode
    io::printfn("=== BitTorrent Download ===");
    io::printfn("");

    // Set up multi-output logging system
    log_outputs::LogSink log_sink;
    log_outputs::FileLogOutput* file_out = null;
    log_outputs::StderrLogOutput* stderr_out = null;

    // Count outputs
    usz num_outputs = 0;
    if (log_file_path.len > 0) num_outputs++;
    if (debug_mode) num_outputs++;

    // Build outputs array
    if (num_outputs > 0)
    {
        log_sink.outputs = mem::new_array(logger::LogOutput, num_outputs);
        usz output_idx = 0;

        // Add file output if requested
        if (log_file_path.len > 0)
        {
            file_out = mem::new(log_outputs::FileLogOutput);
            file_out.file = file::open(log_file_path, "w")!!;
            file_out.is_open = true;
            log_sink.outputs[output_idx] = file_out;
            output_idx++;
            io::printfn("Logging to file: %s", log_file_path);
        }

        // Add stderr output if requested
        if (debug_mode)
        {
            stderr_out = mem::new(log_outputs::StderrLogOutput);
            log_sink.outputs[output_idx] = stderr_out;
            output_idx++;
            io::printfn("Debug logging to stderr enabled");
        }

        // Set callback
        logger::set_log_callback(&log_outputs::on_log_message, &log_sink);
    }

    DownloadContext ctx;
    ctx.loop = loop;
    ctx.torrent = null;
    ctx.dm = null;
    ctx.sm = null;
    ctx.tracker_completed = false;
    ctx.tracker_response = null;
    ctx.announce_timer = null;
    ctx.retry_timer = null;
    ctx.pex_timer = null;
    ctx.keepalive_timer = null;
    ctx.flush_timer = null;
    ctx.announce_retry_count = 0;
    ctx.announce_backoff_ms = 0;
    ctx.initial_announce_done = false;
    ctx.peer_pool = null;
    ctx.download_complete = false;
    ctx.exit_code = 0;
    ctx.num_pieces = 0;
    ctx.pieces_verified_count = 0;
    ctx.numwant = numwant;
    ctx.save_path = save_path;

    // Start periodic log flush timer (every 2 seconds) if logging is enabled
    async::timer::Timer* flush_timer = null;
    if (num_outputs > 0)
    {
        async::timer::Timer*? flush_timer_opt = async::timer::create(loop);
        if (catch err = flush_timer_opt)
        {
            io::eprintfn("Warning: Failed to create log flush timer");
        }
        else
        {
            flush_timer = flush_timer_opt;
            // Start after 2 seconds, then repeat every 2 seconds
            async::timer::start(flush_timer, 2000, 2000,
                              fn void(async::timer::Timer* timer, void* user_data) {
                                  logger::flush_logs();
                              }, null);
        }
    }

    // Load torrent file async
    torrent_loader::load_file_async(loop, torrent_path,
                                     &on_download_load_complete, &ctx);

    // Run event loop - blocks until download completes or error
    // The loop exits naturally when all handles are closed
    loop.run()!!;

    // Cleanup - free allocated memory
    // (Handles are already closed by on_complete_download or error handlers)
    if (ctx.dm)
    {
        download_manager::free(ctx.dm);
        free(ctx.dm);
    }

    if (ctx.sm)
    {
        storage_manager::free(ctx.sm);
        free(ctx.sm);
    }

    if (ctx.torrent)
    {
        libtorrent::metainfo::free_torrent_file(ctx.torrent);
    }

    if (ctx.tracker_response)
    {
        if (ctx.tracker_response.peers.len > 0)
        {
            free(ctx.tracker_response.peers);
        }
    }

    // Free peer pool
    if (ctx.peer_pool)
    {
        peer_pool::free(ctx.peer_pool);
    }

    // Stop and close log flush timer
    if (flush_timer)
    {
        async::timer::close(flush_timer);
    }

    // Flush any remaining logs before cleanup
    logger::flush_logs();

    // Cleanup log outputs (close files, etc.)
    if (num_outputs > 0)
    {
        foreach (output : log_sink.outputs)
        {
            output.close();
        }
        if (file_out) free(file_out);
        if (stderr_out) free(stderr_out);
        if (log_sink.outputs.len > 0) free(log_sink.outputs);
    }

    // Free logger resources
    logger::free_logger();

    return ctx.exit_code;
}

