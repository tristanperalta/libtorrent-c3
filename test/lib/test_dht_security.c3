module libtorrent::krpc::security_test;

import std::io;
import libtorrent::krpc;
import libtorrent::common;

/**
 * DHT Security Validation Test Suite
 * ===================================
 * Tests for IP address and port validation to prevent security issues
 */

// Helper function to create a test IP address
fn common::Ipv4Addr create_ip(char a, char b, char c, char d)
{
    common::Ipv4Addr ip;
    ip[0] = a;
    ip[1] = b;
    ip[2] = c;
    ip[3] = d;
    return ip;
}

// ============================================================================
// IP Address Validation Tests
// ============================================================================

fn void test_reject_loopback_ip() @test
{
    // 127.0.0.1 should be rejected (loopback)
    common::Ipv4Addr loopback = create_ip(127, 0, 0, 1);
    bool is_private = krpc::is_private_or_reserved_ip(loopback);
    assert(is_private, "127.0.0.1 should be private/reserved");

    bool is_valid = krpc::is_valid_dht_ip(loopback);
    assert(!is_valid, "127.0.0.1 should not be valid for DHT");

    io::printn("✓ Reject loopback IP (127.0.0.1)");
}

fn void test_reject_zero_ip() @test
{
    // 0.0.0.0 should be rejected (current network)
    common::Ipv4Addr zero = create_ip(0, 0, 0, 0);
    bool is_private = krpc::is_private_or_reserved_ip(zero);
    assert(is_private, "0.0.0.0 should be private/reserved");

    bool is_valid = krpc::is_valid_dht_ip(zero);
    assert(!is_valid, "0.0.0.0 should not be valid for DHT");

    io::printn("✓ Reject zero IP (0.0.0.0)");
}

fn void test_reject_private_ip_10() @test
{
    // 10.x.x.x should be rejected (private network)
    common::Ipv4Addr private_10 = create_ip(10, 1, 2, 3);
    bool is_private = krpc::is_private_or_reserved_ip(private_10);
    assert(is_private, "10.1.2.3 should be private/reserved");

    bool is_valid = krpc::is_valid_dht_ip(private_10);
    assert(!is_valid, "10.1.2.3 should not be valid for DHT");

    io::printn("✓ Reject private IP (10.x.x.x)");
}

fn void test_reject_private_ip_192() @test
{
    // 192.168.x.x should be rejected (private network)
    common::Ipv4Addr private_192 = create_ip(192, 168, 1, 1);
    bool is_private = krpc::is_private_or_reserved_ip(private_192);
    assert(is_private, "192.168.1.1 should be private/reserved");

    bool is_valid = krpc::is_valid_dht_ip(private_192);
    assert(!is_valid, "192.168.1.1 should not be valid for DHT");

    io::printn("✓ Reject private IP (192.168.x.x)");
}

fn void test_reject_private_ip_172() @test
{
    // 172.16.x.x - 172.31.x.x should be rejected (private network)
    common::Ipv4Addr private_172_16 = create_ip(172, 16, 0, 1);
    bool is_private_16 = krpc::is_private_or_reserved_ip(private_172_16);
    assert(is_private_16, "172.16.0.1 should be private/reserved");

    common::Ipv4Addr private_172_31 = create_ip(172, 31, 255, 255);
    bool is_private_31 = krpc::is_private_or_reserved_ip(private_172_31);
    assert(is_private_31, "172.31.255.255 should be private/reserved");

    // 172.15.x.x should NOT be rejected (outside range)
    common::Ipv4Addr not_private_15 = create_ip(172, 15, 0, 1);
    bool is_private_15 = krpc::is_private_or_reserved_ip(not_private_15);
    assert(!is_private_15, "172.15.0.1 should NOT be private");

    // 172.32.x.x should NOT be rejected (outside range)
    common::Ipv4Addr not_private_32 = create_ip(172, 32, 0, 1);
    bool is_private_32 = krpc::is_private_or_reserved_ip(not_private_32);
    assert(!is_private_32, "172.32.0.1 should NOT be private");

    io::printn("✓ Reject private IP (172.16-31.x.x)");
}

fn void test_reject_multicast_ip() @test
{
    // 224.0.0.0 - 239.255.255.255 should be rejected (multicast)
    common::Ipv4Addr multicast_224 = create_ip(224, 0, 0, 1);
    bool is_private_224 = krpc::is_private_or_reserved_ip(multicast_224);
    assert(is_private_224, "224.0.0.1 should be private/reserved (multicast)");

    common::Ipv4Addr multicast_239 = create_ip(239, 255, 255, 255);
    bool is_private_239 = krpc::is_private_or_reserved_ip(multicast_239);
    assert(is_private_239, "239.255.255.255 should be private/reserved (multicast)");

    io::printn("✓ Reject multicast IP (224-239.x.x.x)");
}

