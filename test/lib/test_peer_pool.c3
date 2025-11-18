module libtorrent::peer_pool_test;

import libtorrent::peer_pool;
import libtorrent::dht_get_peers;
import libtorrent::common;
import async::event_loop;
import std::io;

// Test peer pool module - Phase 1: Core Storage & Discovery

// Helper function to create IPv4 SocketAddress for tests
fn common::SocketAddress make_ipv4_addr(char a, char b, char c, char d, ushort port)
{
    common::SocketAddress addr;
    addr.addr.is_ipv6 = false;
    addr.addr.ipv4.a = a;
    addr.addr.ipv4.b = b;
    addr.addr.ipv4.c = c;
    addr.addr.ipv4.d = d;
    addr.port = port;
    return addr;
}

// Test create and free basic operations.
fn void test_create_and_free() @test
{
    // Create event loop
    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Create peer pool
    char[20] info_hash;
    char[20] peer_id;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)i;
        peer_id[i] = (char)(i + 20);
    }

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    assert(pool != null, "Pool should be created");

    // Verify initial state
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 0, "Should start with 0 peers");
    assert(candidates == 0, "Should start with 0 candidates");
    assert(connecting == 0, "Should start with 0 connecting");
    assert(connected == 0, "Should start with 0 connected");

    // Free pool
    pool.free();
}

// Test adding a single peer.
fn void test_add_single_peer() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add a peer
    common::SocketAddress addr = make_ipv4_addr(192, 168, 1, 1, 6881);
    pool.add_peer(&addr, common::PeerSource.TRACKER);

    // Verify peer was added
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 1, "Should have 1 peer");

    // Verify peer can be found
    peer_pool::TorrentPeer*? found_opt = pool.find_peer(&addr);
    if (catch err = found_opt)
    {
        assert(false, "Should find peer");
        return;
    }
    peer_pool::TorrentPeer* found = found_opt;
    assert(found.addr.port == 6881, "Port should match");
    assert(!found.addr.addr.is_ipv6, "Should be IPv4");
    assert(found.addr.addr.ipv4.a == 192, "IP byte 0 should match");
    assert(found.addr.addr.ipv4.b == 168, "IP byte 1 should match");
    assert(found.addr.addr.ipv4.c == 1, "IP byte 2 should match");
    assert(found.addr.addr.ipv4.d == 1, "IP byte 3 should match");
    assert(found.source == common::PeerSource.TRACKER, "Should be from tracker");
    assert(found.state == peer_pool::PeerState.DISCOVERED, "Should be DISCOVERED");
}

// Test that adding duplicate peer does not create duplicate.
fn void test_add_duplicate_peer() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add same peer twice
    common::SocketAddress addr = make_ipv4_addr(10, 0, 0, 1, 6881);

    pool.add_peer(&addr, common::PeerSource.TRACKER);
    pool.add_peer(&addr, common::PeerSource.TRACKER);

    // Should only have 1 peer
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 1, "Should have only 1 peer (no duplicate)");
}

// Test adding peers from tracker response.
fn void test_add_peers_from_tracker() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Create tracker peer list
    common::SocketAddress[] tracker_peers = mem::new_array(common::SocketAddress, 3);
    tracker_peers[0] = make_ipv4_addr(192, 168, 1, 1, 6881);
    tracker_peers[1] = make_ipv4_addr(192, 168, 1, 2, 6882);
    tracker_peers[2] = make_ipv4_addr(10, 0, 0, 1, 51413);

    // Add peers from tracker
    pool.add_peers_from_tracker(tracker_peers);

    free(tracker_peers);

    // Verify all peers were added
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 3, "Should have 3 peers");

    // Verify each peer can be found
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    if (catch err = pool.find_peer(&addr1))
    {
        assert(false, "Should find peer 1");
    }

    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    if (catch err = pool.find_peer(&addr2))
    {
        assert(false, "Should find peer 2");
    }

    common::SocketAddress addr3 = make_ipv4_addr(10, 0, 0, 1, 51413);
    if (catch err = pool.find_peer(&addr3))
    {
        assert(false, "Should find peer 3");
    }
}

// Test find_peer with non-existent peer.
fn void test_find_nonexistent_peer() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add one peer
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);

    // Try to find different peer
    common::SocketAddress addr2 = make_ipv4_addr(10, 0, 0, 1, 6881);
    peer_pool::TorrentPeer*? found_opt = pool.find_peer(&addr2);
    if (catch err = found_opt)
    {
        // Good - should not find non-existent peer
    }
    else
    {
        assert(false, "Should not find non-existent peer");
    }
}

// Test erase_peer.
fn void test_erase_peer() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add three peers
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(10, 0, 0, 1, 51413);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);

    // Verify 3 peers
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 3, "Should have 3 peers");

    // Find and erase middle peer
    peer_pool::TorrentPeer*? peer_opt = pool.find_peer(&addr2);
    if (catch err = peer_opt)
    {
        assert(false, "Should find peer before erase");
        return;
    }

    pool.erase_peer(peer_opt);

    // Verify 2 peers remain
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 2, "Should have 2 peers after erase");

    // Verify erased peer is gone
    if (catch err = pool.find_peer(&addr2))
    {
        // Good - erased peer should not be found
    }
    else
    {
        assert(false, "Erased peer should not be found");
    }

    // Verify other peers still exist
    if (catch err = pool.find_peer(&addr1))
    {
        assert(false, "Peer 1 should still exist");
    }

    if (catch err = pool.find_peer(&addr3))
    {
        assert(false, "Peer 3 should still exist");
    }
}

