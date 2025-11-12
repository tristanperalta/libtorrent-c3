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
import libtorrent::logger;
import libtorrent::magnet_link;
import libtorrent::dht_client;
import libtorrent::dht_get_peers;
import libtorrent::event_bus;
import libtorrent::event_types;
import libtorrent::file_selection;
import torrent_client::log_outputs;
import torrent_client::session;
import torrent_client::magnet_download_session;
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
    else if (command == "magnet")
    {
        if (argc < 3)
        {
            io::eprintfn("Error: 'magnet' command requires a magnet URI");
            print_usage();
            return 1;
        }
        String magnet_uri = (String)argv[2].str_view();
        return cmd_magnet(magnet_uri);
    }
    else if (command == "download")
    {
        if (argc < 3)
        {
            io::eprintfn("Error: 'download' command requires a torrent file or magnet URI");
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
        String select_files_str = "";  // BEP 21: File selection for multi-file torrents

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
            else if (arg == "--select-files" && i + 1 < (usz)argc)
            {
                // BEP 21: Selective file download (e.g., "0,2,4")
                select_files_str = (String)argv[i + 1].str_view();
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

        return cmd_download(&loop, torrent_path, save_path, numwant, log_file_path, debug_mode, gui_mode, select_files_str);
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
    defer torrent.free();

    // Display metadata
    display_torrent_info(torrent);
    ctx.exit_code = 0;
}

<*
 Magnet command: parse and display magnet link (BEP 9).

 @param magnet_uri : "Magnet URI to parse"
 @return "Exit code (0 = success, 1 = error)"
*>
fn int cmd_magnet(String magnet_uri)
{
    io::printfn("Parsing magnet link...");
    io::printfn("");

    // Parse magnet URI
    magnet_link::MagnetLink*? magnet_opt = magnet_link::parse(magnet_uri);
    if (catch err = magnet_opt)
    {
        io::eprintfn("Error: Failed to parse magnet URI");
        io::eprintfn("  %s", err);
        return 1;
    }

    magnet_link::MagnetLink* magnet = magnet_opt;
    defer magnet.free();

    // Display info hash
    io::printfn("Info Hash (hex):");
    io::printf("  ");
    for (usz i = 0; i < 20; i++)
    {
        char byte = magnet.info_hash[i];
        io::printf("%02x", (uint)(byte & 0xFF));
    }
    io::printfn("");
    io::printfn("");

    // Display name if present
    if (magnet.name.len > 0)
    {
        io::printfn("Display Name:");
        io::printfn("  %s", magnet.name);
        io::printfn("");
    }

    // Display trackers
    if (magnet.trackers.len > 0)
    {
        io::printfn("Trackers (%d):", magnet.trackers.len);
        foreach (tracker : magnet.trackers)
        {
            io::printfn("  %s", tracker);
        }
        io::printfn("");
    }

    // Display peers
    if (magnet.peers.len > 0)
    {
        io::printfn("Peers (%d):", magnet.peers.len);
        foreach (peer : magnet.peers)
        {
            io::printfn("  %s", peer);
        }
        io::printfn("");
    }

    io::printfn("Note: To download from a magnet link, metadata must be fetched from peers.");
    io::printfn("      This requires connecting to trackers/DHT and downloading the .torrent metadata.");

    return 0;
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
    io::printfn("Usage: torrent-client [COMMAND] <torrent-file|magnet-link> [OPTIONS]");
    io::printfn("");
    io::printfn("Commands:");
    io::printfn("  info <file>          Display torrent metadata (default)");
    io::printfn("  announce <file>      Announce to tracker and show peer list");
    io::printfn("  connect <file>       Announce and connect to peers with handshake");
    io::printfn("  download <file>      Download torrent to disk");
    io::printfn("  magnet <uri>         Parse and display magnet link (BEP 9)");
    io::printfn("");
    io::printfn("Download Options:");
    io::printfn("  --save-path <path>       Directory to save files (default: current directory)");
    io::printfn("  --numwant <n>            Number of peers to request from tracker (default: 50)");
    io::printfn("  --select-files <indices> Download only selected files (e.g., '0,2,4') [BEP 21]");
    io::printfn("  --log-file <path>        Log to file");
    io::printfn("  --debug                  Enable debug output to stderr");
    io::printfn("  --gui                    Launch graphical user interface");
    io::printfn("");
    io::printfn("Examples:");
    io::printfn("  torrent-client info ubuntu.torrent");
    io::printfn("  torrent-client announce ubuntu.torrent");
    io::printfn("  torrent-client connect ubuntu.torrent");
    io::printfn("  torrent-client magnet 'magnet:?xt=urn:btih:...'");
    io::printfn("  torrent-client download ubuntu.torrent");
    io::printfn("  torrent-client download ubuntu.torrent --save-path ~/Downloads --numwant 100");
    io::printfn("  torrent-client download ubuntu.torrent --select-files 0,2,4");
    io::printfn("  torrent-client download ubuntu.torrent --log-file download.log --debug");
    io::printfn("  torrent-client download ubuntu.torrent --gui");
    io::printfn("  torrent-client ubuntu.torrent          # Same as 'info'");
}

fn void display_torrent_info(libtorrent::metainfo::TorrentFile* torrent)
{
    io::printfn("=== Torrent Information ===");
    io::printfn("");

    // Basic info
    io::printfn("Name: %s", torrent.info.name);

    String size_str = session::format_size(torrent.info.length);
    defer free(size_str);
    io::printfn("Size: %s (%d bytes)", size_str, torrent.info.length);

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
            String file_size_str = session::format_size(file.length);
            defer free(file_size_str);
            io::printfn("    [%d] %s (%s)", idx + 1, path.str_view(), file_size_str);
        }
    }
    else
    {
        io::printfn("  Single file torrent");
    }
    io::printfn("");

    // Piece info
    io::printfn("Piece Info:");
    String piece_length_str = session::format_size(torrent.info.piece_length);
    defer free(piece_length_str);
    io::printfn("  Piece length: %s", piece_length_str);
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

    // Collections (BEP 38)
    if (torrent.collections.len > 0)
    {
        io::printfn("Collections (BEP 38):");
        foreach (idx, collection : torrent.collections)
        {
            io::printfn("  [%d] %s", idx + 1, collection);
        }
        io::printfn("");
    }

    // Similar torrents (BEP 38)
    if (torrent.similar_count > 0)
    {
        io::printfn("Similar Torrents (BEP 38):");
        for (usz i = 0; i < torrent.similar_count; i++)
        {
            usz offset = i * 20;
            String similar_hash_hex = hex::encode(mem, torrent.similar[offset:20]);
            defer free(similar_hash_hex);
            io::printfn("  [%d] %s", i + 1, similar_hash_hex);
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

<*
 Format IP address from 4-byte array to string.

 @param ip : "4-byte IP address"
 @return "Formatted IP string (xxx.xxx.xxx.xxx)"
*>
fn String format_ip_address(common::Ipv4Addr ip)
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
            io::printfn("  [%d] %s", idx + 1, peer);
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
            ctx.torrent.free();
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
        ctx.torrent.free();
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
            String error_desc = session::tracker_error_string(ctx.tracker_status);
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
    common::PeerId remote_peer_id; // Peer ID from handshake
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
    List{PeerConnectionInfo} peer_infos;

    // Peer pool (Phase 1 - storage only)
    peer_pool::PeerPool* peer_pool;

    int exit_code;
}

fn void on_connect_peer_state(peer_connection::PeerConnection* peer,
                               peer_connection::PeerState state,
                               peer_connection::DisconnectReason reason,
                               void* user_data)
{
    ConnectContext* ctx = (ConnectContext*)user_data;

    // Find which peer this is
    for (usz i = 0; i < ctx.peer_infos.len(); i++)
    {
        PeerConnectionInfo* info = &ctx.peer_infos[i];
        if (info.conn == peer)
        {
            info.state = state;

            if (state == peer_connection::PeerState.READY)
            {
                // Handshake succeeded
                info.handshake_ok = true;
                info.remote_peer_id = peer.remote_peer_id;
                ctx.connections_succeeded++;
            }
            else if (state == peer_connection::PeerState.CLOSED)
            {
                // Connection failed or closed
                if (!info.handshake_ok)
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
            String error_desc = session::tracker_error_string(status);
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

    // Add all peers to peer pool (already SocketAddress[] from tracker)
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
    ctx.peer_infos.init(mem);

    // Generate our peer ID
    common::PeerId our_peer_id = tracker::generate_peer_id();

    for (int i = 0; i < max_connections; i++)
    {
        common::SocketAddress peer = response.peers[i];

        // Create PeerConnectionInfo
        PeerConnectionInfo info;

        // Format IP address (just the IP part, not including port)
        DString ip_buf;
        ip_buf.appendf("%s", peer.addr);  // InetAddress has built-in formatting
        info.ip_str = ip_buf.copy_str(mem);
        info.port = peer.port;
        info.state = peer_connection::PeerState.CONNECTING;
        info.handshake_ok = false;

        // Initiate connection
        peer_connection::PeerConnection*? conn = peer_connection::connect(
            ctx.loop,
            info.ip_str,
            peer.port,
            ctx.torrent.info_hash,
            our_peer_id,
            &on_connect_peer_message,
            &on_connect_peer_state,
            null,  // No PEX callback for simple client
            null,  // No metadata callback for simple client
            ctx,
            ctx.torrent.info.private  // BEP 27: Pass private flag
        );

        if (catch err = conn)
        {
            io::printfn("[%d] %s:%d - Connection failed immediately",
                        i + 1, info.ip_str, peer.port);
            ctx.connections_failed++;
            info.conn = null;
            info.state = peer_connection::PeerState.CLOSED;
        }
        else
        {
            info.conn = conn;
        }

        // Add to list
        ctx.peer_infos.push(info);
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
    common::PeerId our_peer_id = tracker::generate_peer_id();
    peer_pool::PeerPoolConfig pool_config = peer_pool::get_default_config();
    ctx.peer_pool = peer_pool::create(ctx.loop, pool_config, &torrent.info_hash, &our_peer_id, torrent.info.private);

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

    int index = 0;
    foreach (info : ctx.peer_infos.array_view())
    {
        index++;
        if (info.handshake_ok)
        {
            // Convert peer ID to hex for display
            String peer_id_hex = hex::encode(mem, &info.remote_peer_id);
            defer free(peer_id_hex);

            io::printfn("  [%d] %s:%d - SUCCESS (peer_id: %s...)",
                        index, info.ip_str, info.port, peer_id_hex[:20]);
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

            io::printfn("  [%d] %s:%d - %s", index, info.ip_str, info.port, status_str);
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
        ctx.torrent.free();
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
    if (ctx.peer_infos.len() > 0)
    {
        foreach (info : ctx.peer_infos.array_view())
        {
            if (info.conn)
            {
                info.conn.close();
            }
        }

        // Give event loop time to finish closing connections
        // Run a few iterations to let async close operations complete
        for (int i = 0; i < 10 && loop.is_alive(); i++)
        {
            loop.run_once();
        }

        // Free the PeerConnection structs (cmd_connect owns these connections)
        foreach (info : ctx.peer_infos.array_view())
        {
            if (info.conn)
            {
                free(info.conn);
            }
        }

        // Free the peer info structures (ip_str and List itself)
        foreach (info : ctx.peer_infos.array_view())
        {
            if (info.ip_str.len > 0)
            {
                free(info.ip_str);
            }
        }
        ctx.peer_infos.free();
    }

    // Free peer pool
    if (ctx.peer_pool)
    {
        ctx.peer_pool.free();
    }

    return ctx.exit_code;
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
// Download Command - Full torrent download with piece management
// ============================================================================

<*
 Called when download is complete - closes all handles.
 Event loop will exit naturally once all handles are closed.
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
    log_outputs::LogSink* log_sink = log_outputs::setup_gui_logging(ui);

    // Create download context
    // Create TorrentManager for managing this torrent
    libtorrent::torrent_manager::TorrentManager* mgr = libtorrent::torrent_manager::create(loop, 1);

    Session ctx;
    ctx.manager = mgr;
    ctx.torrent = torrent;
    ctx.dm = null;
    ctx.sm = null;
    ctx.tracker_completed = false;
    ctx.tracker_coord = null;  // Will be initialized during session setup
    ctx.pex_timer = null;
    ctx.keepalive_timer = null;
    ctx.flush_timer = null;
    ctx.block_timeout_timer = null;
    ctx.peer_pool = null;
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
    ctx.gui_state = ui;
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

    // Initialize multi-tracker manager (BEP 12)
    if (torrent.announce_list.len > 0)
    {
        // Use announce-list for multi-tracker support
        ctx.tracker_mgr = mem::new(tracker_manager::TrackerManager);
        *ctx.tracker_mgr = tracker_manager::initialize(torrent.announce_list);
        ctx.current_tracker_url = "";

        io::printfn("Multi-tracker support: %d tiers, %d total trackers",
                    ctx.tracker_mgr.get_tier_count(),
                    torrent.announce_list[0].len + (torrent.announce_list.len > 1 ? torrent.announce_list[1].len : 0));

        // Populate GUI tracker list immediately
        raylib_gui::update_tracker_list(ui, ctx.tracker_mgr,
                                         ctx.current_tracker_url, "Idle", -1);
    }
    else
    {
        // Fallback to single tracker
        ctx.tracker_mgr = null;
        ctx.current_tracker_url = torrent.announce;

        // Populate GUI with single tracker
        raylib_gui::update_tracker_list(ui, null,
                                         ctx.current_tracker_url, "Idle", -1);
    }

    // Initialize tracker coordinator
    ctx.tracker_coord = session_tracker_coordinator::create(
        loop, torrent, ctx.tracker_mgr, ctx.current_tracker_url
    );
    ctx.tracker_coord.set_peers_received_callback(&session::on_tracker_peers_received, &ctx);
    ctx.tracker_coord.set_failed_callback(&session::on_tracker_failed, &ctx);

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
        log_outputs::cleanup_log_sink(log_sink);
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

    // Initialize DHT for peer discovery
    raylib_gui::add_log(ui, "Starting DHT on port 6881...");
    session::init_dht(&ctx, 6881);

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
    if (ctx.tracker_coord)
    {
        ctx.tracker_coord.free();
        ctx.tracker_coord = null;
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

    if (ctx.tracker_coord)
    {
        ctx.tracker_coord.free();
    }

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

    // Cleanup logging
    io::printfn("Cleaning up logging...");
    logger::flush_logs();
    log_outputs::cleanup_log_sink(log_sink);

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
                    String save_path, int numwant, String log_file_path, bool debug_mode, bool gui_mode,
                    String select_files_str)
{
    // GUI mode - launch graphical interface
    if (gui_mode)
    {
        return cmd_download_gui(loop, torrent_path, save_path, numwant);
    }

    // Console mode
    io::printfn("=== BitTorrent Download ===");
    io::printfn("");

    // Set up console logging (file and/or stderr)
    log_outputs::LogSink*? log_sink = log_outputs::setup_console_logging(log_file_path, debug_mode);

    // Create TorrentManager for managing this torrent
    libtorrent::torrent_manager::TorrentManager* mgr = libtorrent::torrent_manager::create(loop, 1);

    Session ctx;
    ctx.manager = mgr;
    ctx.torrent = null;
    ctx.dm = null;
    ctx.sm = null;
    ctx.tracker_completed = false;
    ctx.tracker_response = null;
    ctx.tracker_coord = null;  // Will be initialized during session setup
    ctx.pex_timer = null;
    ctx.keepalive_timer = null;
    ctx.flush_timer = null;
    ctx.block_timeout_timer = null;
    ctx.peer_pool = null;
    ctx.download_complete = false;
    ctx.is_partial_seed = false;  // BEP 21: TODO - set true if selective download
    ctx.exit_code = 0;
    ctx.num_pieces = 0;
    ctx.pieces_verified_count = 0;
    ctx.next_piece_to_verify = 0;
    ctx.numwant = numwant;
    ctx.save_path = save_path;
    ctx.max_concurrent_pieces = session::DEFAULT_MAX_CONCURRENT_PIECES;
    ctx.torrent_path = torrent_path;          // BEP 21: Torrent file path for resume data
    ctx.select_files_str = select_files_str;  // BEP 21: File selection for partial seeds
    ctx.gui_state = null;  // Console mode has no GUI
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

    // Start periodic log flush timer (every 2 seconds) if logging is enabled
    async::timer::Timer* flush_timer = null;
    if (catch excuse = log_sink)
    {
        // No logging configured, skip flush timer
    }
    else
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
            flush_timer.start(2000, 2000,
                              fn void(async::timer::Timer* timer, void* user_data) {
                                  logger::flush_logs();
                              }, null);
        }
    }

    // Check if this is a magnet link or torrent file
    if (torrent_path.starts_with("magnet:"))
    {
        // Magnet link download - start metadata download process
        magnet_download_session::start_magnet_download(&ctx, torrent_path);
    }
    else
    {
        // Load torrent file async
        torrent_loader::load_file_async(loop, torrent_path,
                                         &session::on_download_load_complete, &ctx);
    }

    // Run event loop - blocks until user interrupts (Ctrl+C) or error
    // After download completes, continues running in seeding mode
    // The loop only exits when all handles are closed (user presses Ctrl+C)
    loop.run()!!;

    // Cleanup - close all event loop handles FIRST (fires async close callbacks)
    // This ensures TCP/timer handles and PeerConnection structs are freed by callbacks
    // BEFORE we try to free the data structures
    loop.close_all_handles();

    // Now free allocated memory (connections already freed by callbacks above)
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

    // Free tracker coordinator
    if (ctx.tracker_coord)
    {
        ctx.tracker_coord.free();
    }

    // Free tracker manager
    if (ctx.tracker_mgr)
    {
        ctx.tracker_mgr.free();
    }

    // Free upload manager
    if (ctx.upload_mgr)
    {
        ctx.upload_mgr.free();
    }

    // Free peer pool
    if (ctx.peer_pool)
    {
        ctx.peer_pool.free();
    }

    // Free DHT resources
    if (ctx.dht_search)
    {
        ctx.dht_search.free();
    }

    // Free web seed manager
    if (ctx.webseed_mgr)
    {
        ctx.webseed_mgr.free();
    }

    // Free metadata download manager
    if (ctx.metadata_dl)
    {
        ctx.metadata_dl.free();
    }

    // Free speed tracker
    if (ctx.speed_tracker)
    {
        ctx.speed_tracker.free();
    }

    // Free event bus
    if (ctx.event_bus)
    {
        ctx.event_bus.free();
    }

    // Stop and close log flush timer
    if (flush_timer)
    {
        flush_timer.close();
    }

    // Free torrent manager
    if (mgr)
    {
        mgr.free();
    }

    // Flush any remaining logs before cleanup
    logger::flush_logs();

    // Cleanup log sink
    (void)log_outputs::cleanup_log_sink(log_sink);

    // Free logger resources
    logger::free_logger();

    return ctx.exit_code;
}

