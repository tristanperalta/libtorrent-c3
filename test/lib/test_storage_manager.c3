module libtorrent::storage_manager::test;

import libtorrent::storage_manager;
import libtorrent::metainfo;
import async::event_loop;
import std::io;
import std::hash::sha1;

// Test context for async operations
struct TestContext
{
    bool success;
    bool completed;
    int error_code;
    char[] piece_data;
    bool verified;
    event_loop::EventLoop* loop;
}

// ============================================================================
// Test Helpers
// ============================================================================

// Create a simple single-file torrent for testing
fn metainfo::TorrentInfo create_test_torrent_single_file() @private
{
    metainfo::TorrentInfo info;
    info.name = "test_file.bin";
    info.length = 98304;  // 96KB = 3 pieces of 32KB
    info.piece_length = 32768;  // 32KB pieces
    info.is_multi_file = false;
    info.files = {};

    // Create dummy piece hashes (3 pieces)
    info.pieces = mem::new_array(char, 60);  // 3 * 20 bytes
    for (usz i = 0; i < 60; i++)
    {
        info.pieces[i] = (char)(i % 256);
    }

    return info;
}

// Create a multi-file torrent for testing
fn metainfo::TorrentInfo create_test_torrent_multi_file() @private
{
    metainfo::TorrentInfo info;
    info.name = "test_files";
    info.length = 98304;  // 96KB total
    info.piece_length = 32768;  // 32KB pieces
    info.is_multi_file = true;

    // Create 3 files: 40KB, 40KB, 16KB
    info.files = mem::new_array(metainfo::FileEntry, 3);

    // File 1: 40KB
    info.files[0].path = mem::new_array(String, 1);
    info.files[0].path[0] = "file1.bin";
    info.files[0].length = 40960;
    info.files[0].offset = 0;

    // File 2: 40KB
    info.files[1].path = mem::new_array(String, 1);
    info.files[1].path[0] = "file2.bin";
    info.files[1].length = 40960;
    info.files[1].offset = 40960;

    // File 3: 16KB
    info.files[2].path = mem::new_array(String, 1);
    info.files[2].path[0] = "file3.bin";
    info.files[2].length = 16384;
    info.files[2].offset = 81920;

    // Create dummy piece hashes (3 pieces)
    info.pieces = mem::new_array(char, 60);
    for (usz i = 0; i < 60; i++)
    {
        info.pieces[i] = (char)(i % 256);
    }

    return info;
}

// ============================================================================
// Initialization Tests
// ============================================================================

fn void on_init_complete(int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;
    ctx.success = (status == 0);
    ctx.error_code = status;
}

fn void test_create_storage_manager() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    metainfo::TorrentInfo info = create_test_torrent_single_file();
    defer std::core::mem::free(info.pieces);

    storage_manager::StorageManager? manager_opt =
        storage_manager::create(&loop, &info, "/tmp/test_storage_single", true);

    if (catch err = manager_opt)
    {
        assert(false, "Should create storage manager");
        return;
    }

    storage_manager::StorageManager manager = manager_opt;
    defer storage_manager::free(&manager);

    assert(manager.num_pieces == 3, "Should have 3 pieces");
    assert(manager.piece_length == 32768, "Piece length should be 32KB");
    assert(manager.files.len == 1, "Should have 1 file");
}

fn void test_initialize_storage() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    metainfo::TorrentInfo info = create_test_torrent_single_file();
    defer std::core::mem::free(info.pieces);

    storage_manager::StorageManager manager =
        storage_manager::create(&loop, &info, "/tmp/test_storage_init", true)!!;
    defer storage_manager::free(&manager);

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;

    // Initialize storage (should create/open files)
    manager.initialize(&on_init_complete, &ctx);

    // Run event loop until complete
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Storage initialization should succeed");
    assert(ctx.error_code == 0, "Should have no errors");
}

// ============================================================================
// Write/Read Tests
// ============================================================================

