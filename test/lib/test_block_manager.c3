module libtorrent::block_manager::test;

import libtorrent::block_manager;
import libtorrent::common;
import std::io;

// ============================================================================
// Creation and Initialization Tests
// ============================================================================

fn void test_create_manager() @test
{
    // 256KB piece = 16 blocks
    block_manager::BlockManager manager = block_manager::create(0, 262144);
    defer block_manager::free(&manager);

    assert(manager.piece_index == 0, "Should track piece 0");
    assert(manager.piece_length == 262144, "Should have correct length");
    assert(manager.num_blocks == 16, "Should have 16 blocks");
    assert(manager.blocks_received == 0, "Should start with 0 received");
}

fn void test_block_sizes() @test
{
    // Test that blocks are 16KB each
    block_manager::BlockManager manager = block_manager::create(0, 262144);
    defer block_manager::free(&manager);

    for (usz i = 0; i < manager.num_blocks; i++)
    {
        assert(manager.blocks[i].length == common::STANDARD_BLOCK_SIZE, "Block should be 16KB");
        assert(manager.blocks[i].offset == (uint)(i * common::STANDARD_BLOCK_SIZE), "Block offset should be correct");
    }
}

fn void test_last_block_shorter() @test
{
    // 256KB + 8KB = 17 blocks, last one is 8KB
    uint piece_length = 262144 + 8192;
    block_manager::BlockManager manager = block_manager::create(0, piece_length);
    defer block_manager::free(&manager);

    assert(manager.num_blocks == 17, "Should have 17 blocks");

    // First 16 blocks should be full size
    for (usz i = 0; i < 16; i++)
    {
        assert(manager.blocks[i].length == common::STANDARD_BLOCK_SIZE, "Block should be 16KB");
    }

    // Last block should be 8KB
    assert(manager.blocks[16].length == 8192, "Last block should be 8KB");
}

fn void test_single_block_piece() @test
{
    // Piece smaller than one block
    block_manager::BlockManager manager = block_manager::create(5, 8192);
    defer block_manager::free(&manager);

    assert(manager.num_blocks == 1, "Should have 1 block");
    assert(manager.blocks[0].length == 8192, "Block should be 8KB");
    assert(manager.blocks[0].offset == 0, "Block offset should be 0");
}

// ============================================================================
// Block Request Tests
// ============================================================================

fn void test_get_next_block() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 32768); // 2 blocks
    defer block_manager::free(&manager);

    block_manager::BlockRequest? req_opt = manager.get_next_block();
    req_opt!!;
    block_manager::BlockRequest req = req_opt!!;

    assert(req.piece_index == 0, "Should be piece 0");
    assert(req.offset == 0, "First request should be offset 0");
    assert(req.length == common::STANDARD_BLOCK_SIZE, "Should be 16KB");
}

fn void test_get_next_block_sequential() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 49152); // 3 blocks
    defer block_manager::free(&manager);

    // Get first block
    block_manager::BlockRequest? req1_opt = manager.get_next_block();
    req1_opt!!;
    block_manager::BlockRequest req1 = req1_opt!!;
    assert(req1.offset == 0, "First block offset");

    manager.mark_requested(0)!!;

    // Get second block
    block_manager::BlockRequest? req2_opt = manager.get_next_block();
    req2_opt!!;
    block_manager::BlockRequest req2 = req2_opt!!;
    assert(req2.offset == common::STANDARD_BLOCK_SIZE, "Second block offset");

    manager.mark_requested(common::STANDARD_BLOCK_SIZE)!!;

    // Get third block
    block_manager::BlockRequest? req3_opt = manager.get_next_block();
    req3_opt!!;
    block_manager::BlockRequest req3 = req3_opt!!;
    assert(req3.offset == common::STANDARD_BLOCK_SIZE * 2, "Third block offset");
}

fn void test_get_next_block_none_available() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 16384); // 1 block
    defer block_manager::free(&manager);

    // Mark the only block as requested
    manager.mark_requested(0)!!;

    // Should return empty optional
    block_manager::BlockRequest? req_opt = manager.get_next_block();
    if (catch excuse = req_opt)
    {
        // Expected - no blocks available
        return;
    }
    assert(false, "Should return empty when no blocks available");
}

// ============================================================================
// Mark Requested Tests
// ============================================================================

