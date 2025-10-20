module torrent_client;

import std::io;
import std::encoding::hex;
import uv;
import libtorrent;
import libtorrent::tracker;
import libtorrent::event_loop;
import libtorrent::torrent_loader;
import libtorrent::peer_connection;
import libtorrent::peer_wire;
import libtorrent::download_manager;
import libtorrent::block_manager;
import libtorrent::storage_manager;
import libtorrent::bitfield;

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
        }

        return cmd_download(&loop, torrent_path, save_path, numwant);
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
    io::printfn("");
    io::printfn("Examples:");
    io::printfn("  torrent-client info ubuntu.torrent");
    io::printfn("  torrent-client announce ubuntu.torrent");
    io::printfn("  torrent-client connect ubuntu.torrent");
    io::printfn("  torrent-client download ubuntu.torrent");
    io::printfn("  torrent-client download ubuntu.torrent --save-path ~/Downloads --numwant 100");
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

    return ctx.exit_code;
}

// ============================================================================
// Download Command - Full torrent download with piece management
// ============================================================================

<*
 Peer state for download command.
*>
struct DownloadPeerInfo
{
    String ip_str;
    ushort port;
    peer_connection::PeerConnection* conn;
    peer_connection::PeerState state;
    bool handshake_ok;
    bool received_bitfield;  // Have we received BITFIELD from this peer?
    bitfield::Bitfield pieces;  // Which pieces this peer has
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

    // Peer management
    DownloadPeerInfo[] peers;
    int num_peers;
    int max_peers;

    // Download state
    bool download_complete;
    int exit_code;

    // Options
    int numwant;
    String save_path;
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
        // Mark piece as failed for retry
        ctx.dm.fail_piece(piece_index)!!;
        return;
    }

    io::printfn("✓ Piece %d verified (%d bytes)", piece_index, piece_data.len);

    // Write piece to disk via storage_manager
    // TODO: Implement actual storage write when storage_manager is ready
    // For now, just free the piece data
    free(piece_data);

    // Check progress
    usz total, complete, downloading;
    ctx.dm.get_progress(&total, &complete, &downloading);

    if (complete % 100 == 0 || complete == total)
    {
        double percent = (complete * 100.0) / total;
        io::printfn("Progress: %d/%d pieces (%.1f%%)", complete, total, percent);
    }

    // Check if download is complete
    if (ctx.dm.is_complete())
    {
        io::printfn("");
        io::printfn("=== Download Complete! ===");
        io::printfn("All %d pieces verified successfully", total);
        ctx.download_complete = true;
        ctx.exit_code = 0;
        return;
    }

    // Start downloading more pieces from available peers
    // Find peer bitfields and start new pieces
    for (usz i = 0; i < ctx.peers.len; i++)
    {
        if (ctx.peers[i].state == peer_connection::PeerState.READY)
        {
            // Try to start a new piece download
            // This is a simplified version - ideally we'd track which pieces each peer has
            bool[] peer_pieces = mem::new_array(bool, total);
            for (usz j = 0; j < total; j++)
            {
                peer_pieces[j] = true; // Assume peer has all pieces for now
            }

            if (catch excuse = ctx.dm.start_piece_download(peer_pieces))
            {
                // No more pieces available
            }
            else
            {
                // Successfully started a new piece
            }

            free(peer_pieces);
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
                                  void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;

    // Find peer in our list
    DownloadPeerInfo* peer_info = null;
    for (usz i = 0; i < ctx.peers.len; i++)
    {
        if (ctx.peers[i].conn == peer)
        {
            peer_info = &ctx.peers[i];
            break;
        }
    }

    if (!peer_info) return;

    // Debug: log received message type
    io::printfn("  [DEBUG] Received message type %d from peer", (int)msg.type);

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

                io::printfn("  Peer %s sent bitfield", peer_info.ip_str);

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
                for (int i = 0; i < 5; i++)
                {
                    if (catch excuse = ctx.dm.start_piece_download(has_pieces))
                    {
                        // No more pieces to download or no slots available
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
            }

        case peer_wire::MessageType.HAVE:
            // Peer has a new piece
            if (msg.payload.len >= 4)
            {
                uint piece_index = peer_wire::read_u32_be(msg.payload, 0);
                ctx.dm.peer_has_piece(piece_index)!!;
            }

        case peer_wire::MessageType.PIECE:
            // Received a piece block!
            peer_wire::PieceMsg? piece_msg = peer_wire::decode_piece(msg.payload);
            if (catch err = piece_msg) return;

            // Add block to download manager
            ctx.dm.receive_block(piece_msg.index, piece_msg.begin, piece_msg.block)!!;

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
            io::printfn("  Peer %s unchoked us", peer_info.ip_str);

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
            }

            // Now we can start requesting blocks!
            io::printfn("    Starting block requests...");
            request_blocks_from_peers(ctx);

        case peer_wire::MessageType.CHOKE:
            io::printfn("  Peer %s choked us", peer_info.ip_str);

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
            if (requests_sent == 0)
            {
                io::printfn("  [DEBUG] No blocks available to request");
            }
            break;
        }

        // Find a ready peer to request from
        bool requested = false;
        for (usz i = 0; i < ctx.peers.len; i++)
        {
            if (ctx.peers[i].state == peer_connection::PeerState.READY)
            {
                // Send REQUEST message
                if (requests_sent == 0)
                {
                    io::printfn("  [DEBUG] First request: piece=%d offset=%d length=%d",
                               req.piece_index, req.offset, req.length);
                }
                ctx.peers[i].conn.send_request(req.piece_index, req.offset, req.length)!!;
                ctx.dm.mark_block_requested(req.piece_index, req.offset)!!;
                requests_sent++;
                requested = true;
                break;
            }
        }

        if (!requested) break;
    }

    if (requests_sent > 0)
    {
        io::printfn("  Sent %d block requests", requests_sent);
    }
}

