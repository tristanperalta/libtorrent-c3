module torrent_client;

import std::io;
import std::encoding::hex;
import libtorrent;
import libtorrent::tracker;
import libtorrent::event_loop;

faultdef FILE_ERROR;

fn int main(int argc, ZString* argv)
{
    if (argc < 2)
    {
        print_usage();
        return 1;
    }

    String command = (String)argv[1].str_view();

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
        load_and_display_torrent(torrent_path);
        return 0;
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
        return cmd_announce(torrent_path);
    }
    else
    {
        // Legacy behavior: treat first arg as file path
        load_and_display_torrent(command);
        return 0;
    }
}

fn void load_and_display_torrent(String path)
{
    // Load file
    String? data = load_torrent_file(path);
    if (catch err = data)
    {
        io::eprintfn("Error loading file: %s", err);
        return;
    }
    defer free(data);

    // Parse torrent
    libtorrent::torrent::TorrentFile*? torrent = libtorrent::torrent::parse(data);
    if (catch err = torrent)
    {
        io::eprintfn("Error parsing torrent: %s", err);
        return;
    }
    defer libtorrent::torrent::free_torrent_file(torrent);

    // Display metadata
    display_torrent_info(torrent);
}

fn String? load_torrent_file(String path)
{
    // Load entire file
    char[]? buffer = io::file::load(mem, path);
    if (catch err = buffer)
    {
        return FILE_ERROR?;
    }

    return (String)buffer;
}

fn void print_usage()
{
    io::printfn("Usage: torrent-client [COMMAND] <torrent-file>");
    io::printfn("");
    io::printfn("Commands:");
    io::printfn("  info <file>       Display torrent metadata (default)");
    io::printfn("  announce <file>   Announce to tracker and show peer list");
    io::printfn("");
    io::printfn("Examples:");
    io::printfn("  torrent-client info ubuntu.torrent");
    io::printfn("  torrent-client announce ubuntu.torrent");
    io::printfn("  torrent-client ubuntu.torrent          # Same as 'info'");
}

fn void display_torrent_info(libtorrent::torrent::TorrentFile* torrent)
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

// Context for async announce
struct AnnounceContext
{
    bool completed;
    tracker::TrackerResponse* response;
    int status;
}

fn void on_announce_complete(tracker::TrackerResponse* response, int status, void* user_data)
{
    AnnounceContext* ctx = (AnnounceContext*)user_data;
    ctx.completed = true;
    ctx.response = response;
    ctx.status = status;
}

<*
 Announce command: contact tracker and display peer list.
 Now uses async tracker (non-blocking with thread pool for HTTP).

 @param torrent_path : "Path to torrent file"
 @return "Exit code (0 = success, 1 = error)"
*>
fn int cmd_announce(String torrent_path)
{
    // Load torrent file
    String? data = load_torrent_file(torrent_path);
    if (catch err = data)
    {
        io::eprintfn("Error loading file: %s", err);
        return 1;
    }
    defer free(data);

    // Parse torrent
    libtorrent::torrent::TorrentFile*? torrent = libtorrent::torrent::parse(data);
    if (catch err = torrent)
    {
        io::eprintfn("Error parsing torrent: %s", err);
        return 1;
    }
    defer libtorrent::torrent::free_torrent_file(torrent);

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
            return 1;
        }
    }

    io::printfn("Announcing to tracker (async): %s", tracker_url);
    io::printfn("");

    // Create event loop
    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        io::eprintfn("Error creating event loop");
        return 1;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Announce context
    AnnounceContext ctx;
    ctx.completed = false;
    ctx.response = null;
    ctx.status = 0;

    // Announce to tracker (async - doesn't block!)
    ushort our_port = 6881;
    tracker::async_announce(&loop, torrent, our_port, "started",
                            &on_announce_complete, &ctx);

    // Run event loop until announce completes
    while (!ctx.completed && loop.is_alive())
    {
        loop.run_once();
    }

    if (!ctx.completed || ctx.status != 0 || !ctx.response)
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
