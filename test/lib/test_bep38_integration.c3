module libtorrent::bep38_integration_test;

import libtorrent::torrent_manager;
import libtorrent::metainfo;
import libtorrent::resolve_links;
import libtorrent::common;
import libtorrent::session;
import std::io;
import std::collections::list;
import async::event_loop;

<*
 End-to-end integration tests for BEP 38 (Swarm Metadata) file reuse.

 Tests the complete workflow:
 1. Multiple torrents in same collection
 2. File matching via piece hash comparison
 3. Similar torrents linkage
*>

/**
 * Helper: Create a minimal TorrentFile for testing.
 */
fn metainfo::TorrentFile* create_test_torrent_with_collection(
    String name,
    long piece_length,
    long[] file_lengths,
    char[] pieces,
    String[] collections_array
)
{
    metainfo::TorrentFile* torrent = mem::new(metainfo::TorrentFile);
    torrent.arena.init(mem, 4096);

    // Set info fields
    torrent.info.name = copy_string(&torrent.arena, name);
    torrent.info.piece_length = piece_length;
    torrent.info.is_multi_file = true;

    // Copy pieces
    torrent.info.pieces = copy_bytes(&torrent.arena, pieces);

    // Create files
    if (file_lengths.len > 0)
    {
        torrent.info.files = allocator::new_array(&torrent.arena, metainfo::FileEntry, file_lengths.len);
        torrent.info.length = 0;

        foreach (i, file_len : file_lengths)
        {
            metainfo::FileEntry* file = &torrent.info.files[i];
            file.length = file_len;
            file.offset = torrent.info.length;
            torrent.info.length += file_len;

            // Create path components
            DString filename;
            filename.appendf("file%d.txt", i);
            file.path = allocator::new_array(&torrent.arena, String, 1);
            file.path[0] = copy_string(&torrent.arena, filename.str_view());
        }
    }

    // Set collections
    if (collections_array.len > 0)
    {
        torrent.collections = allocator::new_array(&torrent.arena, String, collections_array.len);
        foreach (i, collection : collections_array)
        {
            torrent.collections[i] = copy_string(&torrent.arena, collection);
        }
    }

    // Calculate info_hash (simplified - just use name hash for testing)
    foreach (i, byte : name)
    {
        torrent.info_hash[i % common::SHA1_HASH_SIZE] ^= byte;
    }

    return torrent;
}

/**
 * Helper: Copy string to arena.
 */
fn String copy_string(Allocator allocator, String str)
{
    char[] copy = allocator::new_array(allocator, char, str.len);
    foreach (i, c : str)
    {
        copy[i] = c;
    }
    return (String)copy;
}

/**
 * Helper: Copy bytes to arena.
 */
fn char[] copy_bytes(Allocator allocator, char[] bytes)
{
    char[] copy = allocator::new_array(allocator, char, bytes.len);
    foreach (i, b : bytes)
    {
        copy[i] = b;
    }
    return copy;
}

/**
 * Test: find_by_collection finds torrents in same collection.
 */
fn void test_find_by_collection() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    // Create three torrents: two in "test_collection", one without
    char[20] pieces1; // 1 piece
    char[20] pieces2;
    char[20] pieces3;
    for (usz i = 0; i < 20; i++)
    {
        pieces1[i] = (char)(i % 256);
        pieces2[i] = (char)(i % 256);
        pieces3[i] = (char)(i % 256);
    }

    long[] file_sizes = { 512 };
    String[] collection = { "test_collection" };
    String[] empty_collection = {};

    metainfo::TorrentFile* torrent1 = create_test_torrent_with_collection(
        "torrent1",
        512,
        file_sizes,
        pieces1[..],
        collection
    );

    metainfo::TorrentFile* torrent2 = create_test_torrent_with_collection(
        "torrent2",
        512,
        file_sizes,
        pieces2[..],
        collection
    );

    metainfo::TorrentFile* torrent3 = create_test_torrent_with_collection(
        "torrent3",
        512,
        file_sizes,
        pieces3[..],
        empty_collection
    );

    // Add torrents to manager
    mgr.add_torrent(torrent1, "/tmp/torrent1", null)!!;
    mgr.add_torrent(torrent2, "/tmp/torrent2", null)!!;
    mgr.add_torrent(torrent3, "/tmp/torrent3", null)!!;

    // Find torrents in "test_collection"
    libtorrent::session::Session*[] found = mgr.find_by_collection("test_collection");
    defer free(found);

    assert(found.len == 2, "Should find 2 torrents in test_collection");

    // Verify the found torrents are torrent1 and torrent2
    bool found_torrent1 = false;
    bool found_torrent2 = false;
    foreach (session : found)
    {
        if (session.torrent.info.name == "torrent1") found_torrent1 = true;
        if (session.torrent.info.name == "torrent2") found_torrent2 = true;
    }

    assert(found_torrent1, "Should find torrent1");
    assert(found_torrent2, "Should find torrent2");

    io::printn("✓ find_by_collection finds torrents correctly");
}