<*
 Callback for peer state changes.
*>
fn void on_download_peer_state(peer_connection::PeerConnection* peer,
                                peer_connection::PeerState state,
                                void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;

    // Find peer in our list
    DownloadPeerInfo* peer_info = null;
    for (usz i = 0; i < ctx.peers.len; i++)
    {
        if (ctx.peers[i].conn == peer)
        {
            peer_info = &ctx.peers[i];
            break;
        }
    }

    if (!peer_info) return;

    peer_info.state = state;

    switch (state)
    {
        case peer_connection::PeerState.HANDSHAKING:
            io::printfn("  Peer %s handshaking...", peer_info.ip_str);

        case peer_connection::PeerState.READY:
            peer_info.handshake_ok = true;
            io::printfn("  Peer %s ready for download", peer_info.ip_str);

            // Send INTERESTED message to the peer
            peer.send_interested()!!;
            io::printfn("  Sent INTERESTED to peer %s", peer_info.ip_str);
            io::printfn("  Waiting for peer to send BITFIELD...");

            // DON'T start piece downloads yet - wait for BITFIELD first
            // The BITFIELD message handler will start downloads

        case peer_connection::PeerState.CLOSED:
            io::printfn("  Peer %s closed - connection lost", peer_info.ip_str);

            // Check if all peers are closed
            bool all_closed = true;
            for (usz i = 0; i < ctx.peers.len; i++)
            {
                if (ctx.peers[i].state != peer_connection::PeerState.CLOSED)
                {
                    all_closed = false;
                    break;
                }
            }

            if (all_closed && !ctx.dm.is_complete())
            {
                io::printfn("");
                io::printfn("All peers disconnected - re-announcing to find more peers...");

                // Re-announce to tracker to get fresh peers
                tracker::announce(ctx.loop, ctx.torrent, 6881, "",
                                  &on_download_tracker_complete, ctx);
            }
            else if (all_closed && ctx.dm.is_complete())
            {
                io::printfn("");
                io::printfn("Download complete!");
                ctx.download_complete = true;
                ctx.exit_code = 0;
            }

        default:
    }
}

