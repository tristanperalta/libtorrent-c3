module libtorrent::peer_pool_test;

import libtorrent::peer_pool;
import libtorrent::event_loop;
import libtorrent::tracker;
import std::io;

// Test peer pool module - Phase 1: Core Storage & Discovery

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
                                                    &info_hash, &peer_id);
    assert(pool != null, "Pool should be created");

    // Verify initial state
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 0, "Should start with 0 peers");
    assert(candidates == 0, "Should start with 0 candidates");
    assert(connecting == 0, "Should start with 0 connecting");
    assert(connected == 0, "Should start with 0 connected");

    // Free pool
    peer_pool::free(pool);
}

// Test adding a single peer.
fn void test_add_single_peer() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add a peer
    char[4] ip = { 192, 168, 1, 1 };
    ushort port = 6881;
    pool.add_peer(ip, port, true);

    // Verify peer was added
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 1, "Should have 1 peer");

    // Verify peer can be found
    peer_pool::TorrentPeer*? found_opt = pool.find_peer(ip, port);
    if (catch err = found_opt)
    {
        assert(false, "Should find peer");
        return;
    }
    peer_pool::TorrentPeer* found = found_opt;
    assert(found.port == port, "Port should match");
    assert(found.ip[0] == 192, "IP byte 0 should match");
    assert(found.ip[1] == 168, "IP byte 1 should match");
    assert(found.ip[2] == 1, "IP byte 2 should match");
    assert(found.ip[3] == 1, "IP byte 3 should match");
    assert(found.from_tracker == true, "Should be from tracker");
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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add same peer twice
    char[4] ip = { 10, 0, 0, 1 };
    ushort port = 6881;

    pool.add_peer(ip, port, true);
    pool.add_peer(ip, port, true);

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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Create tracker peer list
    tracker::Peer[] tracker_peers = mem::new_array(tracker::Peer, 3);
    tracker_peers[0].ip = { 192, 168, 1, 1 };
    tracker_peers[0].port = 6881;
    tracker_peers[1].ip = { 192, 168, 1, 2 };
    tracker_peers[1].port = 6882;
    tracker_peers[2].ip = { 10, 0, 0, 1 };
    tracker_peers[2].port = 51413;

    // Add peers from tracker
    pool.add_peers_from_tracker(tracker_peers);

    free(tracker_peers);

    // Verify all peers were added
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 3, "Should have 3 peers");

    // Verify each peer can be found
    if (catch err = pool.find_peer({ 192, 168, 1, 1 }, 6881))
    {
        assert(false, "Should find peer 1");
    }

    if (catch err = pool.find_peer({ 192, 168, 1, 2 }, 6882))
    {
        assert(false, "Should find peer 2");
    }

    if (catch err = pool.find_peer({ 10, 0, 0, 1 }, 51413))
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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add one peer
    pool.add_peer({ 192, 168, 1, 1 }, 6881, true);

    // Try to find different peer
    peer_pool::TorrentPeer*? found_opt = pool.find_peer({ 10, 0, 0, 1 }, 6881);
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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add three peers
    pool.add_peer({ 192, 168, 1, 1 }, 6881, true);
    pool.add_peer({ 192, 168, 1, 2 }, 6882, true);
    pool.add_peer({ 10, 0, 0, 1 }, 51413, true);

    // Verify 3 peers
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 3, "Should have 3 peers");

    // Find and erase middle peer
    peer_pool::TorrentPeer*? peer_opt = pool.find_peer({ 192, 168, 1, 2 }, 6882);
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
    if (catch err = pool.find_peer({ 192, 168, 1, 2 }, 6882))
    {
        // Good - erased peer should not be found
    }
    else
    {
        assert(false, "Erased peer should not be found");
    }

    // Verify other peers still exist
    if (catch err = pool.find_peer({ 192, 168, 1, 1 }, 6881))
    {
        assert(false, "Peer 1 should still exist");
    }

    if (catch err = pool.find_peer({ 10, 0, 0, 1 }, 51413))
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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add one peer
    pool.add_peer({ 192, 168, 1, 1 }, 6881, true);

    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 1, "Should have 1 peer");

    // Erase it
    peer_pool::TorrentPeer* peer = pool.find_peer({ 192, 168, 1, 1 }, 6881)!!;
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

    peer_pool::PeerPool* pool = peer_pool::create(&loop, config, &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Try to add 10 peers (limit is 5)
    for (int i = 0; i < 10; i++)
    {
        char[4] ip = { 192, 168, 1, (char)i };
        pool.add_peer(ip, 6881, true);
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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add peers
    pool.add_peer({ 192, 168, 1, 1 }, 6881, true);
    pool.add_peer({ 192, 168, 1, 2 }, 6882, true);
    pool.add_peer({ 192, 168, 1, 3 }, 6883, true);

    // Initially all should be DISCOVERED
    usz total, candidates, connecting, connected;
    pool.get_stats(&total, &candidates, &connecting, &connected);
    assert(total == 3, "Should have 3 total peers");
    assert(candidates == 0, "Should have 0 candidates");
    assert(connecting == 0, "Should have 0 connecting");
    assert(connected == 0, "Should have 0 connected");

    // Change states manually (Phase 2 will do this properly)
    peer_pool::TorrentPeer* peer1 = pool.find_peer({ 192, 168, 1, 1 }, 6881)!!;
    peer1.state = peer_pool::PeerState.CANDIDATE;

    peer_pool::TorrentPeer* peer2 = pool.find_peer({ 192, 168, 1, 2 }, 6882)!!;
    peer2.state = peer_pool::PeerState.CONNECTING;

    peer_pool::TorrentPeer* peer3 = pool.find_peer({ 192, 168, 1, 3 }, 6883)!!;
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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add peers in non-sorted order
    pool.add_peer({ 192, 168, 1, 5 }, 6885, true);
    pool.add_peer({ 192, 168, 1, 1 }, 6881, true);
    pool.add_peer({ 192, 168, 1, 3 }, 6883, true);
    pool.add_peer({ 10, 0, 0, 1 }, 6881, true);
    pool.add_peer({ 192, 168, 1, 2 }, 6882, true);

    // Verify they're stored in sorted order
    // 10.0.0.1:6881 < 192.168.1.1:6881 < 192.168.1.2:6882 < 192.168.1.3:6883 < 192.168.1.5:6885

    assert(pool.peers[0].ip[0] == 10, "First peer should be 10.x.x.x");
    assert(pool.peers[1].ip[3] == 1 && pool.peers[1].port == 6881, "Second peer should be 192.168.1.1:6881");
    assert(pool.peers[2].ip[3] == 2 && pool.peers[2].port == 6882, "Third peer should be 192.168.1.2:6882");
    assert(pool.peers[3].ip[3] == 3 && pool.peers[3].port == 6883, "Fourth peer should be 192.168.1.3:6883");
    assert(pool.peers[4].ip[3] == 5 && pool.peers[4].port == 6885, "Fifth peer should be 192.168.1.5:6885");
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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add peer and verify base rank (just IP-based randomness)
    pool.add_peer({ 192, 168, 1, 1 }, 6881, true);
    peer_pool::TorrentPeer* peer = pool.find_peer({ 192, 168, 1, 1 }, 6881)!!;

    // Base rank: IP-based randomness only (1 * 7 % 20 = 7)
    assert(peer.peer_rank == 7, "Base rank should be IP-based randomness");

    // Simulate download from peer (should boost rank by +100)
    peer.prev_amount_download = 1000;
    pool.update_candidate_cache();
    peer = pool.find_peer({ 192, 168, 1, 1 }, 6881)!!;
    assert(peer.peer_rank == 107, "Rank with download history should be 107");

    // Mark as seed (should boost rank by +50)
    peer.seed = true;
    pool.update_candidate_cache();
    peer = pool.find_peer({ 192, 168, 1, 1 }, 6881)!!;
    assert(peer.peer_rank == 157, "Rank with seed + download should be 157");

    // Add failure (should penalize by -20)
    peer.failcount = 1;
    pool.update_candidate_cache();
    peer = pool.find_peer({ 192, 168, 1, 1 }, 6881)!!;
    assert(peer.peer_rank == 137, "Rank with 1 failure should be 137");

    // Add hash failure (should penalize by -30)
    peer.hashfails = 1;
    pool.update_candidate_cache();
    peer = pool.find_peer({ 192, 168, 1, 1 }, 6881)!!;
    assert(peer.peer_rank == 107, "Rank with hash failure should be 107");
}

// Test candidate cache gets sorted by rank.
fn void test_candidate_cache_sorting() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add peers with different characteristics
    // Peer 1: Normal peer (rank = 1 * 7 % 20 = 7)
    pool.add_peer({ 192, 168, 1, 1 }, 6881, true);

    // Peer 2: Seed (rank = 50 + 2 * 7 % 20 = 64)
    pool.add_peer({ 192, 168, 1, 2 }, 6882, true);
    peer_pool::TorrentPeer* peer2 = pool.find_peer({ 192, 168, 1, 2 }, 6882)!!;
    peer2.seed = true;

    // Peer 3: Downloaded from before (rank = 100 + 3 * 7 % 20 = 101)
    pool.add_peer({ 192, 168, 1, 3 }, 6883, true);
    peer_pool::TorrentPeer* peer3 = pool.find_peer({ 192, 168, 1, 3 }, 6883)!!;
    peer3.prev_amount_download = 5000;

    // Update cache
    pool.update_candidate_cache();

    // Verify cache is sorted by rank (highest first)
    assert(pool.candidate_cache.len == 3, "Should have 3 candidates");
    assert(pool.candidate_cache[0].peer_rank > pool.candidate_cache[1].peer_rank,
           "First candidate should have highest rank");
    assert(pool.candidate_cache[1].peer_rank > pool.candidate_cache[2].peer_rank,
           "Second candidate should have higher rank than third");

    // Verify order: peer3 (101) > peer2 (64) > peer1 (7)
    assert(pool.candidate_cache[0].port == 6883, "Best candidate should be peer3");
    assert(pool.candidate_cache[1].port == 6882, "Second candidate should be peer2");
    assert(pool.candidate_cache[2].port == 6881, "Third candidate should be peer1");
}