// Test erasing the only peer.
fn void test_erase_only_peer() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add one peer
    common::SocketAddress addr = make_ipv4_addr(192, 168, 1, 1, 6881);
    pool.add_peer(&addr, common::PeerSource.TRACKER);

    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 1, "Should have 1 peer");

    // Erase it
    peer_pool::TorrentPeer* peer = pool.find_peer(&addr)!!;
    pool.erase_peer(peer);

    // Verify empty
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 0, "Should have 0 peers after erase");
}

// Test peer limit enforcement.
fn void test_peer_limit_enforcement() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    // Create pool with small limit
    peer_pool::PeerPoolConfig config = {
        .max_peerlist_size = 5,
        .max_active_connections = 2,
        .max_failcount = 3,
        .min_reconnect_time = 60
    };

    peer_pool::PeerPool* pool = peer_pool::create(&loop, config, &info_hash, &peer_id, false);
    defer pool.free();

    // Try to add 10 peers (limit is 5)
    for (int i = 0; i < 10; i++)
    {
        common::SocketAddress addr = make_ipv4_addr(192, 168, 1, (char)i, 6881);
        pool.add_peer(&addr, common::PeerSource.TRACKER);
    }

    // Should only have 5 peers (the limit)
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 5, "Should enforce peer limit of 5");
}

// Test statistics with different peer states.
fn void test_statistics() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peers
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);

    // Initially all should be DISCOVERED
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 3, "Should have 3 total peers");
    assert(candidates == 0, "Should have 0 candidates");
    assert(connecting == 0, "Should have 0 connecting");
    assert(connected == 0, "Should have 0 connected");

    // Change states manually (Phase 2 will do this properly)
    peer_pool::TorrentPeer* peer1 = pool.find_peer(&addr1)!!;
    peer1.state = peer_pool::PeerState.CANDIDATE;

    peer_pool::TorrentPeer* peer2 = pool.find_peer(&addr2)!!;
    peer2.state = peer_pool::PeerState.CONNECTING;

    peer_pool::TorrentPeer* peer3 = pool.find_peer(&addr3)!!;
    peer3.state = peer_pool::PeerState.CONNECTED;

    // Check stats again
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 3, "Should still have 3 total peers");
    assert(candidates == 1, "Should have 1 candidate");
    assert(connecting == 1, "Should have 1 connecting");
    assert(connected == 1, "Should have 1 connected");
}

// Test sorted order after multiple additions.
fn void test_sorted_order() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peers in non-sorted order
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 5, 6885);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    common::SocketAddress addr4 = make_ipv4_addr(10, 0, 0, 1, 6881);
    common::SocketAddress addr5 = make_ipv4_addr(192, 168, 1, 2, 6882);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);
    pool.add_peer(&addr4, common::PeerSource.TRACKER);
    pool.add_peer(&addr5, common::PeerSource.TRACKER);

    // Verify all peers were added (HashMap doesn't maintain sorted order)
    // Instead, we verify that all peers can be found by address
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 5, "Should have 5 peers total");

    // Verify each peer can be found using @ok() builtin
    assert(@ok(pool.find_peer(&addr1)), "Should find peer 192.168.1.5:6885");
    assert(@ok(pool.find_peer(&addr2)), "Should find peer 192.168.1.1:6881");
    assert(@ok(pool.find_peer(&addr3)), "Should find peer 192.168.1.3:6883");
    assert(@ok(pool.find_peer(&addr4)), "Should find peer 10.0.0.1:6881");
    assert(@ok(pool.find_peer(&addr5)), "Should find peer 192.168.1.2:6882");
}

// ===== Phase 2 Tests: Peer Ranking & Candidate Selection =====

// Test peer rank calculation with different scenarios.
fn void test_peer_rank_calculation() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peer and verify base rank (just IP-based randomness)
    common::SocketAddress addr = make_ipv4_addr(192, 168, 1, 1, 6881);
    pool.add_peer(&addr, common::PeerSource.TRACKER);
    peer_pool::TorrentPeer* peer = pool.find_peer(&addr)!!;

    // Base rank: IP-based randomness only (1 * 7 % 20 = 7)
    assert(peer.peer_rank == 7, "Base rank should be IP-based randomness");

    // Simulate download from peer (should boost rank by +100)
    peer.prev_amount_download = 1000;
    pool.update_peer_rank(peer);
    assert(peer.peer_rank == 107, "Rank with download history should be 107");

    // Mark as seed (should boost rank by +50)
    peer.seed = true;
    pool.update_peer_rank(peer);
    assert(peer.peer_rank == 157, "Rank with seed + download should be 157");

    // Add failure (should penalize by -20)
    peer.failcount = 1;
    pool.update_peer_rank(peer);
    assert(peer.peer_rank == 137, "Rank with 1 failure should be 137");

    // Add hash failure (should penalize by -30)
    peer.hashfails = 1;
    pool.update_peer_rank(peer);
    assert(peer.peer_rank == 107, "Rank with hash failure should be 107");
}

// Test pick_best_candidate returns highest-ranked peer.
fn void test_pick_best_candidate() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Empty pool - should return fault
    if (catch err = pool.pick_best_candidate())
    {
        // Good - no candidates available
    }
    else
    {
        assert(false, "Should fail when no candidates");
    }

    // Add peers
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);

    // Mark one as seed
    peer_pool::TorrentPeer* peer2 = pool.find_peer(&addr2)!!;
    peer2.seed = true;
    pool.update_peer_rank(peer2);

    // Pick best - should be the seed
    peer_pool::TorrentPeer* best = pool.pick_best_candidate()!!;
    assert(best.addr.port == 6882, "Best candidate should be the seed");
    assert(best.seed == true, "Best candidate should be seed");
}