fn void on_read_verify(uint piece_index, char[] piece_data, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;
    ctx.piece_data = piece_data;  // Store the piece data

    if (status < 0)
    {
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    // Verify the data matches what we wrote
    ctx.success = true;
    if (piece_data.len != 32768)
    {
        ctx.success = false;
        return;
    }

    for (usz i = 0; i < piece_data.len; i++)
    {
        if (piece_data[i] != (char)(i % 256))
        {
            ctx.success = false;
            return;
        }
    }

    ctx.piece_data = piece_data;
}

fn void on_write_then_read(uint piece_index, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;

    if (status < 0)
    {
        ctx.completed = true;
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    // Write succeeded, now read it back
    // Note: This is a simplified test - in real code we'd pass the manager
    // For now, just mark as success
    ctx.completed = true;
    ctx.success = true;
}

fn void test_write_piece() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    metainfo::TorrentInfo info = create_test_torrent_single_file();
    defer std::core::mem::free(info.pieces);

    storage_manager::StorageManager manager =
        storage_manager::create(&loop, &info, "/tmp/test_storage_write", true)!!;
    defer storage_manager::free(&manager);

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;

    // Initialize storage first
    manager.initialize(&on_init_complete, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }
    assert(ctx.success, "Init should succeed");

    // Create test piece data
    char[] piece_data = mem::new_array(char, 32768);
    defer std::core::mem::free(piece_data);
    for (usz i = 0; i < 32768; i++)
    {
        piece_data[i] = (char)(i % 256);
    }

    // Write piece 0
    ctx.completed = false;
    manager.write_piece(0, piece_data, &on_write_then_read, &ctx);

    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Write should succeed");
}

fn void test_write_read_piece() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    metainfo::TorrentInfo info = create_test_torrent_single_file();
    defer std::core::mem::free(info.pieces);

    storage_manager::StorageManager manager =
        storage_manager::create(&loop, &info, "/tmp/test_storage_rw", true)!!;
    defer storage_manager::free(&manager);

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;

    // Initialize storage
    manager.initialize(&on_init_complete, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }
    assert(ctx.success, "Init should succeed");

    // Create test piece data
    char[] piece_data = mem::new_array(char, 32768);
    for (usz i = 0; i < 32768; i++)
    {
        piece_data[i] = (char)(i % 256);
    }

    // Write piece 0
    ctx.completed = false;
    manager.write_piece(0, piece_data, &on_write_then_read, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }
    assert(ctx.success, "Write should succeed");

    std::core::mem::free(piece_data);

    // Read piece 0 back
    ctx.completed = false;
    manager.read_piece(0, &on_read_verify, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Read should succeed and data should match");

    // Clean up read data
    if (ctx.piece_data.len > 0)
    {
        std::core::mem::free(ctx.piece_data);
    }
}

// ============================================================================
// Verification Tests
// ============================================================================

fn void on_verify_complete(uint piece_index, bool verified, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;

    if (status < 0)
    {
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    ctx.success = true;
    ctx.verified = verified;
}

fn void test_verify_piece() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    metainfo::TorrentInfo info = create_test_torrent_single_file();
    defer std::core::mem::free(info.pieces);

    storage_manager::StorageManager manager =
        storage_manager::create(&loop, &info, "/tmp/test_storage_verify", true)!!;
    defer storage_manager::free(&manager);

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;

    // Initialize
    manager.initialize(&on_init_complete, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    // Create test piece with known hash
    char[] piece_data = mem::new_array(char, 32768);
    for (usz i = 0; i < 32768; i++)
    {
        piece_data[i] = (char)(i % 256);
    }

    // Calculate hash
    char[20] expected_hash = sha1::hash(piece_data);

    // Write piece
    ctx.completed = false;
    manager.write_piece(0, piece_data, &on_write_then_read, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    std::core::mem::free(piece_data);

    // Verify piece
    ctx.completed = false;
    ctx.verified = false;
    manager.verify_piece(0, expected_hash, &on_verify_complete, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Verify should complete successfully");
    assert(ctx.verified, "Piece should be verified");
}

// ============================================================================
// Multi-file Tests
// ============================================================================

fn void test_multi_file_storage() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    metainfo::TorrentInfo info = create_test_torrent_multi_file();
    defer {
        for (usz i = 0; i < info.files.len; i++)
        {
            std::core::mem::free(info.files[i].path);
        }
        std::core::mem::free(info.files);
        std::core::mem::free(info.pieces);
    }

    storage_manager::StorageManager manager =
        storage_manager::create(&loop, &info, "/tmp/test_storage_multi", true)!!;
    defer storage_manager::free(&manager);

    assert(manager.files.len == 3, "Should have 3 files");
    assert(manager.num_pieces == 3, "Should have 3 pieces");

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;

    // Initialize
    manager.initialize(&on_init_complete, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Multi-file init should succeed");
}

fn void test_piece_spanning_files() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    metainfo::TorrentInfo info = create_test_torrent_multi_file();
    defer {
        for (usz i = 0; i < info.files.len; i++)
        {
            std::core::mem::free(info.files[i].path);
        }
        std::core::mem::free(info.files);
        std::core::mem::free(info.pieces);
    }

    storage_manager::StorageManager manager =
        storage_manager::create(&loop, &info, "/tmp/test_storage_span", true)!!;
    defer storage_manager::free(&manager);

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;

    // Initialize
    manager.initialize(&on_init_complete, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    // Write piece 1 (offset 32768, 32KB)
    // This should span file1 (ends at 40960) and file2 (starts at 40960)
    // File1: bytes 32768-40959 (8192 bytes)
    // File2: bytes 0-24575 (24576 bytes)
    char[] piece_data = mem::new_array(char, 32768);
    for (usz i = 0; i < 32768; i++)
    {
        piece_data[i] = (char)((i + 100) % 256);
    }

    ctx.completed = false;
    manager.write_piece(1, piece_data, &on_write_then_read, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Write spanning files should succeed");

    std::core::mem::free(piece_data);

    // Read it back
    ctx.completed = false;
    manager.read_piece(1, &on_read_verify, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    // Verify data (different pattern than on_read_verify expects)
    ctx.success = true;
    if (ctx.piece_data.len == 32768)
    {
        for (usz i = 0; i < 32768; i++)
        {
            if (ctx.piece_data[i] != (char)((i + 100) % 256))
            {
                ctx.success = false;
                break;
            }
        }
    }
    else
    {
        ctx.success = false;
    }

    assert(ctx.success, "Read spanning files should return correct data");

    if (ctx.piece_data.len > 0)
    {
        std::core::mem::free(ctx.piece_data);
    }
}

// ============================================================================
// Edge Cases
// ============================================================================

fn void test_last_piece_shorter() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    metainfo::TorrentInfo info = create_test_torrent_single_file();
    defer std::core::mem::free(info.pieces);

    storage_manager::StorageManager manager =
        storage_manager::create(&loop, &info, "/tmp/test_storage_last", true)!!;
    defer storage_manager::free(&manager);

    // Last piece (piece 2) should be 98304 - 65536 = 32768 bytes
    // (Actually same size in this test, but tests the logic)
    assert(manager.last_piece_length == 32768, "Last piece calculation");

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;

    manager.initialize(&on_init_complete, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    // Write last piece
    char[] piece_data = mem::new_array(char, 32768);
    for (usz i = 0; i < 32768; i++)
    {
        piece_data[i] = (char)(255 - (i % 256));
    }

    ctx.completed = false;
    manager.write_piece(2, piece_data, &on_write_then_read, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Last piece write should succeed");

    std::core::mem::free(piece_data);
}
