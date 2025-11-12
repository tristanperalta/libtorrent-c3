module libtorrent::torrent_manager_test;

import libtorrent::torrent_manager;
import libtorrent::metainfo;
import libtorrent::common;
import async::event_loop;
import torrent_client::session;
import std::io;

// ============================================================================
// Test Helpers
// ============================================================================

/**
 * Create a minimal test torrent file.
 */
fn metainfo::TorrentFile* create_test_torrent(String name, char[20] info_hash)
{
    metainfo::TorrentFile* torrent = mem::new(metainfo::TorrentFile);

    // Initialize arena like real torrents do
    torrent.arena.init(mem, 1024);

    // Set info hash
    for (usz i = 0; i < 20; i++)
    {
        torrent.info_hash[i] = info_hash[i];
    }

    // Set basic info - use arena for allocations
    torrent.info.name = name.copy(&torrent.arena);
    torrent.info.piece_length = 262144;  // 256KB
    torrent.info.length = 1048576;  // 1MB
    torrent.info.is_multi_file = false;
    torrent.info.private = false;

    // Minimal pieces (4 pieces for 1MB file) - use arena
    torrent.info.pieces = allocator::new_array(&torrent.arena, char, 80);

    // Empty announce list
    torrent.announce_list = {};

    return torrent;
}

/**
 * Generate a unique info hash for testing.
 */
fn char[20] generate_test_hash(int seed)
{
    char[20] hash;
    for (usz i = 0; i < 20; i++)
    {
        hash[i] = (char)((seed + i) % 256);
    }
    return hash;
}

// ============================================================================
// Creation Tests
// ============================================================================

fn void test_create_manager() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    assert(mgr != null, "Manager should be created");
    assert(mgr.shared != null, "Shared resources should exist");
    assert(mgr.is_running == true, "Manager should be running");
    assert(mgr.max_active_torrents == 0, "Should have unlimited torrents");
    assert(mgr.get_torrent_count() == 0, "Should start with no torrents");
}

fn void test_create_manager_with_limit() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 5);
    defer mgr.free();

    assert(mgr.max_active_torrents == 5, "Should respect max active limit");
}

// ============================================================================
// Add Torrent Tests
// ============================================================================

fn void test_add_single_torrent() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    char[20] hash = generate_test_hash(1);
    metainfo::TorrentFile* torrent = create_test_torrent("test1.txt", hash);

    session::Session*? ctx_opt = mgr.add_torrent(torrent, "/tmp/downloads");
    assert(@ok(ctx_opt), "Should return session");

    session::Session* ctx = ctx_opt!!;
    assert(mgr.get_torrent_count() == 1, "Should have 1 torrent");
    assert(mgr.has_torrent(&hash), "Should have the torrent");
    assert(ctx.shared == mgr.shared, "Session should share resources");
    assert(mgr.shared.ref_count == 1, "Shared resources should have 1 reference");
}

fn void test_add_multiple_torrents() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    // Add 3 torrents
    for (int i = 0; i < 3; i++)
    {
        char[20] hash = generate_test_hash(i + 1);
        metainfo::TorrentFile* torrent = create_test_torrent("test", hash);
        session::Session*? ctx = mgr.add_torrent(torrent, "/tmp/downloads");
        assert(@ok(ctx), "Should add torrent");
    }

    assert(mgr.get_torrent_count() == 3, "Should have 3 torrents");
    assert(mgr.shared.ref_count == 3, "Shared resources should have 3 references");
}

fn void test_add_duplicate_torrent() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    char[20] hash = generate_test_hash(1);
    metainfo::TorrentFile* torrent1 = create_test_torrent("test1.txt", hash);
    metainfo::TorrentFile* torrent2 = create_test_torrent("test1.txt", hash);

    session::Session*? ctx1 = mgr.add_torrent(torrent1, "/tmp/downloads");
    assert(@ok(ctx1), "Should add first torrent");

    session::Session*? ctx2 = mgr.add_torrent(torrent2, "/tmp/downloads");
    assert(@ok(ctx2), "Should not fault");
    // For pointer optionals, unwrap then check for null
    assert(ctx2!! == null, "Should reject duplicate torrent");

    assert(mgr.get_torrent_count() == 1, "Should still have 1 torrent");

    // Free the rejected torrent
    torrent2.free();
}