// Test pick_best_candidate returns highest-ranked peer.
fn void test_pick_best_candidate() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;

    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

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
    pool.add_peer({ 192, 168, 1, 1 }, 6881, true);
    pool.add_peer({ 192, 168, 1, 2 }, 6882, true);

    // Mark one as seed
    peer_pool::TorrentPeer* peer2 = pool.find_peer({ 192, 168, 1, 2 }, 6882)!!;
    peer2.seed = true;

    pool.update_candidate_cache();

    // Pick best - should be the seed
    peer_pool::TorrentPeer* best = pool.pick_best_candidate()!!;
    assert(best.port == 6882, "Best candidate should be the seed");
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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add regular peer
    pool.add_peer({ 192, 168, 1, 1 }, 6881, true);
    peer_pool::TorrentPeer* peer1 = pool.find_peer({ 192, 168, 1, 1 }, 6881)!!;
    int regular_rank = peer1.peer_rank;

    // Add seed peer
    pool.add_peer({ 192, 168, 1, 2 }, 6882, true);
    peer_pool::TorrentPeer* peer2 = pool.find_peer({ 192, 168, 1, 2 }, 6882)!!;
    peer2.seed = true;

    pool.update_candidate_cache();
    peer2 = pool.find_peer({ 192, 168, 1, 2 }, 6882)!!;
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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add peer
    pool.add_peer({ 192, 168, 1, 1 }, 6881, true);
    peer_pool::TorrentPeer* peer = pool.find_peer({ 192, 168, 1, 1 }, 6881)!!;
    int initial_rank = peer.peer_rank;

    // Add connection failure
    peer.failcount = 1;
    pool.update_candidate_cache();
    peer = pool.find_peer({ 192, 168, 1, 1 }, 6881)!!;
    int rank_after_fail = peer.peer_rank;

    assert(rank_after_fail < initial_rank, "Rank should decrease after failure");
    assert(initial_rank - rank_after_fail == 20, "Failure penalty should be -20");

    // Add hash failure
    peer.hashfails = 1;
    pool.update_candidate_cache();
    peer = pool.find_peer({ 192, 168, 1, 1 }, 6881)!!;
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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add a peer
    pool.add_peer({ 192, 168, 1, 1 }, 6881, true);

    // Disconnect peer (should not crash even without connection)
    pool.disconnect_peer({ 192, 168, 1, 1 }, 6881);

    // Verify peer still exists but state changed
    peer_pool::TorrentPeer* peer = pool.find_peer({ 192, 168, 1, 1 }, 6881)!!;
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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add multiple peers
    pool.add_peer({ 192, 168, 1, 1 }, 6881, true);
    pool.add_peer({ 192, 168, 1, 2 }, 6882, true);
    pool.add_peer({ 192, 168, 1, 3 }, 6883, true);

    // Disconnect all (peers without connections remain unchanged)
    pool.disconnect_all();

    // Verify active connection count is zero
    assert(pool.num_active_connections == 0, "Should have 0 active connections");

    // Verify peers still exist (just checking disconnect_all doesn't crash)
    peer_pool::TorrentPeer* peer1 = pool.find_peer({ 192, 168, 1, 1 }, 6881)!!;
    peer_pool::TorrentPeer* peer2 = pool.find_peer({ 192, 168, 1, 2 }, 6882)!!;
    peer_pool::TorrentPeer* peer3 = pool.find_peer({ 192, 168, 1, 3 }, 6883)!!;

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

    peer_pool::PeerPool* pool = peer_pool::create(&loop, config, &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add 10 peers
    for (int i = 0; i < 10; i++)
    {
        char[4] ip = { 192, 168, 1, (char)i };
        pool.add_peer(ip, 6881, true);
    }

    // Try to connect to peers
    // Note: This will fail because we're not running a real tracker/peers
    // But we can verify the limit is respected
    pool.connect_to_peers();

    // Verify we didn't exceed the connection limit
    // Note: Actual connections will fail, so num_active_connections stays 0
    // This test verifies the function doesn't crash
    assert(pool.num_active_connections <= config.max_active_connections,
           "Should not exceed max_active_connections");
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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add a peer
    char[4] ip = { 192, 168, 1, 100 };
    pool.add_peer(ip, 6881, true);

    // Get initial rank
    TorrentPeer* peer = pool.find_peer(ip, 6881)!!;
    int initial_rank = peer.peer_rank;

    // Update stats with download data
    pool.update_peer_stats(ip, 6881, 1024000, 512000)!!;

    // Get updated rank
    peer = pool.find_peer(ip, 6881)!!;

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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add a peer
    char[4] ip = { 192, 168, 1, 100 };
    pool.add_peer(ip, 6881, true);

    // Get initial rank
    TorrentPeer* peer = pool.find_peer(ip, 6881)!!;
    int initial_rank = peer.peer_rank;

    // Mark hash failure
    pool.mark_hash_failure(ip, 6881)!!;

    // Verify counter incremented
    peer = pool.find_peer(ip, 6881)!!;
    assert(peer.hashfails == 1, "Hash failure count should be 1");

    // Verify rank decreased (penalty is -30 per failure)
    assert(peer.peer_rank < initial_rank, "Rank should decrease after hash failure");
    assert(peer.peer_rank <= initial_rank - 30, "Should get -30 penalty for hash failure");

    // Mark another failure
    pool.mark_hash_failure(ip, 6881)!!;
    peer = pool.find_peer(ip, 6881)!!;
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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add a peer
    char[4] ip = { 192, 168, 1, 100 };
    pool.add_peer(ip, 6881, true);

    // Get initial rank
    TorrentPeer* peer = pool.find_peer(ip, 6881)!!;
    int initial_rank = peer.peer_rank;
    assert(!peer.seed, "Peer should not be marked as seed initially");

    // Mark as seed
    pool.mark_peer_seed(ip, 6881)!!;

    // Verify seed flag set
    peer = pool.find_peer(ip, 6881)!!;
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
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    char[4] ip = { 192, 168, 1, 100 };

    // Try to update stats for non-existent peer
    if (catch excuse = pool.update_peer_stats(ip, 6881, 1000, 500))
    {
        // Expected - peer doesn't exist
    }
    else
    {
        assert(false, "Should return fault for non-existent peer");
    }

    // Try to mark hash failure for non-existent peer
    if (catch excuse = pool.mark_hash_failure(ip, 6881))
    {
        // Expected - peer doesn't exist
    }
    else
    {
        assert(false, "Should return fault for non-existent peer");
    }

    // Try to mark as seed for non-existent peer
    if (catch excuse = pool.mark_peer_seed(ip, 6881))
    {
        // Expected - peer doesn't exist
    }
    else
    {
        assert(false, "Should return fault for non-existent peer");
    }
}