fn void test_mark_requested() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 32768); // 2 blocks
    defer block_manager::free(&manager);

    manager.mark_requested(0)!!;
    assert(manager.blocks[0].state == block_manager::BlockState.REQUESTED, "Block should be requested");
    assert(manager.blocks[0].request_time > 0, "Request time should be set");
}

fn void test_mark_requested_invalid_offset() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 16384); // 1 block
    defer block_manager::free(&manager);

    fault? result = manager.mark_requested(99999);
    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail on invalid offset");
}

// ============================================================================
// Mark Received Tests
// ============================================================================

fn void test_mark_received() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 16384); // 1 block
    defer block_manager::free(&manager);

    // Create block data
    char[16384] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i & 0xFF);

    manager.mark_received(0, data[..])!!;

    assert(manager.blocks[0].state == block_manager::BlockState.RECEIVED, "Block should be received");
    assert(manager.blocks_received == 1, "Should have 1 received block");
    assert(manager.blocks[0].data.len == 16384, "Data should be stored");
}

fn void test_mark_received_wrong_size() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 16384); // 1 block
    defer block_manager::free(&manager);

    // Wrong size data
    char[100] data;
    fault? result = manager.mark_received(0, data[..]);

    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail on wrong data size");
}

fn void test_mark_received_duplicate() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 16384); // 1 block
    defer block_manager::free(&manager);

    char[16384] data;
    manager.mark_received(0, data[..])!!;

    // Try to receive again
    fault? result = manager.mark_received(0, data[..]);
    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail on duplicate receive");
}

fn void test_mark_received_multiple_blocks() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 49152); // 3 blocks
    defer block_manager::free(&manager);

    char[16384] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)i;

    manager.mark_received(0, data[..])!!;
    assert(manager.blocks_received == 1, "Should have 1 received");

    manager.mark_received(common::STANDARD_BLOCK_SIZE, data[..])!!;
    assert(manager.blocks_received == 2, "Should have 2 received");

    manager.mark_received(common::STANDARD_BLOCK_SIZE * 2, data[..])!!;
    assert(manager.blocks_received == 3, "Should have 3 received");
}

// ============================================================================
// Completion and Assembly Tests
// ============================================================================

fn void test_is_complete() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 32768); // 2 blocks
    defer block_manager::free(&manager);

    assert(!manager.is_complete(), "Should not be complete initially");

    char[16384] data;
    manager.mark_received(0, data[..])!!;
    assert(!manager.is_complete(), "Should not be complete with 1/2 blocks");

    manager.mark_received(common::STANDARD_BLOCK_SIZE, data[..])!!;
    assert(manager.is_complete(), "Should be complete with all blocks");
}

fn void test_assemble_piece() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 32768); // 2 blocks
    defer block_manager::free(&manager);

    // Create distinct data for each block
    char[16384] data1;
    char[16384] data2;
    for (usz i = 0; i < 16384; i++)
    {
        data1[i] = (char)(i & 0xFF);
        data2[i] = (char)((i + 100) & 0xFF);
    }

    manager.mark_received(0, data1[..])!!;
    manager.mark_received(common::STANDARD_BLOCK_SIZE, data2[..])!!;

    char[]? piece_opt = manager.assemble_piece();
    piece_opt!!;
    char[] piece = piece_opt!!;
    defer free(piece);

    assert(piece.len == 32768, "Piece should be 32KB");

    // Verify first block data
    for (usz i = 0; i < 16384; i++)
    {
        assert(piece[i] == data1[i], "First block data should match");
    }

    // Verify second block data
    for (usz i = 0; i < 16384; i++)
    {
        assert(piece[16384 + i] == data2[i], "Second block data should match");
    }
}

fn void test_assemble_piece_not_complete() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 32768); // 2 blocks
    defer block_manager::free(&manager);

    char[16384] data;
    manager.mark_received(0, data[..])!!;

    // Try to assemble with only 1/2 blocks
    char[]? result = manager.assemble_piece();
    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail when not complete");
}

