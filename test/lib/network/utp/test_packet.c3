module libtorrent::utp::packet_test;

import libtorrent::utp::packet;
import libtorrent::utp::common;
import std::io;

<*
 μTP Packet Encoding/Decoding Tests
 ===================================

 Tests all packet types, error cases, and byte order correctness.
*>

/**
 * Test 1: Encode and decode ST_SYN packet (no payload).
 */
fn void test_encode_decode_syn() @test
{
    UtpHeader header;
    header.packet_type = common::ST_SYN;
    header.version = common::UTP_VERSION;
    header.extension = 0;
    header.connection_id = 12345;
    header.timestamp_microseconds = 1000000;
    header.timestamp_difference_microseconds = 500;
    header.wnd_size = 1048576;  // 1MB window
    header.seq_nr = 1;
    header.ack_nr = 0;

    // Encode
    char[] packet = packet::encode_packet(&header);
    defer free(packet);

    assert(packet.len == common::UTP_HEADER_SIZE, "SYN packet should be header-only");

    // Decode
    UtpHeader? decoded_opt = packet::decode_packet(packet);
    if (catch excuse = decoded_opt) {
        assert(false, "Decode should succeed");
    }
    UtpHeader decoded = decoded_opt;

    // Verify all fields
    assert(decoded.packet_type == common::ST_SYN, "packet_type mismatch");
    assert(decoded.version == common::UTP_VERSION, "version mismatch");
    assert(decoded.extension == 0, "extension mismatch");
    assert(decoded.connection_id == 12345, "connection_id mismatch");
    assert(decoded.timestamp_microseconds == 1000000, "timestamp_microseconds mismatch");
    assert(decoded.timestamp_difference_microseconds == 500, "timestamp_difference mismatch");
    assert(decoded.wnd_size == 1048576, "wnd_size mismatch");
    assert(decoded.seq_nr == 1, "seq_nr mismatch");
    assert(decoded.ack_nr == 0, "ack_nr mismatch");

    io::printn("✓ test_encode_decode_syn");
}

/**
 * Test 2: Encode and decode ST_DATA packet (with payload).
 */
fn void test_encode_decode_data_with_payload() @test
{
    UtpHeader header;
    header.packet_type = common::ST_DATA;
    header.version = common::UTP_VERSION;
    header.extension = 0;
    header.connection_id = 54321;
    header.timestamp_microseconds = 2000000;
    header.timestamp_difference_microseconds = 1000;
    header.wnd_size = 524288;  // 512KB window
    header.seq_nr = 42;
    header.ack_nr = 41;

    // Payload
    char[] payload = (char[])"Hello μTP!";

    // Encode
    char[] packet = packet::encode_packet(&header, payload);
    defer free(packet);

    assert(packet.len == common::UTP_HEADER_SIZE + payload.len, "Packet size mismatch");

    // Decode header
    UtpHeader? decoded_opt = packet::decode_packet(packet);
    if (catch excuse = decoded_opt) {
        assert(false, "Decode should succeed");
    }
    UtpHeader decoded = decoded_opt;

    // Verify header
    assert(decoded.packet_type == common::ST_DATA, "packet_type should be ST_DATA");
    assert(decoded.seq_nr == 42, "seq_nr mismatch");
    assert(decoded.ack_nr == 41, "ack_nr mismatch");

    // Verify payload
    char[] decoded_payload = packet::get_payload(packet);
    assert(decoded_payload.len == payload.len, "Payload length mismatch");
    for (usz i = 0; i < payload.len; i++) {
        assert(decoded_payload[i] == payload[i], "Payload data mismatch at byte %d", i);
    }

    io::printn("✓ test_encode_decode_data_with_payload");
}

/**
 * Test 3: All packet types (ST_SYN, ST_STATE, ST_DATA, ST_FIN, ST_RESET).
 */
fn void test_all_packet_types() @test
{
    char[5] types = { common::ST_SYN, common::ST_STATE, common::ST_DATA, common::ST_FIN, common::ST_RESET };

    foreach (pkt_type : types)
    {
        UtpHeader header;
        header.packet_type = pkt_type;
        header.version = common::UTP_VERSION;
        header.extension = 0;
        header.connection_id = 1000;
        header.timestamp_microseconds = 3000000;
        header.timestamp_difference_microseconds = 1500;
        header.wnd_size = 262144;
        header.seq_nr = 10;
        header.ack_nr = 9;

        char[] packet = packet::encode_packet(&header);
        defer free(packet);

        UtpHeader decoded = packet::decode_packet(packet)!!;
        assert(decoded.packet_type == pkt_type, "Packet type mismatch for type %d", pkt_type);
    }

    io::printn("✓ test_all_packet_types");
}

