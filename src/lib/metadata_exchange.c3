module libtorrent::metadata_exchange;

import std::io;
import libtorrent::bencode;

/**
 * BEP 9: Extension for Peers to Send Metadata Files
 * ==================================================
 *
 * Implements the ut_metadata extension protocol for exchanging torrent metadata
 * (the info dictionary) between peers. This enables magnet link support by
 * allowing clients to download metadata from peers instead of requiring a
 * .torrent file.
 *
 * Protocol Details:
 * - Metadata is split into 16KB pieces
 * - Three message types: REQUEST (0), DATA (1), REJECT (2)
 * - Messages are bencoded dictionaries
 * - DATA messages append binary metadata after the bencoded dict
 */

// ============================================================================
// Constants
// ============================================================================

const uint METADATA_PIECE_SIZE = 16384;  // 16KB per BEP 9

// ============================================================================
// Message Types
// ============================================================================

/**
 * BEP 9 metadata message types
 */
enum MetadataMessageType : const char
{
    REQUEST = 0,  // Request a metadata piece
    DATA = 1,     // Send a metadata piece
    REJECT = 2    // Reject a metadata request
}

// ============================================================================
// Message Structures
// ============================================================================

/**
 * Metadata request message (msg_type = 0)
 *
 * Request a specific piece of metadata from a peer.
 * Format: d8:msg_typei0e5:piecei<N>ee
 */
struct MetadataRequest
{
    uint piece;  // Piece index to request (0-based)
}

/**
 * Metadata data message (msg_type = 1)
 *
 * Send a piece of metadata to a peer.
 * Format: d8:msg_typei1e5:piecei<N>e10:total_sizei<SIZE>ee<BINARY_DATA>
 *
 * Note: The binary data is appended AFTER the bencoded dictionary.
 */
struct MetadataData
{
    uint piece;        // Piece index being sent
    uint total_size;   // Total size of complete metadata in bytes
    char[] data;       // Metadata piece data (16KB max, last piece may be smaller)
}

/**
 * Metadata reject message (msg_type = 2)
 *
 * Reject a metadata request (peer doesn't have the piece or is rate limiting).
 * Format: d8:msg_typei2e5:piecei<N>ee
 */
struct MetadataReject
{
    uint piece;  // Piece index that was rejected
}

// ============================================================================
// Utility Functions
// ============================================================================

/**
 * Calculate the number of pieces needed for given metadata size
 *
 * @param total_size : "Total metadata size in bytes"
 * @return "Number of 16KB pieces needed (last piece may be partial)"
 */
fn uint calculate_num_pieces(uint total_size) @public
{
    return (total_size + METADATA_PIECE_SIZE - 1) / METADATA_PIECE_SIZE;
}

/**
 * Get the size of a specific metadata piece
 *
 * @param piece : "Piece index (0-based)"
 * @param total_size : "Total metadata size"
 * @return "Size of this piece (16KB except possibly the last piece)"
 */
fn uint get_piece_size(uint piece, uint total_size) @public
{
    uint num_pieces = calculate_num_pieces(total_size);

    if (piece >= num_pieces)
    {
        return 0;  // Invalid piece index
    }

    if (piece == num_pieces - 1)
    {
        // Last piece may be smaller
        uint remainder = total_size % METADATA_PIECE_SIZE;
        return remainder == 0 ? METADATA_PIECE_SIZE : remainder;
    }

    return METADATA_PIECE_SIZE;
}

// ============================================================================
// Encoding Functions
// ============================================================================

/**
 * Encode a metadata REQUEST message
 *
 * @param piece : "Piece index to request"
 * @return "Bencoded message: d8:msg_typei0e5:piecei<N>ee"
 */
fn char[] encode_request(uint piece) @public
{
    DString buf;

    buf.append("d8:msg_typei0e5:piecei");
    buf.appendf("%d", piece);
    buf.append("ee");

    return buf.copy_str(mem);
}

/**
 * Encode a metadata DATA message
 *
 * @param piece : "Piece index being sent"
 * @param total_size : "Total metadata size in bytes"
 * @param data : "Metadata piece data"
 * @return "Bencoded dict + binary data appended"
 */
fn char[] encode_data(uint piece, uint total_size, char[] data) @public
{
    DString buf;

    // Build bencoded dictionary
    buf.append("d8:msg_typei1e5:piecei");
    buf.appendf("%d", piece);
    buf.append("e10:total_sizei");
    buf.appendf("%d", total_size);
    buf.append("ee");

    // Append binary data AFTER the bencoded dictionary
    String dict_part = buf.copy_str(mem);
    defer free(dict_part);

    // Allocate combined buffer
    char[] result = mem::new_array(char, dict_part.len + data.len);

    // Copy dictionary
    foreach (i, c : dict_part)
    {
        result[i] = c;
    }

    // Copy binary data
    foreach (i, b : data)
    {
        result[dict_part.len + i] = b;
    }

    return result;
}

/**
 * Encode a metadata REJECT message
 *
 * @param piece : "Piece index being rejected"
 * @return "Bencoded message: d8:msg_typei2e5:piecei<N>ee"
 */
