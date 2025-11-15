module libtorrent::metainfo;

import std::io;
import std::hash::sha1;
import std::hash::sha256;
import std::encoding::hex;
import std::net::url;
import std::collections::list;
import std::collections::set;
import std::core::mem::allocator;
import libtorrent::bencode;
import libtorrent::path_sanitize;
import libtorrent::merkle_tree;
import libtorrent::common;

/**
 * Torrent File Parser
 * ===================
 * Parses .torrent files (BitTorrent metainfo files) using bencode decoder.
 *
 * Reference: BEP 3 - The BitTorrent Protocol Specification
 * https://www.bittorrent.org/beps/bep_0003.html
 */

/**
 * DhtNode represents a DHT bootstrap node (BEP 5).
 */
struct DhtNode
{
    String host;    // Hostname or IP address
    ushort port;    // Port number
}

/**
 * FileEntry represents a single file in a multi-file torrent.
 */
struct FileEntry
{
    String[] path;          // Path components (e.g., ["dir", "subdir", "file.txt"])
    long length;            // File size in bytes
    long offset;            // Byte offset in the overall torrent data

    // BEP 47: Extended file attributes
    String attr;            // Attribute flags: "l"=symlink, "x"=executable, "h"=hidden, "p"=padding
    String[] symlink_path;  // Symlink target path (only if attr contains 'l')
    InfoHash sha1;          // Optional SHA1 hash for file deduplication
    bool has_sha1;          // Whether sha1 field is present

    // BEP 52: v2 fields
    common::InfoHashV2 pieces_root;  // 32-byte SHA-256 Merkle root hash
    bool has_pieces_root;            // True for v2/hybrid torrents
}

/**
 * Check if this file is a symlink (BEP 47).
 * @return true if attr contains 'l' flag
 */
fn bool FileEntry.is_symlink(&self) @public
{
    foreach (c : self.attr)
    {
        if (c == 'l') return true;
    }
    return false;
}

/**
 * Check if this file is a padding file (BEP 47).
 * Padding files are used for alignment and should not be written to disk.
 * @return true if attr contains 'p' flag
 */
fn bool FileEntry.is_padding(&self) @public
{
    foreach (c : self.attr)
    {
        if (c == 'p') return true;
    }
    return false;
}

/**
 * TorrentInfo represents the 'info' dictionary in a torrent file.
 * This contains the actual file metadata.
 *
 * For single-file torrents:
 * - name: filename
 * - length: file size in bytes
 * - piece_length: number of bytes in each piece
 * - pieces: concatenated SHA1 hashes (20 bytes each)
 *
 * For multi-file torrents:
 * - name: directory name
 * - files: list of FileEntry structs
 * - length: total size (calculated from files)
 */
struct TorrentInfo
{
    String name;            // File or directory name
    long length;            // Total length (single-file or sum of multi-file)
    long piece_length;      // Bytes per piece
    char[] pieces;          // SHA1 hashes (20 bytes each)
    bool is_multi_file;     // true if multi-file torrent
    FileEntry[] files;      // Files list (multi-file mode only)
    bool private;           // BEP 27: Private torrent flag (DHT/PEX disabled)

    // BEP 52: v2 fields
    int meta_version;       // 1 = v1 only, 2 = v2/hybrid, 0 = unknown
    bool is_v2;             // True if v2 or hybrid torrent
    merkle_tree::MerkleTree*[] piece_layers;  // Merkle trees per file (same order as files[])
}

/**
 * TorrentFile represents a complete .torrent file.
 */
struct TorrentFile
{
    String announce;        // Tracker URL
    String[][] announce_list; // Optional: Multi-tracker tiers (BEP 12)
    DhtNode[] nodes;        // Optional: DHT bootstrap nodes (BEP 5)
    String[] collections;   // Optional: Collection names (BEP 38)
    char[] similar;         // Optional: Similar torrent info-hashes (20 bytes each, BEP 38)
    usz similar_count;      // Number of similar torrents
    String created_by;      // Optional: creator info
    long creation_date;     // Optional: Unix timestamp
    String encoding;        // Optional: character encoding
    String[] url_list;      // Optional: URL seeds (BEP 19)
    String[] httpseeds;     // Optional: HTTP seeds (BEP 17)
    TorrentInfo info;       // File metadata
    char[20] info_hash;     // SHA1 hash of bencoded info dict (v1)

    // BEP 52: v2 fields
    common::InfoHashV2 info_hash_v2;  // v2 SHA-256 info hash
    bool is_hybrid;                   // True if contains both v1 and v2 metadata

    // Memory management
    DynamicArenaAllocator arena;  // Arena allocator for torrent-lifetime allocations
}

/**
 * Faults for torrent parsing errors
 */