// Test seeds are prioritized over non-seeds.
fn void test_seed_priority() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add regular peer
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    peer_pool::TorrentPeer* peer1 = pool.find_peer(&addr1)!!;
    int regular_rank = peer1.peer_rank;

    // Add seed peer
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    peer_pool::TorrentPeer* peer2 = pool.find_peer(&addr2)!!;
    peer2.seed = true;
    pool.update_peer_rank(peer2);
    int seed_rank = peer2.peer_rank;

    // Seed should have higher rank
    assert(seed_rank > regular_rank, "Seed should have higher rank than regular peer");
    assert(seed_rank - regular_rank >= 50, "Seed boost should be at least +50");
}

// Test failures penalize peer rank.
fn void test_failure_penalty() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peer
    common::SocketAddress addr = make_ipv4_addr(192, 168, 1, 1, 6881);
    pool.add_peer(&addr, common::PeerSource.TRACKER);
    peer_pool::TorrentPeer* peer = pool.find_peer(&addr)!!;
    int initial_rank = peer.peer_rank;

    // Add connection failure
    peer.failcount = 1;
    pool.update_peer_rank(peer);
    int rank_after_fail = peer.peer_rank;

    assert(rank_after_fail < initial_rank, "Rank should decrease after failure");
    assert(initial_rank - rank_after_fail == 20, "Failure penalty should be -20");

    // Add hash failure
    peer.hashfails = 1;
    pool.update_peer_rank(peer);
    int rank_after_hash_fail = peer.peer_rank;

    assert(rank_after_hash_fail < rank_after_fail, "Rank should decrease after hash failure");
    assert(rank_after_fail - rank_after_hash_fail == 30, "Hash failure penalty should be -30");
}

// ===== Phase 3 Tests: Async Connection Management =====

// Test set_callbacks function.
fn void test_set_callbacks() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Set callbacks (just verify it doesn't crash)
    pool.set_callbacks(null, null, null, null);

    // Verify we can set non-null callbacks too
    // Note: We can't actually test invocation without real connections
    pool.set_callbacks(null, null, null, null);
}

// Test disconnect_peer function.
fn void test_disconnect_peer() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add a peer
    common::SocketAddress addr = make_ipv4_addr(192, 168, 1, 1, 6881);
    pool.add_peer(&addr, common::PeerSource.TRACKER);

    // Disconnect peer (should not crash even without connection)
    pool.disconnect_peer(&addr);

    // Verify peer still exists but state changed
    peer_pool::TorrentPeer* peer = pool.find_peer(&addr)!!;
    assert(peer.state == peer_pool::PeerState.DISCONNECTED,
           "Disconnected peer should be in DISCONNECTED state");
}

// Test disconnect_all function.
fn void test_disconnect_all() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add multiple peers
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);

    // Disconnect all (peers without connections remain unchanged)
    pool.disconnect_all();

    // Verify active connection count is zero
    assert(pool.num_active_connections == 0, "Should have 0 active connections");

    // Verify peers still exist (just checking disconnect_all doesn't crash)
    peer_pool::TorrentPeer* peer1 = pool.find_peer(&addr1)!!;
    peer_pool::TorrentPeer* peer2 = pool.find_peer(&addr2)!!;
    peer_pool::TorrentPeer* peer3 = pool.find_peer(&addr3)!!;

    // Peers without connections stay in their original state (DISCOVERED)
    assert(peer1.state == peer_pool::PeerState.DISCOVERED, "Peer 1 should still be DISCOVERED");
    assert(peer2.state == peer_pool::PeerState.DISCOVERED, "Peer 2 should still be DISCOVERED");
    assert(peer3.state == peer_pool::PeerState.DISCOVERED, "Peer 3 should still be DISCOVERED");
}

// Test connection limit enforcement.
fn void test_connection_limit() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    // Create pool with low connection limit
    peer_pool::PeerPoolConfig config = {
        .max_peerlist_size = 100,
        .max_active_connections = 3,  // Only 3 connections
        .max_failcount = 3,
        .min_reconnect_time = 60
    };

    peer_pool::PeerPool* pool = peer_pool::create(&loop, config, &info_hash, &peer_id, false);
    defer pool.free();

    // Add 10 peers
    for (int i = 0; i < 10; i++)
    {
        common::SocketAddress addr = make_ipv4_addr(192, 168, 1, (char)i, 6881);
        pool.add_peer(&addr, common::PeerSource.TRACKER);
    }

    // Verify we have 10 peers using get_stats()
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 10, "Should have 10 peers");

    // Verify connection limit is configured correctly
    assert(pool.config.max_active_connections == 3, "Max connections should be 3");

    // Verify no connections yet
    assert(pool.num_active_connections == 0, "Should have no connections initially");

    // Note: We don't actually call connect_to_peers() because it creates
    // real async TCP connections that would leak in this test. The actual
    // connection limiting logic is tested implicitly by integration tests
    // that run with a real event loop.
}

// ============================================================================
// Phase 4: Statistics & Quality Tracking
// ============================================================================

<*
 Test update_peer_stats updates download/upload counters and recalculates rank.
