module libtorrent::peer_wire;

import std::io;

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
    PORT = 9  // DHT extension
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

    // Reserved bytes (all zeros)
    for (usz i = 20; i < 28; i++) msg[i] = 0;

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
