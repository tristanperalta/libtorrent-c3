module libtorrent::peer_wire;

import std::io;
import libtorrent::bencode;

<*
 BitTorrent Peer Wire Protocol (BEP 3)
 ======================================
 Implements message encoding/decoding for peer-to-peer communication.

 Protocol Structure:
 - Handshake: 68 bytes fixed format
 - Messages: <length:4><id:1><payload:variable>
 - All integers in big-endian format

 Usage:
   char[] handshake = encode_handshake(info_hash, peer_id);
   char[] msg = encode_interested();
   Message? parsed = decode_message(data);
*>

// Faults
faultdef PEER_WIRE_INVALID_HANDSHAKE;
faultdef PEER_WIRE_INVALID_MESSAGE;
faultdef PEER_WIRE_INCOMPLETE_DATA;

<*
 Message types in the peer wire protocol.
 All messages except handshake start with a 4-byte big-endian length prefix
 followed by a 1-byte message ID.
*>
enum MessageType : const char
{
    CHOKE = 0,
    UNCHOKE = 1,
    INTERESTED = 2,
    NOT_INTERESTED = 3,
    HAVE = 4,
    BITFIELD = 5,
    REQUEST = 6,
    PIECE = 7,
    CANCEL = 8,
    PORT = 9,      // DHT extension
    EXTENDED = 20  // Extension protocol (BEP 10)
}

<*
 Handshake message (68 bytes total).
 Format: <pstrlen:1><pstr:19><reserved:8><info_hash:20><peer_id:20>
*>
struct HandshakeMsg
{
    char[8] reserved;    // Extension bits (all zeros for basic protocol)
    char[20] info_hash;  // SHA1 hash of torrent info dict
    char[20] peer_id;    // Unique peer identifier
}

<*
 Generic message structure after parsing.
 The payload interpretation depends on the message type.
*>
struct Message
{
    MessageType type;
    char[] payload;  // Raw payload bytes (caller must interpret based on type)
}

<*
 Request message payload (12 bytes).
 Used for REQUEST and CANCEL messages.
*>
struct RequestMsg
{
    uint index;   // Piece index
    uint begin;   // Byte offset within piece
    uint length;  // Block length (typically 16384 bytes)
}

<*
 Piece message payload (8 bytes + data).
 Used for PIECE messages.
*>
struct PieceMsg
{
    uint index;   // Piece index
    uint begin;   // Byte offset within piece
    char[] block; // Block data
}

// ============================================================================
// Big-Endian Integer Encoding/Decoding
// ============================================================================

<*
 Read a 32-bit unsigned integer from buffer in big-endian format.

 @param data : "Buffer containing the integer"
 @param offset : "Offset in buffer to read from"
 @return "The decoded uint32 value"
*>
fn uint read_u32_be(char[] data, usz offset) @inline
{
    return ((uint)((usz)data[offset] & 0xFF) << 24) |
           ((uint)((usz)data[offset + 1] & 0xFF) << 16) |
           ((uint)((usz)data[offset + 2] & 0xFF) << 8) |
           ((uint)((usz)data[offset + 3] & 0xFF));
}

<*
 Write a 32-bit unsigned integer to buffer in big-endian format.

 @param buffer : "Buffer to write to"
 @param offset : "Offset in buffer to write at"
 @param value : "The uint32 value to encode"
*>
fn void write_u32_be(char[] buffer, usz offset, uint value) @inline
{
    buffer[offset] = (char)((value >> 24) & 0xFF);
    buffer[offset + 1] = (char)((value >> 16) & 0xFF);
    buffer[offset + 2] = (char)((value >> 8) & 0xFF);
    buffer[offset + 3] = (char)(value & 0xFF);
}

// ============================================================================
// Handshake Encoding/Decoding
// ============================================================================

<*
 Encode a handshake message.

 Format: <pstrlen:1><pstr:19><reserved:8><info_hash:20><peer_id:20>
 Total: 68 bytes

 @param info_hash : "The torrent info hash (20 bytes)"
 @param peer_id : "Our peer ID (20 bytes)"
 @return "Encoded handshake message (caller must free)"