fn char[] encode_reject(uint piece) @public
{
    DString buf;

    buf.append("d8:msg_typei2e5:piecei");
    buf.appendf("%d", piece);
    buf.append("ee");

    return buf.copy_str(mem);
}

// ============================================================================
// Decoding Functions
// ============================================================================

faultdef METADATA_INVALID_MESSAGE;
faultdef METADATA_INVALID_TYPE;
faultdef METADATA_MISSING_FIELD;

/**
 * Decode a metadata REQUEST message
 *
 * @param payload : "Bencoded message payload"
 * @return "Decoded request or fault"
 */
fn MetadataRequest? decode_request(char[] payload) @public
{
    // Parse bencoded dictionary
    bencode::BencodeValue*? root_opt = bencode::decode((String)payload);
    if (catch err = root_opt)
    {
        return METADATA_INVALID_MESSAGE?;
    }

    bencode::BencodeValue* root = root_opt;
    defer root.free();

    if (root.type != bencode::BencodeType.DICT)
    {
        return METADATA_INVALID_MESSAGE?;
    }

    // Verify msg_type = 0
    bencode::BencodeValue* msg_type = root.dict_get("msg_type");
    if (!msg_type || msg_type.type != bencode::BencodeType.INTEGER || msg_type.integer != 0)
    {
        return METADATA_INVALID_TYPE?;
    }

    // Extract piece
    bencode::BencodeValue* piece_val = root.dict_get("piece");
    if (!piece_val || piece_val.type != bencode::BencodeType.INTEGER)
    {
        return METADATA_MISSING_FIELD?;
    }

    MetadataRequest req;
    req.piece = (uint)piece_val.integer;

    return req;
}

/**
 * Decode a metadata DATA message
 *
 * @param payload : "Bencoded dict + binary data appended"
 * @return "Decoded data message or fault"
 */
fn MetadataData? decode_data(char[] payload) @public
{
    // Find end of bencoded dictionary
    // We need to parse the dict to know where it ends, then the rest is binary data

    bencode::BencodeValue*? root_opt = bencode::decode((String)payload);
    if (catch err = root_opt)
    {
        return METADATA_INVALID_MESSAGE?;
    }

    bencode::BencodeValue* root = root_opt;
    defer root.free();

    if (root.type != bencode::BencodeType.DICT)
    {
        return METADATA_INVALID_MESSAGE?;
    }

    // Verify msg_type = 1
    bencode::BencodeValue* msg_type = root.dict_get("msg_type");
    if (!msg_type || msg_type.type != bencode::BencodeType.INTEGER || msg_type.integer != 1)
    {
        return METADATA_INVALID_TYPE?;
    }

    // Extract piece
    bencode::BencodeValue* piece_val = root.dict_get("piece");
    if (!piece_val || piece_val.type != bencode::BencodeType.INTEGER)
    {
        return METADATA_MISSING_FIELD?;
    }

    // Extract total_size
    bencode::BencodeValue* total_size_val = root.dict_get("total_size");
    if (!total_size_val || total_size_val.type != bencode::BencodeType.INTEGER)
    {
        return METADATA_MISSING_FIELD?;
    }

    // Calculate where binary data starts
    // Re-encode the dictionary to get its exact length
    String dict_encoded = root.encode();
    defer free(dict_encoded);

    usz dict_len = dict_encoded.len;

    if (payload.len <= dict_len)
    {
        // No binary data appended
        return METADATA_MISSING_FIELD?;
    }

    // Extract binary data (everything after the dict)
    usz data_len = payload.len - dict_len;
    char[] data = mem::new_array(char, data_len);

    foreach (i, b : payload[dict_len..])
    {
        data[i] = b;
    }

    MetadataData msg;
    msg.piece = (uint)piece_val.integer;
    msg.total_size = (uint)total_size_val.integer;
    msg.data = data;

    return msg;
}

/**
 * Decode a metadata REJECT message
 *
 * @param payload : "Bencoded message payload"
 * @return "Decoded reject or fault"
 */
fn MetadataReject? decode_reject(char[] payload) @public
{
    // Parse bencoded dictionary
    bencode::BencodeValue*? root_opt = bencode::decode((String)payload);
    if (catch err = root_opt)
    {
        return METADATA_INVALID_MESSAGE?;
    }

    bencode::BencodeValue* root = root_opt;
    defer root.free();

    if (root.type != bencode::BencodeType.DICT)
    {
        return METADATA_INVALID_MESSAGE?;
    }

    // Verify msg_type = 2
    bencode::BencodeValue* msg_type = root.dict_get("msg_type");
    if (!msg_type || msg_type.type != bencode::BencodeType.INTEGER || msg_type.integer != 2)
    {
        return METADATA_INVALID_TYPE?;
    }

    // Extract piece
    bencode::BencodeValue* piece_val = root.dict_get("piece");
    if (!piece_val || piece_val.type != bencode::BencodeType.INTEGER)
    {
        return METADATA_MISSING_FIELD?;
    }

    MetadataReject rej;
    rej.piece = (uint)piece_val.integer;

    return rej;
}

/**
 * Free a MetadataData message
 */
fn void MetadataData.free(&self) @public
{
    if (self.data.len > 0)
    {
        free(self.data);
    }
}
