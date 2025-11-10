module test_compact_ipv6;

import std::io;
import std::net;
import libtorrent::common;

/**
 * Unit tests for BEP 32: IPv6 Extension for DHT
 *
 * Tests compact node format encoding/decoding for both IPv4 and IPv6.
 * Compact node format is used in DHT responses (get_peers, find_node).
 */

// ============================================================================
// IPv4 Compact Node Format Tests
// ============================================================================

/**
 * Test encoding a node to compact IPv4 format.
 */
fn void test_encode_compact_node_ipv4() @test
{
    // Create test node ID (20 bytes of incrementing pattern)
    common::NodeId node_id;
    for (usz i = 0; i < 20; i++)
    {
        node_id[i] = (char)i;
    }

    // Create test socket address (192.168.1.100:6881)
    common::SocketAddress addr;
    addr.addr.is_ipv6 = false;
    addr.addr.ipv4.a = 192;
    addr.addr.ipv4.b = 168;
    addr.addr.ipv4.c = 1;
    addr.addr.ipv4.d = 100;
    addr.port = 6881;

    // Encode to compact format
    char[26] compact = common::encode_compact_node_ipv4(node_id, addr);

    // Verify node ID (bytes 0-19)
    for (usz i = 0; i < 20; i++)
    {
        assert(compact[i] == (char)i, "Node ID byte mismatch");
    }

    // Verify IP address (bytes 20-23)
    assert(compact[20] == 192, "IP byte 0 should be 192");
    assert(compact[21] == 168, "IP byte 1 should be 168");
    assert(compact[22] == 1, "IP byte 2 should be 1");
    assert(compact[23] == 100, "IP byte 3 should be 100");

    // Verify port (bytes 24-25, big-endian)
    assert(compact[24] == (char)(6881 >> 8), "Port high byte incorrect");
    assert(compact[25] == (char)(6881 & 0xFF), "Port low byte incorrect");
}

/**
 * Test decoding a node from compact IPv4 format.
 */
fn void test_decode_compact_node_ipv4() @test
{
    // Create test compact node (26 bytes)
    char[26] compact;

    // Node ID: 20 bytes of 0xAA
    for (usz i = 0; i < 20; i++)
    {
        compact[i] = (char)0xAA;
    }

    // IP: 8.8.8.8
    compact[20] = 8;
    compact[21] = 8;
    compact[22] = 8;
    compact[23] = 8;

    // Port: 6881 (big-endian)
    compact[24] = (char)(6881 >> 8);
    compact[25] = (char)(6881 & 0xFF);

    // Decode
    common::CompactNodeIPv4 result = common::decode_compact_node_ipv4(compact[..])!!;

    // Verify node ID
    for (usz i = 0; i < 20; i++)
    {
        assert(result.node_id[i] == (char)0xAA, "Node ID byte mismatch");
    }

    // Verify IP address
    assert(!result.addr.addr.is_ipv6, "Should be IPv4");
    assert(result.addr.addr.ipv4.a == 8, "IP byte 0 should be 8");
    assert(result.addr.addr.ipv4.b == 8, "IP byte 1 should be 8");
    assert(result.addr.addr.ipv4.c == 8, "IP byte 2 should be 8");
    assert(result.addr.addr.ipv4.d == 8, "IP byte 3 should be 8");

    // Verify port
    assert(result.addr.port == 6881, "Port should be 6881");
}

/**
 * Test round-trip encoding/decoding for IPv4.
 */
fn void test_ipv4_roundtrip() @test
{
    // Create original node
    common::NodeId original_id;
    for (usz i = 0; i < 20; i++)
    {
        original_id[i] = (char)(i * 7);  // Some pattern
    }

    common::SocketAddress original_addr;
    original_addr.addr.is_ipv6 = false;
    original_addr.addr.ipv4.a = 123;
    original_addr.addr.ipv4.b = 45;
    original_addr.addr.ipv4.c = 67;
    original_addr.addr.ipv4.d = 89;
    original_addr.port = 12345;

    // Encode
    char[26] compact = common::encode_compact_node_ipv4(original_id, original_addr);

    // Decode
    common::CompactNodeIPv4 decoded = common::decode_compact_node_ipv4(compact[..])!!;

    // Verify node ID matches
    for (usz i = 0; i < 20; i++)
    {
        assert(decoded.node_id[i] == original_id[i], "Node ID roundtrip failed");
    }

    // Verify address matches
    assert(decoded.addr.addr.ipv4.a == 123, "IP roundtrip failed");
    assert(decoded.addr.addr.ipv4.b == 45, "IP roundtrip failed");
    assert(decoded.addr.addr.ipv4.c == 67, "IP roundtrip failed");
    assert(decoded.addr.addr.ipv4.d == 89, "IP roundtrip failed");
    assert(decoded.addr.port == 12345, "Port roundtrip failed");
}

/**
 * Test decoding with invalid length fails.
 */
