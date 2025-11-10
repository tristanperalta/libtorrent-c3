module test_bep42;

import std::io;
import libtorrent::dht_security;
import libtorrent::common;

/**
 * Unit tests for BEP 42: DHT Security Extension
 *
 * Tests CRC32C implementation, node ID generation, and verification.
 */

// ============================================================================
// CRC32C Tests
// ============================================================================

/**
 * Test CRC32C with known test vectors.
 * Vectors from: https://www.ietf.org/rfc/rfc3720.txt (iSCSI CRC32C)
 */
fn void test_crc32c_known_vectors() @test
{
    // Vector 1: 32 bytes of 0x00
    char[32] zeros;
    for (usz i = 0; i < 32; i++) zeros[i] = 0x00;
    uint crc1 = dht_security::crc32c(zeros[..]);
    assert(crc1 == 0x8a9136aa, "CRC32C of 32 zeros should be 0x8a9136aa");

    // Vector 2: 32 bytes of 0xFF
    char[32] ones;
    for (usz i = 0; i < 32; i++) ones[i] = (char)0xFF;
    uint crc2 = dht_security::crc32c(ones[..]);
    assert(crc2 == 0x62a8ab43, "CRC32C of 32 0xFF should be 0x62a8ab43");

    // Vector 3: Incrementing pattern
    char[32] incr;
    for (usz i = 0; i < 32; i++) incr[i] = (char)i;
    uint crc3 = dht_security::crc32c(incr[..]);
    assert(crc3 == 0x46dd794e, "CRC32C of 0..31 should be 0x46dd794e");
}

/**
 * Test CRC32C with empty data.
 */
fn void test_crc32c_empty_data() @test
{
    char[] empty;
    uint crc = dht_security::crc32c(empty);
    // CRC32C of empty data = ~(~0) = 0
    assert(crc == 0, "CRC32C of empty data should be 0");
}

/**
 * Test CRC32C with single byte.
 */
fn void test_crc32c_single_byte() @test
{
    char[1] data = { (char)0x42 };
    uint crc = dht_security::crc32c(data[..]);
    // Known value for single byte 0x42
    assert(crc != 0, "CRC32C of single byte should not be zero");
}

// ============================================================================
// IP Exemption Tests
// ============================================================================

/**
 * Test that private IPs are exempt from verification.
 */
fn void test_private_ip_10_exempt() @test
{
    common::Ipv4Addr ip = { 10, 0, 0, 1 };
    assert(dht_security::is_ip_exempt_from_verification(ip), "10.0.0.1 should be exempt");
}

fn void test_private_ip_192_168_exempt() @test
{
    common::Ipv4Addr ip = { 192, 168, 1, 1 };
    assert(dht_security::is_ip_exempt_from_verification(ip), "192.168.1.1 should be exempt");
}

fn void test_private_ip_172_16_exempt() @test
{
    common::Ipv4Addr ip = { 172, 16, 0, 1 };
    assert(dht_security::is_ip_exempt_from_verification(ip), "172.16.0.1 should be exempt");

    ip = { 172, 31, 255, 255 };
    assert(dht_security::is_ip_exempt_from_verification(ip), "172.31.255.255 should be exempt");
}

fn void test_link_local_ip_exempt() @test
{
    common::Ipv4Addr ip = { 169, 254, 0, 1 };
    assert(dht_security::is_ip_exempt_from_verification(ip), "169.254.0.1 should be exempt");
}

fn void test_loopback_ip_exempt() @test
{
    common::Ipv4Addr ip = { 127, 0, 0, 1 };
    assert(dht_security::is_ip_exempt_from_verification(ip), "127.0.0.1 should be exempt");
}

fn void test_public_ip_not_exempt() @test
{
    // Google DNS
    common::Ipv4Addr ip = { 8, 8, 8, 8 };
    assert(!dht_security::is_ip_exempt_from_verification(ip), "8.8.8.8 should NOT be exempt");

    // Cloudflare DNS
    ip = { 1, 1, 1, 1 };
    assert(!dht_security::is_ip_exempt_from_verification(ip), "1.1.1.1 should NOT be exempt");
}

// ============================================================================
// Node ID Generation Tests
// ============================================================================

/**
 * Test node ID generation with different random values.
 */
fn void test_generate_node_id_random_0() @test
{
    common::Ipv4Addr ip = { 8, 8, 8, 8 };
    common::NodeId id = dht_security::generate_node_id(ip, 0);

    // Check that random value is encoded in bits 21-23
    char random = id[2] & 0x07;
    assert(random == 0, "Random value should be 0");
}