/**
 * Test 4: Packet too short (should fail).
 */
fn void test_decode_packet_too_short() @test
{
    char[10] short_packet;

    UtpHeader? result = packet::decode_packet(short_packet[..]);
    if (catch excuse = result) {
        assert(excuse == common::UTP_PACKET_TOO_SHORT, "Should return UTP_PACKET_TOO_SHORT");
    } else {
        assert(false, "Should fail on short packet");
    }

    io::printn("✓ test_decode_packet_too_short");
}

/**
 * Test 5: Invalid version (should fail).
 */
fn void test_decode_invalid_version() @test
{
    // Manually create packet with wrong version
    char[common::UTP_HEADER_SIZE] packet;
    packet[0] = (char)((common::ST_DATA << 4) | 99);  // Version 99 (invalid)

    UtpHeader? result = packet::decode_packet(packet[..]);
    if (catch excuse = result) {
        assert(excuse == common::UTP_INVALID_VERSION, "Should return UTP_INVALID_VERSION");
    } else {
        assert(false, "Should fail on invalid version");
    }

    io::printn("✓ test_decode_invalid_version");
}

/**
 * Test 6: Byte order verification (big-endian / network byte order).
 */
fn void test_byte_order() @test
{
    UtpHeader header;
    header.packet_type = common::ST_DATA;
    header.version = common::UTP_VERSION;
    header.extension = 0;
    header.connection_id = 0x1234;  // 4660 decimal
    header.timestamp_microseconds = 0x12345678;
    header.timestamp_difference_microseconds = 0xABCDEF00;
    header.wnd_size = 0xFFFFFFFF;
    header.seq_nr = 0xABCD;
    header.ack_nr = 0x5678;

    char[] packet = packet::encode_packet(&header);
    defer free(packet);

    // Verify big-endian encoding manually
    // connection_id at bytes 2-3
    assert(packet[2] == (char)0x12, "connection_id MSB should be 0x12");
    assert(packet[3] == (char)0x34, "connection_id LSB should be 0x34");

    // timestamp_microseconds at bytes 4-7
    assert(packet[4] == (char)0x12, "timestamp byte 0 should be 0x12");
    assert(packet[5] == (char)0x34, "timestamp byte 1 should be 0x34");
    assert(packet[6] == (char)0x56, "timestamp byte 2 should be 0x56");
    assert(packet[7] == (char)0x78, "timestamp byte 3 should be 0x78");

    // seq_nr at bytes 16-17
    assert(packet[16] == (char)0xAB, "seq_nr MSB should be 0xAB");
    assert(packet[17] == (char)0xCD, "seq_nr LSB should be 0xCD");

    io::printn("✓ test_byte_order");
}

/**
 * Test 7: Utility functions (get_packet_type, get_connection_id, get_payload).
 */
fn void test_utility_functions() @test
{
    UtpHeader header;
    header.packet_type = common::ST_FIN;
    header.version = common::UTP_VERSION;
    header.extension = 0;
    header.connection_id = 9999;
    header.timestamp_microseconds = 0;
    header.timestamp_difference_microseconds = 0;
    header.wnd_size = 0;
    header.seq_nr = 0;
    header.ack_nr = 0;

    char[] payload = (char[])"Test payload";
    char[] packet = packet::encode_packet(&header, payload);
    defer free(packet);

    // Test get_packet_type
    char pkt_type = packet::get_packet_type(packet);
    assert(pkt_type == common::ST_FIN, "get_packet_type should return ST_FIN");

    // Test get_connection_id
    ushort conn_id = packet::get_connection_id(packet);
    assert(conn_id == 9999, "get_connection_id should return 9999");

    // Test get_payload
    char[] extracted_payload = packet::get_payload(packet);
    assert(extracted_payload.len == payload.len, "Payload length should match");
    for (usz i = 0; i < payload.len; i++) {
        assert(extracted_payload[i] == payload[i], "Payload content should match");
    }

    io::printn("✓ test_utility_functions");
}
