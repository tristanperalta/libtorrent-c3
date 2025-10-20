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