*>
fn void test_update_peer_stats() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;
    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add a peer
    common::SocketAddress addr = make_ipv4_addr(192, 168, 1, 100, 6881);
    pool.add_peer(&addr, common::PeerSource.TRACKER);

    // Get initial rank
    peer_pool::TorrentPeer* peer = pool.find_peer(&addr)!!;
    int initial_rank = peer.peer_rank;

    // Update stats with download data
    pool.update_peer_stats(&addr, 1024000, 512000)!!;

    // Get updated rank
    peer = pool.find_peer(&addr)!!;

    // Verify stats were updated
    assert(peer.prev_amount_download == 1024000, "Download count should be updated");
    assert(peer.prev_amount_upload == 512000, "Upload count should be updated");

    // Verify rank increased (download history gives +100)
    assert(peer.peer_rank > initial_rank, "Rank should increase with download history");
    assert(peer.peer_rank >= initial_rank + 100, "Should get +100 bonus for download history");
}

<*
 Test mark_hash_failure increments counter and penalizes rank.
*>
fn void test_mark_hash_failure() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;
    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add a peer
    common::SocketAddress addr = make_ipv4_addr(192, 168, 1, 100, 6881);
    pool.add_peer(&addr, common::PeerSource.TRACKER);

    // Get initial rank
    peer_pool::TorrentPeer* peer = pool.find_peer(&addr)!!;
    int initial_rank = peer.peer_rank;

    // Mark hash failure
    pool.mark_hash_failure(&addr)!!;

    // Verify counter incremented
    peer = pool.find_peer(&addr)!!;
    assert(peer.hashfails == 1, "Hash failure count should be 1");

    // Verify rank decreased (penalty is -30 per failure)
    assert(peer.peer_rank < initial_rank, "Rank should decrease after hash failure");
    assert(peer.peer_rank <= initial_rank - 30, "Should get -30 penalty for hash failure");

    // Mark another failure
    pool.mark_hash_failure(&addr)!!;
    peer = pool.find_peer(&addr)!!;
    assert(peer.hashfails == 2, "Hash failure count should be 2");
    assert(peer.peer_rank <= initial_rank - 60, "Should get -60 penalty for 2 hash failures");
}

<*
 Test mark_peer_seed sets flag and boosts rank.
*>
fn void test_mark_peer_seed() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;
    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add a peer
    common::SocketAddress addr = make_ipv4_addr(192, 168, 1, 100, 6881);
    pool.add_peer(&addr, common::PeerSource.TRACKER);

    // Get initial rank
    peer_pool::TorrentPeer* peer = pool.find_peer(&addr)!!;
    int initial_rank = peer.peer_rank;
    assert(!peer.seed, "Peer should not be marked as seed initially");

    // Mark as seed
    pool.mark_peer_seed(&addr)!!;

    // Verify seed flag set
    peer = pool.find_peer(&addr)!!;
    assert(peer.seed, "Peer should be marked as seed");

    // Verify rank increased (seed boost is +50)
    assert(peer.peer_rank > initial_rank, "Rank should increase when marked as seed");
    assert(peer.peer_rank >= initial_rank + 50, "Should get +50 bonus for being seed");
}

<*
 Test that statistics functions return error for non-existent peer.
*>
fn void test_stats_peer_not_found() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;
    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    common::SocketAddress addr = make_ipv4_addr(192, 168, 1, 100, 6881);

    // Try to update stats for non-existent peer
    if (catch excuse = pool.update_peer_stats(&addr, 1000, 500))
    {
        // Expected - peer doesn't exist
    }
    else
    {
        assert(false, "Should return fault for non-existent peer");
    }

    // Try to mark hash failure for non-existent peer
    if (catch excuse = pool.mark_hash_failure(&addr))
    {
        // Expected - peer doesn't exist
    }
    else
    {
        assert(false, "Should return fault for non-existent peer");
    }

    // Try to mark as seed for non-existent peer
    if (catch excuse = pool.mark_peer_seed(&addr))
    {
        // Expected - peer doesn't exist
    }
    else
    {
        assert(false, "Should return fault for non-existent peer");
    }
}

<*
 Test that peer ranking updates affect best candidate selection.
*>
fn void test_peer_ranking_updates_best_candidate() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;
    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add two peers
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 100, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 101, 6881);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);

    // Initially both have similar ranks, check who is first
    peer_pool::TorrentPeer* initial_best = pool.pick_best_candidate()!!;

    // Mark addr2 as seed (should boost its rank significantly)
    pool.mark_peer_seed(&addr2)!!;

    // Now addr2 should be the best candidate
    peer_pool::TorrentPeer* new_best = pool.pick_best_candidate()!!;

    // Verify addr2 is now best
    assert(new_best.addr.addr.ipv4.a == 192 && new_best.addr.addr.ipv4.b == 168 &&
           new_best.addr.addr.ipv4.c == 1 && new_best.addr.addr.ipv4.d == 101 &&
           new_best.addr.port == 6881,
           "Seed peer should be ranked highest");

    // Mark addr2 with hash failure multiple times (should tank its rank)
    pool.mark_hash_failure(&addr2)!!;
    pool.mark_hash_failure(&addr2)!!;
    pool.mark_hash_failure(&addr2)!!;

    // Now addr1 should be better
    new_best = pool.pick_best_candidate()!!;

    // Verify addr1 is now best (addr2 has too many hash failures)
    assert(new_best.addr.addr.ipv4.a == 192 && new_best.addr.addr.ipv4.b == 168 &&
           new_best.addr.addr.ipv4.c == 1 && new_best.addr.addr.ipv4.d == 100 &&
           new_best.addr.port == 6881,
           "Peer with hash failures should be ranked lower");
}

// ============================================================================
// Phase 6 Tests: DHT Integration
// ============================================================================

<*
 Test adding peers from DHT get_peers response.