faultdef TORRENT_INVALID_FORMAT;
faultdef TORRENT_MISSING_FIELD;
faultdef TORRENT_INVALID_INFO;
faultdef TORRENT_INDEX_OUT_OF_BOUNDS;
faultdef TORRENT_INVALID_PATH;
faultdef TORRENT_INVALID_SYMLINK;    // BEP 47: Invalid symlink format or target
faultdef TORRENT_SYMLINK_ESCAPE;     // BEP 47: Symlink escapes torrent directory

/**
 * Parse a .torrent file from bencoded data.
 *
 * @param data The contents of a .torrent file
 * @return The parsed torrent metadata or a fault
 */
fn TorrentFile*? parse(String data) @public => @pool()
{
    // Decode the bencode data
    BencodeValue* root = bencode::decode(data)!;
    defer root.free();

    // Root must be a dictionary
    if (root.type != bencode::BencodeType.DICT)
    {
        return TORRENT_INVALID_FORMAT?;
    }

    // Allocate result
    TorrentFile* torrent = mem::new(TorrentFile);

    // Initialize arena allocator with 64KB pages
    // Will automatically grow as needed for torrent metadata
    torrent.arena.init(mem, 64 * 1024);

    // Extract 'announce' (optional - may be missing in some torrents)
    BencodeValue* announce_val = root.dict_get("announce");
    if (announce_val && announce_val.type == bencode::BencodeType.STRING)
    {
        // Trim whitespace from announce URL
        torrent.announce = trim_whitespace(&torrent.arena, (String)announce_val.string);
    }

    // Extract 'announce-list' (optional - BEP 12 multi-tracker)
    BencodeValue* announce_list_val = root.dict_get("announce-list");
    if (announce_list_val && announce_list_val.type == bencode::BencodeType.LIST)
    {
        usz num_tiers = announce_list_val.list.size;
        if (num_tiers > 0)
        {
            // Allocate array of tiers from arena
            torrent.announce_list = allocator::new_array(&torrent.arena, String[], num_tiers);

            for (usz i = 0; i < num_tiers; i++)
            {
                BencodeValue* tier = announce_list_val.list.get(i);
                if (tier.type == bencode::BencodeType.LIST)
                {
                    usz num_trackers = tier.list.size;
                    if (num_trackers > 0)
                    {
                        // Allocate array of tracker URLs for this tier from arena
                        torrent.announce_list[i] = allocator::new_array(&torrent.arena, String, num_trackers);

                        for (usz j = 0; j < num_trackers; j++)
                        {
                            BencodeValue* tracker = tier.list.get(j);
                            if (tracker.type == bencode::BencodeType.STRING)
                            {
                                // Trim whitespace from tracker URLs (uses arena)
                                torrent.announce_list[i][j] = trim_whitespace(&torrent.arena, (String)tracker.string);
                            }
                        }
                    }
                }
            }
        }
    }

    // Extract 'nodes' (optional - BEP 5 DHT bootstrap nodes)
    BencodeValue* nodes_val = root.dict_get("nodes");
    if (nodes_val && nodes_val.type == bencode::BencodeType.LIST)
    {
        usz num_nodes = nodes_val.list.size;
        if (num_nodes > 0)
        {
            torrent.nodes = allocator::new_array(&torrent.arena, DhtNode, num_nodes);

            for (usz i = 0; i < num_nodes; i++)
            {
                BencodeValue* node = nodes_val.list.get(i);
                if (node.type == bencode::BencodeType.LIST && node.list.size == 2)
                {
                    // Each node is [host_string, port_integer]
                    BencodeValue* host = node.list.get(0);
                    BencodeValue* port = node.list.get(1);

                    if (host.type == bencode::BencodeType.STRING &&
                        port.type == bencode::BencodeType.INTEGER)
                    {
                        torrent.nodes[i].host = copy_string(&torrent.arena, host.string);
                        torrent.nodes[i].port = (ushort)port.integer;
                    }
                }
            }
        }
    }

    // Extract 'collections' (optional - BEP 38)
    // Can be in root dictionary or info dictionary (merge both)
    BencodeValue* collections_val = root.dict_get("collections");
    if (collections_val && collections_val.type == bencode::BencodeType.LIST)
    {
        usz count = collections_val.list.size;
        if (count > 0)
        {
            torrent.collections = allocator::new_array(&torrent.arena, String, count);
            for (usz i = 0; i < count; i++)
            {
                BencodeValue* collection = collections_val.list.get(i);
                if (collection.type == bencode::BencodeType.STRING)
                {
                    torrent.collections[i] = copy_string(&torrent.arena, collection.string);
                }
            }
        }
    }

    // Extract 'similar' (optional - BEP 38)
    // List of info-hashes (20-byte binary strings)
    BencodeValue* similar_val = root.dict_get("similar");
    if (similar_val && similar_val.type == bencode::BencodeType.LIST)
    {
        usz count = similar_val.list.size;
        if (count > 0)
        {
            torrent.similar_count = count;
            torrent.similar = allocator::new_array(&torrent.arena, char, count * common::SHA1_HASH_SIZE);
            for (usz i = 0; i < count; i++)
            {
                BencodeValue* info_hash = similar_val.list.get(i);
                if (info_hash.type == bencode::BencodeType.STRING &&
                    info_hash.string.len == common::SHA1_HASH_SIZE)
                {
                    // Copy SHA1 hash to flat array
                    usz offset = i * common::SHA1_HASH_SIZE;
                    foreach (j, byte : info_hash.string)
                    {
                        torrent.similar[offset + j] = byte;
                    }
                }
            }
        }
    }

    // Extract 'created by' (optional)
    BencodeValue* created_by_val = root.dict_get("created by");
    if (created_by_val && created_by_val.type == bencode::BencodeType.STRING)
    {
        torrent.created_by = copy_string(&torrent.arena, created_by_val.string);
    }

    // Extract 'creation date' (optional)
    BencodeValue* creation_date_val = root.dict_get("creation date");
    if (creation_date_val && creation_date_val.type == bencode::BencodeType.INTEGER)
    {
        torrent.creation_date = creation_date_val.integer;
    }

    // Extract 'encoding' (optional)
    BencodeValue* encoding_val = root.dict_get("encoding");
    if (encoding_val && encoding_val.type == bencode::BencodeType.STRING)
    {
        torrent.encoding = copy_string(&torrent.arena, encoding_val.string);
    }

    // Extract 'url-list' (optional - BEP 19)
    // Can be either a single string or a list of strings
    // Deduplicates URLs to avoid redundant requests
    BencodeValue* url_list_val = root.dict_get("url-list");
    if (url_list_val)
    {
        if (url_list_val.type == bencode::BencodeType.LIST)
        {
            // List of URL seeds - deduplicate using HashSet
            HashSet{String} seen_urls;
            seen_urls.init(mem);
            defer seen_urls.free();

            List{String} urls;
            urls.init(mem);
            defer urls.free();  // Always free List's internal storage

            foreach (url_val : url_list_val.list.array_view())
            {
                if (url_val.type == bencode::BencodeType.STRING)
                {
                    String url_str = (String)url_val.string;
                    // Skip empty strings
                    if (url_str.len == 0) continue;

                    // Percent-encode spaces for BEP 19 compliance (heap allocated by url::encode)
                    String encoded_url = percent_encode_url(url_str);
                    defer free(encoded_url);  // Always free the heap copy

                    // Only add if not already seen and not empty
                    if (encoded_url.len > 0 && !seen_urls.contains(encoded_url))
                    {
                        // Copy to arena for permanent storage
                        String arena_url = copy_string(&torrent.arena, encoded_url);
                        seen_urls.add(arena_url);
                        urls.push(arena_url);
                    }
                }
            }

            // Copy List to arena-allocated array
            if (urls.size > 0)
            {
                torrent.url_list = allocator::new_array(&torrent.arena, String, urls.size);
                for (usz i = 0; i < urls.size; i++)
                {
                    torrent.url_list[i] = urls.get(i);  // String pointers already in arena
                }
            }
        }
        else if (url_list_val.type == bencode::BencodeType.STRING)
        {
            // Single URL seed - percent-encode spaces
            String url_str = (String)url_list_val.string;
            if (url_str.len > 0)
            {
                // Percent-encode (heap allocated by url::encode)
                String encoded_url = percent_encode_url(url_str);
                defer free(encoded_url);  // Always free the heap copy

                if (encoded_url.len > 0)
                {
                    // Allocate array from arena and copy encoded URL
                    torrent.url_list = allocator::new_array(&torrent.arena, String, 1);
                    torrent.url_list[0] = copy_string(&torrent.arena, encoded_url);
                }
            }
        }
    }

    // Extract 'httpseeds' (optional - BEP 17)
    // Deduplicates URLs and checks against url_list to avoid cross-list duplicates
    BencodeValue* httpseeds_val = root.dict_get("httpseeds");
    if (httpseeds_val && httpseeds_val.type == bencode::BencodeType.LIST)
    {
        // Use HashSet for deduplication
        HashSet{String} seen_seeds;
        seen_seeds.init(mem);
        defer seen_seeds.free();

        // Pre-populate with url_list URLs to avoid cross-list duplicates
        foreach (url : torrent.url_list)
        {
            seen_seeds.add(url);
        }

        List{String} seeds;
        seeds.init(mem);
        defer seeds.free();  // Always free List's internal storage

        foreach (seed_val : httpseeds_val.list.array_view())
        {
            if (seed_val.type == bencode::BencodeType.STRING)
            {
                String seed_str = (String)seed_val.string;
                // Skip empty strings
                if (seed_str.len == 0) continue;

                // Percent-encode spaces for BEP 17 compliance (heap allocated by url::encode)
                String encoded_seed = percent_encode_url(seed_str);
                defer free(encoded_seed);  // Always free the heap copy

                // Only add if not already seen and not empty
                if (encoded_seed.len > 0 && !seen_seeds.contains(encoded_seed))
                {
                    // Copy to arena for permanent storage
                    String arena_seed = copy_string(&torrent.arena, encoded_seed);
                    seen_seeds.add(arena_seed);
                    seeds.push(arena_seed);
                }
            }
        }

        // Copy List to arena-allocated array
        if (seeds.size > 0)
        {
            torrent.httpseeds = allocator::new_array(&torrent.arena, String, seeds.size);
            for (usz i = 0; i < seeds.size; i++)
            {
                torrent.httpseeds[i] = seeds.get(i);  // String pointers already in arena
            }
        }
    }

    // Extract 'info' dictionary (required)
    BencodeValue* info_val = root.dict_get("info");
    if (!info_val || info_val.type != bencode::BencodeType.DICT)
    {
        torrent.free();
        return TORRENT_MISSING_FIELD?;
    }

    // Parse info dictionary (pass arena for allocations)
    if (catch err = parse_info(&torrent.arena, &torrent.info, info_val))
    {
        torrent.free();
        return err?;
    }

    // Calculate info_hash (SHA1 of bencoded info dict)
    String info_encoded = info_val.encode();
    defer free(info_encoded);  // bencode::encode() returns heap memory
    torrent.info_hash = sha1::hash(info_encoded);

    // BEP 52: Calculate v2 info hash (SHA-256) if this is a v2 torrent
    if (torrent.info.is_v2)
    {
        torrent.info_hash_v2 = calculate_info_hash_v2((char[])info_encoded);

        // Detect hybrid torrents: v2 torrent with v1 compatibility fields
        // Hybrid = has both "pieces" (v1) and "file tree" (v2)
        torrent.is_hybrid = (torrent.info.pieces.len > 0);
    }

    // Validate torrent name (BEP 3 compliance)
    // If name is empty, ".", or "..", use info-hash as name
    // Note: Null bytes and path traversal within names are handled by path sanitization
    bool is_invalid = torrent.info.name.len == 0 ||
                     (torrent.info.name.len == 1 && torrent.info.name[0] == '.') ||
                     (torrent.info.name.len == 2 && torrent.info.name[0] == '.' && torrent.info.name[1] == '.');
    if (is_invalid)
    {
        // Replace with info-hash hex using stdlib hex::tencode()
        // Note: Old name was in arena (no need to free individually)
        String temp_hex = hex::tencode(torrent.info_hash[..]);
        // Copy temp hex to arena for permanent storage
        torrent.info.name = copy_string(&torrent.arena, temp_hex);
    }

    return torrent;
}

