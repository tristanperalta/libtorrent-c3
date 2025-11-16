module mktorrent;

import libtorrent::bencode;
import libtorrent::metainfo;
import libtorrent::merkle_tree;
import std::io;
import std::collections::list;
import std::hash::sha1;
import std::hash::sha256;
import std::time;

<*
 mktorrent - Create BitTorrent metainfo files

 Supports BEP 52 v2 torrents with Merkle trees.

 Usage:
   mktorrent [options] <input>

 Options:
   -o <file>      Output .torrent file (default: <name>.torrent)
   -a <url>       Announce URL (tracker)
   -c <comment>   Add comment
   -p             Private torrent flag
   -v <1|2|h>     Version: 1 (v1 only), 2 (v2 only), h (hybrid)
   -l <n>         Piece length in KiB (auto-calculate if not specified)
   --help         Show this help
*>

// Constants
const uint DEFAULT_PIECE_LENGTH = 16384;  // 16 KiB minimum for v2
const uint MAX_PIECE_LENGTH = 16 * 1024 * 1024;  // 16 MiB
const uint TARGET_PIECES = 1500;

// Configuration
struct Config
{
    String input_path;
    String output_path;
    String[] announce_urls;
    String comment;
    bool is_private;
    int version;  // 1 = v1, 2 = v2, 3 = hybrid
    uint piece_length;
}

fn void print_usage()
{
    io::printn("mktorrent - Create BitTorrent metainfo files");
    io::printn("");
    io::printn("Usage: mktorrent [options] <input>");
    io::printn("");
    io::printn("Options:");
    io::printn("  -o <file>      Output .torrent file");
    io::printn("  -a <url>       Announce URL (tracker)");
    io::printn("  -c <comment>   Add comment");
    io::printn("  -p             Private torrent");
    io::printn("  -v <1|2|h>     Version: 1=v1, 2=v2, h=hybrid (default: 2)");
    io::printn("  -l <n>         Piece length in KiB");
    io::printn("  --help         Show this help");
}

fn int main(String[] args)
{
    if (args.len < 2) {
        print_usage();
        return 1;
    }

    Config config;
    config.input_path = "";
    config.output_path = "";
    config.announce_urls = {};
    config.comment = "";
    config.is_private = false;
    config.version = 2;  // Default to v2
    config.piece_length = 0;  // Auto-calculate
    bool output_path_allocated = false;

    // Parse arguments
    for (usz i = 1; i < args.len; i++) {
        String arg = args[i];

        if (arg == "--help" || arg == "-h") {
            print_usage();
            return 0;
        } else if (arg == "-o" && i + 1 < args.len) {
            config.output_path = args[++i];
        } else if (arg == "-a" && i + 1 < args.len) {
            config.announce_urls = {args[++i]};
        } else if (arg == "-c" && i + 1 < args.len) {
            config.comment = args[++i];
        } else if (arg == "-p") {
            config.is_private = true;
        } else if (arg == "-v" && i + 1 < args.len) {
            String ver = args[++i];
            if (ver == "1") {
                config.version = 1;
            } else if (ver == "2") {
                config.version = 2;
            } else if (ver == "h") {
                config.version = 3;
            } else {
                io::printfn("Invalid version: %s (use 1, 2, or h)", ver);
                return 1;
            }
        } else if (arg == "-l" && i + 1 < args.len) {
            // Parse piece length in KiB
            String len_str = args[++i];
            int len_kib = (int)len_str.to_long()!!;
            config.piece_length = (uint)(len_kib * 1024);
        } else if (!arg.starts_with("-")) {
            config.input_path = arg;
        } else {
            io::printfn("Unknown option: %s", arg);
            print_usage();
            return 1;
        }
    }

    // Validate configuration
    if (config.input_path.len == 0) {
        io::printn("Error: No input path specified");
        print_usage();
        return 1;
    }

    if (config.output_path.len == 0) {
        // Auto-generate output filename
        DString buf;
        buf.append(config.input_path);
        buf.append(".torrent");
        config.output_path = buf.copy_str(mem);
        output_path_allocated = true;
    }

    // Cleanup allocated config memory
    defer {
        if (output_path_allocated) {
            free(config.output_path);
        }
    }

    if (config.announce_urls.len == 0) {
        io::printn("Warning: No announce URL specified (torrent will not be usable without a tracker)");
    }

    // Scan files
    io::printfn("Scanning: %s", config.input_path);
    ScanResult scan = scan_path(config.input_path);
    defer scan.free();  // Clean up scan result

    if (scan.files.len() == 0) {
        io::printn("Error: No files found");
        return 1;
    }

    io::printfn("Found %d file(s), total size: %d bytes", scan.files.len(), scan.total_size);

    // Calculate piece length if auto
    if (config.piece_length == 0) {
        if (scan.total_size == 0) {
            config.piece_length = DEFAULT_PIECE_LENGTH;
        } else {
            uint calc_piece_length = (uint)(scan.total_size / TARGET_PIECES);
            // Round up to next power of 2
            uint n = calc_piece_length;
            if (n > 0) {
                n--;
                n |= n >> 1;
                n |= n >> 2;
                n |= n >> 4;
                n |= n >> 8;
                n |= n >> 16;
                n++;
            }
            config.piece_length = n;

            if (config.piece_length < DEFAULT_PIECE_LENGTH) {
                config.piece_length = DEFAULT_PIECE_LENGTH;
            }
            if (config.piece_length > MAX_PIECE_LENGTH) {
                config.piece_length = MAX_PIECE_LENGTH;
            }
        }
    }

    io::printfn("Piece length: %d KiB (%d pieces)", config.piece_length / 1024,
        (scan.total_size + config.piece_length - 1) / config.piece_length);

    io::printn("");
    io::printn("File list:");
    foreach (file : scan.files) {
        DString path_str;
        for (usz i = 0; i < file.path_components.len; i++) {
            if (i > 0) path_str.append("/");
            path_str.append(file.path_components[i]);
        }
        io::printfn("  %s (%d bytes)", path_str.str_view(), file.size);
    }

    // Hash files
    io::printn("");
    HashResult hash_result;

    // Convert List to array for hasher
    FileEntry[] files_array = mem::new_array(FileEntry, scan.files.len());
    defer free(files_array);
    foreach (i, file : scan.files) {
        files_array[i] = file;
    }

    hash_files(files_array, config.input_path, config.piece_length, config.version, &hash_result);

    io::printn("");
    io::printfn("Hashing complete: %d pieces", hash_result.num_pieces);

    if (config.version == 1 || config.version == 3) {
        io::printfn("v1 pieces hash size: %d bytes", hash_result.pieces_v1.len);
    }

    if (config.version == 2 || config.version == 3) {
        io::printn("v2 root hash: [computed]");
    }

    // Write .torrent file
    io::printn("");
    write_torrent_file(
        config.output_path,
        config.input_path,
        config.announce_urls,
        config.comment,
        config.is_private,
        files_array,
        &hash_result,
        config.piece_length,
        config.version
    );

    // Clean up hash result
    if (hash_result.pieces_v1.len > 0) {
        free(hash_result.pieces_v1);
    }
    if (hash_result.piece_layers.len > 0) {
        free(hash_result.piece_layers);
    }

    io::printn("\nDone!");
    return 0;
}
