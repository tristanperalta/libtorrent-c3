module libtorrent::piece_assembler::test;

import libtorrent::piece_assembler;
import async::event_loop;
import std::hash::sha1;
import std::io;

// Context for async verification tests
struct TestVerifyContext
{
    bool completed;
    bool verified;
    uint expected_piece_index;
}

fn void on_test_verify_complete(uint piece_index, bool verified, void* user_data)
{
    TestVerifyContext* ctx = (TestVerifyContext*)user_data;
    ctx.completed = true;
    ctx.verified = verified;
    assert(piece_index == ctx.expected_piece_index, "Piece index should match");
}

// ============================================================================
// Creation Tests
// ============================================================================

fn void test_create_assembler() @test
{
    char[20] expected_hash;
    for (usz i = 0; i < 20; i++) expected_hash[i] = (char)i;

    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 32768, expected_hash, 16384);
    defer assembler.free();

    assert(assembler.piece_index == 0, "Should be piece 0");
    assert(assembler.piece_length == 32768, "Should be 32KB");
    assert(assembler.blocks_received == 0, "Should start with 0 blocks");
    assert(assembler.total_blocks == 2, "Should need 2 blocks");
}

// ============================================================================
// Add Block Tests
// ============================================================================

fn void test_add_single_block() @test
{
    char[20] expected_hash;
    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 16384, expected_hash, 16384);
    defer assembler.free();

    char[16384] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i & 0xFF);

    assembler.add_block(0, data[..])!!;

    assert(assembler.blocks_received == 1, "Should have 1 block");
    assert(assembler.is_complete(), "Should be complete");
}

fn void test_add_multiple_blocks() @test
{
    char[20] expected_hash;
    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 32768, expected_hash, 16384);
    defer assembler.free();

    char[16384] data1;
    char[16384] data2;
    for (usz i = 0; i < 16384; i++)
    {
        data1[i] = (char)0xAA;
        data2[i] = (char)0xBB;
    }

    assembler.add_block(0, data1[..])!!;
    assert(assembler.blocks_received == 1, "Should have 1 block");
    assert(!assembler.is_complete(), "Should not be complete");

    assembler.add_block(16384, data2[..])!!;
    assert(assembler.blocks_received == 2, "Should have 2 blocks");
    assert(assembler.is_complete(), "Should be complete");
}

fn void test_add_block_out_of_order() @test
{
    char[20] expected_hash;
    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 49152, expected_hash, 16384);
    defer assembler.free();

    char[16384] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)i;

    // Add blocks out of order: 2, 0, 1
    assembler.add_block(32768, data[..])!!;  // Block 2
    assert(assembler.blocks_received == 1, "Should have 1 block");

    assembler.add_block(0, data[..])!!;       // Block 0
    assert(assembler.blocks_received == 2, "Should have 2 blocks");

    assembler.add_block(16384, data[..])!!;   // Block 1
    assert(assembler.blocks_received == 3, "Should have 3 blocks");
    assert(assembler.is_complete(), "Should be complete");
}

fn void test_add_duplicate_block() @test
{
    char[20] expected_hash;
    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 16384, expected_hash, 16384);
    defer assembler.free();

    char[16384] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)i;

    assembler.add_block(0, data[..])!!;
    assert(assembler.blocks_received == 1, "Should have 1 block");

    // Add same block again
    assembler.add_block(0, data[..])!!;
    assert(assembler.blocks_received == 1, "Should still have 1 block (no double count)");
}

fn void test_add_block_invalid_offset() @test
{
    char[20] expected_hash;
    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 16384, expected_hash, 16384);
    defer assembler.free();

    char[16384] data;
    fault? result = assembler.add_block(99999, data[..]);

    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail on invalid offset");
}

fn void test_add_block_exceeds_length() @test
{
    char[20] expected_hash;
    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 16384, expected_hash, 16384);
    defer assembler.free();

    char[20000] data;  // Too large
    fault? result = assembler.add_block(0, data[..]);

    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail when block exceeds piece length");
}

// ============================================================================
// Hash Verification Tests
// ============================================================================

