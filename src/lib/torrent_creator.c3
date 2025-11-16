module libtorrent::torrent_creator;

import libtorrent::metainfo;
import libtorrent::merkle_tree;
import libtorrent::bencode;
import async::event_loop;
import async::file;
import uv;
import std::io;
import std::collections::list;
import std::hash::sha1;
import std::hash::sha256;

<*
 Torrent Creator - BEP 52 v2 Torrent Creation

 This module provides functionality to create .torrent files with support for:
 - v1 (SHA-1 piece hashes)
 - v2 (SHA-256 Merkle trees per file)
 - Hybrid (both v1 and v2)
*>

// Constants
const uint DEFAULT_PIECE_LENGTH = 16384;  // 16 KiB minimum for v2
const uint MAX_PIECE_LENGTH = 16 * 1024 * 1024;  // 16 MiB max
const uint MERKLE_BLOCK_SIZE = 16384;  // 16 KiB blocks for Merkle tree
const uint TARGET_PIECES = 1500;  // Target number of pieces per torrent

// Faults
faultdef CREATOR_SCAN_FAILED;
faultdef CREATOR_HASH_FAILED;
faultdef CREATOR_ENCODING_FAILED;
faultdef CREATOR_NO_FILES;
faultdef CREATOR_INVALID_PATH;

// Torrent metadata version
enum TorrentVersion
{
    V1_ONLY,    // Only v1 (SHA-1 piece hashes)
    V2_ONLY,    // Only v2 (Merkle trees)
    HYBRID,     // Both v1 and v2
}

// File entry with metadata
struct FileInfo
{
    String[] path_components;  // Path split into components
    long length;               // File size in bytes
    long offset;               // Byte offset in the torrent (for alignment)
    bool is_padding;          // BEP 47 padding file
}

// Torrent creator configuration
struct TorrentConfig
{
    String input_path;         // File or directory to create torrent from
    String output_path;        // Output .torrent file path
    String[] announce_urls;    // Tracker URLs
    String comment;            // Optional comment
    String created_by;         // Creator info
    bool is_private;           // Private torrent flag
    TorrentVersion version;    // v1, v2, or hybrid
    uint piece_length;         // 0 = auto-calculate
}

// Scan result from recursive directory traversal
struct ScanResult
{
    List{FileInfo} files;
    long total_size;
}

// Creator state
struct TorrentCreator
{
    TorrentConfig config;
    event_loop::EventLoop* loop;
    ScanResult scan_result;
    bool scanning_complete;
    int scan_error;
}

// ============================================================================
// Helper Functions
// ============================================================================

<*
 Calculate the next power of 2 greater than or equal to the given value.
*>
fn uint next_power_of_2(uint n) @private
{
    if (n == 0) return 1;

    n--;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    n++;

    return n;
}

<*
 Calculate optimal piece length based on total torrent size.

 Uses mktorrent's lookup table approach: smaller piece lengths for smaller
 torrents to avoid excessive overhead, larger piece lengths for large torrents.
*>
fn uint calculate_piece_length(long total_size) @private
{
    // Based on mktorrent's piece length selection table
    // Aims for ~1000-2000 pieces per torrent

    if (total_size == 0) return DEFAULT_PIECE_LENGTH;

    uint piece_length = (uint)(total_size / TARGET_PIECES);

    // Round up to nearest power of 2
    piece_length = next_power_of_2(piece_length);

    // Enforce v2 minimum (16 KiB)
    if (piece_length < DEFAULT_PIECE_LENGTH) {
        piece_length = DEFAULT_PIECE_LENGTH;
    }

    // Enforce reasonable maximum (16 MiB)
    if (piece_length > MAX_PIECE_LENGTH) {
        piece_length = MAX_PIECE_LENGTH;
    }

    return piece_length;
}

<*
 Split a file path into components for BEP 52 file tree.

 Example: "/home/user/data/file.txt" -> ["data", "file.txt"]
         (assuming input_path was "/home/user")
*>
fn String[] split_path_components(String full_path, String base_path) @private
{
    // Remove base path prefix
    String relative;
    if (full_path.starts_with(base_path)) {
        relative = full_path[base_path.len..];
        // Remove leading slash
        if (relative.len > 0 && relative[0] == '/') {
            relative = relative[1..];
        }
    } else {
        relative = full_path;
    }

    // Split by '/' into components
    return relative.tsplit("/");
}