*>
fn char[] encode_handshake(char[20] info_hash, char[20] peer_id) @public
{
    char[] msg = mem::new_array(char, 68);

    // Protocol string length and name
    msg[0] = 19;
    String pstr = "BitTorrent protocol";
    foreach (i, c : pstr) msg[i + 1] = c;

    // Reserved bytes - set extension protocol support bit (BEP 10)
    // Byte 5, bit 0x10 (bit 20 from right) indicates extension protocol support
    for (usz i = 20; i < 28; i++) msg[i] = 0;
    msg[25] |= 0x10;  // Enable extension protocol (BEP 10)

    // Info hash
    foreach (i, b : info_hash) msg[i + 28] = b;

    // Peer ID
    foreach (i, b : peer_id) msg[i + 48] = b;

    return msg;
}

<*
 Decode a handshake message.

 @param data : "Buffer containing the handshake (must be at least 68 bytes)"
 @return "Decoded handshake or fault if invalid"
*>
fn HandshakeMsg? decode_handshake(char[] data) @public
{
    // Check minimum length
    if (data.len < 68)
    {
        return PEER_WIRE_INCOMPLETE_DATA?;
    }

    // Validate protocol string length
    if (data[0] != 19)
    {
        return PEER_WIRE_INVALID_HANDSHAKE?;
    }

    // Validate protocol string
    String expected = "BitTorrent protocol";
    for (usz i = 0; i < 19; i++)
    {
        if (data[i + 1] != expected[i])
        {
            return PEER_WIRE_INVALID_HANDSHAKE?;
        }
    }

    HandshakeMsg msg;

    // Extract reserved bytes
    for (usz i = 0; i < 8; i++) msg.reserved[i] = data[i + 20];

    // Extract info hash
    for (usz i = 0; i < 20; i++) msg.info_hash[i] = data[i + 28];

    // Extract peer ID
    for (usz i = 0; i < 20; i++) msg.peer_id[i] = data[i + 48];

    return msg;
}

<*
 Check if a handshake indicates extension protocol support (BEP 10).

 @param handshake : "Decoded handshake message"
 @return "True if peer supports extension protocol"
*>
fn bool handshake_supports_extensions(HandshakeMsg* handshake) @public
{
    // Check bit 20 (byte 5, bit 0x10)
    return (handshake.reserved[5] & 0x10) != 0;
}

// ============================================================================
// Extension Protocol (BEP 10)
// ============================================================================

// Extension message IDs
const char EXTENSION_HANDSHAKE_ID = 0;

<*
 Extension handshake payload (bencoded dictionary).

 The extension handshake is sent immediately after the BT handshake
 if both peers support extensions (bit 20 in reserved bytes).
*>
struct ExtensionHandshake
{
    // m: Dictionary mapping extension names to message IDs
    // For PEX: { "ut_pex": <our_msg_id> }
    char ut_pex_id;  // Our local message ID for ut_pex (0 = disabled)

    // Optional fields
    ushort port;          // Our TCP listen port (0 = unknown)
    String client_name;   // Client name and version (e.g., "libtorrent-c3 0.1")
    uint reqq;            // Max outstanding requests (default 250)
}

<*
 Extension message structure.

 Format: <length:4><id:1=20><ext_msg_id:1><payload:variable>
 - length: Total message length minus 4 bytes
 - id: Always 20 (EXTENDED)
 - ext_msg_id: 0 for handshake, >0 for specific extensions
 - payload: Bencoded dictionary
*>
struct ExtensionMessage
{
    char ext_msg_id;    // 0 = handshake, 1+ = extension-specific
    char[] payload;      // Bencoded data (caller must free)
}

// ============================================================================
// Message Encoding
// ============================================================================

<*
 Encode a keep-alive message.
 Keep-alive is just a length of 0 (4 zero bytes).

 @return "Encoded keep-alive message (4 bytes)"
*>
fn char[] encode_keepalive() @public
{
    char[] msg = mem::new_array(char, 4);
    write_u32_be(msg, 0, 0);
    return msg;
}

<*
 Encode a message with no payload (choke, unchoke, interested, not interested).

 Format: <length:4><id:1>
 Total: 5 bytes

 @param msg_type : "The message type"
 @return "Encoded message (caller must free)"
*>
fn char[] encode_simple_message(MessageType msg_type) @public
{
    char[] msg = mem::new_array(char, 5);
    write_u32_be(msg, 0, 1);  // Length = 1 (just the message ID)
    msg[4] = (char)msg_type;
    return msg;
}

<*
 Encode a HAVE message.

 Format: <length:4><id:1><piece_index:4>
 Total: 9 bytes

 @param piece_index : "The piece index we have"
 @return "Encoded HAVE message (caller must free)"