<*
 Callback for tracker announce completion.
*>
fn void on_download_tracker_complete(tracker::TrackerResponse* response, int status, void* user_data)
{
    DownloadContext* ctx = (DownloadContext*)user_data;
    ctx.tracker_completed = true;
    ctx.tracker_response = response;

    if (status != 0 || !response)
    {
        String error_desc = tracker_error_string(status);
        io::eprintfn("Error announcing to tracker: %s (status=%d)", error_desc, status);
        ctx.exit_code = 1;
        ctx.download_complete = true;
        return;
    }

    if (response.failure_reason.len > 0)
    {
        io::eprintfn("Tracker error: %s", response.failure_reason);
        ctx.exit_code = 1;
        ctx.download_complete = true;
        return;
    }

    int num_peers = (int)response.peers.len;
    if (num_peers == 0)
    {
        io::printfn("No peers returned by tracker - will retry later");
        // Don't stop download, just wait for next re-announce
        return;
    }

    io::printfn("Tracker returned %d peers", num_peers);

    // Check if this is first announce or re-announce
    bool is_first_announce = (ctx.num_peers == 0);

    if (is_first_announce)
    {
        io::printfn("Connecting to peers...");
        io::printfn("");

        // First announce - create peers array
        int peers_to_connect = num_peers < ctx.max_peers ? num_peers : ctx.max_peers;
        ctx.peers = mem::new_array(DownloadPeerInfo, peers_to_connect);
        ctx.num_peers = peers_to_connect;
    }
    else
    {
        // Re-announce - try to add new peers to closed slots
        io::printfn("Looking for new peers to replace closed connections...");
    }

    // Generate our peer ID
    char[20] our_peer_id = tracker::generate_peer_id();

    if (is_first_announce)
    {
        // Connect to all initial peers
        for (int i = 0; i < ctx.num_peers; i++)
        {
            tracker::Peer* peer = &response.peers[i];

            // Format IP address
            DString ip_builder;
            ip_builder.appendf("%d.%d.%d.%d",
                              (int)peer.ip[0] & 0xFF,
                              (int)peer.ip[1] & 0xFF,
                              (int)peer.ip[2] & 0xFF,
                              (int)peer.ip[3] & 0xFF);

            ctx.peers[i].ip_str = ip_builder.copy_str(mem);
            ctx.peers[i].port = peer.port;
            ctx.peers[i].handshake_ok = false;
            ctx.peers[i].received_bitfield = false;
            ctx.peers[i].state = peer_connection::PeerState.CONNECTING;

            io::printfn("Connecting to peer %d/%d: %s:%d",
                       i + 1, ctx.num_peers,
                       ctx.peers[i].ip_str, ctx.peers[i].port);

            // Connect to peer
            peer_connection::PeerConnection*? conn_opt = peer_connection::connect(
                ctx.loop,
                ctx.peers[i].ip_str,
                ctx.peers[i].port,
                ctx.torrent.info_hash,
                our_peer_id,
                &on_download_peer_message,
                &on_download_peer_state,
                ctx
            );

            if (catch err = conn_opt)
            {
                io::eprintfn("  Failed to initiate connection: %s", err);
                ctx.peers[i].conn = null;
            }
            else
            {
                ctx.peers[i].conn = conn_opt;
            }
        }
    }
    else
    {
        // Re-announce - connect new peers to closed slots
        int new_peer_index = 0;
        for (usz i = 0; i < ctx.peers.len && new_peer_index < num_peers; i++)
        {
            // Skip peers that are still connected
            if (ctx.peers[i].state != peer_connection::PeerState.CLOSED) continue;

            tracker::Peer* peer = &response.peers[new_peer_index];
            new_peer_index++;

            // Format IP address
            DString ip_builder;
            ip_builder.appendf("%d.%d.%d.%d",
                              (int)peer.ip[0] & 0xFF,
                              (int)peer.ip[1] & 0xFF,
                              (int)peer.ip[2] & 0xFF,
                              (int)peer.ip[3] & 0xFF);

            // Free old IP string
            if (ctx.peers[i].ip_str.len > 0) free(ctx.peers[i].ip_str);

            ctx.peers[i].ip_str = ip_builder.copy_str(mem);
            ctx.peers[i].port = peer.port;
            ctx.peers[i].handshake_ok = false;
            ctx.peers[i].received_bitfield = false;
            ctx.peers[i].state = peer_connection::PeerState.CONNECTING;

            io::printfn("  Connecting to new peer: %s:%d",
                       ctx.peers[i].ip_str, ctx.peers[i].port);

            // Connect to peer
            peer_connection::PeerConnection*? conn_opt = peer_connection::connect(
                ctx.loop,
                ctx.peers[i].ip_str,
                ctx.peers[i].port,
                ctx.torrent.info_hash,
                our_peer_id,
                &on_download_peer_message,
                &on_download_peer_state,
                ctx
            );

            if (catch err = conn_opt)
            {
                io::eprintfn("    Failed to initiate connection: %s", err);
                ctx.peers[i].conn = null;
            }
            else
            {
                ctx.peers[i].conn = conn_opt;
            }
        }
    }

    if (is_first_announce)
    {
        io::printfn("");
        io::printfn("Download in progress...");
        io::printfn("(Download will continue until complete or Ctrl+C)");
        io::printfn("");
    }

    // Don't set download_complete yet - let the download run
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

    // Create storage manager
    storage_manager::StorageManager? sm_opt = storage_manager::create(
        ctx.loop, &torrent.info, ctx.save_path);
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

    io::printfn("Announcing to tracker: %s", torrent.announce);

    // Announce to tracker
    tracker::announce(ctx.loop, torrent, 6881, "started",
                      &on_download_tracker_complete, ctx);
}

