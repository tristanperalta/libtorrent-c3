module libtorrent::download_manager::test;

import libtorrent::download_manager;
import async::event_loop;
import libtorrent::block_manager;
import std::hash::sha1;
import std::io;

// ============================================================================
// Creation and Initialization Tests
// ============================================================================

fn void test_create_manager() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // Create 5 pieces, 256KB each, max 2 concurrent
    char[100] hashes; // 5 pieces * 20 bytes
    for (usz i = 0; i < 100; i++) hashes[i] = (char)i;

    download_manager::DownloadManager manager = download_manager::create(
        &loop, 5, 262144, 262144, hashes[..], 2, 16384);
    defer download_manager::free(&manager);

    assert(manager.num_pieces == 5, "Should track 5 pieces");
    assert(manager.max_concurrent_pieces == 2, "Should allow 2 concurrent");
    assert(manager.piece_length == 262144, "Should have correct piece length");
}

fn void test_create_with_shorter_last_piece() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes; // 3 pieces * 20 bytes

    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 262144, 131072, hashes[..], 1, 16384);
    defer download_manager::free(&manager);

    assert(manager.last_piece_length == 131072, "Last piece should be 128KB");
}

// ============================================================================
// Peer Availability Tests
// ============================================================================

fn void test_update_peer_bitfield() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 262144, 262144, hashes[..], 1, 16384);
    defer download_manager::free(&manager);

    bool[3] bitfield = {true, false, true};
    manager.update_peer_bitfield(bitfield[..])!!;

    assert(manager.picker.get_availability(0) == 1, "Piece 0 should be available");
    assert(manager.picker.get_availability(1) == 0, "Piece 1 should not be available");
    assert(manager.picker.get_availability(2) == 1, "Piece 2 should be available");
}

fn void test_update_bitfield_wrong_size() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 262144, 262144, hashes[..], 1, 16384);
    defer download_manager::free(&manager);

    bool[5] wrong_size = {true, false, true, false, true};
    fault? result = manager.update_peer_bitfield(wrong_size[..]);

    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail on wrong bitfield size");
}

fn void test_peer_has_piece() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 262144, 262144, hashes[..], 1, 16384);
    defer download_manager::free(&manager);

    manager.peer_has_piece(1)!!;
    assert(manager.picker.get_availability(1) == 1, "Piece 1 should be available");
}

// ============================================================================
// Start Download Tests
// ============================================================================

fn void test_start_piece_download() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 262144, 262144, hashes[..], 2, 16384);
    defer download_manager::free(&manager);

    // Peer has all pieces
    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;

    // Start downloading a piece
    manager.start_piece_download(peer_pieces[..])!!;

    // Should have one active download
    usz active_count = 0;
    for (usz i = 0; i < manager.max_concurrent_pieces; i++)
    {
        if (manager.active_downloads[i].active) active_count++;
    }
    assert(active_count == 1, "Should have 1 active download");
}

fn void test_start_multiple_pieces() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 262144, 262144, hashes[..], 2, 16384);
    defer download_manager::free(&manager);

    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;

    // Start two downloads
    manager.start_piece_download(peer_pieces[..])!!;
    manager.start_piece_download(peer_pieces[..])!!;

    // Should have two active downloads
    usz active_count = 0;
    for (usz i = 0; i < manager.max_concurrent_pieces; i++)
    {
        if (manager.active_downloads[i].active) active_count++;
    }
    assert(active_count == 2, "Should have 2 active downloads");
}

fn void test_start_exceeds_max_concurrent() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 262144, 262144, hashes[..], 1, 16384);  // Max 1 concurrent
    defer download_manager::free(&manager);

    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;

    // Start first download - should succeed
    manager.start_piece_download(peer_pieces[..])!!;

    // Try to start second - should fail
    fault? result = manager.start_piece_download(peer_pieces[..]);
    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail when max concurrent reached");
}