*>
fn char[] encode_have(uint piece_index) @public
{
    char[] msg = mem::new_array(char, 9);
    write_u32_be(msg, 0, 5);  // Length = 5 (1 byte ID + 4 bytes payload)
    msg[4] = (char)MessageType.HAVE;
    write_u32_be(msg, 5, piece_index);
    return msg;
}

<*
 Encode a BITFIELD message.

 Format: <length:4><id:1><bitfield:variable>

 @param bitfield : "The bitfield bytes"
 @return "Encoded BITFIELD message (caller must free)"
*>
fn char[] encode_bitfield(char[] bitfield) @public
{
    usz msg_len = 5 + bitfield.len;
    char[] msg = mem::new_array(char, msg_len);
    write_u32_be(msg, 0, (uint)(1 + bitfield.len));  // Length = 1 + bitfield length
    msg[4] = (char)MessageType.BITFIELD;
    foreach (i, b : bitfield) msg[i + 5] = b;
    return msg;
}

<*
 Encode a REQUEST message.

 Format: <length:4><id:1><index:4><begin:4><length:4>
 Total: 17 bytes

 @param index : "Piece index"
 @param begin : "Byte offset within piece"
 @param length : "Block length to request"
 @return "Encoded REQUEST message (caller must free)"
*>
fn char[] encode_request(uint index, uint begin, uint length) @public
{
    char[] msg = mem::new_array(char, 17);
    write_u32_be(msg, 0, 13);  // Length = 13 (1 byte ID + 12 bytes payload)
    msg[4] = (char)MessageType.REQUEST;
    write_u32_be(msg, 5, index);
    write_u32_be(msg, 9, begin);
    write_u32_be(msg, 13, length);
    return msg;
}

<*
 Encode a PIECE message.

 Format: <length:4><id:1><index:4><begin:4><block:variable>

 @param index : "Piece index"
 @param begin : "Byte offset within piece"
 @param block : "Block data"
 @return "Encoded PIECE message (caller must free)"
*>
fn char[] encode_piece(uint index, uint begin, char[] block) @public
{
    usz msg_len = 13 + block.len;  // 4 (length) + 1 (id) + 4 (index) + 4 (begin) + block
    char[] msg = mem::new_array(char, msg_len);
    write_u32_be(msg, 0, (uint)(9 + block.len));  // Length = 9 + block length
    msg[4] = (char)MessageType.PIECE;
    write_u32_be(msg, 5, index);
    write_u32_be(msg, 9, begin);
    foreach (i, b : block) msg[i + 13] = b;
    return msg;
}

<*
 Encode a CANCEL message.

 Format: <length:4><id:1><index:4><begin:4><length:4>
 Total: 17 bytes (same as REQUEST)

 @param index : "Piece index"
 @param begin : "Byte offset within piece"
 @param length : "Block length to cancel"
 @return "Encoded CANCEL message (caller must free)"
*>
fn char[] encode_cancel(uint index, uint begin, uint length) @public
{
    char[] msg = mem::new_array(char, 17);
    write_u32_be(msg, 0, 13);  // Length = 13
    msg[4] = (char)MessageType.CANCEL;
    write_u32_be(msg, 5, index);
    write_u32_be(msg, 9, begin);
    write_u32_be(msg, 13, length);
    return msg;
}

<*
 Encode a PORT message (DHT extension).

 Format: <length:4><id:1><port:2>
 Total: 7 bytes

 @param port : "DHT listen port"
 @return "Encoded PORT message (caller must free)"
*>
fn char[] encode_port(ushort port) @public
{
    char[] msg = mem::new_array(char, 7);
    write_u32_be(msg, 0, 3);  // Length = 3 (1 byte ID + 2 bytes payload)
    msg[4] = (char)MessageType.PORT;
    msg[5] = (char)((port >> 8) & 0xFF);
    msg[6] = (char)(port & 0xFF);
    return msg;
}

<*
 Encode an extension handshake message (BEP 10).

 Format: <length:4><id:1=20><ext_msg_id:1=0><bencoded_dict>

 @param handshake : "Extension handshake data"
 @return "Encoded extension handshake message (caller must free)"
