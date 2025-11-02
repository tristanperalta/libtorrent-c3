module libtorrent::dht_get_peers::test;

import std::io;
import libtorrent::dht_get_peers;
import libtorrent::common;

/**
 * DHT Get Peers Test Suite
 * ========================
 * Tests for DHT peer discovery operations
 */

// Helper function to create a test info hash
fn common::InfoHash create_test_info_hash(char seed)
{
    common::InfoHash hash;
    for (usz i = 0; i < 20; i++)
    {
        hash[i] = (char)(seed + i);
    }
    return hash;
}

// Helper function to create a test node ID
fn common::NodeId create_test_node_id(char seed)
{
    common::NodeId id;
    for (usz i = 0; i < 20; i++)
    {
        id[i] = (char)(seed + i);
    }
    return id;
}

// Helper function to create a test IP address
fn common::Ipv4Addr create_test_ip(char a, char b, char c, char d)
{
    common::Ipv4Addr ip;
    ip[0] = a;
    ip[1] = b;
    ip[2] = c;
    ip[3] = d;
    return ip;
}

// ============================================================================
// Basic Search Tests
// ============================================================================

fn void test_create_search() @test
{
    common::InfoHash info_hash = create_test_info_hash(0x42);
    dht_get_peers::GetPeersSearch* search = dht_get_peers::create_search(info_hash);
    defer search.free();

    // Verify info hash was copied
    for (usz i = 0; i < 20; i++)
    {
        assert(search.info_hash[i] == info_hash[i], "Info hash should match");
    }

    // Verify initial state
    assert(search.peer_count == 0, "Should start with no peers");
    assert(search.token_count == 0, "Should start with no tokens");
    assert(!search.found_peers, "Should not have found peers initially");
    assert(search.traversal != null, "Should have traversal");

    io::printn("✓ Create get_peers search");
}

// ============================================================================
// Peer Management Tests
// ============================================================================

fn void test_add_peer() @test
{
    common::InfoHash info_hash = create_test_info_hash(0x50);
    dht_get_peers::GetPeersSearch* search = dht_get_peers::create_search(info_hash);
    defer search.free();

    common::Ipv4Addr ip = create_test_ip(192, 168, 1, 100);
    bool added = search.add_peer( ip, 6881);

    assert(added, "Should add peer");
    assert(search.peer_count == 1, "Should have 1 peer");
    assert(search.found_peers, "Should have found peers flag set");

    io::printn("✓ Add peer");
}

fn void test_add_duplicate_peer() @test
{
    common::InfoHash info_hash = create_test_info_hash(0x60);
    dht_get_peers::GetPeersSearch* search = dht_get_peers::create_search(info_hash);
    defer search.free();

    common::Ipv4Addr ip = create_test_ip(192, 168, 1, 100);

    // Add peer first time
    bool added1 = search.add_peer( ip, 6881);
    assert(added1, "Should add peer first time");

    // Try to add same peer again
    bool added2 = search.add_peer( ip, 6881);
    assert(!added2, "Should not add duplicate peer");
    assert(search.peer_count == 1, "Should still have only 1 peer");

    io::printn("✓ Add duplicate peer");
}

fn void test_add_multiple_peers() @test
{
    common::InfoHash info_hash = create_test_info_hash(0x70);
    dht_get_peers::GetPeersSearch* search = dht_get_peers::create_search(info_hash);
    defer search.free();

    // Add 5 different peers
    for (int i = 0; i < 5; i++)
    {
        common::Ipv4Addr ip = create_test_ip(192, 168, 1, (char)(100 + i));
        bool added = search.add_peer( ip, (ushort)(6881 + i));
        assert(added, "Should add peer");
    }

    assert(search.peer_count == 5, "Should have 5 peers");

    io::printn("✓ Add multiple peers");
}

fn void test_add_peers_compact() @test
{
    common::InfoHash info_hash = create_test_info_hash(0x80);
    dht_get_peers::GetPeersSearch* search = dht_get_peers::create_search(info_hash);
    defer search.free();

    // Create compact peer data (2 peers)
    char[12] compact = {
        192, 168, 1, 100, 0x1A, 0xE1,  // 192.168.1.100:6881
        192, 168, 1, 101, 0x1A, 0xE2   // 192.168.1.101:6882
    };

    int added = search.add_peers_compact( compact[..]);
    assert(added == 2, "Should add 2 peers from compact format");
    assert(search.peer_count == 2, "Should have 2 peers");

    io::printn("✓ Add peers from compact format");
}

fn void test_get_peers() @test
{
    common::InfoHash info_hash = create_test_info_hash(0x90);
    dht_get_peers::GetPeersSearch* search = dht_get_peers::create_search(info_hash);
    defer search.free();

    // Add peers
    for (int i = 0; i < 3; i++)
    {
        common::Ipv4Addr ip = create_test_ip(192, 168, 1, (char)(100 + i));
        search.add_peer( ip, 6881);
    }

    // Get peers
    common::Peer[] peers = search.get_peers();
    defer free(peers);

    assert(peers.len == 3, "Should return 3 peers");

    io::printn("✓ Get peers");
}

// ============================================================================
// Token Management Tests
// ============================================================================

