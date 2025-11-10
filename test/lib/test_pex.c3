module libtorrent::pex::test;

import libtorrent::pex;
import libtorrent::common;
import std::io;

// ============================================================================
// IP Address Validation Tests
// ============================================================================

fn void test_private_ip_10_0_0_0() @test
{
    common::Ipv4Addr ip = {10, 0, 0, 1};
    assert(pex::is_private_or_reserved_ip(ip), "10.0.0.1 should be private");
}

fn void test_private_ip_192_168() @test
{
    common::Ipv4Addr ip = {192, 168, 1, 1};
    assert(pex::is_private_or_reserved_ip(ip), "192.168.1.1 should be private");
}

fn void test_private_ip_172_16() @test
{
    common::Ipv4Addr ip = {172, 16, 0, 1};
    assert(pex::is_private_or_reserved_ip(ip), "172.16.0.1 should be private");
}

fn void test_private_ip_172_31() @test
{
    common::Ipv4Addr ip = {172, 31, 255, 255};
    assert(pex::is_private_or_reserved_ip(ip), "172.31.255.255 should be private");
}

fn void test_loopback_ip() @test
{
    common::Ipv4Addr ip = {127, 0, 0, 1};
    assert(pex::is_private_or_reserved_ip(ip), "127.0.0.1 should be loopback");
}

fn void test_link_local_ip() @test
{
    common::Ipv4Addr ip = {169, 254, 1, 1};
    assert(pex::is_private_or_reserved_ip(ip), "169.254.1.1 should be link-local");
}

fn void test_multicast_ip() @test
{
    common::Ipv4Addr ip = {224, 0, 0, 1};
    assert(pex::is_private_or_reserved_ip(ip), "224.0.0.1 should be multicast");
}

fn void test_reserved_ip() @test
{
    common::Ipv4Addr ip = {240, 0, 0, 1};
    assert(pex::is_private_or_reserved_ip(ip), "240.0.0.1 should be reserved");
}

fn void test_public_ip_8_8_8_8() @test
{
    common::Ipv4Addr ip = {8, 8, 8, 8};
    assert(!pex::is_private_or_reserved_ip(ip), "8.8.8.8 should be public");
}

fn void test_public_ip_1_1_1_1() @test
{
    common::Ipv4Addr ip = {1, 1, 1, 1};
    assert(!pex::is_private_or_reserved_ip(ip), "1.1.1.1 should be public");
}

fn void test_valid_pex_peer() @test
{
    pex::PexPeer peer;
    peer.ip = {8, 8, 8, 8};
    peer.port = 6881;
    peer.flags = 0;

    assert(pex::is_valid_pex_peer(&peer), "Public IP with valid port should be valid");
}

fn void test_invalid_pex_peer_private_ip() @test
{
    pex::PexPeer peer;
    peer.ip = {192, 168, 1, 1};
    peer.port = 6881;
    peer.flags = 0;

    assert(!pex::is_valid_pex_peer(&peer), "Private IP should be invalid");
}

fn void test_invalid_pex_peer_zero_port() @test
{
    pex::PexPeer peer;
    peer.ip = {8, 8, 8, 8};
    peer.port = 0;
    peer.flags = 0;

    assert(!pex::is_valid_pex_peer(&peer), "Zero port should be invalid");
}

// ============================================================================
// Compact Format Tests
// ============================================================================

fn void test_encode_compact_peer() @test
{
    pex::PexPeer peer;
    peer.ip[0] = 192;
    peer.ip[1] = 168;
    peer.ip[2] = 1;
    peer.ip[3] = 100;
    peer.port = 6881;
    peer.flags = 0;

    char[] compact = pex::encode_compact_peer(&peer);
    defer free(compact);

    assert(compact.len == 6, "Compact peer should be 6 bytes");
    assert(compact[0] == (char)192, "IP byte 0 should match");
    assert(compact[1] == (char)168, "IP byte 1 should match");
    assert(compact[2] == (char)1, "IP byte 2 should match");
    assert(compact[3] == (char)100, "IP byte 3 should match");

    // Port 6881 = 0x1AE1 in big-endian
    assert(compact[4] == (char)0x1A, "Port high byte should match");
    assert(compact[5] == (char)0xE1, "Port low byte should match");
}

