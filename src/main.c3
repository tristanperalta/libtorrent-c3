module torrent_client;

import std::io;
import std::encoding::hex;
import libtorrent;

faultdef FILE_ERROR;

fn int main(int argc, ZString* argv)
{
    if (argc < 2)
    {
        print_usage();
        return 1;
    }

    String torrent_path = (String)argv[1].str_view();
    load_and_display_torrent(torrent_path);
    return 0;
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
    io::printfn("Usage: torrent-client <torrent-file>");
    io::printfn("");
    io::printfn("Display metadata from a .torrent file");
    io::printfn("");
    io::printfn("Examples:");
    io::printfn("  torrent-client ubuntu.torrent");
    io::printfn("  torrent-client path/to/file.torrent");
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