*>
fn char[] encode_extension_handshake(ExtensionHandshake* handshake) @public
{
    // Build bencoded dictionary
    // Format: d1:md6:ut_pexi<id>ee1:pi<port>e1:v<len>:<client>e4:reqqi<reqq>ee
    DString builder;

    builder.append("d");  // Start dictionary

    // m: { "ut_pex": <id> }
    builder.append("1:md");
    if (handshake.ut_pex_id > 0)
    {
        builder.append("6:ut_pexi");
        builder.appendf("%d", (int)handshake.ut_pex_id);
        builder.append("e");
    }
    builder.append("e");  // End 'm' dictionary

    // p: port (if provided)
    if (handshake.port > 0)
    {
        builder.append("1:pi");
        builder.appendf("%d", (int)handshake.port);
        builder.append("e");
    }

    // reqq: max outstanding requests
    if (handshake.reqq > 0)
    {
        builder.append("4:reqqi");
        builder.appendf("%d", handshake.reqq);
        builder.append("e");
    }

    // v: client name/version
    if (handshake.client_name.len > 0)
    {
        builder.append("1:v");
        builder.appendf("%d:", handshake.client_name.len);
        builder.append(handshake.client_name);
    }

    builder.append("e");  // End main dictionary

    String bencoded = builder.str_view();

    // Allocate message buffer: 4 (length) + 1 (id=20) + 1 (ext_id=0) + payload
    usz total_len = 4 + 1 + 1 + bencoded.len;
    char[] msg = mem::new_array(char, total_len);

    // Write length (excluding length prefix itself)
    write_u32_be(msg, 0, (uint)(total_len - 4));

    // Write message ID (EXTENDED = 20)
    msg[4] = (char)MessageType.EXTENDED;

    // Write extension message ID (0 = handshake)
    msg[5] = EXTENSION_HANDSHAKE_ID;

    // Write bencoded payload
    for (usz i = 0; i < bencoded.len; i++)
    {
        msg[6 + i] = bencoded[i];
    }

    return msg;
}

<*
 Encode a generic extension message (BEP 10).

 Format: <length:4><id:1=20><ext_msg_id:1><payload>

 @param ext_msg_id : "Extension-specific message ID"
 @param payload : "Bencoded payload data"
 @return "Encoded extension message (caller must free)"
*>
fn char[] encode_extension_message(char ext_msg_id, char[] payload) @public
{
    // Allocate message: 4 (length) + 1 (id=20) + 1 (ext_id) + payload
    usz total_len = 4 + 1 + 1 + payload.len;
    char[] msg = mem::new_array(char, total_len);

    // Write length (excluding length prefix)
    write_u32_be(msg, 0, (uint)(total_len - 4));

    // Write message ID (EXTENDED = 20)
    msg[4] = (char)MessageType.EXTENDED;

    // Write extension message ID
    msg[5] = ext_msg_id;

    // Write payload
    for (usz i = 0; i < payload.len; i++)
    {
        msg[6 + i] = payload[i];
    }

    return msg;
}

// ============================================================================
// Message Decoding
// ============================================================================

<*
 Decode a peer wire message.

 @param data : "Buffer containing the message (must start with length prefix)"
 @return "Decoded message or fault if invalid/incomplete"
*>
fn Message? decode_message(char[] data) @public
{
    // Need at least 4 bytes for length prefix
    if (data.len < 4)
    {
        return PEER_WIRE_INCOMPLETE_DATA?;
    }

    // Read message length
    uint msg_len = read_u32_be(data, 0);

    // Keep-alive message (length = 0)
    if (msg_len == 0)
    {
        // Return a special message with no type
        Message msg;
        msg.payload = {};
        return msg;
    }

    // Check if we have the complete message
    if (data.len < 4 + msg_len)
    {
        return PEER_WIRE_INCOMPLETE_DATA?;
    }

    // Read message ID
    MessageType msg_type = (MessageType)data[4];

    // Extract payload (everything after the message ID)
    char[] payload;
    if (msg_len > 1)
    {
        usz payload_len = (usz)(msg_len - 1);
        payload = mem::new_array(char, payload_len);
        for (usz i = 0; i < payload_len; i++) payload[i] = data[i + 5];
    }

    Message msg;
    msg.type = msg_type;
    msg.payload = payload;

    return msg;
}

<*
 Decode a REQUEST or CANCEL message payload.

 @param payload : "Message payload (must be 12 bytes)"
 @return "Decoded request or fault if invalid"
*>
fn RequestMsg? decode_request(char[] payload) @public
{
    if (payload.len != 12)
    {
        return PEER_WIRE_INVALID_MESSAGE?;
    }

    RequestMsg msg;
    msg.index = read_u32_be(payload, 0);
    msg.begin = read_u32_be(payload, 4);
    msg.length = read_u32_be(payload, 8);

    return msg;
}

<*
 Decode a PIECE message payload.

 @param payload : "Message payload (must be at least 8 bytes)"
 @return "Decoded piece or fault if invalid"