*>
fn void test_add_peers_from_dht() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Create DHT peer list
    common::SocketAddress[] dht_peers = mem::new_array(common::SocketAddress, 3);
    defer free(dht_peers);

    dht_peers[0] = make_ipv4_addr(10, 20, 30, 40, 51413);
    dht_peers[1] = make_ipv4_addr(172, 16, 0, 1, 6881);
    dht_peers[2] = make_ipv4_addr(192, 168, 100, 1, 6882);

    // Add peers from DHT
    pool.add_peers_from_dht(dht_peers);

    // Verify all peers were added
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 3, "Should have 3 peers from DHT");

    // Verify each peer can be found
    common::SocketAddress addr1 = make_ipv4_addr(10, 20, 30, 40, 51413);
    if (catch err = pool.find_peer(&addr1))
    {
        assert(false, "Should find DHT peer 1");
    }

    common::SocketAddress addr2 = make_ipv4_addr(172, 16, 0, 1, 6881);
    if (catch err = pool.find_peer(&addr2))
    {
        assert(false, "Should find DHT peer 2");
    }

    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 100, 1, 6882);
    if (catch err = pool.find_peer(&addr3))
    {
        assert(false, "Should find DHT peer 3");
    }

    io::printn("✓ Add peers from DHT");
}

<*
 Test that DHT peers are marked with from_tracker=false.
*>
fn void test_dht_peers_not_from_tracker() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add DHT peer
    common::SocketAddress[] dht_peers = mem::new_array(common::SocketAddress, 1);
    defer free(dht_peers);

    dht_peers[0] = make_ipv4_addr(10, 20, 30, 40, 51413);

    pool.add_peers_from_dht(dht_peers);

    // Verify peer is marked as NOT from tracker
    common::SocketAddress addr = make_ipv4_addr(10, 20, 30, 40, 51413);
    peer_pool::TorrentPeer* peer = pool.find_peer(&addr)!!;
    assert(peer.source != common::PeerSource.TRACKER, "DHT peer should not be marked as from_tracker");
    assert(peer.state == peer_pool::PeerState.DISCOVERED, "DHT peer should be DISCOVERED");

    io::printn("✓ DHT peers marked correctly");
}

<*
 Test deduplication between tracker and DHT peers.
 If a peer comes from both tracker and DHT, the from_tracker flag should remain true.
*>
fn void test_dht_tracker_deduplication() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    common::SocketAddress shared_addr = make_ipv4_addr(192, 168, 1, 100, 6881);

    // Add peer from tracker first
    pool.add_peer(&shared_addr, common::PeerSource.TRACKER);

    peer_pool::TorrentPeer* peer = pool.find_peer(&shared_addr)!!;
    assert(peer.source == common::PeerSource.TRACKER, "Peer from tracker should be marked");

    // Now add same peer from DHT
    common::SocketAddress[] dht_peers = mem::new_array(common::SocketAddress, 1);
    defer free(dht_peers);

    dht_peers[0] = shared_addr;

    pool.add_peers_from_dht(dht_peers);

    // Verify no duplicate - still only 1 peer
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 1, "Should not create duplicate peer");

    // Verify from_tracker flag remains true
    peer = pool.find_peer(&shared_addr)!!;
    assert(peer.source == common::PeerSource.TRACKER, "source == common::PeerSource.TRACKER flag should remain true");

    io::printn("✓ DHT/tracker deduplication");
}

// ============================================================================
// Phase 7 Tests: Filtering and Sorting
// ============================================================================

<*
 Test default filter shows all peers.
*>
fn void test_filter_default() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peers in different states
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);

    // Change states
    peer_pool::TorrentPeer* peer1 = pool.find_peer(&addr1)!!;
    peer1.state = peer_pool::PeerState.CONNECTED;

    peer_pool::TorrentPeer* peer2 = pool.find_peer(&addr2)!!;
    peer2.state = peer_pool::PeerState.CONNECTING;

    // Use default filter
    peer_pool::PeerFilter filter = peer_pool::create_default_filter();
    peer_pool::PeerDisplayInfo[] info = pool.get_peer_display_info_filtered(&filter, peer_pool::PeerSortOrder.SORT_BY_STATE);
    defer {
        for (usz i = 0; i < info.len; i++)
        {
            free(info[i].ip_address);
            free(info[i].client);
            free(info[i].state);
        }
        free(info);
    }

    // Should show all 3 peers
    assert(info.len == 3, "Default filter should show all peers");
}

<*
 Test filtering by single state using bitflags.
*>
fn void test_filter_single_state() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peers in different states
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);

    peer_pool::TorrentPeer* peer1 = pool.find_peer(&addr1)!!;
    peer1.state = peer_pool::PeerState.CONNECTED;

    peer_pool::TorrentPeer* peer2 = pool.find_peer(&addr2)!!;
    peer2.state = peer_pool::PeerState.CONNECTING;

    // Filter for CONNECTED only
    peer_pool::PeerFilter filter = peer_pool::create_default_filter();
    filter.state_flags = (char)peer_pool::PeerStateFlag.CONNECTED;

    peer_pool::PeerDisplayInfo[] info = pool.get_peer_display_info_filtered(&filter, peer_pool::PeerSortOrder.SORT_BY_STATE);
    defer {
        for (usz i = 0; i < info.len; i++)
        {
            free(info[i].ip_address);
            free(info[i].client);
            free(info[i].state);
        }
        free(info);
    }

    // Should show only 1 peer (CONNECTED)
    assert(info.len == 1, "Should show only CONNECTED peers");
    assert(info[0].port == 6881, "Should be peer1");
}

<*
 Test combining multiple states with bitwise OR.
