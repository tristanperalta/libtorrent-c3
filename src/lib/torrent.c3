module libtorrent::torrent;

import std::io;
import std::hash::sha1;
import libtorrent::bencode;

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
        torrent.announce = copy_string(announce_val.string);
    }

    // Extract 'announce-list' (optional - BEP 12 multi-tracker)
    BencodeValue* announce_list_val = bencode::dict_get(root, "announce-list");
    if (announce_list_val && announce_list_val.type == bencode::BencodeType.LIST)
    {
        usz num_tiers = announce_list_val.list.len;
        if (num_tiers > 0)
        {
            // Allocate array of tiers
            torrent.announce_list = mem::new_array(String[], num_tiers);

            for (usz i = 0; i < num_tiers; i++)
            {
                BencodeValue* tier = announce_list_val.list[i];
                if (tier.type == bencode::BencodeType.LIST)
                {
                    usz num_trackers = tier.list.len;
                    if (num_trackers > 0)
                    {
                        // Allocate array of tracker URLs for this tier
                        torrent.announce_list[i] = mem::new_array(String, num_trackers);

                        for (usz j = 0; j < num_trackers; j++)
                        {
                            BencodeValue* tracker = tier.list[j];
                            if (tracker.type == bencode::BencodeType.STRING)
                            {
                                torrent.announce_list[i][j] = copy_string(tracker.string);
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
        usz num_nodes = nodes_val.list.len;
        if (num_nodes > 0)
        {
            torrent.nodes = mem::new_array(DhtNode, num_nodes);

            for (usz i = 0; i < num_nodes; i++)
            {
                BencodeValue* node = nodes_val.list[i];
                if (node.type == bencode::BencodeType.LIST && node.list.len == 2)
                {
                    // Each node is [host_string, port_integer]
                    BencodeValue* host = node.list[0];
                    BencodeValue* port = node.list[1];

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
        usz count = collections_val.list.len;
        if (count > 0)
        {
            torrent.collections = mem::new_array(String, count);
            for (usz i = 0; i < count; i++)
            {
                BencodeValue* collection = collections_val.list[i];
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
        usz count = similar_val.list.len;
        if (count > 0)
        {
            torrent.similar_count = count;
            torrent.similar = mem::new_array(char, count * 20);
            for (usz i = 0; i < count; i++)
            {
                BencodeValue* info_hash = similar_val.list[i];
                if (info_hash.type == bencode::BencodeType.STRING &&
                    info_hash.string.len == 20)
                {
                    // Copy 20-byte info-hash to flat array
                    usz offset = i * 20;
                    for (usz j = 0; j < 20; j++)
                    {
                        torrent.similar[offset + j] = info_hash.string[j];
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
    BencodeValue* url_list_val = bencode::dict_get(root, "url-list");
    if (url_list_val)
    {
        if (url_list_val.type == bencode::BencodeType.LIST)
        {
            // List of URL seeds
            usz count = url_list_val.list.len;
            if (count > 0)
            {
                torrent.url_list = mem::new_array(String, count);
                for (usz i = 0; i < count; i++)
                {
                    BencodeValue* url = url_list_val.list[i];
                    if (url.type == bencode::BencodeType.STRING)
                    {
                        torrent.url_list[i] = copy_string(url.string);
                    }
                }
            }
        }
        else if (url_list_val.type == bencode::BencodeType.STRING)
        {
            // Single URL seed
            torrent.url_list = mem::new_array(String, 1);
            torrent.url_list[0] = copy_string(url_list_val.string);
        }
    }

    // Extract 'httpseeds' (optional - BEP 17)
    BencodeValue* httpseeds_val = bencode::dict_get(root, "httpseeds");
    if (httpseeds_val && httpseeds_val.type == bencode::BencodeType.LIST)
    {
        usz count = httpseeds_val.list.len;
        if (count > 0)
        {
            torrent.httpseeds = mem::new_array(String, count);
            for (usz i = 0; i < count; i++)
            {
                BencodeValue* seed = httpseeds_val.list[i];
                if (seed.type == bencode::BencodeType.STRING)
                {
                    torrent.httpseeds[i] = copy_string(seed.string);
                }
            }
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
    defer free(info_encoded);
    torrent.info_hash = sha1::hash(info_encoded);

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
    BencodeValue* name_val = bencode::dict_get(info_val, "name");
    if (!name_val || name_val.type != bencode::BencodeType.STRING)
    {
        return TORRENT_MISSING_FIELD?;
    }
    info.name = copy_string(name_val.string);

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
    BencodeValue* piece_length_val = bencode::dict_get(info_val, "piece length");
    if (!piece_length_val || piece_length_val.type != bencode::BencodeType.INTEGER)
    {
        return TORRENT_MISSING_FIELD?;
    }
    info.piece_length = piece_length_val.integer;

    // Validate piece_length is positive
    if (info.piece_length <= 0)
    {
        return TORRENT_INVALID_INFO?;
    }

    // Extract 'pieces' (required)
    BencodeValue* pieces_val = bencode::dict_get(info_val, "pieces");
    if (!pieces_val || pieces_val.type != bencode::BencodeType.STRING)
    {
        return TORRENT_MISSING_FIELD?;
    }

    // Validate pieces length (must be multiple of 20)
    if (pieces_val.string.len % 20 != 0)
    {
        return TORRENT_INVALID_INFO?;
    }

    info.pieces = copy_bytes(pieces_val.string);

    return {};  // Success
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
    usz num_files = files_val.list.len;

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
        BencodeValue* file_dict = files_val.list[i];
        if (file_dict.type != bencode::BencodeType.DICT)
        {
            return TORRENT_INVALID_INFO?;
        }

        FileEntry* file = &info.files[i];

        // Extract 'length' (required)
        BencodeValue* length = bencode::dict_get(file_dict, "length");
        if (!length || length.type != bencode::BencodeType.INTEGER)
        {
            return TORRENT_MISSING_FIELD?;
        }

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
        BencodeValue* path = bencode::dict_get(file_dict, "path");
        if (!path || path.type != bencode::BencodeType.LIST)
        {
            return TORRENT_MISSING_FIELD?;
        }

        // Validate path has at least one component
        if (path.list.len == 0)
        {
            return TORRENT_INVALID_INFO?;
        }

        // Allocate path array
        file.path = mem::new_array(String, path.list.len);

        // Copy path components
        for (usz j = 0; j < path.list.len; j++)
        {
            BencodeValue* component = path.list[j];
            if (component.type != bencode::BencodeType.STRING)
            {
                return TORRENT_INVALID_INFO?;
            }
            file.path[j] = copy_string(component.string);
        }
    }

    return {};  // Success
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
        for (usz i = 0; i < torrent.announce_list.len; i++)
        {
            if (torrent.announce_list[i].len > 0)
            {
                // Free each tracker URL in this tier
                for (usz j = 0; j < torrent.announce_list[i].len; j++)
                {
                    if (torrent.announce_list[i][j].len > 0)
                    {
                        free(torrent.announce_list[i][j]);
                    }
                }
                free(torrent.announce_list[i]);
            }
        }
        free(torrent.announce_list);
    }

    // Free DHT nodes
    if (torrent.nodes.len > 0)
    {
        for (usz i = 0; i < torrent.nodes.len; i++)
        {
            if (torrent.nodes[i].host.len > 0)
            {
                free(torrent.nodes[i].host);
            }
        }
        free(torrent.nodes);
    }

    // Free collections (BEP 38)
    if (torrent.collections.len > 0)
    {
        for (usz i = 0; i < torrent.collections.len; i++)
        {
            if (torrent.collections[i].len > 0)
            {
                free(torrent.collections[i]);
            }
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
        for (usz i = 0; i < torrent.url_list.len; i++)
        {
            if (torrent.url_list[i].len > 0) free(torrent.url_list[i]);
        }
        free(torrent.url_list);
    }

    if (torrent.httpseeds.len > 0)
    {
        for (usz i = 0; i < torrent.httpseeds.len; i++)
        {
            if (torrent.httpseeds[i].len > 0) free(torrent.httpseeds[i]);
        }
        free(torrent.httpseeds);
    }

    if (torrent.info.name.len > 0) free(torrent.info.name);
    if (torrent.info.pieces.len > 0) free(torrent.info.pieces);

    // Free multi-file data
    if (torrent.info.is_multi_file && torrent.info.files.len > 0)
    {
        for (usz i = 0; i < torrent.info.files.len; i++)
        {
            FileEntry* file = &torrent.info.files[i];
            if (file.path.len > 0)
            {
                // Free each path component
                for (usz j = 0; j < file.path.len; j++)
                {
                    if (file.path[j].len > 0) free(file.path[j]);
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
    return torrent.info.pieces.len / 20;
}

/**
 * Get a specific piece hash by index.
 *
 * @param torrent The torrent file
 * @param index Piece index (0-based)
 * @return 20-byte SHA1 hash or fault if index out of bounds
 */
fn char[]? get_piece_hash(TorrentFile* torrent, usz index) @public
{
    usz num_pieces = get_num_pieces(torrent);
    if (index >= num_pieces) return TORRENT_INDEX_OUT_OF_BOUNDS?;

    usz offset = index * 20;
    char[20] hash;
    for (usz i = 0; i < 20; i++)
    {
        hash[i] = torrent.info.pieces[offset + i];
    }
    return hash[..];
}