/**
 * Parse the 'info' dictionary from a torrent.
 *
 * @param arena Arena allocator for persistent allocations
 * @param info Pointer to TorrentInfo to fill
 * @param info_val The 'info' BencodeValue dictionary
 * @return Fault if parsing fails
 */
fn fault? parse_info(Allocator arena, TorrentInfo* info, BencodeValue* info_val)
{
    // Extract 'name' (required)
    BencodeValue* name_val = bencode::dict_get_required(bencode::BencodeType.STRING, info_val, "name", TORRENT_MISSING_FIELD)!;

    // Validate name for security (reject directory traversal, absolute paths, etc.)
    if (is_invalid_path_component((String)name_val.string))
    {
        return TORRENT_INVALID_PATH?;
    }

    // Sanitize the torrent name for filesystem safety (returns heap-allocated string)
    String? sanitized_name_opt = path_sanitize::sanitize_torrent_path((String)name_val.string);
    if (catch err = sanitized_name_opt)
    {
        // Sanitization failed (e.g., name is "." or "..") - copy to arena, will be replaced with hash later
        info.name = copy_string(arena, (char[])name_val.string);
    }
    else
    {
        // Copy sanitized string to arena (sanitize_torrent_path returns heap allocation)
        info.name = copy_string(arena, sanitized_name_opt);
        free(sanitized_name_opt);  // Free the heap copy from sanitize_torrent_path
    }

    // Check for single-file vs multi-file mode
    BencodeValue* length_val = info_val.dict_get("length");
    BencodeValue* files_val = info_val.dict_get("files");

    if (length_val && length_val.type == bencode::BencodeType.INTEGER)
    {
        // Single-file mode
        info.length = length_val.integer;
        info.is_multi_file = false;

        // Validate length is positive (single-file torrents must have content)
        if (info.length <= 0)
        {
            return TORRENT_INVALID_INFO?;
        }
    }
    else if (files_val && files_val.type == bencode::BencodeType.LIST)
    {
        // Multi-file mode
        info.is_multi_file = true;

        // Parse files list (pass arena for allocations)
        if (catch err = parse_files_list(arena, info, files_val))
        {
            return err?;
        }
    }
    else
    {
        // Neither length nor files found
        return TORRENT_MISSING_FIELD?;
    }

    // Extract 'piece length' (required)
    BencodeValue* piece_length_val = bencode::dict_get_required(bencode::BencodeType.INTEGER, info_val, "piece length", TORRENT_MISSING_FIELD)!;
    info.piece_length = piece_length_val.integer;

    // Validate piece_length is positive
    if (info.piece_length <= 0)
    {
        return TORRENT_INVALID_INFO?;
    }

    // Extract 'pieces' (required)
    BencodeValue* pieces_val = bencode::dict_get_required(bencode::BencodeType.STRING, info_val, "pieces", TORRENT_MISSING_FIELD)!;

    // Validate pieces length (must be multiple of SHA1_HASH_SIZE)
    if (pieces_val.string.len % common::SHA1_HASH_SIZE != 0)
    {
        return TORRENT_INVALID_INFO?;
    }

    info.pieces = copy_bytes(arena, pieces_val.string);

    // Extract 'private' (optional - BEP 27)
    // If private=1, DHT and PEX must be disabled
    BencodeValue* private_val = info_val.dict_get("private");
    if (private_val && private_val.type == bencode::BencodeType.INTEGER)
    {
        info.private = (private_val.integer == 1);
    }
    else
    {
        info.private = false;  // Default to public torrent
    }

    // BEP 52: Extract 'meta version' (optional - indicates v2/hybrid torrent)
    BencodeValue* meta_version_val = info_val.dict_get("meta version");
    if (meta_version_val && meta_version_val.type == bencode::BencodeType.INTEGER)
    {
        info.meta_version = (int)meta_version_val.integer;
        info.is_v2 = (info.meta_version == 2);
    }
    else
    {
        // Default to v1 (no meta version field = v1 torrent)
        info.meta_version = 1;
        info.is_v2 = false;
    }

    // BEP 52: Extract 'file tree' (v2 torrents only)
    BencodeValue* file_tree_val = info_val.dict_get("file tree");
    if (file_tree_val && file_tree_val.type == bencode::BencodeType.DICT)
    {
        // v2 torrent detected
        info.is_v2 = true;

        // Parse file tree (this populates info.files with v2 metadata)
        parse_file_tree(arena, info, file_tree_val)!;

        // BEP 52: Extract 'piece layers' (required for v2)
        BencodeValue* piece_layers_val = info_val.dict_get("piece layers");
        if (piece_layers_val && piece_layers_val.type == bencode::BencodeType.DICT)
        {
            parse_piece_layers(arena, info, piece_layers_val)!;
        }
    }

    return {};  // Success
}