fn void test_decode_ipv4_invalid_length() @test
{
    // Too short
    char[25] short_data;
    if (catch excuse = common::decode_compact_node_ipv4(short_data[..]))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should fail with short data");
    }

    // Too long
    char[27] long_data;
    if (catch excuse = common::decode_compact_node_ipv4(long_data[..]))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should fail with long data");
    }
}

// ============================================================================
// IPv6 Compact Node Format Tests
// ============================================================================

/**
 * Test encoding a node to compact IPv6 format.
 */
fn void test_encode_compact_node_ipv6() @test
{
    // Create test node ID (20 bytes of incrementing pattern)
    common::NodeId node_id;
    for (usz i = 0; i < 20; i++)
    {
        node_id[i] = (char)i;
    }

    // Create test IPv6 socket address (2001:db8::1:6881)
    common::SocketAddress addr;
    addr.addr.is_ipv6 = true;
    char* ipv6_bytes = (char*)&addr.addr.ipv6;

    // 2001:0db8:0000:0000:0000:0000:0000:0001
    ipv6_bytes[0] = 0x20;
    ipv6_bytes[1] = 0x01;
    ipv6_bytes[2] = 0x0d;
    ipv6_bytes[3] = 0xb8;
    for (usz i = 4; i < 15; i++) ipv6_bytes[i] = 0x00;
    ipv6_bytes[15] = 0x01;

    addr.port = 6881;

    // Encode to compact format
    char[38] compact = common::encode_compact_node_ipv6(node_id, addr);

    // Verify node ID (bytes 0-19)
    for (usz i = 0; i < 20; i++)
    {
        assert(compact[i] == (char)i, "Node ID byte mismatch");
    }

    // Verify IPv6 address (bytes 20-35)
    assert(compact[20] == 0x20, "IPv6 byte 0 incorrect");
    assert(compact[21] == 0x01, "IPv6 byte 1 incorrect");
    assert(compact[22] == 0x0d, "IPv6 byte 2 incorrect");
    assert(compact[23] == 0xb8, "IPv6 byte 3 incorrect");
    for (usz i = 24; i < 35; i++)
    {
        assert(compact[i] == 0x00, "IPv6 padding byte should be 0");
    }
    assert(compact[35] == 0x01, "IPv6 byte 15 incorrect");

    // Verify port (bytes 36-37, big-endian)
    assert(compact[36] == (char)(6881 >> 8), "Port high byte incorrect");
    assert(compact[37] == (char)(6881 & 0xFF), "Port low byte incorrect");
}

/**
 * Test decoding a node from compact IPv6 format.
 */
fn void test_decode_compact_node_ipv6() @test
{
    // Create test compact node (38 bytes)
    char[38] compact;

    // Node ID: 20 bytes of 0xBB
    for (usz i = 0; i < 20; i++)
    {
        compact[i] = (char)0xBB;
    }

    // IPv6: 2001:db8::1 (16 bytes)
    compact[20] = 0x20;
    compact[21] = 0x01;
    compact[22] = 0x0d;
    compact[23] = 0xb8;
    for (usz i = 24; i < 35; i++)
    {
        compact[i] = 0x00;
    }
    compact[35] = 0x01;

    // Port: 6881 (big-endian)
    compact[36] = (char)(6881 >> 8);
    compact[37] = (char)(6881 & 0xFF);

    // Decode
    common::CompactNodeIPv6 result = common::decode_compact_node_ipv6(compact[..])!!;

    // Verify node ID
    for (usz i = 0; i < 20; i++)
    {
        assert(result.node_id[i] == (char)0xBB, "Node ID byte mismatch");
    }

    // Verify IPv6 address
    assert(result.addr.addr.is_ipv6, "Should be IPv6");
    char* ipv6_bytes = (char*)&result.addr.addr.ipv6;
    assert(ipv6_bytes[0] == 0x20, "IPv6 byte 0 mismatch");
    assert(ipv6_bytes[1] == 0x01, "IPv6 byte 1 mismatch");
    assert(ipv6_bytes[2] == 0x0d, "IPv6 byte 2 mismatch");
    assert(ipv6_bytes[3] == 0xb8, "IPv6 byte 3 mismatch");
    for (usz i = 4; i < 15; i++)
    {
        assert(ipv6_bytes[i] == 0x00, "IPv6 padding mismatch");
    }
    assert(ipv6_bytes[15] == 0x01, "IPv6 byte 15 mismatch");

    // Verify port
    assert(result.addr.port == 6881, "Port should be 6881");
}

/**
 * Test round-trip encoding/decoding for IPv6.
 */
