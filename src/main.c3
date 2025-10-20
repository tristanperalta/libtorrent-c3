module torrent_client;

import std::io;
import std::encoding::hex;
import libtorrent;
import libtorrent::tracker;
import libtorrent::event_loop;
import libtorrent::torrent_loader;
import libtorrent::peer_connection;
import libtorrent::peer_wire;

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
        io::eprintfn("Error loading file: status=%d", status);
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
    io::printfn("Usage: torrent-client [COMMAND] <torrent-file>");
    io::printfn("");
    io::printfn("Commands:");
    io::printfn("  info <file>       Display torrent metadata (default)");
    io::printfn("  announce <file>   Announce to tracker and show peer list");
    io::printfn("  connect <file>    Announce and connect to peers with handshake");
    io::printfn("");
    io::printfn("Examples:");
    io::printfn("  torrent-client info ubuntu.torrent");
    io::printfn("  torrent-client announce ubuntu.torrent");
    io::printfn("  torrent-client connect ubuntu.torrent");
    io::printfn("  torrent-client ubuntu.torrent          # Same as 'info'");
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
        io::eprintfn("Error loading file: status=%d", status);
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
        io::eprintfn("Error announcing to tracker");
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
        io::eprintfn("Error announcing to tracker");
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
        io::eprintfn("Error loading file: status=%d", status);
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
            if (ctx.peer_infos[i].ip_str.len > 0)
            {
                free(ctx.peer_infos[i].ip_str);
            }
            if (ctx.peer_infos[i].conn)
            {
                peer_connection::close(ctx.peer_infos[i].conn);
            }
        }
        free(ctx.peer_infos);
    }

    return ctx.exit_code;
}