/**
 * Check if a path component contains invalid characters or sequences.
 * This validates against directory traversal attacks and malformed paths.
 *
 * @param component Path component to validate
 * @return true if invalid, false if valid
 */
fn bool is_invalid_path_component(String component)
{
    // Empty path components are invalid
    if (component.len == 0) return true;

    // Reject relative path components (. and ..)
    if (component == "." || component == "..") return true;

    // Reject paths containing directory separators
    if (component.contains("/") || component.contains("\\")) return true;

    // Reject absolute paths (starting with / or \)
    if (component.starts_with("/") || component.starts_with("\\")) return true;

    return false;
}

/**
 * Validate symlink path components for security (BEP 47).
 *
 * Ensures symlink targets cannot escape the torrent directory.
 *
 * @param components Symlink path components to validate
 * @return Fault if validation fails
 */
fn fault? validate_symlink_path(String[] components)
{
    foreach (component : components)
    {
        // BEP 47: Symlink path must not contain ".." elements
        if (component == "..")
        {
            return TORRENT_SYMLINK_ESCAPE?;
        }

        // Apply existing path component validation
        // (rejects empty, ".", "/", "\", absolute paths)
        if (is_invalid_path_component(component))
        {
            return TORRENT_INVALID_PATH?;
        }
    }
    return {};
}