/**
 * Test: check_similar_torrents matches files from same collection.
 */
fn void test_check_similar_torrents_collection() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    // Create identical piece hashes for matching
    char[40] pieces;  // 2 pieces
    for (usz i = 0; i < 40; i++)
    {
        pieces[i] = (char)(i % 256);
    }

    long[] file_sizes = { 512, 512 };  // 2 files, 1 piece each
    String[] collection = { "ubuntu_releases" };

    // Create source torrent (already "downloaded")
    metainfo::TorrentFile* source = create_test_torrent_with_collection(
        "ubuntu-22.04",
        512,
        file_sizes,
        pieces[..],
        collection
    );

    // Create target torrent (being added)
    metainfo::TorrentFile* target = create_test_torrent_with_collection(
        "ubuntu-24.04",
        512,
        file_sizes,
        pieces[..],
        collection
    );

    // Add source torrent to manager
    mgr.add_torrent(source, "/tmp/ubuntu-22.04", null)!!;

    // Check if target can reuse files from source
    resolve_links::ResolveLinks links = mgr.check_similar_torrents(target);
    defer links.free();

    // Should find 2 file matches (both files have identical hashes)
    assert(links.get_match_count() == 2, "Should match 2 files from collection");

    // Don't free target - it wasn't added to manager
    target.free();

    io::printn("✓ check_similar_torrents matches files from same collection");
}

/**
 * Test: check_similar_torrents handles no matches gracefully.
 */
fn void test_check_similar_torrents_no_matches() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    // Create different piece hashes (no matches)
    char[20] pieces1;
    char[20] pieces2;
    for (usz i = 0; i < 20; i++)
    {
        pieces1[i] = (char)(i % 256);
        pieces2[i] = (char)((i + 1) % 256);  // Different!
    }

    long[] file_sizes = { 512 };
    String[] collection = { "test_collection" };

    metainfo::TorrentFile* source = create_test_torrent_with_collection(
        "source",
        512,
        file_sizes,
        pieces1[..],
        collection
    );

    metainfo::TorrentFile* target = create_test_torrent_with_collection(
        "target",
        512,
        file_sizes,
        pieces2[..],
        collection
    );

    // Add source
    mgr.add_torrent(source, "/tmp/source", null)!!;

    // Check target - should find no matches (different hashes)
    resolve_links::ResolveLinks links = mgr.check_similar_torrents(target);
    defer links.free();

    assert(links.get_match_count() == 0, "Should find no matches (different hashes)");

    target.free();

    io::printn("✓ check_similar_torrents handles no matches gracefully");
}

/**
 * Test: find_by_collection returns empty array when collection not found.
 */
fn void test_find_by_collection_not_found() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    // Find non-existent collection
    libtorrent::session::Session*[] found = mgr.find_by_collection("nonexistent");
    defer free(found);

    assert(found.len == 0, "Should return empty array for non-existent collection");

    io::printn("✓ find_by_collection returns empty array when not found");
}

/**
 * Test: Empty manager returns empty results.
 */
fn void test_empty_manager() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    torrent_manager::TorrentManager* mgr = torrent_manager::create(&loop, 0);
    defer mgr.free();

    // Find in empty manager
    libtorrent::session::Session*[] found = mgr.find_by_collection("any_collection");
    defer free(found);

    assert(found.len == 0, "Empty manager should return empty array");

    io::printn("✓ Empty manager returns empty results");
}