fn void test_reject_link_local_ip() @test
{
    // 169.254.x.x should be rejected (link-local)
    common::Ipv4Addr link_local = create_ip(169, 254, 1, 1);
    bool is_private = krpc::is_private_or_reserved_ip(link_local);
    assert(is_private, "169.254.1.1 should be private/reserved (link-local)");

    bool is_valid = krpc::is_valid_dht_ip(link_local);
    assert(!is_valid, "169.254.1.1 should not be valid for DHT");

    io::printn("✓ Reject link-local IP (169.254.x.x)");
}

fn void test_accept_public_ip() @test
{
    // 8.8.8.8 should be accepted (Google Public DNS - valid public IP)
    common::Ipv4Addr public_ip = create_ip(8, 8, 8, 8);
    bool is_private = krpc::is_private_or_reserved_ip(public_ip);
    assert(!is_private, "8.8.8.8 should NOT be private/reserved");

    bool is_valid = krpc::is_valid_dht_ip(public_ip);
    assert(is_valid, "8.8.8.8 should be valid for DHT");

    // Test another public IP
    common::Ipv4Addr public_ip2 = create_ip(1, 1, 1, 1);
    bool is_valid2 = krpc::is_valid_dht_ip(public_ip2);
    assert(is_valid2, "1.1.1.1 should be valid for DHT");

    io::printn("✓ Accept public IP addresses");
}

// ============================================================================
// Port Validation Tests
// ============================================================================

fn void test_reject_port_zero() @test
{
    // Port 0 should be rejected (invalid)
    bool is_valid = krpc::is_valid_dht_port(0);
    assert(!is_valid, "Port 0 should not be valid");

    io::printn("✓ Reject port 0");
}

fn void test_reject_port_65535() @test
{
    // Port 65535 should be rejected (often used as invalid marker)
    bool is_valid = krpc::is_valid_dht_port(65535);
    assert(!is_valid, "Port 65535 should not be valid");

    io::printn("✓ Reject port 65535");
}

fn void test_accept_valid_port() @test
{
    // Port 6881 should be accepted (standard BitTorrent port)
    bool is_valid_6881 = krpc::is_valid_dht_port(6881);
    assert(is_valid_6881, "Port 6881 should be valid");

    // Port 1 should be accepted (minimum valid port)
    bool is_valid_1 = krpc::is_valid_dht_port(1);
    assert(is_valid_1, "Port 1 should be valid");

    // Port 65534 should be accepted (maximum valid port)
    bool is_valid_65534 = krpc::is_valid_dht_port(65534);
    assert(is_valid_65534, "Port 65534 should be valid");

    io::printn("✓ Accept valid ports");
}

// ============================================================================
// Combined IP + Port Validation Tests
// ============================================================================

fn void test_validate_combined_valid_address() @test
{
    // Valid public IP + valid port should pass
    common::Ipv4Addr public_ip = create_ip(8, 8, 8, 8);
    bool is_valid = krpc::is_valid_dht_address(public_ip, 6881);
    assert(is_valid, "8.8.8.8:6881 should be valid");

    io::printn("✓ Validate combined valid IP and port");
}

fn void test_validate_combined_invalid_ip() @test
{
    // Private IP + valid port should fail
    common::Ipv4Addr private_ip = create_ip(192, 168, 1, 1);
    bool is_valid = krpc::is_valid_dht_address(private_ip, 6881);
    assert(!is_valid, "192.168.1.1:6881 should not be valid (private IP)");

    io::printn("✓ Reject combined address with invalid IP");
}

fn void test_validate_combined_invalid_port() @test
{
    // Valid public IP + invalid port should fail
    common::Ipv4Addr public_ip = create_ip(8, 8, 8, 8);
    bool is_valid = krpc::is_valid_dht_address(public_ip, 0);
    assert(!is_valid, "8.8.8.8:0 should not be valid (invalid port)");

    io::printn("✓ Reject combined address with invalid port");
}

fn void test_validate_combined_both_invalid() @test
{
    // Private IP + invalid port should fail
    common::Ipv4Addr private_ip = create_ip(127, 0, 0, 1);
    bool is_valid = krpc::is_valid_dht_address(private_ip, 0);
    assert(!is_valid, "127.0.0.1:0 should not be valid (both invalid)");

    io::printn("✓ Reject combined address with both IP and port invalid");
}