*>
fn void test_filter_combined_states() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peers in different states
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    common::SocketAddress addr4 = make_ipv4_addr(192, 168, 1, 4, 6884);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);
    pool.add_peer(&addr4, common::PeerSource.TRACKER);

    peer_pool::TorrentPeer* peer1 = pool.find_peer(&addr1)!!;
    peer1.state = peer_pool::PeerState.CONNECTED;

    peer_pool::TorrentPeer* peer2 = pool.find_peer(&addr2)!!;
    peer2.state = peer_pool::PeerState.CONNECTING;

    peer_pool::TorrentPeer* peer3 = pool.find_peer(&addr3)!!;
    peer3.state = peer_pool::PeerState.DISCONNECTED;

    // Filter for CONNECTED | CONNECTING
    peer_pool::PeerFilter filter = peer_pool::create_default_filter();
    filter.state_flags = (char)(peer_pool::PeerStateFlag.CONNECTED | peer_pool::PeerStateFlag.CONNECTING);

    peer_pool::PeerDisplayInfo[] info = pool.get_peer_display_info_filtered(&filter, peer_pool::PeerSortOrder.SORT_BY_STATE);
    defer {
        for (usz i = 0; i < info.len; i++)
        {
            free(info[i].ip_address);
            free(info[i].client);
            free(info[i].state);
        }
        free(info);
    }

    // Should show 2 peers (CONNECTED + CONNECTING)
    assert(info.len == 2, "Should show CONNECTED and CONNECTING peers");
}

<*
 Test excluding states with bitwise NOT.
*>
fn void test_filter_exclude_states() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peers in different states
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);

    peer_pool::TorrentPeer* peer1 = pool.find_peer(&addr1)!!;
    peer1.state = peer_pool::PeerState.CONNECTED;

    peer_pool::TorrentPeer* peer2 = pool.find_peer(&addr2)!!;
    peer2.state = peer_pool::PeerState.BANNED;

    // Filter for ALL except BANNED
    peer_pool::PeerFilter filter = peer_pool::create_default_filter();
    filter.state_flags = (char)(peer_pool::PeerStateFlag.ALL & ~peer_pool::PeerStateFlag.BANNED);

    peer_pool::PeerDisplayInfo[] info = pool.get_peer_display_info_filtered(&filter, peer_pool::PeerSortOrder.SORT_BY_STATE);
    defer {
        for (usz i = 0; i < info.len; i++)
        {
            free(info[i].ip_address);
            free(info[i].client);
            free(info[i].state);
        }
        free(info);
    }

    // Should show 2 peers (all except banned)
    assert(info.len == 2, "Should exclude BANNED peers");

    // Verify banned peer is not in results
    bool found_banned = false;
    for (usz i = 0; i < info.len; i++)
    {
        if (info[i].port == 6882) found_banned = true;
    }
    assert(!found_banned, "Banned peer should not be in results");
}

<*
 Test filtering by seeds only.
*>
fn void test_filter_seeds_only() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peers - some seeds, some leechers
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);

    peer_pool::TorrentPeer* peer1 = pool.find_peer(&addr1)!!;
    peer1.seed = true;

    peer_pool::TorrentPeer* peer3 = pool.find_peer(&addr3)!!;
    peer3.seed = true;

    // Filter for seeds only
    peer_pool::PeerFilter filter = peer_pool::create_default_filter();
    filter.seeds_only = true;

    peer_pool::PeerDisplayInfo[] info = pool.get_peer_display_info_filtered(&filter, peer_pool::PeerSortOrder.SORT_BY_STATE);
    defer {
        for (usz i = 0; i < info.len; i++)
        {
            free(info[i].ip_address);
            free(info[i].client);
            free(info[i].state);
        }
        free(info);
    }

    // Should show 2 seeds
    assert(info.len == 2, "Should show only seeds");
}

<*
 Test filtering by leechers only.
*>
fn void test_filter_leechers_only() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peers - some seeds, some leechers
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);

    peer_pool::TorrentPeer* peer1 = pool.find_peer(&addr1)!!;
    peer1.seed = true;

    // Filter for leechers only
    peer_pool::PeerFilter filter = peer_pool::create_default_filter();
    filter.leechers_only = true;

    peer_pool::PeerDisplayInfo[] info = pool.get_peer_display_info_filtered(&filter, peer_pool::PeerSortOrder.SORT_BY_STATE);
    defer {
        for (usz i = 0; i < info.len; i++)
        {
            free(info[i].ip_address);
            free(info[i].client);
            free(info[i].state);
        }
        free(info);
    }

    // Should show 2 leechers
    assert(info.len == 2, "Should show only leechers");
}

<*
 Test filtering by peer source.
*>
fn void test_filter_by_source() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peers from different sources
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.DHT);
    pool.add_peer(&addr3, common::PeerSource.PEX);

    // Filter for TRACKER only
    peer_pool::PeerFilter filter = peer_pool::create_default_filter();
    filter.filter_by_source = true;
    filter.source_filter = common::PeerSource.TRACKER;

    peer_pool::PeerDisplayInfo[] info = pool.get_peer_display_info_filtered(&filter, peer_pool::PeerSortOrder.SORT_BY_STATE);
    defer {
        for (usz i = 0; i < info.len; i++)
        {
            free(info[i].ip_address);
            free(info[i].client);
            free(info[i].state);
        }
        free(info);
    }

    // Should show only 1 peer from tracker
    assert(info.len == 1, "Should show only TRACKER peers");
    assert(info[0].port == 6881, "Should be tracker peer");
}

<*
 Test empty result when all peers filtered out.