fn void test_add_token() @test
{
    common::InfoHash info_hash = create_test_info_hash(0xA0);
    dht_get_peers::GetPeersSearch* search = dht_get_peers::create_search(info_hash);
    defer search.free();

    common::NodeId node_id = create_test_node_id(0xB0);
    common::Ipv4Addr node_ip = create_test_ip(192, 168, 1, 50);
    char[8] token = { 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };

    bool added = search.add_token( node_id, node_ip, 6881, token[..]);
    assert(added, "Should add token");
    assert(search.token_count == 1, "Should have 1 token");

    io::printn("✓ Add announce token");
}

fn void test_add_multiple_tokens() @test
{
    common::InfoHash info_hash = create_test_info_hash(0xC0);
    dht_get_peers::GetPeersSearch* search = dht_get_peers::create_search(info_hash);
    defer search.free();

    // Add 3 tokens
    for (int i = 0; i < 3; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x10 + i * 10));
        common::Ipv4Addr node_ip = create_test_ip(192, 168, 1, (char)(50 + i));
        char[4] token = { (char)i, (char)i, (char)i, (char)i };

        bool added = search.add_token( node_id, node_ip, 6881, token[..]);
        assert(added, "Should add token");
    }

    assert(search.token_count == 3, "Should have 3 tokens");

    io::printn("✓ Add multiple tokens");
}

fn void test_get_announce_token() @test
{
    common::InfoHash info_hash = create_test_info_hash(0xD0);
    dht_get_peers::GetPeersSearch* search = dht_get_peers::create_search(info_hash);
    defer search.free();

    common::NodeId node_id = create_test_node_id(0xE0);
    common::Ipv4Addr node_ip = create_test_ip(192, 168, 1, 50);
    char[8] token = { 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 };

    search.add_token( node_id, node_ip, 6881, token[..]);

    // Get token back
    char[32] token_out;
    char token_len;
    common::NodeId node_id_out;
    common::Ipv4Addr node_ip_out;
    ushort node_port_out;

    bool got = search.get_announce_token( &token_out[0], &token_len,
                                                  &node_id_out, &node_ip_out, &node_port_out);

    assert(got, "Should get announce token");
    assert(token_len == 8, "Token length should be 8");
    assert(token_out[0] == 0xAA, "Token should match");

    io::printn("✓ Get announce token");
}

fn void test_get_announce_token_empty() @test
{
    common::InfoHash info_hash = create_test_info_hash(0xF0);
    dht_get_peers::GetPeersSearch* search = dht_get_peers::create_search(info_hash);
    defer search.free();

    char[32] token_out;
    char token_len;
    common::NodeId node_id_out;
    common::Ipv4Addr node_ip_out;
    ushort node_port_out;

    bool got = search.get_announce_token( &token_out[0], &token_len,
                                                  &node_id_out, &node_ip_out, &node_port_out);

    assert(!got, "Should not get token when none available");

    io::printn("✓ Get announce token: empty");
}

// ============================================================================
// Statistics Tests
// ============================================================================

fn void test_get_stats() @test
{
    common::InfoHash info_hash = create_test_info_hash(0x11);
    dht_get_peers::GetPeersSearch* search = dht_get_peers::create_search(info_hash);
    defer search.free();

    int peers, tokens, queries;
    search.get_stats( &peers, &tokens, &queries);

    assert(peers == 0, "Should have 0 peers initially");
    assert(tokens == 0, "Should have 0 tokens initially");
    assert(queries == 0, "Should have 0 queries initially");

    // Add some peers and tokens
    common::Ipv4Addr ip = create_test_ip(192, 168, 1, 100);
    search.add_peer( ip, 6881);

    common::NodeId node_id = create_test_node_id(0x22);
    common::Ipv4Addr node_ip = create_test_ip(192, 168, 1, 50);
    char[4] token = { 0x01, 0x02, 0x03, 0x04 };
    search.add_token( node_id, node_ip, 6881, token[..]);

    search.get_stats( &peers, &tokens, &queries);
    assert(peers == 1, "Should have 1 peer");
    assert(tokens == 1, "Should have 1 token");

    io::printn("✓ Get search statistics");
}

fn void test_found_peers() @test
{
    common::InfoHash info_hash = create_test_info_hash(0x33);
    dht_get_peers::GetPeersSearch* search = dht_get_peers::create_search(info_hash);
    defer search.free();

    // Initially should not have found peers
    bool found = dht_get_peers::found_peers(search);
    assert(!found, "Should not have found peers initially");

    // Add a peer
    common::Ipv4Addr ip = create_test_ip(192, 168, 1, 100);
    search.add_peer( ip, 6881);

    // Should now have found peers
    found = dht_get_peers::found_peers(search);
    assert(found, "Should have found peers after adding one");

    io::printn("✓ Check if found peers");
}

fn void test_is_done() @test
{
    common::InfoHash info_hash = create_test_info_hash(0x44);
    dht_get_peers::GetPeersSearch* search = dht_get_peers::create_search(info_hash);
    defer search.free();

    // Empty search should be done
    bool done = search.is_done();
    assert(done, "Empty search should be done");

    io::printn("✓ Check if search is done");
}