fn void test_verify_correct_hash() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // Create known data
    char[16384] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i & 0xFF);

    // Calculate expected hash
    char[20] expected_hash = sha1::hash(data[..]);

    // Create assembler
    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 16384, expected_hash, 16384);
    defer assembler.free();

    // Add data
    assembler.add_block(0, data[..])!!;
    assert(assembler.is_complete(), "Should be complete");

    // Verify (async)
    TestVerifyContext ctx;
    ctx.completed = false;
    ctx.expected_piece_index = 0;

    assembler.verify(&loop, &on_test_verify_complete, &ctx);

    // Run event loop until completion
    while (!ctx.completed && loop.is_alive())
    {
        loop.run_once();
    }

    assert(ctx.completed, "Verification callback should be called");
    assert(ctx.verified, "Should verify successfully");
}

fn void test_verify_incorrect_hash() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // Create data
    char[16384] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i & 0xFF);

    // Wrong hash
    char[20] wrong_hash;
    for (usz i = 0; i < 20; i++) wrong_hash[i] = (char)0xFF;

    // Create assembler
    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 16384, wrong_hash, 16384);
    defer assembler.free();

    // Add data
    assembler.add_block(0, data[..])!!;

    // Verify should fail (async)
    TestVerifyContext ctx;
    ctx.completed = false;
    ctx.expected_piece_index = 0;

    assembler.verify(&loop, &on_test_verify_complete, &ctx);

    // Run event loop until completion
    while (!ctx.completed && loop.is_alive())
    {
        loop.run_once();
    }

    assert(ctx.completed, "Verification callback should be called");
    assert(!ctx.verified, "Verification should fail with wrong hash");
}

fn void test_verify_not_complete() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[20] expected_hash;
    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 32768, expected_hash, 16384);
    defer assembler.free();

    char[16384] data;
    assembler.add_block(0, data[..])!!;  // Only 1 of 2 blocks

    // Try to verify incomplete piece (async)
    TestVerifyContext ctx;
    ctx.completed = false;
    ctx.expected_piece_index = 0;

    assembler.verify(&loop, &on_test_verify_complete, &ctx);

    // Run event loop (callback should be called immediately)
    while (!ctx.completed && loop.is_alive())
    {
        loop.run_once();
    }

    assert(ctx.completed, "Verification callback should be called");
    assert(!ctx.verified, "Should fail to verify incomplete piece");
}

fn void test_verify_multiple_blocks() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // Create two blocks of known data
    char[32768] full_data;
    for (usz i = 0; i < full_data.len; i++) full_data[i] = (char)(i & 0xFF);

    // Calculate expected hash of full data
    char[20] expected_hash = sha1::hash(full_data[..]);

    // Create assembler
    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 32768, expected_hash, 16384);
    defer assembler.free();

    // Split into two blocks
    char[16384] block1;
    char[16384] block2;
    for (usz i = 0; i < 16384; i++)
    {
        block1[i] = full_data[i];
        block2[i] = full_data[i + 16384];
    }

    // Add blocks
    assembler.add_block(0, block1[..])!!;
    assembler.add_block(16384, block2[..])!!;

    // Verify (async)
    TestVerifyContext ctx;
    ctx.completed = false;
    ctx.expected_piece_index = 0;

    assembler.verify(&loop, &on_test_verify_complete, &ctx);

    // Run event loop until completion
    while (!ctx.completed && loop.is_alive())
    {
        loop.run_once();
    }

    assert(ctx.completed, "Verification callback should be called");
    assert(ctx.verified, "Should verify successfully");
}

// ============================================================================
// Data Retrieval Tests
// ============================================================================

fn void test_get_data() @test
{
    char[20] expected_hash;
    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 32768, expected_hash, 16384);
    defer assembler.free();

    char[16384] data1;
    char[16384] data2;
    for (usz i = 0; i < 16384; i++)
    {
        data1[i] = (char)0xAA;
        data2[i] = (char)0xBB;
    }

    assembler.add_block(0, data1[..])!!;
    assembler.add_block(16384, data2[..])!!;

    char[] piece = assembler.get_data();
    assert(piece.len == 32768, "Piece should be 32KB");

    // Verify first block
    for (usz i = 0; i < 16384; i++)
    {
        assert(piece[i] == (char)0xAA, "First block should be 0xAA");
    }

    // Verify second block
    for (usz i = 0; i < 16384; i++)
    {
        assert(piece[16384 + i] == (char)0xBB, "Second block should be 0xBB");
    }
}