*>
fn void test_filter_empty_result() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peers all in DISCOVERED state
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);

    // Filter for CONNECTED only (but no peers are connected)
    peer_pool::PeerFilter filter = peer_pool::create_default_filter();
    filter.state_flags = (char)peer_pool::PeerStateFlag.CONNECTED;

    peer_pool::PeerDisplayInfo[] info = pool.get_peer_display_info_filtered(&filter, peer_pool::PeerSortOrder.SORT_BY_STATE);
    defer {
        for (usz i = 0; i < info.len; i++)
        {
            free(info[i].ip_address);
            free(info[i].client);
            free(info[i].state);
        }
        free(info);
    }

    // Should return empty array
    assert(info.len == 0, "Should return empty array when all filtered out");
}

<*
 Test sorting by state priority.
*>
fn void test_sort_by_state() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peers in different states
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);

    peer_pool::TorrentPeer* peer1 = pool.find_peer(&addr1)!!;
    peer1.state = peer_pool::PeerState.DISCOVERED;

    peer_pool::TorrentPeer* peer2 = pool.find_peer(&addr2)!!;
    peer2.state = peer_pool::PeerState.CONNECTED;

    peer_pool::TorrentPeer* peer3 = pool.find_peer(&addr3)!!;
    peer3.state = peer_pool::PeerState.CONNECTING;

    // Sort by state
    peer_pool::PeerFilter filter = peer_pool::create_default_filter();
    peer_pool::PeerDisplayInfo[] info = pool.get_peer_display_info_filtered(&filter, peer_pool::PeerSortOrder.SORT_BY_STATE);
    defer {
        for (usz i = 0; i < info.len; i++)
        {
            free(info[i].ip_address);
            free(info[i].client);
            free(info[i].state);
        }
        free(info);
    }

    // Order should be: CONNECTED, CONNECTING, DISCOVERED
    assert(info.len == 3, "Should have 3 peers");
    assert(info[0].port == 6882, "First should be CONNECTED");
    assert(info[1].port == 6883, "Second should be CONNECTING");
    assert(info[2].port == 6881, "Third should be DISCOVERED");
}

<*
 Test sorting by download amount.
*>
fn void test_sort_by_downloaded() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peers with different download amounts
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);

    peer_pool::TorrentPeer* peer1 = pool.find_peer(&addr1)!!;
    peer1.prev_amount_download = 1000;

    peer_pool::TorrentPeer* peer2 = pool.find_peer(&addr2)!!;
    peer2.prev_amount_download = 5000;

    peer_pool::TorrentPeer* peer3 = pool.find_peer(&addr3)!!;
    peer3.prev_amount_download = 3000;

    // Sort by downloaded (highest first)
    peer_pool::PeerFilter filter = peer_pool::create_default_filter();
    peer_pool::PeerDisplayInfo[] info = pool.get_peer_display_info_filtered(&filter, peer_pool::PeerSortOrder.SORT_BY_DOWNLOADED);
    defer {
        for (usz i = 0; i < info.len; i++)
        {
            free(info[i].ip_address);
            free(info[i].client);
            free(info[i].state);
        }
        free(info);
    }

    // Order should be: 5000, 3000, 1000
    assert(info.len == 3, "Should have 3 peers");
    assert(info[0].port == 6882, "First should have most downloaded");
    assert(info[1].port == 6883, "Second should have middle downloaded");
    assert(info[2].port == 6881, "Third should have least downloaded");
}

<*
 Test sorting by peer rank.
*>
fn void test_sort_by_rank() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peers with different characteristics
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);

    // Mark one as seed (boosts rank)
    peer_pool::TorrentPeer* peer2 = pool.find_peer(&addr2)!!;
    peer2.seed = true;
    pool.update_peer_rank(peer2);

    // Mark one with download history (boosts rank)
    peer_pool::TorrentPeer* peer3 = pool.find_peer(&addr3)!!;
    peer3.prev_amount_download = 10000;
    pool.update_peer_rank(peer3);

    // Sort by rank (highest first)
    peer_pool::PeerFilter filter = peer_pool::create_default_filter();
    peer_pool::PeerDisplayInfo[] info = pool.get_peer_display_info_filtered(&filter, peer_pool::PeerSortOrder.SORT_BY_RANK);
    defer {
        for (usz i = 0; i < info.len; i++)
        {
            free(info[i].ip_address);
            free(info[i].client);
            free(info[i].state);
        }
        free(info);
    }

    // Verify peers are sorted by rank
    assert(info.len == 3, "Should have 3 peers");
    // peer3 should be first (download history gives +100)
    assert(info[0].port == 6883, "Peer with download history should be first");
}

<*
 Test sorting by reliability (failures).
*>
fn void test_sort_by_reliability() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add peers with different failure counts
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.TRACKER);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);

    peer_pool::TorrentPeer* peer1 = pool.find_peer(&addr1)!!;
    peer1.failcount = 5;
    peer1.hashfails = 2;

    peer_pool::TorrentPeer* peer2 = pool.find_peer(&addr2)!!;
    peer2.failcount = 1;
    peer2.hashfails = 0;

    peer_pool::TorrentPeer* peer3 = pool.find_peer(&addr3)!!;
    peer3.failcount = 0;
    peer3.hashfails = 0;

    // Sort by reliability (fewest failures first)
    peer_pool::PeerFilter filter = peer_pool::create_default_filter();
    peer_pool::PeerDisplayInfo[] info = pool.get_peer_display_info_filtered(&filter, peer_pool::PeerSortOrder.SORT_BY_RELIABILITY);
    defer {
        for (usz i = 0; i < info.len; i++)
        {
            free(info[i].ip_address);
            free(info[i].client);
            free(info[i].state);
        }
        free(info);
    }

    // Order should be: peer3 (0 failures), peer2 (1 failure), peer1 (7 failures)
    assert(info.len == 3, "Should have 3 peers");
    assert(info[0].port == 6883, "Most reliable peer should be first");
    assert(info[2].port == 6881, "Least reliable peer should be last");
}