fn void test_start_no_pieces_available() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 262144, 262144, hashes[..], 1, 16384);
    defer download_manager::free(&manager);

    // Peer has no pieces
    bool[3] peer_pieces = {false, false, false};
    manager.update_peer_bitfield(peer_pieces[..])!!;

    fault? result = manager.start_piece_download(peer_pieces[..]);
    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail when no pieces available");
}

// ============================================================================
// Block Request Tests
// ============================================================================

fn void test_get_next_block_request() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 32768, 32768, hashes[..], 1, 16384);  // Small pieces for testing
    defer download_manager::free(&manager);

    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;
    manager.start_piece_download(peer_pieces[..])!!;

    // Get block request
    block_manager::BlockRequest? req_opt = manager.get_next_block_request();
    req_opt!!;
    block_manager::BlockRequest req = req_opt!!;

    assert(req.offset == 0, "First block should be offset 0");
    assert(req.length == 16384, "Block should be 16KB");
}

fn void test_get_multiple_block_requests() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 49152, 49152, hashes[..], 1, 16384);  // 3 blocks per piece
    defer download_manager::free(&manager);

    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;
    manager.start_piece_download(peer_pieces[..])!!;

    // Get first block
    block_manager::BlockRequest req1 = manager.get_next_block_request()!!;
    manager.mark_block_requested(req1.piece_index, req1.offset)!!;

    // Get second block
    block_manager::BlockRequest req2 = manager.get_next_block_request()!!;
    assert(req2.offset == 16384, "Second block should be offset 16384");
}

fn void test_no_blocks_available() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 16384, 16384, hashes[..], 1, 16384);  // 1 block pieces
    defer download_manager::free(&manager);

    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;
    manager.start_piece_download(peer_pieces[..])!!;

    // Get and mark first block
    block_manager::BlockRequest req1 = manager.get_next_block_request()!!;
    manager.mark_block_requested(req1.piece_index, req1.offset)!!;

    // No more blocks available
    block_manager::BlockRequest? result = manager.get_next_block_request();
    if (catch excuse = result)
    {
        // Expected
        return;
    }
    assert(false, "Should return fault when no blocks available");
}

// ============================================================================
// Receive Block Tests
// ============================================================================

fn void test_receive_block() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 16384, 16384, hashes[..], 1, 16384);
    defer download_manager::free(&manager);

    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;
    manager.start_piece_download(peer_pieces[..])!!;

    block_manager::BlockRequest req = manager.get_next_block_request()!!;

    // Receive the block
    char[16384] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)i;

    manager.receive_block(req.piece_index, req.offset, data[..])!!;

    // Verify block was received
    usz total, received;
    manager.get_piece_progress(req.piece_index, &total, &received)!!;
    assert(received == 1, "Should have 1 block received");
}

fn void test_receive_block_not_downloading() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 16384, 16384, hashes[..], 1, 16384);
    defer download_manager::free(&manager);

    char[16384] data;
    fault? result = manager.receive_block(99, 0, data[..]);

    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail when piece not downloading");
}

// ============================================================================
// Complete Piece Tests
// ============================================================================

// Context for async completion tests
struct TestCompletionContext
{
    bool completed;
    char[] piece_data;
    bool success;
    uint expected_piece_index;
}

fn void on_test_piece_complete(uint piece_index, char[] piece_data, bool success, void* user_data)
{
    TestCompletionContext* ctx = (TestCompletionContext*)user_data;
    ctx.completed = true;
    ctx.piece_data = piece_data;
    ctx.success = success;
    assert(piece_index == ctx.expected_piece_index, "Piece index should match");
}