fn void test_add_torrent_exceeds_limit() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 2);
    defer mgr.free();

    // Add 2 torrents (at limit)
    char[20] hash1 = generate_test_hash(1);
    char[20] hash2 = generate_test_hash(2);
    metainfo::TorrentFile* torrent1 = create_test_torrent("test1.txt", hash1);
    metainfo::TorrentFile* torrent2 = create_test_torrent("test2.txt", hash2);

    assert(@ok(mgr.add_torrent(torrent1, "/tmp")), "Should add torrent 1");
    assert(@ok(mgr.add_torrent(torrent2, "/tmp")), "Should add torrent 2");

    // Try to add 3rd torrent (exceeds limit)
    char[20] hash3 = generate_test_hash(3);
    metainfo::TorrentFile* torrent3 = create_test_torrent("test3.txt", hash3);
    session::Session*? ctx3 = mgr.add_torrent(torrent3, "/tmp");
    assert(@ok(ctx3), "Should not fault");
    assert(ctx3!! == null, "Should reject torrent exceeding limit");

    assert(mgr.get_torrent_count() == 2, "Should still have 2 torrents");

    // Free the rejected torrent
    torrent3.free();
}

// ============================================================================
// Remove Torrent Tests
// ============================================================================

fn void test_remove_single_torrent() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    char[20] hash = generate_test_hash(1);
    metainfo::TorrentFile* torrent = create_test_torrent("test1.txt", hash);
    (void)mgr.add_torrent(torrent, "/tmp/downloads");

    assert(mgr.get_torrent_count() == 1, "Should have 1 torrent");

    bool removed = mgr.remove_torrent(&hash);

    assert(removed == true, "Should successfully remove torrent");
    assert(mgr.get_torrent_count() == 0, "Should have 0 torrents");
    assert(!mgr.has_torrent(&hash), "Should not have the torrent");
    assert(mgr.shared.ref_count == 0, "Shared resources should have 0 references");
}

fn void test_remove_torrent_not_found() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    char[20] hash = generate_test_hash(99);
    bool removed = mgr.remove_torrent(&hash);

    assert(removed == false, "Should fail to remove non-existent torrent");
}

fn void test_remove_middle_torrent() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    // Add 3 torrents
    char[20] hash1 = generate_test_hash(1);
    char[20] hash2 = generate_test_hash(2);
    char[20] hash3 = generate_test_hash(3);

    (void)mgr.add_torrent(create_test_torrent("test1", hash1), "/tmp");
    (void)mgr.add_torrent(create_test_torrent("test2", hash2), "/tmp");
    (void)mgr.add_torrent(create_test_torrent("test3", hash3), "/tmp");

    assert(mgr.get_torrent_count() == 3, "Should have 3 torrents");
    assert(mgr.shared.ref_count == 3, "Should have 3 references");

    // Remove middle torrent
    mgr.remove_torrent(&hash2);

    assert(mgr.get_torrent_count() == 2, "Should have 2 torrents");
    assert(mgr.has_torrent(&hash1), "Should still have torrent 1");
    assert(!mgr.has_torrent(&hash2), "Should not have torrent 2");
    assert(mgr.has_torrent(&hash3), "Should still have torrent 3");
    assert(mgr.shared.ref_count == 2, "Should have 2 references");
}

// ============================================================================
// Lookup Tests
// ============================================================================

fn void test_get_session() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    char[20] hash = generate_test_hash(1);
    metainfo::TorrentFile* torrent = create_test_torrent("test1.txt", hash);
    session::Session*? added_ctx_opt = mgr.add_torrent(torrent, "/tmp/downloads");
    assert(@ok(added_ctx_opt), "Should add torrent");
    session::Session* added_ctx = added_ctx_opt!!;

    session::Session* found_ctx = mgr.get_session(&hash);

    assert(found_ctx != null, "Should find session");
    assert(found_ctx == added_ctx, "Should return same session pointer");
}

fn void test_get_session_not_found() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    char[20] hash = generate_test_hash(99);
    session::Session* ctx = mgr.get_session(&hash);

    assert(ctx == null, "Should not find non-existent session");
}

fn void test_has_torrent() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    char[20] hash1 = generate_test_hash(1);
    char[20] hash2 = generate_test_hash(2);

    (void)mgr.add_torrent(create_test_torrent("test1", hash1), "/tmp");

    assert(mgr.has_torrent(&hash1), "Should have added torrent");
    assert(!mgr.has_torrent(&hash2), "Should not have other torrent");
}

