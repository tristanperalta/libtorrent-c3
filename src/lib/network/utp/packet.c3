module libtorrent::utp::packet;

import libtorrent::utp::common;
import std::core::bitorder;
import std::io;

<*
 μTP Packet Encoding and Decoding
 =================================

 Implements BEP 29 packet format:
   - 20-byte header (network byte order / big-endian)
   - Variable-length payload
   - Uses std::core::bitorder for endian conversions

 Packet Header Format (from BEP 29):
   0       4       8               16              24              32
   +-------+-------+---------------+---------------+---------------+
   | type  | ver   | extension     | connection_id                 |
   +-------+-------+---------------+---------------+---------------+
   | timestamp_microseconds                                        |
   +-------+-------+---------------+---------------+---------------+
   | timestamp_difference_microseconds                             |
   +-------+-------+---------------+---------------+---------------+
   | wnd_size                                                      |
   +-------+-------+---------------+---------------+---------------+
   | seq_nr                        | ack_nr                        |
   +-------+-------+---------------+---------------+---------------+
*>

// ============================================================================
// Data Structures
// ============================================================================

/**
 * μTP packet header (20 bytes).
 *
 * All multi-byte fields are in network byte order (big-endian) when encoded.
 */
struct UtpHeader {
    char packet_type;        // ST_DATA, ST_FIN, ST_STATE, ST_RESET, or ST_SYN
    char version;            // Protocol version (always 1)
    char extension;          // Extension type or 0 (Phase 1: always 0)
    ushort connection_id;    // Connection identifier
    uint timestamp_microseconds;            // Send timestamp
    uint timestamp_difference_microseconds; // One-way delay measurement
    uint wnd_size;           // Advertised receive window (bytes)
    ushort seq_nr;           // Packet sequence number
    ushort ack_nr;           // Last received in-order sequence number
}

// ============================================================================
// Encoding (C3 → Bytes)
// ============================================================================

/**
 * Encode μTP packet header + payload into byte array.
 * Uses network byte order (big-endian) for all multi-byte fields.
 *
 * @param header : Packet header to encode
 * @param payload : Optional payload data (default: empty)
 * @return Encoded packet (caller must free)
 */
fn char[] encode_packet(UtpHeader* header, char[] payload = {}) @public
{
    // Allocate buffer for header + payload
    usz total_size = common::UTP_HEADER_SIZE + payload.len;
    char[] packet = mem::new_array(char, total_size);

    // Byte 0: [type:4][version:4]
    packet[0] = (char)((header.packet_type << 4) | (header.version & 0x0F));

    // Byte 1: extension type
    packet[1] = (char)header.extension;

    // Bytes 2-3: connection_id (16-bit, big-endian)
    bitorder::write(header.connection_id, packet[2..], UShortBE);

    // Bytes 4-7: timestamp_microseconds (32-bit, big-endian)
    bitorder::write(header.timestamp_microseconds, packet[4..], UIntBE);

    // Bytes 8-11: timestamp_difference_microseconds (32-bit, big-endian)
    bitorder::write(header.timestamp_difference_microseconds, packet[8..], UIntBE);

    // Bytes 12-15: wnd_size (32-bit, big-endian)
    bitorder::write(header.wnd_size, packet[12..], UIntBE);

    // Bytes 16-17: seq_nr (16-bit, big-endian)
    bitorder::write(header.seq_nr, packet[16..], UShortBE);

    // Bytes 18-19: ack_nr (16-bit, big-endian)
    bitorder::write(header.ack_nr, packet[18..], UShortBE);

    // Copy payload (if any)
    if (payload.len > 0) {
        for (usz i = 0; i < payload.len; i++) {
            packet[common::UTP_HEADER_SIZE + i] = payload[i];
        }
    }

    return packet;
}

// ============================================================================
// Decoding (Bytes → C3)
// ============================================================================

/**
 * Decode μTP packet from byte array.
 * Validates minimum size and protocol version.
 *
 * @param data : Packet bytes (header + optional payload)
 * @return Decoded header (payload not included)
 */
fn UtpHeader? decode_packet(char[] data) @public
{
    // Validate minimum size
    if (data.len < common::UTP_HEADER_SIZE) {
        return common::UTP_PACKET_TOO_SHORT?;
    }

    UtpHeader header;

    // Byte 0: [type:4][version:4]
    header.packet_type = (data[0] >> 4) & 0x0F;
    header.version = data[0] & 0x0F;

    // Validate protocol version
    if (header.version != common::UTP_VERSION) {
        return common::UTP_INVALID_VERSION?;
    }

    // Byte 1: extension type
    header.extension = data[1];

    // Bytes 2-3: connection_id (16-bit, big-endian)
    header.connection_id = bitorder::read(data[2..], UShortBE);

    // Bytes 4-7: timestamp_microseconds (32-bit, big-endian)
    header.timestamp_microseconds = bitorder::read(data[4..], UIntBE);

    // Bytes 8-11: timestamp_difference_microseconds (32-bit, big-endian)
    header.timestamp_difference_microseconds = bitorder::read(data[8..], UIntBE);

    // Bytes 12-15: wnd_size (32-bit, big-endian)
    header.wnd_size = bitorder::read(data[12..], UIntBE);

    // Bytes 16-17: seq_nr (16-bit, big-endian)
    header.seq_nr = bitorder::read(data[16..], UShortBE);

    // Bytes 18-19: ack_nr (16-bit, big-endian)
    header.ack_nr = bitorder::read(data[18..], UShortBE);

    return header;
}

// ============================================================================
// Utility Functions
// ============================================================================

/**
 * Get packet type from raw packet data (without full decode).
 * Useful for quick packet dispatch without allocating UtpHeader.
 *
 * @param data : Packet bytes
 * @return Packet type (ST_DATA, ST_FIN, ST_STATE, ST_RESET, or ST_SYN)
 */
fn char get_packet_type(char[] data) @public
{
    if (data.len < 1) return 0;
    return (data[0] >> 4) & 0x0F;
}

/**
 * Get connection ID from raw packet data.
 *
 * @param data : Packet bytes
 * @return Connection ID (0 if packet too short)
 */
fn ushort get_connection_id(char[] data) @public
{
    if (data.len < 4) return 0;
    return bitorder::read(data[2..], UShortBE);
}

/**
 * Get payload from packet (data after header).
 *
 * @param packet : Complete packet (header + payload)
 * @return Payload slice (empty if no payload)
 */
fn char[] get_payload(char[] packet) @public
{
    if (packet.len <= common::UTP_HEADER_SIZE) return {};
    return packet[common::UTP_HEADER_SIZE..];
}