fn void test_complete_piece_success() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // Create data and calculate hash
    char[16384] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i & 0xFF);
    char[20] hash = sha1::hash(data[..]);

    // Create manager with correct hash
    char[60] hashes;
    for (usz i = 0; i < 20; i++) hashes[i] = hash[i];

    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 16384, 16384, hashes[..], 1, 16384);
    defer download_manager::free(&manager);

    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;
    manager.start_piece_download(peer_pieces[..])!!;

    // Get the piece index that was started
    uint piece_index = 0;
    for (usz i = 0; i < manager.max_concurrent_pieces; i++)
    {
        if (manager.active_downloads[i].active)
        {
            piece_index = manager.active_downloads[i].piece_index;
            break;
        }
    }

    // Receive block
    manager.receive_block(piece_index, 0, data[..])!!;

    // Complete piece (async)
    TestCompletionContext ctx;
    ctx.completed = false;
    ctx.expected_piece_index = piece_index;

    manager.complete_piece(piece_index, &on_test_piece_complete, &ctx);

    // Run event loop until completion
    while (!ctx.completed && loop.is_alive())
    {
        loop.run_once();
    }

    assert(ctx.completed, "Completion callback should be called");
    assert(ctx.success, "Completion should succeed");
    assert(ctx.piece_data.len == 16384, "Piece should be 16KB");
    assert(manager.have_piece(piece_index), "Piece should be marked complete");

    // Clean up piece data
    if (ctx.piece_data.len > 0) free(ctx.piece_data);
}

fn void test_complete_piece_hash_fail() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // Create data
    char[16384] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i & 0xFF);

    // Use WRONG hash
    char[60] hashes;
    for (usz i = 0; i < 20; i++) hashes[i] = (char)0xFF;

    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 16384, 16384, hashes[..], 1, 16384);
    defer download_manager::free(&manager);

    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;
    manager.start_piece_download(peer_pieces[..])!!;

    uint piece_index = 0;
    for (usz i = 0; i < manager.max_concurrent_pieces; i++)
    {
        if (manager.active_downloads[i].active)
        {
            piece_index = manager.active_downloads[i].piece_index;
            break;
        }
    }

    manager.receive_block(piece_index, 0, data[..])!!;

    // Try to complete with wrong hash (async)
    TestCompletionContext ctx;
    ctx.completed = false;
    ctx.expected_piece_index = piece_index;

    manager.complete_piece(piece_index, &on_test_piece_complete, &ctx);

    // Run event loop until completion
    while (!ctx.completed && loop.is_alive())
    {
        loop.run_once();
    }

    assert(ctx.completed, "Completion callback should be called");
    assert(!ctx.success, "Should fail with hash mismatch");
}

fn void test_complete_piece_not_downloading() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 16384, 16384, hashes[..], 1, 16384);
    defer download_manager::free(&manager);

    TestCompletionContext ctx;
    ctx.completed = false;
    ctx.expected_piece_index = 99;

    manager.complete_piece(99, &on_test_piece_complete, &ctx);

    // Run event loop (callback should be called immediately)
    while (!ctx.completed && loop.is_alive())
    {
        loop.run_once();
    }

    assert(ctx.completed, "Completion callback should be called");
    assert(!ctx.success, "Should fail when piece not downloading");
}

// ============================================================================
// Fail Piece Tests
// ============================================================================

fn void test_fail_piece() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 16384, 16384, hashes[..], 2, 16384);
    defer download_manager::free(&manager);

    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;
    manager.start_piece_download(peer_pieces[..])!!;

    uint piece_index = 0;
    for (usz i = 0; i < manager.max_concurrent_pieces; i++)
    {
        if (manager.active_downloads[i].active)
        {
            piece_index = manager.active_downloads[i].piece_index;
            break;
        }
    }

    // Fail the piece
    manager.fail_piece(piece_index)!!;

    // Should be marked as FREE (can retry)
    assert(!manager.is_piece_downloading(piece_index), "Piece should not be downloading");
    assert(!manager.have_piece(piece_index), "Piece should not be complete");

    // Should be able to start it again
    manager.start_piece_download(peer_pieces[..])!!;
}

