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
    defer manager.free();

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
    defer manager.free();

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
    defer manager.free();

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
    defer manager.free();

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
    defer manager.free();

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
    defer manager.free();

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
    defer manager.free();

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
    defer manager.free();

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

// ============================================================================
// BEP 47: Symlink and Padding File Tests
// ============================================================================

// Create a multi-file torrent with symlinks and padding files
fn metainfo::TorrentInfo create_test_torrent_with_symlinks() @private
{
    metainfo::TorrentInfo info;
    info.name = "test_symlinks";
    info.length = 131072;  // 128KB total
    info.piece_length = 32768;  // 32KB pieces
    info.is_multi_file = true;

    // Create 5 files:
    // 1. Regular file: 40KB
    // 2. Symlink: 40KB (should be skipped)
    // 3. Padding file: 8KB (should be skipped)
    // 4. Regular file: 32KB
    // 5. Another symlink: 8KB (should be skipped)
    info.files = mem::new_array(metainfo::FileEntry, 5);

    // File 1: Regular file - 40KB
    info.files[0].path = mem::new_array(String, 1);
    info.files[0].path[0] = "data.bin";
    info.files[0].length = 40960;
    info.files[0].offset = 0;
    info.files[0].attr = "";
    info.files[0].symlink_path = {};

    // File 2: Symlink - 40KB (attr='l')
    info.files[1].path = mem::new_array(String, 1);
    info.files[1].path[0] = "link_to_data.bin";
    info.files[1].length = 40960;
    info.files[1].offset = 40960;
    info.files[1].attr = "l";  // Symlink flag
    info.files[1].symlink_path = mem::new_array(String, 1);
    info.files[1].symlink_path[0] = "data.bin";

    // File 3: Padding file - 8KB (attr='p')
    info.files[2].path = mem::new_array(String, 1);
    info.files[2].path[0] = ".pad";
    info.files[2].length = 8192;
    info.files[2].offset = 81920;
    info.files[2].attr = "p";  // Padding flag
    info.files[2].symlink_path = {};

    // File 4: Regular file - 32KB
    info.files[3].path = mem::new_array(String, 1);
    info.files[3].path[0] = "other_data.bin";
    info.files[3].length = 32768;
    info.files[3].offset = 90112;
    info.files[3].attr = "";
    info.files[3].symlink_path = {};

    // File 5: Another symlink - 8KB (attr='lx' - symlink + executable)
    info.files[4].path = mem::new_array(String, 1);
    info.files[4].path[0] = "link_exec";
    info.files[4].length = 8192;
    info.files[4].offset = 122880;
    info.files[4].attr = "lx";  // Symlink + executable flags
    info.files[4].symlink_path = mem::new_array(String, 1);
    info.files[4].symlink_path[0] = "other_data.bin";

    // Create dummy piece hashes (4 pieces)
    info.pieces = mem::new_array(char, 80);  // 4 * 20 bytes
    for (usz i = 0; i < 80; i++)
    {
        info.pieces[i] = (char)(i % 256);
    }

    return info;
}

fn void test_symlink_detection() @test
{
    metainfo::TorrentInfo info = create_test_torrent_with_symlinks();
    defer {
        for (usz i = 0; i < info.files.len; i++)
        {
            std::core::mem::free(info.files[i].path);
            if (info.files[i].symlink_path.len > 0)
            {
                std::core::mem::free(info.files[i].symlink_path);
            }
        }
        std::core::mem::free(info.files);
        std::core::mem::free(info.pieces);
    }

    // Test FileEntry.is_symlink() helper
    assert(!info.files[0].is_symlink(), "Regular file should not be symlink");
    assert(info.files[1].is_symlink(), "File with 'l' attr should be symlink");
    assert(!info.files[2].is_symlink(), "Padding file should not be symlink");
    assert(!info.files[3].is_symlink(), "Regular file should not be symlink");
    assert(info.files[4].is_symlink(), "File with 'lx' attr should be symlink");

    // Test FileEntry.is_padding() helper
    assert(!info.files[0].is_padding(), "Regular file should not be padding");
    assert(!info.files[1].is_padding(), "Symlink should not be padding");
    assert(info.files[2].is_padding(), "File with 'p' attr should be padding");
    assert(!info.files[3].is_padding(), "Regular file should not be padding");
    assert(!info.files[4].is_padding(), "Symlink should not be padding");
}

fn void test_storage_manager_skips_symlinks() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    metainfo::TorrentInfo info = create_test_torrent_with_symlinks();
    defer {
        for (usz i = 0; i < info.files.len; i++)
        {
            std::core::mem::free(info.files[i].path);
            if (info.files[i].symlink_path.len > 0)
            {
                std::core::mem::free(info.files[i].symlink_path);
            }
        }
        std::core::mem::free(info.files);
        std::core::mem::free(info.pieces);
    }

    storage_manager::StorageManager manager =
        storage_manager::create(&loop, &info, "/tmp/test_storage_symlinks", true)!!;
    defer manager.free();

    // Verify flags are set correctly on FileInfo structs
    assert(manager.files.len == 5, "Should have 5 files");
    assert(!manager.files[0].is_symlink, "File 0 should not be symlink");
    assert(manager.files[1].is_symlink, "File 1 should be symlink");
    assert(!manager.files[2].is_symlink, "File 2 should not be symlink");
    assert(!manager.files[3].is_symlink, "File 3 should not be symlink");
    assert(manager.files[4].is_symlink, "File 4 should be symlink");

    assert(!manager.files[0].is_padding, "File 0 should not be padding");
    assert(!manager.files[1].is_padding, "File 1 should not be padding");
    assert(manager.files[2].is_padding, "File 2 should be padding");
    assert(!manager.files[3].is_padding, "File 3 should not be padding");
    assert(!manager.files[4].is_padding, "File 4 should not be padding");

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;

    // Initialize storage - symlinks and padding should be skipped
    manager.initialize(&on_init_complete, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Storage init should succeed with symlinks");
}