<*
 Download command: Download a complete torrent to disk.

 @param loop : "Event loop"
 @param torrent_path : "Path to torrent file"
 @param save_path : "Directory to save downloaded files"
 @param numwant : "Number of peers to request from tracker"
 @return "Exit code (0 = success, 1 = error)"
*>
fn int cmd_download(event_loop::EventLoop* loop, String torrent_path,
                    String save_path, int numwant)
{
    io::printfn("=== BitTorrent Download ===");
    io::printfn("");

    DownloadContext ctx;
    ctx.loop = loop;
    ctx.torrent = null;
    ctx.dm = null;
    ctx.sm = null;
    ctx.tracker_completed = false;
    ctx.tracker_response = null;
    ctx.peers = {};
    ctx.num_peers = 0;
    ctx.max_peers = 10;
    ctx.download_complete = false;
    ctx.exit_code = 0;
    ctx.numwant = numwant;
    ctx.save_path = save_path;

    // Load torrent file async
    torrent_loader::load_file_async(loop, torrent_path,
                                     &on_download_load_complete, &ctx);

    // Run event loop until download completes
    while (!ctx.download_complete && loop.is_alive())
    {
        loop.run_once();
    }

    // Cleanup
    // Close all peer connections
    if (ctx.peers.len > 0)
    {
        for (usz i = 0; i < ctx.peers.len; i++)
        {
            if (ctx.peers[i].conn)
            {
                peer_connection::close(ctx.peers[i].conn);
            }
        }

        // Give event loop time to finish closing connections
        for (int i = 0; i < 10 && loop.is_alive(); i++)
        {
            loop.run_once();
        }

        // Free peer info
        for (usz i = 0; i < ctx.peers.len; i++)
        {
            if (ctx.peers[i].ip_str.len > 0)
            {
                free(ctx.peers[i].ip_str);
            }
        }
        free(ctx.peers);
    }

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

    return ctx.exit_code;
}