fn void test_fail_piece_not_downloading() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 16384, 16384, hashes[..], 1, 16384);
    defer download_manager::free(&manager);

    fault? result = manager.fail_piece(99);
    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail when piece not downloading");
}

// ============================================================================
// Progress Tests
// ============================================================================

fn void test_get_progress() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 16384, 16384, hashes[..], 2, 16384);
    defer download_manager::free(&manager);

    usz total, complete, downloading;
    manager.get_progress(&total, &complete, &downloading);

    assert(total == 3, "Total should be 3");
    assert(complete == 0, "Complete should be 0");
    assert(downloading == 0, "Downloading should be 0");

    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;
    manager.start_piece_download(peer_pieces[..])!!;

    manager.get_progress(&total, &complete, &downloading);
    assert(downloading == 1, "Should have 1 downloading");
}

fn void test_is_complete() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    // Fill with valid hashes
    char[16384] piece_data;
    for (usz i = 0; i < 16384; i++) piece_data[i] = (char)i;
    char[20] piece_hash = sha1::hash(piece_data[..]);
    for (usz p = 0; p < 3; p++)
    {
        for (usz i = 0; i < 20; i++)
        {
            hashes[p * 20 + i] = piece_hash[i];
        }
    }

    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 16384, 16384, hashes[..], 3, 16384);
    defer download_manager::free(&manager);

    assert(!manager.is_complete(), "Should not be complete initially");

    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;

    // Download all 3 pieces
    for (usz p = 0; p < 3; p++)
    {
        manager.start_piece_download(peer_pieces[..])!!;
    }

    // Find and complete each piece (async)
    usz completed_count = 0;
    for (usz slot = 0; slot < 3; slot++)
    {
        if (manager.active_downloads[slot].active)
        {
            uint piece_idx = manager.active_downloads[slot].piece_index;
            manager.receive_block(piece_idx, 0, piece_data[..])!!;

            TestCompletionContext ctx;
            ctx.completed = false;
            ctx.expected_piece_index = piece_idx;

            manager.complete_piece(piece_idx, &on_test_piece_complete, &ctx);

            // Run event loop until this piece completes
            while (!ctx.completed && loop.is_alive())
            {
                loop.run_once();
            }

            assert(ctx.completed, "Piece should complete");
            assert(ctx.success, "Piece should verify");
            if (ctx.piece_data.len > 0) free(ctx.piece_data);
            completed_count++;
        }
    }

    assert(completed_count == 3, "Should have completed all 3 pieces");
    assert(manager.is_complete(), "Should be complete after all pieces");
}

fn void test_get_piece_progress() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 49152, 49152, hashes[..], 1, 16384);  // 3 blocks per piece
    defer download_manager::free(&manager);

    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;
    manager.start_piece_download(peer_pieces[..])!!;

    uint piece_index = manager.active_downloads[0].piece_index;

    usz total, received;
    manager.get_piece_progress(piece_index, &total, &received)!!;

    assert(total == 3, "Should have 3 total blocks");
    assert(received == 0, "Should have 0 received initially");

    // Receive a block
    char[16384] data;
    manager.receive_block(piece_index, 0, data[..])!!;

    manager.get_piece_progress(piece_index, &total, &received)!!;
    assert(received == 1, "Should have 1 received after block");
}

// ============================================================================
// Query Tests
// ============================================================================

fn void test_is_piece_downloading() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[60] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 16384, 16384, hashes[..], 1, 16384);
    defer download_manager::free(&manager);

    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;
    manager.start_piece_download(peer_pieces[..])!!;

    uint piece_index = manager.active_downloads[0].piece_index;
    assert(manager.is_piece_downloading(piece_index), "Piece should be downloading");

    // Other pieces should not be downloading
    for (uint i = 0; i < 3; i++)
    {
        if (i != piece_index)
        {
            assert(!manager.is_piece_downloading(i), "Other pieces should not be downloading");
        }
    }
}