fn void test_ipv6_roundtrip() @test
{
    // Create original node
    common::NodeId original_id;
    for (usz i = 0; i < 20; i++)
    {
        original_id[i] = (char)(i * 11);  // Some pattern
    }

    common::SocketAddress original_addr;
    original_addr.addr.is_ipv6 = true;
    char* ipv6_bytes = (char*)&original_addr.addr.ipv6;

    // Fill with test pattern
    for (usz i = 0; i < 16; i++)
    {
        ipv6_bytes[i] = (char)(i * 13);
    }

    original_addr.port = 54321;

    // Encode
    char[38] compact = common::encode_compact_node_ipv6(original_id, original_addr);

    // Decode
    common::CompactNodeIPv6 decoded = common::decode_compact_node_ipv6(compact[..])!!;

    // Verify node ID matches
    for (usz i = 0; i < 20; i++)
    {
        assert(decoded.node_id[i] == original_id[i], "Node ID roundtrip failed");
    }

    // Verify address matches
    char* decoded_ipv6 = (char*)&decoded.addr.addr.ipv6;
    for (usz i = 0; i < 16; i++)
    {
        assert(decoded_ipv6[i] == ipv6_bytes[i], "IPv6 roundtrip failed");
    }
    assert(decoded.addr.port == 54321, "Port roundtrip failed");
}

/**
 * Test decoding with invalid length fails.
 */
fn void test_decode_ipv6_invalid_length() @test
{
    // Too short
    char[37] short_data;
    if (catch excuse = common::decode_compact_node_ipv6(short_data[..]))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should fail with short data");
    }

    // Too long
    char[39] long_data;
    if (catch excuse = common::decode_compact_node_ipv6(long_data[..]))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should fail with long data");
    }
}

// ============================================================================
// Edge Case Tests
// ============================================================================

/**
 * Test encoding with port 0 (minimum port).
 */
fn void test_port_zero() @test
{
    common::NodeId node_id;
    for (usz i = 0; i < 20; i++) node_id[i] = 0;

    common::SocketAddress addr;
    addr.addr.is_ipv6 = false;
    addr.addr.ipv4.a = 127;
    addr.addr.ipv4.b = 0;
    addr.addr.ipv4.c = 0;
    addr.addr.ipv4.d = 1;
    addr.port = 0;

    char[26] compact = common::encode_compact_node_ipv4(node_id, addr);

    assert(compact[24] == 0, "Port high byte should be 0");
    assert(compact[25] == 0, "Port low byte should be 0");

    common::CompactNodeIPv4 decoded = common::decode_compact_node_ipv4(compact[..])!!;
    assert(decoded.addr.port == 0, "Port should be 0");
}

/**
 * Test encoding with port 65535 (maximum port).
 */
fn void test_port_max() @test
{
    common::NodeId node_id;
    for (usz i = 0; i < 20; i++) node_id[i] = (char)0xFF;

    common::SocketAddress addr;
    addr.addr.is_ipv6 = false;
    addr.addr.ipv4.a = 255;
    addr.addr.ipv4.b = 255;
    addr.addr.ipv4.c = 255;
    addr.addr.ipv4.d = 255;
    addr.port = 65535;

    char[26] compact = common::encode_compact_node_ipv4(node_id, addr);

    assert(compact[24] == (char)0xFF, "Port high byte should be 0xFF");
    assert(compact[25] == (char)0xFF, "Port low byte should be 0xFF");

    common::CompactNodeIPv4 decoded = common::decode_compact_node_ipv4(compact[..])!!;
    assert(decoded.addr.port == 65535, "Port should be 65535");
}

/**
 * Test that all node ID bytes are preserved.
 */
fn void test_node_id_all_patterns() @test
{
    common::SocketAddress addr;
    addr.addr.is_ipv6 = false;
    addr.addr.ipv4.a = 1;
    addr.addr.ipv4.b = 2;
    addr.addr.ipv4.c = 3;
    addr.addr.ipv4.d = 4;
    addr.port = 6881;

    // Test with all 0xFF
    common::NodeId id1;
    for (usz i = 0; i < 20; i++) id1[i] = (char)0xFF;
    char[26] compact1 = common::encode_compact_node_ipv4(id1, addr);
    common::CompactNodeIPv4 decoded1 = common::decode_compact_node_ipv4(compact1[..])!!;
    for (usz i = 0; i < 20; i++)
    {
        assert(decoded1.node_id[i] == (char)0xFF, "All 0xFF pattern failed");
    }

    // Test with all 0x00
    common::NodeId id2;
    for (usz i = 0; i < 20; i++) id2[i] = 0;
    char[26] compact2 = common::encode_compact_node_ipv4(id2, addr);
    common::CompactNodeIPv4 decoded2 = common::decode_compact_node_ipv4(compact2[..])!!;
    for (usz i = 0; i < 20; i++)
    {
        assert(decoded2.node_id[i] == 0, "All 0x00 pattern failed");
    }

    // Test with alternating 0xAA/0x55
    common::NodeId id3;
    for (usz i = 0; i < 20; i++) id3[i] = (i % 2 == 0) ? (char)0xAA : (char)0x55;
    char[26] compact3 = common::encode_compact_node_ipv4(id3, addr);
    common::CompactNodeIPv4 decoded3 = common::decode_compact_node_ipv4(compact3[..])!!;
    for (usz i = 0; i < 20; i++)
    {
        char expected = (i % 2 == 0) ? (char)0xAA : (char)0x55;
        assert(decoded3.node_id[i] == expected, "Alternating pattern failed");
    }
}