// ============================================================================
// Progress Tests
// ============================================================================

fn void test_get_progress() @test
{
    char[20] expected_hash;
    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 49152, expected_hash, 16384);
    defer assembler.free();

    usz total, received;
    assembler.get_progress(&total, &received);
    assert(total == 3, "Total should be 3");
    assert(received == 0, "Received should be 0");

    char[16384] data;
    assembler.add_block(0, data[..])!!;

    assembler.get_progress(&total, &received);
    assert(received == 1, "Received should be 1");

    assembler.add_block(16384, data[..])!!;

    assembler.get_progress(&total, &received);
    assert(received == 2, "Received should be 2");
}

fn void test_is_complete() @test
{
    char[20] expected_hash;
    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 32768, expected_hash, 16384);
    defer assembler.free();

    assert(!assembler.is_complete(), "Should not be complete initially");

    char[16384] data;
    assembler.add_block(0, data[..])!!;
    assert(!assembler.is_complete(), "Should not be complete with 1/2 blocks");

    assembler.add_block(16384, data[..])!!;
    assert(assembler.is_complete(), "Should be complete with all blocks");
}

// ============================================================================
// Edge Cases
// ============================================================================

fn void test_single_block_piece() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    char[8192] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i & 0xFF);

    char[20] expected_hash = sha1::hash(data[..]);

    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 8192, expected_hash, 16384);
    defer assembler.free();

    assert(assembler.total_blocks == 1, "Should need 1 block");

    assembler.add_block(0, data[..])!!;
    assert(assembler.is_complete(), "Should be complete");

    // Verify (async)
    TestVerifyContext ctx;
    ctx.completed = false;
    ctx.expected_piece_index = 0;

    assembler.verify(&loop, &on_test_verify_complete, &ctx);

    // Run event loop until completion
    while (!ctx.completed && loop.is_alive())
    {
        loop.run_once();
    }

    assert(ctx.completed, "Verification callback should be called");
    assert(ctx.verified, "Should verify successfully");
}

fn void test_last_block_shorter() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // 2.5 blocks (40KB)
    char[40960] full_data;
    for (usz i = 0; i < full_data.len; i++) full_data[i] = (char)(i & 0xFF);

    char[20] expected_hash = sha1::hash(full_data[..]);

    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 40960, expected_hash, 16384);
    defer assembler.free();

    assert(assembler.total_blocks == 3, "Should need 3 blocks");

    // Split into blocks
    char[16384] block1;
    char[16384] block2;
    char[8192] block3;  // Last block is 8KB

    for (usz i = 0; i < 16384; i++) block1[i] = full_data[i];
    for (usz i = 0; i < 16384; i++) block2[i] = full_data[16384 + i];
    for (usz i = 0; i < 8192; i++) block3[i] = full_data[32768 + i];

    assembler.add_block(0, block1[..])!!;
    assembler.add_block(16384, block2[..])!!;
    assembler.add_block(32768, block3[..])!!;

    assert(assembler.is_complete(), "Should be complete");

    // Verify (async)
    TestVerifyContext ctx;
    ctx.completed = false;
    ctx.expected_piece_index = 0;

    assembler.verify(&loop, &on_test_verify_complete, &ctx);

    // Run event loop until completion
    while (!ctx.completed && loop.is_alive())
    {
        loop.run_once();
    }

    assert(ctx.completed, "Verification callback should be called");
    assert(ctx.verified, "Should succeed with last block shorter");
}

fn void test_large_piece() @test
{
    // 1MB piece = 64 blocks
    char[20] expected_hash;
    piece_assembler::PieceAssembler assembler = piece_assembler::create(0, 1048576, expected_hash, 16384);
    defer assembler.free();

    assert(assembler.total_blocks == 64, "Should need 64 blocks");
    assert(assembler.piece_length == 1048576, "Should be 1MB");
}