fn void test_have_piece() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[16384] piece_data;
    for (usz i = 0; i < 16384; i++) piece_data[i] = (char)i;
    char[20] piece_hash = sha1::hash(piece_data[..]);

    char[60] hashes;
    for (usz i = 0; i < 20; i++) hashes[i] = piece_hash[i];

    download_manager::DownloadManager manager = download_manager::create(
        &loop, 3, 16384, 16384, hashes[..], 1, 16384);
    defer download_manager::free(&manager);

    bool[3] peer_pieces = {true, true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;
    manager.start_piece_download(peer_pieces[..])!!;

    uint piece_index = manager.active_downloads[0].piece_index;
    assert(!manager.have_piece(piece_index), "Should not have piece initially");

    manager.receive_block(piece_index, 0, piece_data[..])!!;

    TestCompletionContext ctx;
    ctx.completed = false;
    ctx.expected_piece_index = piece_index;

    manager.complete_piece(piece_index, &on_test_piece_complete, &ctx);

    // Run event loop until completion
    while (!ctx.completed && loop.is_alive())
    {
        loop.run_once();
    }

    assert(ctx.completed, "Completion callback should be called");
    assert(ctx.success, "Completion should succeed");
    if (ctx.piece_data.len > 0) free(ctx.piece_data);

    assert(manager.have_piece(piece_index), "Should have piece after completion");
}

// ============================================================================
// Edge Cases
// ============================================================================

fn void test_last_piece_shorter() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[16384] piece_data;
    for (usz i = 0; i < 16384; i++) piece_data[i] = (char)i;
    char[20] piece_hash = sha1::hash(piece_data[..]);

    char[8192] last_piece_data;
    for (usz i = 0; i < 8192; i++) last_piece_data[i] = (char)(i + 100);
    char[20] last_hash = sha1::hash(last_piece_data[..]);

    char[60] hashes;
    for (usz i = 0; i < 20; i++) hashes[i] = piece_hash[i];
    for (usz i = 0; i < 20; i++) hashes[20 + i] = last_hash[i];

    download_manager::DownloadManager manager = download_manager::create(
        &loop, 2, 16384, 8192, hashes[..], 2, 16384);  // Last piece is 8KB
    defer download_manager::free(&manager);

    bool[2] peer_pieces = {true, true};
    manager.update_peer_bitfield(peer_pieces[..])!!;

    // Start both pieces
    manager.start_piece_download(peer_pieces[..])!!;
    manager.start_piece_download(peer_pieces[..])!!;

    // Find the last piece (piece index 1)
    for (usz i = 0; i < 2; i++)
    {
        if (manager.active_downloads[i].active &&
            manager.active_downloads[i].piece_index == 1)
        {
            // Receive last piece (8KB)
            manager.receive_block(1, 0, last_piece_data[..])!!;

            TestCompletionContext ctx;
            ctx.completed = false;
            ctx.expected_piece_index = 1;

            manager.complete_piece(1, &on_test_piece_complete, &ctx);

            // Run event loop until completion
            while (!ctx.completed && loop.is_alive())
            {
                loop.run_once();
            }

            assert(ctx.completed, "Completion callback should be called");
            assert(ctx.success, "Completion should succeed");
            assert(ctx.piece_data.len == 8192, "Last piece should be 8KB");
            if (ctx.piece_data.len > 0) free(ctx.piece_data);

            return;
        }
    }
    assert(false, "Should find last piece download");
}

// ============================================================================
// Regression Tests
// ============================================================================

<*
 * Test starting piece downloads immediately after empty verification.
 * Regression test for the scenario where:
 * 1. All pieces fail verification (new download)
 * 2. Peer sends BITFIELD with all pieces
 * 3. Try to start piece downloads
 *
 * This was failing with NO_PIECES_TO_REQUEST because availability was 0.
 *>