/**
 * Parse the 'files' list from a multi-file torrent.
 *
 * @param arena Arena allocator for persistent allocations
 * @param info Pointer to TorrentInfo to fill
 * @param files_val The 'files' BencodeValue list
 * @return Fault if parsing fails
 */
fn fault? parse_files_list(Allocator arena, TorrentInfo* info, BencodeValue* files_val)
{
    usz num_files = files_val.list.size;

    // Validate: must have at least one file
    if (num_files == 0)
    {
        return TORRENT_INVALID_INFO?;
    }

    // Allocate files array from arena
    info.files = allocator::new_array(arena, FileEntry, num_files);
    info.length = 0;  // Will accumulate total length

    // Parse each file
    for (usz i = 0; i < num_files; i++)
    {
        BencodeValue* file_dict = files_val.list.get(i);
        if (file_dict.type != bencode::BencodeType.DICT)
        {
            return TORRENT_INVALID_INFO?;
        }

        FileEntry* file = &info.files[i];

        // Extract 'length' (required)
        BencodeValue* length = bencode::dict_get_required(bencode::BencodeType.INTEGER, file_dict, "length", TORRENT_MISSING_FIELD)!;

        file.length = length.integer;

        // Validate length is non-negative (zero-length files are allowed)
        if (file.length < 0)
        {
            return TORRENT_INVALID_INFO?;
        }

        // Set offset and accumulate total length
        file.offset = info.length;
        info.length += file.length;

        // Extract 'path' (required)
        BencodeValue* path = bencode::dict_get_required(bencode::BencodeType.LIST, file_dict, "path", TORRENT_MISSING_FIELD)!;

        // Validate path has at least one component
        if (path.list.size == 0)
        {
            return TORRENT_INVALID_INFO?;
        }

        // Allocate path array from arena
        file.path = allocator::new_array(arena, String, path.list.size);

        // Copy path components
        foreach (j, component : path.list)
        {
            if (component.type != bencode::BencodeType.STRING)
            {
                return TORRENT_INVALID_INFO?;
            }

            // Validate path component for security
            if (is_invalid_path_component((String)component.string))
            {
                return TORRENT_INVALID_PATH?;
            }

            // Sanitize each path component (returns heap allocation)
            String? sanitized_component = path_sanitize::sanitize_torrent_path((String)component.string);
            if (catch err = sanitized_component)
            {
                // Sanitization failed - copy to arena
                file.path[j] = copy_string(arena, (char[])component.string);
            }
            else
            {
                // Copy sanitized string to arena, then free heap copy
                file.path[j] = copy_string(arena, sanitized_component);
                free(sanitized_component);
            }
        }

        // BEP 47: Parse optional 'attr' field (file attributes)
        BencodeValue* attr_val = file_dict.dict_get("attr");
        if (attr_val && attr_val.type == bencode::BencodeType.STRING)
        {
            // Copy attr string to arena
            file.attr = copy_string(arena, (char[])attr_val.string);

            // BEP 47: If symlink attribute present, parse symlink path
            bool has_symlink = false;
            foreach (c : attr_val.string)
            {
                if (c == 'l') { has_symlink = true; break; }
            }
            if (has_symlink)
            {
                BencodeValue* symlink_val = file_dict.dict_get("symlink path");
                if (!symlink_val || symlink_val.type != bencode::BencodeType.LIST)
                {
                    return TORRENT_INVALID_SYMLINK?;  // Symlinks require 'symlink path' field
                }

                // Validate symlink path has at least one component
                if (symlink_val.list.size == 0)
                {
                    return TORRENT_INVALID_SYMLINK?;
                }

                // Allocate symlink path array from arena
                file.symlink_path = allocator::new_array(arena, String, symlink_val.list.size);

                // Parse and validate symlink path components
                foreach (k, component : symlink_val.list)
                {
                    if (component.type != bencode::BencodeType.STRING)
                    {
                        return TORRENT_INVALID_SYMLINK?;  // All path components must be strings
                    }

                    // Copy component to arena
                    file.symlink_path[k] = copy_string(arena, (char[])component.string);
                }

                // Validate symlink path for security
                validate_symlink_path(file.symlink_path)!;
            }
        }

        // BEP 47: Parse optional 'sha1' field (file hash for deduplication)
        BencodeValue* sha1_val = file_dict.dict_get("sha1");
        if (sha1_val && sha1_val.type == bencode::BencodeType.STRING && sha1_val.string.len == 20)
        {
            // Copy 20-byte SHA1 hash
            foreach (k, c : sha1_val.string[:20])
            {
                file.sha1[k] = c;
            }
            file.has_sha1 = true;
        }
    }

    return {};  // Success
}