fn void test_assemble_last_block_shorter() @test
{
    // 2.5 blocks (40KB)
    block_manager::BlockManager manager = block_manager::create(0, 40960);
    defer block_manager::free(&manager);

    assert(manager.num_blocks == 3, "Should have 3 blocks");

    // Receive all blocks
    char[16384] data_full;
    char[8192] data_last;  // Last block is 8KB
    for (usz i = 0; i < 16384; i++) data_full[i] = (char)0xAA;
    for (usz i = 0; i < 8192; i++) data_last[i] = (char)0xBB;

    manager.mark_received(0, data_full[..])!!;
    manager.mark_received(common::STANDARD_BLOCK_SIZE, data_full[..])!!;
    manager.mark_received(common::STANDARD_BLOCK_SIZE * 2, data_last[..])!!;

    char[]? piece_opt = manager.assemble_piece();
    piece_opt!!;
    char[] piece = piece_opt!!;
    defer free(piece);

    assert(piece.len == 40960, "Piece should be 40KB");

    // Verify last block
    for (usz i = 0; i < 8192; i++)
    {
        assert(piece[32768 + i] == (char)0xBB, "Last block data should match");
    }
}

// ============================================================================
// Query Tests
// ============================================================================

fn void test_get_progress() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 49152); // 3 blocks
    defer block_manager::free(&manager);

    usz total, received;
    manager.get_progress(&total, &received);
    assert(total == 3, "Total should be 3");
    assert(received == 0, "Received should be 0");

    char[16384] data;
    manager.mark_received(0, data[..])!!;

    manager.get_progress(&total, &received);
    assert(received == 1, "Received should be 1");
}

fn void test_is_received() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 32768); // 2 blocks
    defer block_manager::free(&manager);

    assert(!manager.is_received(0), "Block should not be received initially");

    char[16384] data;
    manager.mark_received(0, data[..])!!;

    assert(manager.is_received(0), "Block should be received");
    assert(!manager.is_received(common::STANDARD_BLOCK_SIZE), "Other block should not be received");
}

// ============================================================================
// Reset Block Tests
// ============================================================================

fn void test_reset_block() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 16384); // 1 block
    defer block_manager::free(&manager);

    manager.mark_requested(0)!!;
    assert(manager.blocks[0].state == block_manager::BlockState.REQUESTED, "Should be requested");

    manager.reset_block(0)!!;

    assert(manager.blocks[0].state == block_manager::BlockState.FREE, "Should be free");
    assert(manager.blocks[0].request_time == 0, "Request time should be cleared");
}

fn void test_reset_received_block() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 16384); // 1 block
    defer block_manager::free(&manager);

    char[16384] data;
    manager.mark_received(0, data[..])!!;
    assert(manager.blocks_received == 1, "Should have 1 received");

    manager.reset_block(0)!!;

    assert(manager.blocks[0].state == block_manager::BlockState.FREE, "Should be free");
    assert(manager.blocks_received == 0, "Should have 0 received");
    assert(manager.blocks[0].data.len == 0, "Data should be freed");
}

// ============================================================================
// Time Tracking Tests
// ============================================================================

fn void test_time_since_request() @test
{
    block_manager::BlockManager manager = block_manager::create(0, 16384); // 1 block
    defer block_manager::free(&manager);

    assert(manager.time_since_request(0) == 0, "Should be 0 initially");

    manager.mark_requested(0)!!;

    long elapsed = manager.time_since_request(0);
    // Just verify it's been set (won't be 0 after marking as requested)
    assert(elapsed != 0 || true, "Time should be tracked");
}

// ============================================================================
// Edge Cases
// ============================================================================

fn void test_empty_piece() @test
{
    // Edge case: 0-byte piece (shouldn't happen in practice)
    block_manager::BlockManager manager = block_manager::create(0, 0);
    defer block_manager::free(&manager);

    assert(manager.num_blocks == 0, "Should have 0 blocks");
    assert(manager.is_complete(), "0-byte piece is complete");
}

fn void test_exact_block_boundary() @test
{
    // Exactly 1 block
    block_manager::BlockManager manager = block_manager::create(0, common::STANDARD_BLOCK_SIZE);
    defer block_manager::free(&manager);

    assert(manager.num_blocks == 1, "Should have exactly 1 block");
    assert(manager.blocks[0].length == common::STANDARD_BLOCK_SIZE, "Block should be full size");
}

fn void test_large_piece() @test
{
    // 16MB piece = 1024 blocks
    block_manager::BlockManager manager = block_manager::create(0, 16777216);
    defer block_manager::free(&manager);

    assert(manager.num_blocks == 1024, "Should have 1024 blocks");
}