fn void test_start_piece_after_empty_verification() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // Create manager with realistic number of pieces (like Fedora ISO)
    usz num_pieces = 9150;
    char[] hashes = mem::new_array(char, num_pieces * 20);
    defer free(hashes);
    for (usz i = 0; i < hashes.len; i++)
    {
        hashes[i] = (char)i;
    }

    download_manager::DownloadManager manager = download_manager::create(
        &loop, (uint)num_pieces, 262144, 262144, hashes, 5, 16384);
    defer download_manager::free(&manager);

    // Verify initial state (all pieces should be FREE, availability=0)
    assert(manager.picker.pieces_complete == 0, "No pieces should be complete");
    assert(manager.picker.pieces_downloading == 0, "No pieces should be downloading");
    for (usz i = 0; i < 5; i++)
    {
        assert(manager.picker.pieces[i].availability == 0,
               "Pieces should have 0 availability initially");
    }

    // Peer sends BITFIELD - has all pieces (like a seed)
    bool[] peer_pieces = mem::new_array(bool, num_pieces);
    defer free(peer_pieces);
    for (usz i = 0; i < num_pieces; i++)
    {
        peer_pieces[i] = true;
    }

    // Update availability
    manager.update_peer_bitfield(peer_pieces)!!;

    // Verify availability was updated
    for (usz i = 0; i < 5; i++)
    {
        assert(manager.picker.pieces[i].availability == 1,
               "Pieces should have availability 1 after BITFIELD");
    }

    // Start piece downloads - THIS SHOULD SUCCEED (was failing before)
    for (usz i = 0; i < 5; i++)
    {
        fault? result = manager.start_piece_download(peer_pieces);
        if (catch excuse = result)
        {
            if (i == 0)
            {
                // First piece should always succeed
                assert(false, "First piece download should succeed");
            }
            // Later pieces may fail if slots are full (that's OK)
            break;
        }
    }

    // At least one piece should have started
    usz active_count = 0;
    for (usz i = 0; i < manager.max_concurrent_pieces; i++)
    {
        if (manager.active_downloads[i].active) active_count++;
    }
    assert(active_count > 0, "Should have started at least one piece download");
}

<*
 * Test that download slots can be filled incrementally as peers connect.
 *>
fn void test_fill_download_slots_incrementally() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[100] hashes;
    download_manager::DownloadManager manager = download_manager::create(
        &loop, 5, 262144, 262144, hashes[..], 5, 16384);  // 5 concurrent slots
    defer download_manager::free(&manager);

    // First peer connects with all pieces
    bool[5] peer1_pieces = {true, true, true, true, true};
    manager.update_peer_bitfield(peer1_pieces[..])!!;

    // Start 2 pieces from first peer
    manager.start_piece_download(peer1_pieces[..])!!;
    manager.start_piece_download(peer1_pieces[..])!!;

    usz active_count = 0;
    for (usz i = 0; i < 5; i++)
    {
        if (manager.active_downloads[i].active) active_count++;
    }
    assert(active_count == 2, "Should have 2 active downloads");

    // Second peer connects (also has all pieces)
    bool[5] peer2_pieces = {true, true, true, true, true};
    manager.update_peer_bitfield(peer2_pieces[..])!!;

    // Start 3 more pieces from second peer
    manager.start_piece_download(peer2_pieces[..])!!;
    manager.start_piece_download(peer2_pieces[..])!!;
    manager.start_piece_download(peer2_pieces[..])!!;

    active_count = 0;
    for (usz i = 0; i < 5; i++)
    {
        if (manager.active_downloads[i].active) active_count++;
    }
    assert(active_count == 5, "Should have 5 active downloads (all slots full)");

    // Try to start one more - should fail (all slots full)
    fault? result = manager.start_piece_download(peer2_pieces[..]);
    if (catch excuse = result)
    {
        // Expected - all slots full
        return;
    }
    assert(false, "Should fail when all slots are full");
}