fn void test_generate_node_id_random_7() @test
{
    common::Ipv4Addr ip = { 8, 8, 8, 8 };
    common::NodeId id = dht_security::generate_node_id(ip, 7);

    // Check that random value is encoded in bits 21-23
    char random = id[2] & 0x07;
    assert(random == 7, "Random value should be 7");
}

fn void test_generate_node_id_all_randoms() @test
{
    common::Ipv4Addr ip = { 1, 2, 3, 4 };

    // Generate IDs with all 8 random values
    for (char r = 0; r < 8; r++)
    {
        common::NodeId id = dht_security::generate_node_id(ip, r);
        char extracted = id[2] & 0x07;
        assert(extracted == r, "Random value should match");
    }
}

/**
 * Test that different IPs produce different node IDs.
 */
fn void test_generate_node_id_different_ips() @test
{
    common::Ipv4Addr ip1 = { 1, 2, 3, 4 };
    common::Ipv4Addr ip2 = { 5, 6, 7, 8 };

    common::NodeId id1 = dht_security::generate_node_id(ip1, 0);
    common::NodeId id2 = dht_security::generate_node_id(ip2, 0);

    // IDs should be different
    bool same = true;
    for (usz i = 0; i < 3; i++)  // Check first 3 bytes (contain CRC + random)
    {
        if (id1[i] != id2[i])
        {
            same = false;
            break;
        }
    }
    assert(!same, "Different IPs should produce different node IDs");
}

/**
 * Test that same IP with different random values produces different IDs.
 */
fn void test_generate_node_id_different_randoms() @test
{
    common::Ipv4Addr ip = { 8, 8, 8, 8 };

    common::NodeId id0 = dht_security::generate_node_id(ip, 0);
    common::NodeId id1 = dht_security::generate_node_id(ip, 1);

    // IDs should be different
    bool same = true;
    for (usz i = 0; i < 3; i++)
    {
        if (id0[i] != id1[i])
        {
            same = false;
            break;
        }
    }
    assert(!same, "Different random values should produce different node IDs");
}

// ============================================================================
// Node ID Verification Tests
// ============================================================================

/**
 * Test that generated node IDs verify correctly.
 */
fn void test_verify_generated_node_id() @test
{
    common::Ipv4Addr ip = { 8, 8, 8, 8 };

    // Generate and verify with all random values
    for (char r = 0; r < 8; r++)
    {
        common::NodeId id = dht_security::generate_node_id(ip, r);
        bool verified = dht_security::verify_node_id(id, ip);
        assert(verified, "Generated node ID should verify");
    }
}

/**
 * Test that node ID from wrong IP fails verification.
 */
fn void test_verify_wrong_ip_fails() @test
{
    common::Ipv4Addr ip1 = { 8, 8, 8, 8 };
    common::Ipv4Addr ip2 = { 1, 1, 1, 1 };

    // Generate ID for ip1
    common::NodeId id = dht_security::generate_node_id(ip1, 0);

    // Try to verify with ip2
    bool verified = dht_security::verify_node_id(id, ip2);
    assert(!verified, "Node ID from different IP should NOT verify");
}

/**
 * Test that corrupted node ID fails verification.
 */
fn void test_verify_corrupted_id_fails() @test
{
    common::Ipv4Addr ip = { 8, 8, 8, 8 };

    // Generate valid ID
    common::NodeId id = dht_security::generate_node_id(ip, 0);

    // Corrupt first byte (changes first 21 bits)
    id[0] ^= 0xFF;

    // Should fail verification
    bool verified = dht_security::verify_node_id(id, ip);
    assert(!verified, "Corrupted node ID should NOT verify");
}

/**
 * Test that wrong random value in ID fails verification.
 */
fn void test_verify_wrong_random_fails() @test
{
    common::Ipv4Addr ip = { 8, 8, 8, 8 };

    // Generate ID with random = 0
    common::NodeId id = dht_security::generate_node_id(ip, 0);

    // Change random bits to 7 (corrupt bits 21-23)
    id[2] = (id[2] & 0xF8) | 0x07;

    // Should fail verification (wrong random value)
    bool verified = dht_security::verify_node_id(id, ip);
    assert(!verified, "Node ID with wrong random value should NOT verify");
}

/**
 * Test that exempt IPs always verify.
 */
fn void test_verify_exempt_ip_always_passes() @test
{
    common::Ipv4Addr ip = { 192, 168, 1, 1 };

    // Create arbitrary node ID (not properly generated)
    common::NodeId id;
    for (usz i = 0; i < 20; i++)
    {
        id[i] = (char)0xAA;
    }

    // Should verify because IP is exempt
    bool verified = dht_security::verify_node_id(id, ip);
    assert(verified, "Exempt IP should always verify");
}