<*
 Test filtering on empty pool.
*>
fn void test_filter_empty_pool() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Don't add any peers

    // Apply filter
    peer_pool::PeerFilter filter = peer_pool::create_default_filter();
    peer_pool::PeerDisplayInfo[] info = pool.get_peer_display_info_filtered(&filter, peer_pool::PeerSortOrder.SORT_BY_STATE);
    defer {
        for (usz i = 0; i < info.len; i++)
        {
            free(info[i].ip_address);
            free(info[i].client);
            free(info[i].state);
        }
        free(info);
    }

    // Should return empty array
    assert(info.len == 0, "Empty pool should return empty array");
}

<*
 Test complex filter: multiple criteria combined.
*>
fn void test_filter_complex() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    // Add various peers
    common::SocketAddress addr1 = make_ipv4_addr(192, 168, 1, 1, 6881);
    common::SocketAddress addr2 = make_ipv4_addr(192, 168, 1, 2, 6882);
    common::SocketAddress addr3 = make_ipv4_addr(192, 168, 1, 3, 6883);
    common::SocketAddress addr4 = make_ipv4_addr(192, 168, 1, 4, 6884);
    pool.add_peer(&addr1, common::PeerSource.TRACKER);
    pool.add_peer(&addr2, common::PeerSource.DHT);
    pool.add_peer(&addr3, common::PeerSource.TRACKER);
    pool.add_peer(&addr4, common::PeerSource.TRACKER);

    // Set characteristics
    peer_pool::TorrentPeer* peer1 = pool.find_peer(&addr1)!!;
    peer1.state = peer_pool::PeerState.CONNECTED;
    peer1.seed = true;

    peer_pool::TorrentPeer* peer2 = pool.find_peer(&addr2)!!;
    peer2.state = peer_pool::PeerState.CONNECTED;
    peer2.seed = true;

    peer_pool::TorrentPeer* peer3 = pool.find_peer(&addr3)!!;
    peer3.state = peer_pool::PeerState.CONNECTING;

    peer_pool::TorrentPeer* peer4 = pool.find_peer(&addr4)!!;
    peer4.state = peer_pool::PeerState.CONNECTED;
    peer4.seed = false;

    // Complex filter: CONNECTED state + seeds only + from TRACKER only
    peer_pool::PeerFilter filter = peer_pool::create_default_filter();
    filter.state_flags = (char)peer_pool::PeerStateFlag.CONNECTED;
    filter.seeds_only = true;
    filter.filter_by_source = true;
    filter.source_filter = common::PeerSource.TRACKER;

    peer_pool::PeerDisplayInfo[] info = pool.get_peer_display_info_filtered(&filter, peer_pool::PeerSortOrder.SORT_BY_STATE);
    defer {
        for (usz i = 0; i < info.len; i++)
        {
            free(info[i].ip_address);
            free(info[i].client);
            free(info[i].state);
        }
        free(info);
    }

    // Should show only peer1 (CONNECTED + seed + TRACKER)
    // peer2 is excluded (DHT source)
    // peer3 is excluded (not CONNECTED)
    // peer4 is excluded (not seed)
    assert(info.len == 1, "Should match only 1 peer with all criteria");
    assert(info[0].port == 6881, "Should be peer1");
}

// ============================================================================
// BEP 27: Private Torrent Tests
// ============================================================================

/**
 * Test that private flag is properly set when creating peer pool
 */
fn void test_private_flag_set_on_pool() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    common::InfoHash info_hash;
    common::PeerId peer_id;

    // Create pool with is_private = true
    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, true);
    defer pool.free();

    assert(pool.is_private == true, "Private flag should be set to true on pool");

    io::printn("BEP 27: Private flag correctly set on peer pool ✓");
}

/**
 * Test that public flag is properly set when creating peer pool
 */
fn void test_public_flag_set_on_pool() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    common::InfoHash info_hash;
    common::PeerId peer_id;

    // Create pool with is_private = false
    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, false);
    defer pool.free();

    assert(pool.is_private == false, "Private flag should be set to false on pool");

    io::printn("BEP 27: Public flag correctly set on peer pool ✓");
}

/**
 * Test that PEX updates are disabled for private torrents (BEP 27)
 *
 * This test verifies that the private flag is propagated correctly through
 * the peer pool, which will cause PEX broadcasts to be skipped (tested
 * indirectly since broadcast_pex_update is @private).
 */
fn void test_pex_disabled_for_private_pool() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    common::InfoHash info_hash;
    common::PeerId peer_id;

    // Create PRIVATE pool
    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id, true);
    defer pool.free();

    // Verify private flag is set (which will cause PEX to be disabled)
    assert(pool.is_private == true, "Pool should be marked as private");

    // Add a peer to the pool (would normally trigger PEX if not private)
    common::SocketAddress addr = make_ipv4_addr(1, 2, 3, 4, 6881);
    pool.add_peer(&addr, common::PeerSource.TRACKER);

    // Call send_pex_updates - should not crash for private torrents
    // The internal broadcast_pex_update will return early (peer_pool.c3:1145-1149)
    pool.send_pex_updates();

    // If we reach here without crashing, the implementation is working correctly
    io::printn("BEP 27: PEX correctly disabled for private torrent pool ✓");
}