// ============================================================================
// BEP 52: v2 Torrent Parsing Functions
// ============================================================================

/**
 * Parse BEP 52 file tree (recursive helper).
 * Traverses nested dictionaries to extract file entries with v2 metadata.
 *
 * File tree structure (BEP 52):
 *   "dir1": {
 *     "file.txt": {
 *       "": {                    // Empty string key contains file metadata
 *         "length": 1234,
 *         "pieces root": <32-byte SHA-256 hash>
 *       }
 *     }
 *   }
 *
 * @param arena: Allocator for file entry allocations
 * @param tree_node: Current node in the file tree (dictionary)
 * @param path_components: List of accumulated path components
 * @param files: Accumulator for extracted file entries
 * @param total_length: Accumulator for total torrent size
 * @return: Fault if parsing fails
 */
fn fault? parse_file_tree_recursive(Allocator arena, BencodeValue* tree_node, List{String}* path_components, List{FileEntry}* files, long* total_length)
{
    if (tree_node.type != bencode::BencodeType.DICT) return TORRENT_INVALID_FORMAT?;

    // Iterate over dictionary entries
    foreach (entry : tree_node.dict.entries())
    {
        String key = entry.key;
        BencodeValue* value = entry.value;

        if (key.len == 0)
        {
            // Empty string key "" - this is a file metadata node
            if (value.type != bencode::BencodeType.DICT) return TORRENT_INVALID_FORMAT?;

            // Extract file metadata
            BencodeValue* length_val = bencode::dict_get_required(bencode::BencodeType.INTEGER, value, "length", TORRENT_MISSING_FIELD)!;
            BencodeValue* pieces_root_val = bencode::dict_get_required(bencode::BencodeType.STRING, value, "pieces root", TORRENT_MISSING_FIELD)!;

            // Validate pieces_root is 32 bytes
            if (pieces_root_val.string.len != common::SHA256_HASH_SIZE)
            {
                return TORRENT_INVALID_FORMAT?;
            }

            // Create file entry
            FileEntry file;
            file.length = length_val.integer;
            file.offset = *total_length;
            *total_length += file.length;

            // Copy path components to file entry
            file.path = allocator::new_array(arena, String, path_components.len());
            foreach (i, component : *path_components)
            {
                file.path[i] = copy_string(arena, component);
            }

            // Copy pieces_root hash
            foreach (i, byte : pieces_root_val.string[:common::SHA256_HASH_SIZE])
            {
                file.pieces_root[i] = byte;
            }
            file.has_pieces_root = true;

            // Add file to list
            files.push(file);
        }
        else
        {
            // Non-empty key - this is a directory or file name
            // Recursively traverse this subtree
            path_components.push(key);
            parse_file_tree_recursive(arena, value, path_components, files, total_length)!;
            path_components.pop()!!;  // Remove path component after recursion
        }
    }

    return {};
}