*>
fn PieceMsg? decode_piece(char[] payload) @public
{
    if (payload.len < 8)
    {
        return PEER_WIRE_INVALID_MESSAGE?;
    }

    PieceMsg msg;
    msg.index = read_u32_be(payload, 0);
    msg.begin = read_u32_be(payload, 4);

    // Extract block data (everything after index and begin)
    usz block_len = payload.len - 8;
    msg.block = mem::new_array(char, block_len);
    for (usz i = 0; i < block_len; i++) msg.block[i] = payload[i + 8];

    return msg;
}

<*
 Decode a HAVE message payload.

 @param payload : "Message payload (must be 4 bytes)"
 @return "Piece index or fault if invalid"
*>
fn uint? decode_have(char[] payload) @public
{
    if (payload.len != 4)
    {
        return PEER_WIRE_INVALID_MESSAGE?;
    }

    return read_u32_be(payload, 0);
}

<*
 Decode an extension message (BEP 10).

 Format: <length:4><id:1=20><ext_msg_id:1><payload>

 @param payload : "Complete message payload (after message ID 20)"
 @return "Decoded extension message or fault if invalid"
*>
fn ExtensionMessage? decode_extension_message(char[] payload) @public
{
    if (payload.len < 1)
    {
        return PEER_WIRE_INVALID_MESSAGE?;
    }

    ExtensionMessage msg;
    msg.ext_msg_id = payload[0];

    // Copy payload (bencoded data after ext_msg_id)
    if (payload.len > 1)
    {
        msg.payload = mem::new_array(char, payload.len - 1);
        for (usz i = 1; i < payload.len; i++)
        {
            msg.payload[i - 1] = payload[i];
        }
    }
    else
    {
        msg.payload = {};
    }

    return msg;
}

<*
 Decode an extension handshake message (BEP 10).

 @param payload : "Bencoded dictionary payload"
 @return "Decoded extension handshake or fault if invalid"
*>
fn ExtensionHandshake? decode_extension_handshake(char[] payload) @public
{
    // Parse bencoded dictionary
    bencode::BencodeValue*? root_opt = bencode::decode((String)payload);
    if (catch err = root_opt)
    {
        return PEER_WIRE_INVALID_MESSAGE?;
    }

    bencode::BencodeValue* root = root_opt;
    defer root.free();

    if (root.type != bencode::BencodeType.DICT)
    {
        return PEER_WIRE_INVALID_MESSAGE?;
    }

    ExtensionHandshake handshake;
    handshake.ut_pex_id = 0;
    handshake.port = 0;
    handshake.client_name = "";
    handshake.reqq = 0;

    // Parse "m" dictionary (extension name -> message ID mappings)
    bencode::BencodeValue* m_dict = root.dict_get("m");
    if (m_dict && m_dict.type == bencode::BencodeType.DICT)
    {
        // Look for "ut_pex" key
        bencode::BencodeValue* pex_val = m_dict.dict_get("ut_pex");
        if (pex_val && pex_val.type == bencode::BencodeType.INTEGER)
        {
            handshake.ut_pex_id = (char)pex_val.integer;
        }
    }

    // Parse "p" (port)
    bencode::BencodeValue* p_val = root.dict_get("p");
    if (p_val && p_val.type == bencode::BencodeType.INTEGER)
    {
        handshake.port = (ushort)p_val.integer;
    }

    // Parse "v" (client version)
    bencode::BencodeValue* v_val = root.dict_get("v");
    if (v_val && v_val.type == bencode::BencodeType.STRING)
    {
        // Copy the string
        handshake.client_name = ((String)v_val.string).copy(mem);
    }

    // Parse "reqq" (max outstanding requests)
    bencode::BencodeValue* reqq_val = root.dict_get("reqq");
    if (reqq_val && reqq_val.type == bencode::BencodeType.INTEGER)
    {
        handshake.reqq = (uint)reqq_val.integer;
    }

    return handshake;
}

<*
 Get the total size of a message from its length prefix.
 Useful for determining if we've received a complete message.

 @param data : "Buffer containing at least the length prefix (4 bytes)"
 @return "Total message size in bytes (including the 4-byte length prefix)"
*>
fn usz? message_total_size(char[] data) @public
{
    if (data.len < 4)
    {
        return PEER_WIRE_INCOMPLETE_DATA?;
    }

    uint payload_len = read_u32_be(data, 0);
    return (usz)(4 + payload_len);  // 4 bytes for length prefix + payload length
}
