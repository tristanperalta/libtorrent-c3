module libtorrent::metainfo;

import std::io;
import std::hash::sha1;
import std::encoding::hex;
import std::net::url;
import std::collections::list;
import std::collections::set;
import libtorrent::bencode;
import libtorrent::path_sanitize;
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
    char[20] info_hash;     // SHA1 hash of bencoded info dict
}

/**
 * Faults for torrent parsing errors
 */
faultdef TORRENT_INVALID_FORMAT;
faultdef TORRENT_MISSING_FIELD;
faultdef TORRENT_INVALID_INFO;
faultdef TORRENT_INDEX_OUT_OF_BOUNDS;
faultdef TORRENT_INVALID_PATH;

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
    defer bencode::free_bencode_value(root);

    // Root must be a dictionary
    if (root.type != bencode::BencodeType.DICT)
    {
        return TORRENT_INVALID_FORMAT?;
    }

    // Allocate result
    TorrentFile* torrent = mem::new(TorrentFile);

    // Extract 'announce' (optional - may be missing in some torrents)
    BencodeValue* announce_val = bencode::dict_get(root, "announce");
    if (announce_val && announce_val.type == bencode::BencodeType.STRING)
    {
        // Trim whitespace from announce URL
        torrent.announce = trim_whitespace((String)announce_val.string);
    }

    // Extract 'announce-list' (optional - BEP 12 multi-tracker)
    BencodeValue* announce_list_val = bencode::dict_get(root, "announce-list");
    if (announce_list_val && announce_list_val.type == bencode::BencodeType.LIST)
    {
        usz num_tiers = announce_list_val.list.size;
        if (num_tiers > 0)
        {
            // Allocate array of tiers
            torrent.announce_list = mem::new_array(String[], num_tiers);

            for (usz i = 0; i < num_tiers; i++)
            {
                BencodeValue* tier = announce_list_val.list.get(i);
                if (tier.type == bencode::BencodeType.LIST)
                {
                    usz num_trackers = tier.list.size;
                    if (num_trackers > 0)
                    {
                        // Allocate array of tracker URLs for this tier
                        torrent.announce_list[i] = mem::new_array(String, num_trackers);

                        for (usz j = 0; j < num_trackers; j++)
                        {
                            BencodeValue* tracker = tier.list.get(j);
                            if (tracker.type == bencode::BencodeType.STRING)
                            {
                                // Trim whitespace from tracker URLs
                                torrent.announce_list[i][j] = trim_whitespace((String)tracker.string);
                            }
                        }
                    }
                }
            }
        }
    }

    // Extract 'nodes' (optional - BEP 5 DHT bootstrap nodes)
    BencodeValue* nodes_val = bencode::dict_get(root, "nodes");
    if (nodes_val && nodes_val.type == bencode::BencodeType.LIST)
    {
        usz num_nodes = nodes_val.list.size;
        if (num_nodes > 0)
        {
            torrent.nodes = mem::new_array(DhtNode, num_nodes);

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
                        torrent.nodes[i].host = copy_string(host.string);
                        torrent.nodes[i].port = (ushort)port.integer;
                    }
                }
            }
        }
    }

    // Extract 'collections' (optional - BEP 38)
    // Can be in root dictionary or info dictionary (merge both)
    BencodeValue* collections_val = bencode::dict_get(root, "collections");
    if (collections_val && collections_val.type == bencode::BencodeType.LIST)
    {
        usz count = collections_val.list.size;
        if (count > 0)
        {
            torrent.collections = mem::new_array(String, count);
            for (usz i = 0; i < count; i++)
            {
                BencodeValue* collection = collections_val.list.get(i);
                if (collection.type == bencode::BencodeType.STRING)
                {
                    torrent.collections[i] = copy_string(collection.string);
                }
            }
        }
    }

    // Extract 'similar' (optional - BEP 38)
    // List of info-hashes (20-byte binary strings)
    BencodeValue* similar_val = bencode::dict_get(root, "similar");
    if (similar_val && similar_val.type == bencode::BencodeType.LIST)
    {
        usz count = similar_val.list.size;
        if (count > 0)
        {
            torrent.similar_count = count;
            torrent.similar = mem::new_array(char, count * common::SHA1_HASH_SIZE);
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
    BencodeValue* created_by_val = bencode::dict_get(root, "created by");
    if (created_by_val && created_by_val.type == bencode::BencodeType.STRING)
    {
        torrent.created_by = copy_string(created_by_val.string);
    }

    // Extract 'creation date' (optional)
    BencodeValue* creation_date_val = bencode::dict_get(root, "creation date");
    if (creation_date_val && creation_date_val.type == bencode::BencodeType.INTEGER)
    {
        torrent.creation_date = creation_date_val.integer;
    }

    // Extract 'encoding' (optional)
    BencodeValue* encoding_val = bencode::dict_get(root, "encoding");
    if (encoding_val && encoding_val.type == bencode::BencodeType.STRING)
    {
        torrent.encoding = copy_string(encoding_val.string);
    }

    // Extract 'url-list' (optional - BEP 19)
    // Can be either a single string or a list of strings
    // Deduplicates URLs to avoid redundant requests
    BencodeValue* url_list_val = bencode::dict_get(root, "url-list");
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

                    // Percent-encode spaces for BEP 19 compliance
                    String encoded_url = percent_encode_url(url_str);
                    bool keep = false;
                    defer if (!keep) free(encoded_url);

                    // Only add if not already seen and not empty
                    if (encoded_url.len > 0 && !seen_urls.contains(encoded_url))
                    {
                        seen_urls.add(encoded_url);
                        urls.push(encoded_url);
                        keep = true;  // Ownership transferred to collection
                    }
                }
            }

            // Convert List to array (to_array copies, so we still need to free List)
            if (urls.size > 0)
            {
                torrent.url_list = urls.to_array(mem);
            }
        }
        else if (url_list_val.type == bencode::BencodeType.STRING)
        {
            // Single URL seed - percent-encode spaces
            String url_str = (String)url_list_val.string;
            if (url_str.len > 0)
            {
                String encoded_url = percent_encode_url(url_str);
                bool keep = false;
                defer if (!keep) free(encoded_url);

                if (encoded_url.len > 0)
                {
                    torrent.url_list = mem::new_array(String, 1);
                    torrent.url_list[0] = encoded_url;
                    keep = true;  // Ownership transferred to array
                }
            }
        }
    }

    // Extract 'httpseeds' (optional - BEP 17)
    // Deduplicates URLs and checks against url_list to avoid cross-list duplicates
    BencodeValue* httpseeds_val = bencode::dict_get(root, "httpseeds");
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

                // Percent-encode spaces for BEP 17 compliance
                String encoded_seed = percent_encode_url(seed_str);
                bool keep = false;
                defer if (!keep) free(encoded_seed);

                // Only add if not already seen and not empty
                if (encoded_seed.len > 0 && !seen_seeds.contains(encoded_seed))
                {
                    seen_seeds.add(encoded_seed);
                    seeds.push(encoded_seed);
                    keep = true;  // Ownership transferred to collection
                }
            }
        }

        // Convert List to array (to_array copies, so we still need to free List)
        if (seeds.size > 0)
        {
            torrent.httpseeds = seeds.to_array(mem);
        }
    }

    // Extract 'info' dictionary (required)
    BencodeValue* info_val = bencode::dict_get(root, "info");
    if (!info_val || info_val.type != bencode::BencodeType.DICT)
    {
        free_torrent_file(torrent);
        return TORRENT_MISSING_FIELD?;
    }

    // Parse info dictionary
    if (catch err = parse_info(&torrent.info, info_val))
    {
        free_torrent_file(torrent);
        return err?;
    }

    // Calculate info_hash (SHA1 of bencoded info dict)
    String info_encoded = bencode::encode(info_val);
    defer free(info_encoded);  // bencode::encode() returns heap memory
    torrent.info_hash = sha1::hash(info_encoded);

    // Validate torrent name (BEP 3 compliance)
    // If name is empty, ".", or "..", use info-hash as name
    // Note: Null bytes and path traversal within names are handled by path sanitization
    bool is_invalid = torrent.info.name.len == 0 ||
                     (torrent.info.name.len == 1 && torrent.info.name[0] == '.') ||
                     (torrent.info.name.len == 2 && torrent.info.name[0] == '.' && torrent.info.name[1] == '.');
    if (is_invalid)
    {
        // Replace with info-hash hex using stdlib hex::tencode()
        // Must copy to heap with malloc() because @pool() memory gets freed when function returns
        // First free the old name (which was allocated when sanitization failed)
        free(torrent.info.name);
        String temp_hex = hex::tencode(torrent.info_hash[..]);
        char* hex_persistent = (char*)malloc(temp_hex.len);
        foreach (i, c : temp_hex) hex_persistent[i] = c;
        torrent.info.name = (String)hex_persistent[:temp_hex.len];
    }

    return torrent;
}