fn void test_encode_compact_peers_multiple() @test
{
    pex::PexPeer[] peers = mem::new_array(pex::PexPeer, 3);
    defer free(peers);

    // Peer 1: 10.0.0.1:8080
    peers[0].ip = {10, 0, 0, 1};
    peers[0].port = 8080;
    peers[0].flags = 0;

    // Peer 2: 172.16.0.1:6881
    peers[1].ip = {172, 16, 0, 1};
    peers[1].port = 6881;
    peers[1].flags = 0;

    // Peer 3: 192.168.1.1:51413
    peers[2].ip = {192, 168, 1, 1};
    peers[2].port = 51413;
    peers[2].flags = 0;

    char[] compact = pex::encode_compact_peers(peers);
    defer free(compact);

    assert(compact.len == 18, "3 peers should be 18 bytes");

    // Verify first peer
    assert(compact[0] == (char)10, "Peer 1 IP byte 0");
    assert(compact[1] == (char)0, "Peer 1 IP byte 1");
    assert(compact[2] == (char)0, "Peer 1 IP byte 2");
    assert(compact[3] == (char)1, "Peer 1 IP byte 3");
}

fn void test_encode_compact_peers_empty() @test
{
    pex::PexPeer[] peers = {};
    char[] compact = pex::encode_compact_peers(peers);
    assert(compact.len == 0, "Empty peers should produce empty string");
}

fn void test_decode_compact_peers() @test
{
    // Create compact format: 192.168.1.100:6881
    char[6] compact;
    compact[0] = (char)192;
    compact[1] = (char)168;
    compact[2] = (char)1;
    compact[3] = (char)100;
    compact[4] = (char)0x1A;  // Port 6881 = 0x1AE1
    compact[5] = (char)0xE1;

    char[] flags = {};
    pex::PexPeer[]? peers_opt = pex::decode_compact_peers(compact[..], flags);
    if (catch err = peers_opt)
    {
        assert(false, "Should decode valid compact format");
        return;
    }

    pex::PexPeer[] peers = peers_opt;
    defer free(peers);

    assert(peers.len == 1, "Should have 1 peer");
    assert(peers[0].ip[0] == 192, "IP byte 0 should match");
    assert(peers[0].ip[1] == 168, "IP byte 1 should match");
    assert(peers[0].ip[2] == 1, "IP byte 2 should match");
    assert(peers[0].ip[3] == 100, "IP byte 3 should match");
    assert(peers[0].port == 6881, "Port should match");
    assert(peers[0].flags == 0, "Flags should be 0 when not provided");
}

fn void test_decode_compact_peers_with_flags() @test
{
    // Create compact format: 10.0.0.1:8080
    char[6] compact;
    compact[0] = (char)10;
    compact[1] = (char)0;
    compact[2] = (char)0;
    compact[3] = (char)1;
    compact[4] = (char)0x1F;  // Port 8080 = 0x1F90
    compact[5] = (char)0x90;

    // Flags: seed + reachable
    char[1] flags;
    flags[0] = (char)(pex::PexFlags.SEED | pex::PexFlags.REACHABLE);

    pex::PexPeer[]? peers_opt = pex::decode_compact_peers(compact[..], flags[..]);
    peers_opt!!;
    pex::PexPeer[] peers = peers_opt!!;
    defer free(peers);

    assert(peers.len == 1, "Should have 1 peer");
    assert(peers[0].port == 8080, "Port should be 8080");
    assert(peers[0].flags == (char)(pex::PexFlags.SEED | pex::PexFlags.REACHABLE),
           "Flags should match");
}