// ============================================================================
// File Scanning
// ============================================================================

// Context for async directory scanning
struct ScanContext
{
    TorrentCreator* creator;
    String current_path;
    String base_path;
    List{String} pending_dirs;  // Stack of directories to scan
}

fn void on_scandir_callback(async::file::DirEntry[] entries, int status, void* user_data)
{
    ScanContext* ctx = (ScanContext*)user_data;
    TorrentCreator* creator = ctx.creator;

    if (status < 0) {
        creator.scan_error = status;
        creator.scanning_complete = true;
        free(ctx);
        return;
    }

    // Process entries: collect files, queue directories
    for (usz i = 0; i < entries.len; i++) {
        async::file::DirEntry entry = entries[i];

        // Skip . and ..
        if (entry.name == "." || entry.name == "..") {
            continue;
        }

        // Build full path
        DString full_path;
        full_path.append(ctx.current_path);
        if (!ctx.current_path.ends_with("/")) {
            full_path.append("/");
        }
        full_path.append(entry.name);
        String path_str = full_path.copy_str(mem);

        if (entry.type == uv::DirEntryType.DIR) {
            // Queue directory for scanning
            ctx.pending_dirs.push(path_str);
        } else if (entry.type == uv::DirEntryType.FILE) {
            // Add file to result
            FileInfo file;
            file.path_components = split_path_components(path_str, ctx.base_path);

            // Get file size using stat (we need to do this async)
            // For now, mark as 0 and we'll get size later
            // TODO: Add async stat call here
            file.length = 0;
            file.offset = 0;
            file.is_padding = false;

            creator.scan_result.files.push(file);
        }
    }

    // Continue scanning if there are more directories
    if (ctx.pending_dirs.len() > 0) {
        String next_dir = ctx.pending_dirs.pop()!!;
        ctx.current_path = next_dir;

        // Scan next directory
        async::file::scandir(creator.loop, next_dir, &on_scandir_callback, user_data);
    } else {
        // Scanning complete
        creator.scanning_complete = true;
        free(ctx);
    }
}

<*
 Scan a directory recursively and collect file metadata.

 This is an async operation that uses the event loop.
*>
fn void TorrentCreator.scan_files(&self) @private
{
    self.scanning_complete = false;
    self.scan_error = 0;
    self.scan_result.files = {};
    self.scan_result.total_size = 0;

    ScanContext* ctx = mem::new(ScanContext);
    ctx.creator = self;
    ctx.current_path = self.config.input_path;
    ctx.base_path = self.config.input_path;
    ctx.pending_dirs = {};

    // Start scanning the root directory
    async::file::scandir(self.loop, self.config.input_path, &on_scandir_callback, ctx);
}

// ============================================================================
// Public API
// ============================================================================

<*
 Create a new torrent creator with the given configuration.
*>
fn TorrentCreator* create(event_loop::EventLoop* loop, TorrentConfig config) @public
{
    TorrentCreator* creator = mem::new(TorrentCreator);
    creator.config = config;
    creator.loop = loop;
    creator.scanning_complete = false;
    creator.scan_error = 0;

    return creator;
}

<*
 Free a torrent creator and its resources.
*>
fn void TorrentCreator.free(&self) @public
{
    if (self.scan_result.files.len() > 0) {
        // Free file path components
        foreach (file : self.scan_result.files) {
            for (usz j = 0; j < file.path_components.len; j++) {
                std::core::mem::free(file.path_components[j].ptr);
            }
            std::core::mem::free(file.path_components.ptr);
        }
        self.scan_result.files.free();
    }

    free(self);
}

<*
 Start creating the torrent asynchronously.

 This initiates the torrent creation process which includes:
 1. Scanning files
 2. Calculating piece length (if auto)
 3. Hashing files
 4. Generating Merkle trees (for v2)
 5. Encoding to bencode format
 6. Writing to output file
*>
fn void TorrentCreator.start(&self) @public
{
    // Phase 1: Scan files
    self.scan_files();
}

<*
 Check if torrent creation is complete.
*>
fn bool TorrentCreator.is_complete(&self) @public
{
    return self.scanning_complete;
}

<*
 Get the error code if creation failed.
*>
fn int TorrentCreator.get_error(&self) @public
{
    return self.scan_error;
}