fn void test_get_all_info_hashes() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    // Add 3 torrents
    char[20] hash1 = generate_test_hash(1);
    char[20] hash2 = generate_test_hash(2);
    char[20] hash3 = generate_test_hash(3);

    (void)mgr.add_torrent(create_test_torrent("test1", hash1), "/tmp");
    (void)mgr.add_torrent(create_test_torrent("test2", hash2), "/tmp");
    (void)mgr.add_torrent(create_test_torrent("test3", hash3), "/tmp");

    common::InfoHash[] hashes = mgr.get_all_info_hashes();
    defer if (hashes.len > 0) free(hashes);

    assert(hashes.len == 3, "Should return 3 hashes");

    // Verify all hashes are present (order may vary)
    bool found1 = false;
    bool found2 = false;
    bool found3 = false;

    foreach (hash : hashes)
    {
        if (hash == hash1) found1 = true;
        if (hash == hash2) found2 = true;
        if (hash == hash3) found3 = true;
    }

    assert(found1 && found2 && found3, "All hashes should be present");
}

fn void test_get_all_info_hashes_empty() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    common::InfoHash[] hashes = mgr.get_all_info_hashes();

    assert(hashes.len == 0, "Should return empty array");
}

// ============================================================================
// Statistics Tests
// ============================================================================

fn void test_get_stats() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    char[20] hash = generate_test_hash(1);
    metainfo::TorrentFile* torrent = create_test_torrent("test1.txt", hash);
    (void)mgr.add_torrent(torrent, "/tmp/downloads");

    torrent_manager::TorrentStats* stats = mgr.get_stats(&hash);
    defer if (stats) { free(stats.name); free(stats); }

    assert(stats != null, "Should return stats");
    assert(stats.name == "test1.txt", "Should have correct name");
    assert(stats.total_size == 1048576, "Should have correct size");
    assert(stats.is_complete == false, "Should not be complete initially");
}

fn void test_get_stats_not_found() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    char[20] hash = generate_test_hash(99);
    torrent_manager::TorrentStats* stats = mgr.get_stats(&hash);

    assert(stats == null, "Should return null for non-existent torrent");
}

fn void test_get_torrent_count() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    assert(mgr.get_torrent_count() == 0, "Should start at 0");

    (void)mgr.add_torrent(create_test_torrent("test1", generate_test_hash(1)), "/tmp");
    assert(mgr.get_torrent_count() == 1, "Should be 1 after add");

    (void)mgr.add_torrent(create_test_torrent("test2", generate_test_hash(2)), "/tmp");
    assert(mgr.get_torrent_count() == 2, "Should be 2 after second add");

    char[20] hash = generate_test_hash(1);
    mgr.remove_torrent(&hash);
    assert(mgr.get_torrent_count() == 1, "Should be 1 after remove");
}

// ============================================================================
// Cleanup Tests
// ============================================================================

fn void test_free_with_active_torrents() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);

    // Add 3 torrents
    (void)mgr.add_torrent(create_test_torrent("test1", generate_test_hash(1)), "/tmp");
    (void)mgr.add_torrent(create_test_torrent("test2", generate_test_hash(2)), "/tmp");
    (void)mgr.add_torrent(create_test_torrent("test3", generate_test_hash(3)), "/tmp");

    assert(mgr.get_torrent_count() == 3, "Should have 3 torrents");
    assert(mgr.shared.ref_count == 3, "Should have 3 references");

    // Free should clean up all torrents and shared resources
    mgr.free();

    // Test passes if no memory leaks occur
}

fn void test_shared_resources_lifecycle() @test => @pool()
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);

    // Add torrents
    char[20] hash1 = generate_test_hash(1);
    char[20] hash2 = generate_test_hash(2);

    (void)mgr.add_torrent(create_test_torrent("test1", hash1), "/tmp");
    assert(mgr.shared.ref_count == 1, "Should have 1 ref after first add");

    (void)mgr.add_torrent(create_test_torrent("test2", hash2), "/tmp");
    assert(mgr.shared.ref_count == 2, "Should have 2 refs after second add");

    // Remove first torrent
    mgr.remove_torrent(&hash1);
    assert(mgr.shared.ref_count == 1, "Should have 1 ref after remove");

    // Remove second torrent
    mgr.remove_torrent(&hash2);
    assert(mgr.shared.ref_count == 0, "Should have 0 refs after all removed");

    // Free manager (SharedResources should already be freed by auto-cleanup)
    mgr.free();
}