fn void test_decode_compact_peers_invalid_length() @test
{
    // 5 bytes (not a multiple of 6)
    char[5] invalid;
    char[] flags = {};

    pex::PexPeer[]? result = pex::decode_compact_peers(invalid[..], flags);
    if (catch err = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail on invalid length");
}

fn void test_decode_compact_peers_empty() @test
{
    char[] empty = {};
    char[] flags = {};

    pex::PexPeer[]? peers_opt = pex::decode_compact_peers(empty, flags);
    peers_opt!!;
    pex::PexPeer[] peers = peers_opt!!;

    assert(peers.len == 0, "Empty compact should give empty array");
}

// ============================================================================
// PEX Message Encoding Tests
// ============================================================================

fn void test_encode_pex_message_with_added() @test
{
    pex::PexMessage msg;

    // Add 2 peers
    msg.added = mem::new_array(pex::PexPeer, 2);
    msg.added[0].ip = {192, 168, 1, 1};
    msg.added[0].port = 6881;
    msg.added[0].flags = (char)pex::PexFlags.SEED;

    msg.added[1].ip = {10, 0, 0, 1};
    msg.added[1].port = 8080;
    msg.added[1].flags = (char)pex::PexFlags.REACHABLE;

    msg.dropped = {};
    msg.added6 = {};
    msg.dropped6 = {};

    char[] encoded = pex::encode_pex_message(&msg);
    defer free(encoded);
    defer free(msg.added);

    assert(encoded.len > 0, "Encoded message should not be empty");

    // Should contain "added" key
    String encoded_str = (String)encoded;
    assert(encoded_str.contains("5:added"), "Should contain 'added' key");
    assert(encoded_str.contains("7:added.f"), "Should contain 'added.f' key");
}

fn void test_encode_pex_message_with_dropped() @test
{
    pex::PexMessage msg;
    msg.added = {};
    msg.added6 = {};
    msg.dropped6 = {};

    // Add 1 dropped peer
    msg.dropped = mem::new_array(pex::PexPeer, 1);
    msg.dropped[0].ip = {172, 16, 0, 1};
    msg.dropped[0].port = 51413;
    msg.dropped[0].flags = 0;

    char[] encoded = pex::encode_pex_message(&msg);
    defer free(encoded);
    defer free(msg.dropped);

    String encoded_str = (String)encoded;
    assert(encoded_str.contains("7:dropped"), "Should contain 'dropped' key");
}

fn void test_encode_pex_message_empty() @test
{
    pex::PexMessage msg;
    msg.added = {};
    msg.dropped = {};
    msg.added6 = {};
    msg.dropped6 = {};

    char[] encoded = pex::encode_pex_message(&msg);
    defer free(encoded);

    // Should be minimal bencoded dict: "de"
    assert(encoded.len == 2, "Empty message should be 'de'");
    assert(encoded[0] == 'd', "Should start with 'd'");
    assert(encoded[1] == 'e', "Should end with 'e'");
}

// ============================================================================
// PEX Message Decoding Tests
// ============================================================================

fn void test_decode_pex_message_with_added() @test
{
    // Create a bencoded PEX message
    // d5:added12:<12 bytes of compact peers>7:added.f2:<2 bytes of flags>e
    DString builder;
    builder.append("d5:added12:");

    // 2 peers in compact format
    // Peer 1: 192.168.1.1:6881 (0xC0A80101, 0x1AE1)
    builder.append_char((char)192);
    builder.append_char((char)168);
    builder.append_char((char)1);
    builder.append_char((char)1);
    builder.append_char((char)0x1A);
    builder.append_char((char)0xE1);

    // Peer 2: 10.0.0.1:8080 (0x0A000001, 0x1F90)
    builder.append_char((char)10);
    builder.append_char((char)0);
    builder.append_char((char)0);
    builder.append_char((char)1);
    builder.append_char((char)0x1F);
    builder.append_char((char)0x90);

    builder.append("7:added.f2:");
    builder.append_char((char)pex::PexFlags.SEED);
    builder.append_char((char)pex::PexFlags.REACHABLE);
    builder.append("e");

    String bencoded = builder.str_view();

    pex::PexMessage? msg_opt = pex::decode_pex_message((char[])bencoded);
    if (catch err = msg_opt)
    {
        assert(false, "Should decode valid PEX message");
        return;
    }

    pex::PexMessage msg = msg_opt;
    defer pex::free_pex_message(&msg);

    assert(msg.added.len == 2, "Should have 2 added peers");
    assert(msg.dropped.len == 0, "Should have 0 dropped peers");

    // Verify peer 1
    assert(msg.added[0].ip[0] == 192, "Peer 1 IP byte 0");
    assert(msg.added[0].port == 6881, "Peer 1 port");
    assert(msg.added[0].flags == (char)pex::PexFlags.SEED, "Peer 1 flags");

    // Verify peer 2
    assert(msg.added[1].ip[0] == 10, "Peer 2 IP byte 0");
    assert(msg.added[1].port == 8080, "Peer 2 port");
    assert(msg.added[1].flags == (char)pex::PexFlags.REACHABLE, "Peer 2 flags");
}

fn void test_decode_pex_message_with_dropped() @test
{
    // d7:dropped6:<6 bytes of compact peer>e
    DString builder;
    builder.append("d7:dropped6:");

    // 1 peer: 172.16.0.1:51413 (0xAC100001, 0xC8D5)
    builder.append_char((char)172);
    builder.append_char((char)16);
    builder.append_char((char)0);
    builder.append_char((char)1);
    builder.append_char((char)0xC8);
    builder.append_char((char)0xD5);

    builder.append("e");

    String bencoded = builder.str_view();

    pex::PexMessage? msg_opt = pex::decode_pex_message((char[])bencoded);
    msg_opt!!;
    pex::PexMessage msg = msg_opt!!;
    defer pex::free_pex_message(&msg);

    assert(msg.added.len == 0, "Should have 0 added peers");
    assert(msg.dropped.len == 1, "Should have 1 dropped peer");

    assert(msg.dropped[0].ip[0] == 172, "Dropped peer IP byte 0");
    assert(msg.dropped[0].port == 51413, "Dropped peer port");
}

fn void test_decode_pex_message_empty() @test
{
    String bencoded = "de";

    pex::PexMessage? msg_opt = pex::decode_pex_message((char[])bencoded);
    msg_opt!!;
    pex::PexMessage msg = msg_opt!!;

    assert(msg.added.len == 0, "Empty message should have 0 added peers");
    assert(msg.dropped.len == 0, "Empty message should have 0 dropped peers");
}

fn void test_decode_pex_message_invalid_bencode() @test
{
    String invalid = "not valid bencode";

    pex::PexMessage? result = pex::decode_pex_message((char[])invalid);
    if (catch err = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail on invalid bencode");
}

// ============================================================================
// Round-trip Tests
// ============================================================================

fn void test_pex_roundtrip() @test
{
    // Create original message
    pex::PexMessage original;

    original.added = mem::new_array(pex::PexPeer, 2);
    original.added[0].ip = {192, 168, 1, 100};
    original.added[0].port = 6881;
    original.added[0].flags = (char)(pex::PexFlags.SEED | pex::PexFlags.REACHABLE);

    original.added[1].ip = {10, 0, 0, 50};
    original.added[1].port = 51413;
    original.added[1].flags = (char)pex::PexFlags.PREFERS_ENCRYPTION;

    original.dropped = mem::new_array(pex::PexPeer, 1);
    original.dropped[0].ip = {172, 16, 1, 1};
    original.dropped[0].port = 8080;
    original.dropped[0].flags = 0;

    original.added6 = {};
    original.dropped6 = {};

    // Encode
    char[] encoded = pex::encode_pex_message(&original);
    defer free(encoded);
    defer free(original.added);
    defer free(original.dropped);

    // Decode
    pex::PexMessage? decoded_opt = pex::decode_pex_message(encoded);
    decoded_opt!!;
    pex::PexMessage decoded = decoded_opt!!;
    defer pex::free_pex_message(&decoded);

    // Verify roundtrip
    assert(decoded.added.len == 2, "Should have 2 added peers");
    assert(decoded.dropped.len == 1, "Should have 1 dropped peer");

    // Verify added peer 1
    assert(decoded.added[0].ip[0] == 192, "Added peer 1 IP matches");
    assert(decoded.added[0].port == 6881, "Added peer 1 port matches");
    assert(decoded.added[0].flags == original.added[0].flags, "Added peer 1 flags match");

    // Verify dropped peer
    assert(decoded.dropped[0].ip[0] == 172, "Dropped peer IP matches");
    assert(decoded.dropped[0].port == 8080, "Dropped peer port matches");
}

// ============================================================================
// IPv6 Address Validation Tests
// ============================================================================

fn void test_ipv6_unspecified_address() @test
{
    common::Ipv6Addr ip = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    assert(pex::is_private_or_reserved_ipv6(ip), "::/128 should be reserved");
}

fn void test_ipv6_loopback() @test
{
    common::Ipv6Addr ip = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    assert(pex::is_private_or_reserved_ipv6(ip), "::1/128 should be loopback");
}

fn void test_ipv6_unique_local_fc00() @test
{
    common::Ipv6Addr ip = {0xFC, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    assert(pex::is_private_or_reserved_ipv6(ip), "fc00::/7 should be private");
}

fn void test_ipv6_unique_local_fd00() @test
{
    common::Ipv6Addr ip = {0xFD, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    assert(pex::is_private_or_reserved_ipv6(ip), "fd00::/7 should be private");
}

fn void test_ipv6_link_local() @test
{
    common::Ipv6Addr ip = {0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    assert(pex::is_private_or_reserved_ipv6(ip), "fe80::/10 should be link-local");
}

fn void test_ipv6_multicast() @test
{
    common::Ipv6Addr ip = {0xFF, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    assert(pex::is_private_or_reserved_ipv6(ip), "ff00::/8 should be multicast");
}

fn void test_ipv6_public_2001() @test
{
    // 2001:4860:4860::8888 (Google DNS)
    common::Ipv6Addr ip = {0x20, 0x01, 0x48, 0x60, 0x48, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0x88, 0x88};
    assert(!pex::is_private_or_reserved_ipv6(ip), "2001:4860:4860::8888 should be public");
}

fn void test_ipv6_public_2606() @test
{
    // 2606:4700:4700::1111 (Cloudflare DNS)
    common::Ipv6Addr ip = {0x26, 0x06, 0x47, 0x00, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11};
    assert(!pex::is_private_or_reserved_ipv6(ip), "2606:4700:4700::1111 should be public");
}

fn void test_valid_pex_peer_v6() @test
{
    pex::PexPeerV6 peer;
    peer.ip = {0x20, 0x01, 0x48, 0x60, 0x48, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0x88, 0x88};
    peer.port = 6881;
    peer.flags = 0;

    assert(pex::is_valid_pex_peer_v6(&peer), "Public IPv6 with valid port should be valid");
}

fn void test_invalid_pex_peer_v6_private_ip() @test
{
    pex::PexPeerV6 peer;
    peer.ip = {0xFC, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    peer.port = 6881;
    peer.flags = 0;

    assert(!pex::is_valid_pex_peer_v6(&peer), "Private IPv6 should be invalid");
}

fn void test_invalid_pex_peer_v6_zero_port() @test
{
    pex::PexPeerV6 peer;
    peer.ip = {0x20, 0x01, 0x48, 0x60, 0x48, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0x88, 0x88};
    peer.port = 0;
    peer.flags = 0;

    assert(!pex::is_valid_pex_peer_v6(&peer), "Zero port should be invalid");
}

// ============================================================================
// IPv6 Compact Format Tests
// ============================================================================

fn void test_encode_compact_peer_v6() @test
{
    pex::PexPeerV6 peer;
    // 2001:db8::1
    peer.ip = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    peer.port = 6881;
    peer.flags = 0;

    char[] compact = pex::encode_compact_peer_v6(&peer);
    defer free(compact);

    assert(compact.len == 18, "Compact IPv6 peer should be 18 bytes");
    assert(compact[0] == (char)0x20, "IP byte 0 should match");
    assert(compact[1] == (char)0x01, "IP byte 1 should match");
    assert(compact[2] == (char)0x0d, "IP byte 2 should match");
    assert(compact[3] == (char)0xb8, "IP byte 3 should match");
    assert(compact[15] == (char)1, "IP byte 15 should match");

    // Port 6881 = 0x1AE1 in big-endian
    assert(compact[16] == (char)0x1A, "Port high byte should match");
    assert(compact[17] == (char)0xE1, "Port low byte should match");
}

fn void test_encode_compact_peers_v6_multiple() @test
{
    pex::PexPeerV6[] peers = mem::new_array(pex::PexPeerV6, 2);
    defer free(peers);

    // Peer 1: 2001:db8::1:8080
    peers[0].ip = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    peers[0].port = 8080;
    peers[0].flags = 0;

    // Peer 2: 2001:db8::2:6881
    peers[1].ip = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2};
    peers[1].port = 6881;
    peers[1].flags = 0;

    char[] compact = pex::encode_compact_peers_v6(peers);
    defer free(compact);

    assert(compact.len == 36, "2 IPv6 peers should be 36 bytes");

    // Verify first peer
    assert(compact[0] == (char)0x20, "Peer 1 IP byte 0");
    assert(compact[1] == (char)0x01, "Peer 1 IP byte 1");
    assert(compact[15] == (char)1, "Peer 1 IP byte 15");
}

fn void test_encode_compact_peers_v6_empty() @test
{
    pex::PexPeerV6[] peers = {};
    char[] compact = pex::encode_compact_peers_v6(peers);
    assert(compact.len == 0, "Empty IPv6 peers should produce empty string");
}

fn void test_decode_compact_peers_v6() @test
{
    // Create compact format: 2001:db8::1:6881
    char[18] compact;
    compact[0] = (char)0x20;
    compact[1] = (char)0x01;
    compact[2] = (char)0x0d;
    compact[3] = (char)0xb8;
    for (usz i = 4; i < 15; i++) compact[i] = 0;
    compact[15] = (char)1;
    compact[16] = (char)0x1A;  // Port 6881 = 0x1AE1
    compact[17] = (char)0xE1;

    char[] flags = {};
    pex::PexPeerV6[]? peers_opt = pex::decode_compact_peers_v6(compact[..], flags);
    if (catch err = peers_opt)
    {
        assert(false, "Should decode valid compact format");
        return;
    }

    pex::PexPeerV6[] peers = peers_opt;
    defer free(peers);

    assert(peers.len == 1, "Should have 1 IPv6 peer");
    assert(peers[0].ip[0] == 0x20, "IP byte 0 should match");
    assert(peers[0].ip[1] == 0x01, "IP byte 1 should match");
    assert(peers[0].ip[15] == 1, "IP byte 15 should match");
    assert(peers[0].port == 6881, "Port should match");
    assert(peers[0].flags == 0, "Flags should be 0 when not provided");
}

fn void test_decode_compact_peers_v6_with_flags() @test
{
    // Create compact format: 2001:db8::1:8080
    char[18] compact;
    compact[0] = (char)0x20;
    compact[1] = (char)0x01;
    compact[2] = (char)0x0d;
    compact[3] = (char)0xb8;
    for (usz i = 4; i < 15; i++) compact[i] = 0;
    compact[15] = (char)1;
    compact[16] = (char)0x1F;  // Port 8080 = 0x1F90
    compact[17] = (char)0x90;

    // Flags: seed + reachable
    char[1] flags;
    flags[0] = (char)(pex::PexFlags.SEED | pex::PexFlags.REACHABLE);

    pex::PexPeerV6[]? peers_opt = pex::decode_compact_peers_v6(compact[..], flags[..]);
    peers_opt!!;
    pex::PexPeerV6[] peers = peers_opt!!;
    defer free(peers);

    assert(peers.len == 1, "Should have 1 IPv6 peer");
    assert(peers[0].port == 8080, "Port should be 8080");
    assert(peers[0].flags == (char)(pex::PexFlags.SEED | pex::PexFlags.REACHABLE),
           "Flags should match");
}

fn void test_decode_compact_peers_v6_invalid_length() @test
{
    // 17 bytes (not a multiple of 18)
    char[17] invalid;
    char[] flags = {};

    pex::PexPeerV6[]? result = pex::decode_compact_peers_v6(invalid[..], flags);
    if (catch err = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail on invalid length");
}

fn void test_decode_compact_peers_v6_empty() @test
{
    char[] empty = {};
    char[] flags = {};

    pex::PexPeerV6[]? peers_opt = pex::decode_compact_peers_v6(empty, flags);
    peers_opt!!;
    pex::PexPeerV6[] peers = peers_opt!!;

    assert(peers.len == 0, "Empty compact should give empty array");
}

// ============================================================================
// IPv6 PEX Message Encoding/Decoding Tests
// ============================================================================

fn void test_encode_pex_message_with_added6() @test
{
    pex::PexMessage msg;
    msg.added = {};
    msg.dropped = {};
    msg.dropped6 = {};

    // Add 2 IPv6 peers
    msg.added6 = mem::new_array(pex::PexPeerV6, 2);
    msg.added6[0].ip = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    msg.added6[0].port = 6881;
    msg.added6[0].flags = (char)pex::PexFlags.SEED;

    msg.added6[1].ip = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2};
    msg.added6[1].port = 8080;
    msg.added6[1].flags = (char)pex::PexFlags.REACHABLE;

    char[] encoded = pex::encode_pex_message(&msg);
    defer free(encoded);
    defer free(msg.added6);

    assert(encoded.len > 0, "Encoded message should not be empty");

    // Should contain "added6" key
    String encoded_str = (String)encoded;
    assert(encoded_str.contains("6:added6"), "Should contain 'added6' key");
    assert(encoded_str.contains("8:added6.f"), "Should contain 'added6.f' key");
}

fn void test_encode_pex_message_with_dropped6() @test
{
    pex::PexMessage msg;
    msg.added = {};
    msg.dropped = {};
    msg.added6 = {};

    // Add 1 dropped IPv6 peer
    msg.dropped6 = mem::new_array(pex::PexPeerV6, 1);
    msg.dropped6[0].ip = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    msg.dropped6[0].port = 51413;
    msg.dropped6[0].flags = 0;

    char[] encoded = pex::encode_pex_message(&msg);
    defer free(encoded);
    defer free(msg.dropped6);

    String encoded_str = (String)encoded;
    assert(encoded_str.contains("8:dropped6"), "Should contain 'dropped6' key");
}

fn void test_decode_pex_message_with_added6() @test
{
    // Create a bencoded PEX message with IPv6 peers
    // d6:added636:<36 bytes of compact IPv6 peers>8:added6.f2:<2 bytes of flags>e
    DString builder;
    builder.append("d6:added636:");

    // 2 IPv6 peers in compact format
    // Peer 1: 2001:db8::1:6881
    builder.append_char((char)0x20);
    builder.append_char((char)0x01);
    builder.append_char((char)0x0d);
    builder.append_char((char)0xb8);
    for (usz i = 0; i < 11; i++) builder.append_char((char)0);
    builder.append_char((char)1);
    builder.append_char((char)0x1A);  // Port 6881
    builder.append_char((char)0xE1);

    // Peer 2: 2001:db8::2:8080
    builder.append_char((char)0x20);
    builder.append_char((char)0x01);
    builder.append_char((char)0x0d);
    builder.append_char((char)0xb8);
    for (usz i = 0; i < 11; i++) builder.append_char((char)0);
    builder.append_char((char)2);
    builder.append_char((char)0x1F);  // Port 8080
    builder.append_char((char)0x90);

    builder.append("8:added6.f2:");
    builder.append_char((char)pex::PexFlags.SEED);
    builder.append_char((char)pex::PexFlags.REACHABLE);
    builder.append("e");

    String bencoded = builder.str_view();

    pex::PexMessage? msg_opt = pex::decode_pex_message((char[])bencoded);
    if (catch err = msg_opt)
    {
        assert(false, "Should decode valid PEX message");
        return;
    }

    pex::PexMessage msg = msg_opt;
    defer pex::free_pex_message(&msg);

    assert(msg.added.len == 0, "Should have 0 IPv4 added peers");
    assert(msg.added6.len == 2, "Should have 2 IPv6 added peers");
    assert(msg.dropped.len == 0, "Should have 0 IPv4 dropped peers");
    assert(msg.dropped6.len == 0, "Should have 0 IPv6 dropped peers");

    // Verify peer 1
    assert(msg.added6[0].ip[0] == 0x20, "Peer 1 IP byte 0");
    assert(msg.added6[0].ip[15] == 1, "Peer 1 IP byte 15");
    assert(msg.added6[0].port == 6881, "Peer 1 port");
    assert(msg.added6[0].flags == (char)pex::PexFlags.SEED, "Peer 1 flags");

    // Verify peer 2
    assert(msg.added6[1].ip[15] == 2, "Peer 2 IP byte 15");
    assert(msg.added6[1].port == 8080, "Peer 2 port");
    assert(msg.added6[1].flags == (char)pex::PexFlags.REACHABLE, "Peer 2 flags");
}

fn void test_pex_roundtrip_ipv6() @test
{
    // Create original message with IPv6 peers
    pex::PexMessage original;
    original.added = {};
    original.dropped = {};

    original.added6 = mem::new_array(pex::PexPeerV6, 2);
    original.added6[0].ip = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    original.added6[0].port = 6881;
    original.added6[0].flags = (char)(pex::PexFlags.SEED | pex::PexFlags.REACHABLE);

    original.added6[1].ip = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2};
    original.added6[1].port = 51413;
    original.added6[1].flags = (char)pex::PexFlags.PREFERS_ENCRYPTION;

    original.dropped6 = mem::new_array(pex::PexPeerV6, 1);
    original.dropped6[0].ip = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3};
    original.dropped6[0].port = 8080;
    original.dropped6[0].flags = 0;

    // Encode
    char[] encoded = pex::encode_pex_message(&original);
    defer free(encoded);
    defer free(original.added6);
    defer free(original.dropped6);

    // Decode
    pex::PexMessage? decoded_opt = pex::decode_pex_message(encoded);
    decoded_opt!!;
    pex::PexMessage decoded = decoded_opt!!;
    defer pex::free_pex_message(&decoded);

    // Verify roundtrip
    assert(decoded.added6.len == 2, "Should have 2 IPv6 added peers");
    assert(decoded.dropped6.len == 1, "Should have 1 IPv6 dropped peer");

    // Verify added peer 1
    assert(decoded.added6[0].ip[15] == 1, "Added peer 1 IP matches");
    assert(decoded.added6[0].port == 6881, "Added peer 1 port matches");
    assert(decoded.added6[0].flags == original.added6[0].flags, "Added peer 1 flags match");

    // Verify dropped peer
    assert(decoded.dropped6[0].ip[15] == 3, "Dropped peer IP matches");
    assert(decoded.dropped6[0].port == 8080, "Dropped peer port matches");
}

fn void test_pex_roundtrip_mixed_ipv4_ipv6() @test
{
    // Create message with both IPv4 and IPv6 peers
    pex::PexMessage original;

    // IPv4 peers
    original.added = mem::new_array(pex::PexPeer, 1);
    original.added[0].ip = {192, 168, 1, 1};
    original.added[0].port = 6881;
    original.added[0].flags = (char)pex::PexFlags.SEED;

    original.dropped = {};

    // IPv6 peers
    original.added6 = mem::new_array(pex::PexPeerV6, 1);
    original.added6[0].ip = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    original.added6[0].port = 8080;
    original.added6[0].flags = (char)pex::PexFlags.REACHABLE;

    original.dropped6 = {};

    // Encode
    char[] encoded = pex::encode_pex_message(&original);
    defer free(encoded);
    defer free(original.added);
    defer free(original.added6);

    // Decode
    pex::PexMessage? decoded_opt = pex::decode_pex_message(encoded);
    decoded_opt!!;
    pex::PexMessage decoded = decoded_opt!!;
    defer pex::free_pex_message(&decoded);

    // Verify roundtrip
    assert(decoded.added.len == 1, "Should have 1 IPv4 added peer");
    assert(decoded.added6.len == 1, "Should have 1 IPv6 added peer");

    // Verify IPv4 peer
    assert(decoded.added[0].ip[0] == 192, "IPv4 peer IP matches");
    assert(decoded.added[0].port == 6881, "IPv4 peer port matches");

    // Verify IPv6 peer
    assert(decoded.added6[0].ip[15] == 1, "IPv6 peer IP matches");
    assert(decoded.added6[0].port == 8080, "IPv6 peer port matches");
}