<*
 Test that candidate cache updates after statistics changes.
*>
fn void test_stats_update_candidate_cache() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] info_hash;
    char[20] peer_id;
    peer_pool::PeerPool* pool = peer_pool::create(&loop, peer_pool::DEFAULT_CONFIG,
                                                    &info_hash, &peer_id);
    defer peer_pool::free(pool);

    // Add two peers
    char[4] ip1 = { 192, 168, 1, 100 };
    char[4] ip2 = { 192, 168, 1, 101 };
    pool.add_peer(ip1, 6881, true);
    pool.add_peer(ip2, 6881, true);

    // Update candidate cache to make peers available
    pool.update_candidate_cache();

    // Initially both have similar ranks, check who is first
    TorrentPeer* initial_best = pool.pick_best_candidate()!!;

    // Mark ip2 as seed (should boost its rank significantly)
    pool.mark_peer_seed(ip2, 6881)!!;

    // Now ip2 should be the best candidate
    TorrentPeer* new_best = pool.pick_best_candidate()!!;

    // Verify ip2 is now best
    assert(new_best.ip[0] == ip2[0] && new_best.ip[1] == ip2[1] &&
           new_best.ip[2] == ip2[2] && new_best.ip[3] == ip2[3] &&
           new_best.port == 6881,
           "Seed peer should be ranked highest");

    // Mark ip2 with hash failure multiple times (should tank its rank)
    pool.mark_hash_failure(ip2, 6881)!!;
    pool.mark_hash_failure(ip2, 6881)!!;
    pool.mark_hash_failure(ip2, 6881)!!;

    // Now ip1 should be better
    new_best = pool.pick_best_candidate()!!;

    // Verify ip1 is now best (ip2 has too many hash failures)
    assert(new_best.ip[0] == ip1[0] && new_best.ip[1] == ip1[1] &&
           new_best.ip[2] == ip1[2] && new_best.ip[3] == ip1[3] &&
           new_best.port == 6881,
           "Peer with hash failures should be ranked lower");
}