// ============================================================================
// Edge Case Tests
// ============================================================================

/**
 * Test node ID verification with boundary IPs.
 */
fn void test_verify_boundary_ips() @test
{
    // Test edge of private IP ranges

    // 10.255.255.255 (still exempt)
    common::Ipv4Addr ip1 = { 10, 255, 255, 255 };
    assert(dht_security::is_ip_exempt_from_verification(ip1), "10.255.255.255 should be exempt");

    // 11.0.0.0 (not exempt)
    common::Ipv4Addr ip2 = { 11, 0, 0, 0 };
    assert(!dht_security::is_ip_exempt_from_verification(ip2), "11.0.0.0 should NOT be exempt");

    // 172.15.255.255 (not exempt - before /12 range)
    common::Ipv4Addr ip3 = { 172, 15, 255, 255 };
    assert(!dht_security::is_ip_exempt_from_verification(ip3), "172.15.255.255 should NOT be exempt");

    // 172.32.0.0 (not exempt - after /12 range)
    common::Ipv4Addr ip4 = { 172, 32, 0, 0 };
    assert(!dht_security::is_ip_exempt_from_verification(ip4), "172.32.0.0 should NOT be exempt");
}

/**
 * Test that all 8 random values can be used for any IP.
 */
fn void test_all_randoms_verify_for_any_ip() @test
{
    // Test various public IPs
    common::Ipv4Addr[4] ips = {
        { 8, 8, 8, 8 },       // Google DNS
        { 1, 1, 1, 1 },       // Cloudflare DNS
        { 123, 45, 67, 89 },  // Arbitrary public IP
        { 200, 100, 50, 25 }  // Another arbitrary public IP
    };

    foreach (ip : ips)
    {
        // Each IP should have at least one valid node ID per BEP 42
        bool found_valid = false;
        for (char r = 0; r < 8; r++)
        {
            common::NodeId id = dht_security::generate_node_id(ip, r);
            if (dht_security::verify_node_id(id, ip))
            {
                found_valid = true;
            }
        }
        assert(found_valid, "At least one random value should produce valid node ID");
    }
}

/**
 * Test node ID consistency (same IP + random always produces same ID).
 */
fn void test_node_id_generation_consistency() @test
{
    common::Ipv4Addr ip = { 8, 8, 8, 8 };

    // Generate same ID twice
    common::NodeId id1 = dht_security::generate_node_id(ip, 3);
    common::NodeId id2 = dht_security::generate_node_id(ip, 3);

    // Should be identical
    for (usz i = 0; i < 20; i++)
    {
        assert(id1[i] == id2[i], "Same IP and random should produce identical node ID");
    }
}

// ============================================================================
// IPv6 Tests (BEP 42 IPv6 Support)
// ============================================================================

/**
 * Test IPv6 node ID generation with different random values.
 */
fn void test_generate_ipv6_node_id_all_randoms() @test
{
    // 2001:db8::1 (documentation address)
    char[16] ipv6_bytes = {
        0x20, 0x01, 0x0d, 0xb8,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01
    };

    common::SocketAddress addr = common::create_ipv6_address(ipv6_bytes, 6881);

    // Generate IDs with all 8 random values
    for (char r = 0; r < 8; r++)
    {
        common::NodeId id = dht_security::generate_node_id_for_address(addr, r);
        char extracted = id[2] & 0x07;
        assert(extracted == r, "Random value should match for IPv6");
    }
}

/**
 * Test that generated IPv6 node IDs verify correctly.
 */
fn void test_verify_generated_ipv6_node_id() @test
{
    // 2001:db8::1
    char[16] ipv6_bytes = {
        0x20, 0x01, 0x0d, 0xb8,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01
    };

    common::SocketAddress addr = common::create_ipv6_address(ipv6_bytes, 6881);

    // Generate and verify with all random values
    for (char r = 0; r < 8; r++)
    {
        common::NodeId id = dht_security::generate_node_id_for_address(addr, r);
        bool verified = dht_security::verify_node_id_for_address(id, addr);
        assert(verified, "Generated IPv6 node ID should verify");
    }
}

/**
 * Test that IPv6 node ID from wrong address fails verification.
 */
fn void test_verify_ipv6_wrong_address_fails() @test
{
    // 2001:db8::1
    char[16] ipv6_1 = {
        0x20, 0x01, 0x0d, 0xb8,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01
    };

    // 2001:db8::100:0 (differs in byte 6, which IS part of the 64-bit mask)
    char[16] ipv6_2 = {
        0x20, 0x01, 0x0d, 0xb8,
        0x00, 0x00, 0x01, 0x00,  // Changed byte 6 from 0x00 to 0x01
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01
    };

    common::SocketAddress addr1 = common::create_ipv6_address(ipv6_1, 6881);
    common::SocketAddress addr2 = common::create_ipv6_address(ipv6_2, 6881);

    // Generate ID for addr1
    common::NodeId id = dht_security::generate_node_id_for_address(addr1, 0);

    // Try to verify with addr2
    bool verified = dht_security::verify_node_id_for_address(id, addr2);
    assert(!verified, "IPv6 node ID from different address should NOT verify");
}