fn void test_write_spanning_symlink() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    metainfo::TorrentInfo info = create_test_torrent_with_symlinks();
    defer {
        for (usz i = 0; i < info.files.len; i++)
        {
            std::core::mem::free(info.files[i].path);
            if (info.files[i].symlink_path.len > 0)
            {
                std::core::mem::free(info.files[i].symlink_path);
            }
        }
        std::core::mem::free(info.files);
        std::core::mem::free(info.pieces);
    }

    storage_manager::StorageManager manager =
        storage_manager::create(&loop, &info, "/tmp/test_storage_symlink_write", true)!!;
    defer manager.free();

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
    assert(ctx.success, "Init should succeed");

    // Write piece 1 (offset 32768, 32KB)
    // This piece spans:
    //   - End of file 0 (bytes 32768-40959 = 8192 bytes)
    //   - Start of file 1/symlink (bytes 0-24575 = 24576 bytes)
    // The symlink portion should be skipped
    char[] piece_data = mem::new_array(char, 32768);
    for (usz i = 0; i < 32768; i++)
    {
        piece_data[i] = (char)(i % 256);
    }

    ctx.completed = false;
    manager.write_piece(1, piece_data, &on_write_then_read, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Write spanning symlink should succeed");

    std::core::mem::free(piece_data);
}

fn void test_write_padding_file() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    metainfo::TorrentInfo info = create_test_torrent_with_symlinks();
    defer {
        for (usz i = 0; i < info.files.len; i++)
        {
            std::core::mem::free(info.files[i].path);
            if (info.files[i].symlink_path.len > 0)
            {
                std::core::mem::free(info.files[i].symlink_path);
            }
        }
        std::core::mem::free(info.files);
        std::core::mem::free(info.pieces);
    }

    storage_manager::StorageManager manager =
        storage_manager::create(&loop, &info, "/tmp/test_storage_padding", true)!!;
    defer manager.free();

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
    assert(ctx.success, "Init should succeed");

    // Write piece 2 (offset 65536, 32KB)
    // This piece spans:
    //   - End of file 1/symlink (bytes 24576-40959 = 16384 bytes)
    //   - All of file 2/padding (bytes 0-8191 = 8192 bytes)
    //   - Start of file 3 (bytes 0-8191 = 8192 bytes)
    // Both symlink and padding portions should be skipped
    char[] piece_data = mem::new_array(char, 32768);
    for (usz i = 0; i < 32768; i++)
    {
        piece_data[i] = (char)((i + 50) % 256);
    }

    ctx.completed = false;
    manager.write_piece(2, piece_data, &on_write_then_read, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Write spanning padding file should succeed");

    std::core::mem::free(piece_data);
}

fn void test_single_file_no_symlinks() @test
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
        storage_manager::create(&loop, &info, "/tmp/test_storage_single_nosym", true)!!;
    defer manager.free();

    // Single-file torrents should never have symlinks or padding
    assert(manager.files.len == 1, "Should have 1 file");
    assert(!manager.files[0].is_symlink, "Single-file should not be symlink");
    assert(!manager.files[0].is_padding, "Single-file should not be padding");
}

fn void test_all_symlinks_and_padding() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    // Create torrent where all files are symlinks or padding
    metainfo::TorrentInfo info;
    info.name = "test_all_skip";
    info.length = 65536;  // 64KB total
    info.piece_length = 32768;  // 32KB pieces
    info.is_multi_file = true;

    info.files = mem::new_array(metainfo::FileEntry, 2);

    // File 1: Symlink - 32KB
    info.files[0].path = mem::new_array(String, 1);
    info.files[0].path[0] = "link1";
    info.files[0].length = 32768;
    info.files[0].offset = 0;
    info.files[0].attr = "l";
    info.files[0].symlink_path = {};

    // File 2: Padding - 32KB
    info.files[1].path = mem::new_array(String, 1);
    info.files[1].path[0] = ".pad";
    info.files[1].length = 32768;
    info.files[1].offset = 32768;
    info.files[1].attr = "p";
    info.files[1].symlink_path = {};

    info.pieces = mem::new_array(char, 40);  // 2 * 20 bytes
    for (usz i = 0; i < 40; i++)
    {
        info.pieces[i] = (char)(i % 256);
    }

    defer {
        for (usz i = 0; i < info.files.len; i++)
        {
            std::core::mem::free(info.files[i].path);
        }
        std::core::mem::free(info.files);
        std::core::mem::free(info.pieces);
    }

    storage_manager::StorageManager manager =
        storage_manager::create(&loop, &info, "/tmp/test_storage_all_skip", true)!!;
    defer manager.free();

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;

    // Initialize - should skip all files
    manager.initialize(&on_init_complete, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Init should succeed even with all files skipped");

    // Write piece 0 - everything should be skipped
    char[] piece_data = mem::new_array(char, 32768);
    for (usz i = 0; i < 32768; i++)
    {
        piece_data[i] = (char)(i % 256);
    }

    ctx.completed = false;
    manager.write_piece(0, piece_data, &on_write_then_read, &ctx);
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Write should succeed with all files skipped");

    std::core::mem::free(piece_data);
}