/**
 * Parse BEP 52 "file tree" dictionary to extract v2 file entries.
 *
 * @param arena: Allocator for file entry allocations
 * @param info: TorrentInfo to populate with files
 * @param file_tree_val: "file tree" bencode dictionary
 * @return: Fault if parsing fails
 */
fn fault? parse_file_tree(Allocator arena, TorrentInfo* info, BencodeValue* file_tree_val) => @pool()
{
    if (file_tree_val.type != bencode::BencodeType.DICT) return TORRENT_INVALID_FORMAT?;

    // Use temp allocator for temporary path components list
    List{String} path_components;
    path_components.init(tmem);

    List{FileEntry} files;
    files.init(tmem);

    long total_length = 0;

    // Recursively parse file tree
    parse_file_tree_recursive(arena, file_tree_val, &path_components, &files, &total_length)!;

    // Validate: must have at least one file
    if (files.len() == 0) return TORRENT_INVALID_INFO?;

    // Copy file list to arena
    info.files = allocator::new_array(arena, FileEntry, files.len());
    foreach (i, file : files)
    {
        info.files[i] = file;
    }
    info.length = total_length;
    info.is_multi_file = (files.len() > 1);

    return {};
}

/**
 * Parse BEP 52 "piece layers" dictionary to validate and count entries.
 *
 * Piece layers structure (BEP 52):
 *   {
 *     <32-byte pieces_root>: <concatenated 32-byte piece hashes>,
 *     ...
 *   }
 *
 * Each entry maps a file's pieces_root hash to its Merkle tree layer hashes.
 * For now, we just validate the structure. Merkle trees will be built on-demand.
 *
 * @param arena: Allocator for allocations
 * @param info: TorrentInfo with parsed files (must have pieces_root for each file)
 * @param piece_layers_val: "piece layers" bencode dictionary
 * @return: Fault if parsing fails
 */
fn fault? parse_piece_layers(Allocator arena, TorrentInfo* info, BencodeValue* piece_layers_val)
{
    if (piece_layers_val.type != bencode::BencodeType.DICT) return TORRENT_INVALID_FORMAT?;

    // Allocate Merkle tree array (one per file) - will be populated on-demand
    info.piece_layers = allocator::new_array(arena, merkle_tree::MerkleTree*, info.files.len);

    // Initialize all to null - Merkle trees will be built on-demand when needed
    foreach (i, file : info.files)
    {
        info.piece_layers[i] = null;
    }

    // Validate piece layers structure
    foreach (entry : piece_layers_val.dict.entries())
    {
        // Validate key is 32 bytes (pieces_root hash)
        if (entry.key.len != common::SHA256_HASH_SIZE)
        {
            return TORRENT_INVALID_FORMAT?;
        }

        // Validate value is a string (concatenated hashes)
        if (entry.value.type != bencode::BencodeType.STRING)
        {
            return TORRENT_INVALID_FORMAT?;
        }

        // Validate layer data is multiple of SHA256_HASH_SIZE
        if (entry.value.string.len % common::SHA256_HASH_SIZE != 0)
        {
            return TORRENT_INVALID_FORMAT?;
        }
    }

    return {};
}

/**
 * Calculate BEP 52 v2 info hash (SHA-256 of bencoded info dict).
 *
 * @param info_dict_bencode: Raw bencoded info dictionary bytes
 * @return: 32-byte SHA-256 hash
 */