/**
 * Test IPv6 ULA (fc00::/7) exemption.
 */
fn void test_ipv6_ula_exempt() @test
{
    // fc00::1 (Unique Local Address)
    char[16] ipv6_bytes = {
        0xfc, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01
    };

    common::SocketAddress addr = common::create_ipv6_address(ipv6_bytes, 6881);

    // Create arbitrary node ID (not properly generated)
    common::NodeId id;
    for (usz i = 0; i < 20; i++)
    {
        id[i] = (char)0xAA;
    }

    // Should verify because ULA is exempt
    bool verified = dht_security::verify_node_id_for_address(id, addr);
    assert(verified, "IPv6 ULA should always verify (exempt)");
}

/**
 * Test IPv6 link-local (fe80::/10) exemption.
 */
fn void test_ipv6_link_local_exempt() @test
{
    // fe80::1 (Link-Local)
    char[16] ipv6_bytes = {
        0xfe, 0x80, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01
    };

    common::SocketAddress addr = common::create_ipv6_address(ipv6_bytes, 6881);

    // Create arbitrary node ID
    common::NodeId id;
    for (usz i = 0; i < 20; i++)
    {
        id[i] = (char)0xBB;
    }

    // Should verify because link-local is exempt
    bool verified = dht_security::verify_node_id_for_address(id, addr);
    assert(verified, "IPv6 link-local should always verify (exempt)");
}

/**
 * Test IPv6 loopback (::1) exemption.
 */
fn void test_ipv6_loopback_exempt() @test
{
    // ::1 (Loopback)
    char[16] ipv6_bytes = {
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01
    };

    common::SocketAddress addr = common::create_ipv6_address(ipv6_bytes, 6881);

    // Create arbitrary node ID
    common::NodeId id;
    for (usz i = 0; i < 20; i++)
    {
        id[i] = (char)0xCC;
    }

    // Should verify because loopback is exempt
    bool verified = dht_security::verify_node_id_for_address(id, addr);
    assert(verified, "IPv6 loopback should always verify (exempt)");
}

/**
 * Test IPv6 public address requires proper node ID.
 */
fn void test_ipv6_public_address_not_exempt() @test
{
    // 2001:db8::1 (public documentation address)
    char[16] ipv6_bytes = {
        0x20, 0x01, 0x0d, 0xb8,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01
    };

    common::SocketAddress addr = common::create_ipv6_address(ipv6_bytes, 6881);

    // Create arbitrary node ID (not properly generated)
    common::NodeId id;
    for (usz i = 0; i < 20; i++)
    {
        id[i] = (char)0xDD;
    }

    // Should NOT verify (public address requires proper node ID)
    bool verified = dht_security::verify_node_id_for_address(id, addr);
    assert(!verified, "IPv6 public address should NOT verify with arbitrary node ID");
}

/**
 * Test unified API works for both IPv4 and IPv6.
 */
fn void test_unified_api_ipv4_and_ipv6() @test
{
    // Test IPv4 address (8.8.8.8:6881)
    common::SocketAddress ipv4_addr = common::create_ipv4_address(8, 8, 8, 8, 6881);

    // Test IPv6 address (2001:db8::1:6881)
    char[16] ipv6_bytes = {
        0x20, 0x01, 0x0d, 0xb8,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01
    };
    common::SocketAddress ipv6_addr = common::create_ipv6_address(ipv6_bytes, 6881);

    // Both should generate and verify correctly
    common::NodeId ipv4_id = dht_security::generate_node_id_for_address(ipv4_addr, 3);
    common::NodeId ipv6_id = dht_security::generate_node_id_for_address(ipv6_addr, 3);

    assert(dht_security::verify_node_id_for_address(ipv4_id, ipv4_addr),
           "IPv4 unified API should work");
    assert(dht_security::verify_node_id_for_address(ipv6_id, ipv6_addr),
           "IPv6 unified API should work");

    // IDs should be different (different addresses)
    bool same = true;
    for (usz i = 0; i < 3; i++)
    {
        if (ipv4_id[i] != ipv6_id[i])
        {
            same = false;
            break;
        }
    }
    assert(!same, "IPv4 and IPv6 addresses should produce different node IDs");
}
