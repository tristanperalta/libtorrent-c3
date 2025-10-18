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
 * TorrentInfo represents the 'info' dictionary in a torrent file.
 * This contains the actual file metadata.
 *
 * For single-file torrents:
 * - name: filename
 * - length: file size in bytes
 * - piece_length: number of bytes in each piece
 * - pieces: concatenated SHA1 hashes (20 bytes each)
 *
 * For multi-file torrents (not yet supported):
 * - name: directory name
 * - files: list of file info dictionaries
 */
struct TorrentInfo
{
    String name;            // File or directory name
    long length;            // File length (single-file mode)
    long piece_length;      // Bytes per piece
    char[] pieces;          // SHA1 hashes (20 bytes each)
    bool is_multi_file;     // TODO: multi-file support
}

/**
 * TorrentFile represents a complete .torrent file.
 */
struct TorrentFile
{
    String announce;        // Tracker URL
    String created_by;      // Optional: creator info
    long creation_date;     // Optional: Unix timestamp
    String encoding;        // Optional: character encoding
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

    // Extract 'length' (required for single-file)
    BencodeValue* length_val = bencode::dict_get(info_val, "length");
    if (length_val && length_val.type == bencode::BencodeType.INTEGER)
    {
        info.length = length_val.integer;
        info.is_multi_file = false;

        // Validate length is positive
        if (info.length <= 0)
        {
            return TORRENT_INVALID_INFO?;
        }
    }
    else
    {
        // Multi-file mode (not yet supported)
        info.is_multi_file = true;
        return TORRENT_INVALID_INFO?;
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
    if (torrent.created_by.len > 0) free(torrent.created_by);
    if (torrent.encoding.len > 0) free(torrent.encoding);

    if (torrent.info.name.len > 0) free(torrent.info.name);
    if (torrent.info.pieces.len > 0) free(torrent.info.pieces);

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