/**
 * Parse the 'info' dictionary from a torrent.
 *
 * @param info Pointer to TorrentInfo to fill
 * @param info_val The 'info' BencodeValue dictionary
 * @return Fault if parsing fails
 */
fn fault? parse_info(TorrentInfo* info, BencodeValue* info_val)
{
    // Extract 'name' (required)
    BencodeValue* name_val = bencode::dict_get_required(bencode::BencodeType.STRING, info_val, "name", TORRENT_MISSING_FIELD)!;

    // Validate name for security (reject directory traversal, absolute paths, etc.)
    if (is_invalid_path_component((String)name_val.string))
    {
        return TORRENT_INVALID_PATH?;
    }

    // Sanitize the torrent name for filesystem safety
    String? sanitized_name_opt = path_sanitize::sanitize_torrent_path((String)name_val.string);
    if (catch err = sanitized_name_opt)
    {
        // Sanitization failed (e.g., name is "." or "..") - copy to heap using malloc, will be replaced with hash later
        // Must use explicit heap allocation (not pool) so memory persists after parse() returns
        char* raw = (char*)malloc(name_val.string.len);
        foreach (i, c : name_val.string) raw[i] = c;
        info.name = (String)raw[:name_val.string.len];
    }
    else
    {
        // Use sanitized string directly (it's heap-allocated)
        // After the catch check, sanitized_name_opt is automatically unwrapped to String
        info.name = sanitized_name_opt;
    }

    // Check for single-file vs multi-file mode
    BencodeValue* length_val = bencode::dict_get(info_val, "length");
    BencodeValue* files_val = bencode::dict_get(info_val, "files");

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

        // Parse files list
        if (catch err = parse_files_list(info, files_val))
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

    info.pieces = copy_bytes(pieces_val.string);

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
 * Parse the 'files' list from a multi-file torrent.
 *
 * @param info Pointer to TorrentInfo to fill
 * @param files_val The 'files' BencodeValue list
 * @return Fault if parsing fails
 */
fn fault? parse_files_list(TorrentInfo* info, BencodeValue* files_val)
{
    usz num_files = files_val.list.size;

    // Validate: must have at least one file
    if (num_files == 0)
    {
        return TORRENT_INVALID_INFO?;
    }

    // Allocate files array
    info.files = mem::new_array(FileEntry, num_files);
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

        // Allocate path array
        file.path = mem::new_array(String, path.list.size);

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

            // Sanitize each path component
            String? sanitized_component = path_sanitize::sanitize_torrent_path((String)component.string);
            if (catch err = sanitized_component)
            {
                // Sanitization failed - copy to heap using malloc to avoid pool allocation issues
                char* raw = (char*)malloc(component.string.len);
                foreach (k, c : component.string) raw[k] = c;
                file.path[j] = (String)raw[:component.string.len];
            }
            else
            {
                // Use sanitized string directly (it's heap-allocated)
                file.path[j] = sanitized_component;
            }
        }
    }

    return {};  // Success
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
fn String trim_whitespace(String url)
{
    if (url.len == 0) return copy_string((char[])url);

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
        return (String)mem::new_array(char, 0);
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
    char[] trimmed = mem::new_array(char, trimmed_len);

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
fn String copy_string(char[] source)
{
    char[] copy = mem::new_array(char, source.len);
    foreach (i, c : source)
    {
        copy[i] = c;
    }
    return (String)copy;
}

/**
 * Helper: Copy bytes to persistent memory.
 */
fn char[] copy_bytes(char[] source)
{
    char[] copy = mem::new_array(char, source.len);
    foreach (i, c : source)
    {
        copy[i] = c;
    }
    return copy;
}

/**
 * Free a TorrentFile and all its contents.
 */
fn void free_torrent_file(TorrentFile* torrent) @public
{
    if (!torrent) return;

    if (torrent.announce.len > 0) free(torrent.announce);

    // Free announce-list (multi-tracker)
    if (torrent.announce_list.len > 0)
    {
        foreach (tier : torrent.announce_list)
        {
            if (tier.len > 0)
            {
                // Free each tracker URL in this tier
                foreach (url : tier)
                {
                    if (url.len > 0) free(url);
                }
                free(tier);
            }
        }
        free(torrent.announce_list);
    }

    // Free DHT nodes
    if (torrent.nodes.len > 0)
    {
        foreach (node : torrent.nodes)
        {
            if (node.host.len > 0) free(node.host);
        }
        free(torrent.nodes);
    }

    // Free collections (BEP 38)
    if (torrent.collections.len > 0)
    {
        foreach (collection : torrent.collections)
        {
            if (collection.len > 0) free(collection);
        }
        free(torrent.collections);
    }

    // Free similar info-hashes (BEP 38)
    if (torrent.similar.len > 0)
    {
        free(torrent.similar);
    }

    if (torrent.created_by.len > 0) free(torrent.created_by);
    if (torrent.encoding.len > 0) free(torrent.encoding);

    // Free web seeds
    if (torrent.url_list.len > 0)
    {
        foreach (url : torrent.url_list)
        {
            if (url.len > 0) free(url);
        }
        free(torrent.url_list);
    }

    if (torrent.httpseeds.len > 0)
    {
        foreach (seed : torrent.httpseeds)
        {
            if (seed.len > 0) free(seed);
        }
        free(torrent.httpseeds);
    }

    if (torrent.info.name.len > 0) free(torrent.info.name);
    if (torrent.info.pieces.len > 0) free(torrent.info.pieces);

    // Free multi-file data
    if (torrent.info.is_multi_file && torrent.info.files.len > 0)
    {
        foreach (file : torrent.info.files)
        {
            if (file.path.len > 0)
            {
                // Free each path component
                foreach (path_component : file.path)
                {
                    if (path_component.len > 0) free(path_component);
                }
                free(file.path);
            }
        }
        free(torrent.info.files);
    }

    free(torrent);
}

/**
 * Get the number of pieces in a torrent.
 */
fn usz get_num_pieces(TorrentFile* torrent) @public
{
    return torrent.info.pieces.len / common::SHA1_HASH_SIZE;
}

/**
 * Get a specific piece hash by index.
 *
 * @param torrent The torrent file
 * @param index Piece index (0-based)
 * @return SHA1_HASH_SIZE-byte SHA1 hash or fault if index out of bounds
 */
fn char[]? get_piece_hash(TorrentFile* torrent, usz index) @public
{
    usz num_pieces = get_num_pieces(torrent);
    if (index >= num_pieces) return TORRENT_INDEX_OUT_OF_BOUNDS?;

    usz offset = index * common::SHA1_HASH_SIZE;
    char[common::SHA1_HASH_SIZE] hash;
    foreach (i, byte : torrent.info.pieces[offset:common::SHA1_HASH_SIZE])
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
 * @param info Torrent info dictionary
 * @return Number of pieces
 */
fn uint calculate_num_pieces(TorrentInfo* info) @public
{
    return (uint)((info.length + info.piece_length - 1) / info.piece_length);
}

/**
 * Calculate the length of the last piece in a torrent.
 *
 * The last piece may be shorter than piece_length if the file
 * size is not evenly divisible by piece_length.
 *
 * @param info Torrent info dictionary
 * @return Length of the last piece in bytes
 */
fn uint calculate_last_piece_length(TorrentInfo* info) @public
{
    uint last_piece_length = (uint)(info.length % info.piece_length);
    if (last_piece_length == 0)
    {
        // If evenly divisible, last piece is full size
        last_piece_length = (uint)info.piece_length;
    }
    return last_piece_length;
}