fn common::InfoHashV2 calculate_info_hash_v2(char[] info_dict_bencode) => @pool()
{
    // Compute SHA-256 hash of the raw bencode data
    Sha256 hasher;
    hasher.init();
    hasher.update(info_dict_bencode);

    common::InfoHashV2 hash;
    char[32] hash_result = hasher.final();
    foreach (i, byte : hash_result[:common::SHA256_HASH_SIZE])
    {
        hash[i] = byte;
    }

    return hash;
}

/**
 * Helper: Percent-encode URLs for BEP 17/19 compliance.
 * Uses standard library URL encoding for proper RFC 3986 compliance.
 */
fn String percent_encode_url(String url_str)
{
    // Use PATH encoding mode which allows most URL characters
    // but encodes spaces and other special characters
    return url::encode(mem, url_str, url::UrlEncodingMode.PATH);
}

/**
 * Helper: Trim leading and trailing whitespace from URLs.
 * This handles tabs, spaces, newlines, and carriage returns.
 */
fn String trim_whitespace(Allocator allocator, String url)
{
    if (url.len == 0) return copy_string(allocator, (char[])url);

    // Find first non-whitespace character
    usz start = 0;
    while (start < url.len)
    {
        char c = url[start];
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r')
        {
            break;
        }
        start++;
    }

    // If all whitespace, return empty string
    if (start >= url.len)
    {
        return (String)allocator::new_array(allocator, char, 0);
    }

    // Find last non-whitespace character
    usz end = url.len - 1;
    while (end > start)
    {
        char c = url[end];
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r')
        {
            break;
        }
        end--;
    }

    // Calculate trimmed length
    usz trimmed_len = end - start + 1;
    char[] trimmed = allocator::new_array(allocator, char, trimmed_len);

    // Copy trimmed portion
    for (usz i = 0; i < trimmed_len; i++)
    {
        trimmed[i] = url[start + i];
    }

    return (String)trimmed;
}

/**
 * Helper: Check if a string contains null bytes.
 * Returns true if any null byte is found, false otherwise.
 */
fn bool contains_null_bytes(String str)
{
    for (usz i = 0; i < str.len; i++)
    {
        if (str[i] == 0) return true;
    }
    return false;
}


/**
 * Helper: Copy a string to persistent memory.
 */
fn String copy_string(Allocator allocator, char[] source)
{
    char[] copy = allocator::new_array(allocator, char, source.len);
    foreach (i, c : source)
    {
        copy[i] = c;
    }
    return (String)copy;
}

/**
 * Helper: Copy bytes to persistent memory.
 */
fn char[] copy_bytes(Allocator allocator, char[] source)
{
    char[] copy = allocator::new_array(allocator, char, source.len);
    foreach (i, c : source)
    {
        copy[i] = c;
    }
    return copy;
}

/**
 * Free a TorrentFile and all its contents.
 *
 * Frees all torrent metadata in ONE operation using arena allocator.
 * This replaces 100+ lines of nested cleanup with single bulk free.
 */
fn void TorrentFile.free(&self) @public
{
    self.arena.free();

    free(self);
}

/**
 * Get the number of pieces in a torrent.
 */
fn usz TorrentFile.get_num_pieces(&self) @public
{
    return self.info.pieces.len / common::SHA1_HASH_SIZE;
}

/**
 * Get a specific piece hash by index.
 *
 * @param index Piece index (0-based)
 * @return SHA1_HASH_SIZE-byte SHA1 hash or fault if index out of bounds
 */
fn char[]? TorrentFile.get_piece_hash(&self, usz index) @public
{
    usz num_pieces = self.get_num_pieces();
    if (index >= num_pieces) return TORRENT_INDEX_OUT_OF_BOUNDS?;

    usz offset = index * common::SHA1_HASH_SIZE;
    char[common::SHA1_HASH_SIZE] hash;
    foreach (i, byte : self.info.pieces[offset:common::SHA1_HASH_SIZE])
    {
        hash[i] = byte;
    }
    return hash[..];
}

/**
 * Calculate the number of pieces in a torrent.
 *
 * Uses ceiling division: (length + piece_length - 1) / piece_length
 *
 * @return Number of pieces
 */
fn uint TorrentInfo.calculate_num_pieces(&self) @public
{
    return (uint)((self.length + self.piece_length - 1) / self.piece_length);
}

/**
 * Calculate the length of the last piece in a torrent.
 *
 * The last piece may be shorter than piece_length if the file
 * size is not evenly divisible by piece_length.
 *
 * @return Length of the last piece in bytes
 */
fn uint TorrentInfo.calculate_last_piece_length(&self) @public
{
    uint last_piece_length = (uint)(self.length % self.piece_length);
    if (last_piece_length == 0)
    {
        // If evenly divisible, last piece is full size
        last_piece_length = (uint)self.piece_length;
    }
    return last_piece_length;
}
