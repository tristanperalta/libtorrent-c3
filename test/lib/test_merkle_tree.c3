module test_merkle_tree;

import std::io;
import std::hash::sha256;
import libtorrent::merkle_tree;

/**
 * Test Suite: Merkle Tree Foundation (BEP 52)
 * ============================================
 * Tests for v2 Merkle tree construction, layer selection,
 * proof generation, and proof verification.
 *
 * BEP 52 Merkle Tree Rules:
 * - Block size: 16 KiB (MERKLE_BLOCK_SIZE = 16384 bytes)
 * - Hash: SHA-256 (32 bytes)
 * - Tree: Binary tree, bottom-up construction
 * - Padding: Incomplete blocks padded with zeros to 16 KiB
 * - Odd nodes: Duplicate last node when building parent layer
 */

const uint MERKLE_BLOCK_SIZE = 16384;  // 16 KiB

/**
 * Test 1: Build Merkle tree for single 16 KiB block
 *
 * File: 16 KiB (1 block)
 * Expected tree:
 *   Layer 0: 1 hash (leaf = block hash)
 *   Root: Same as Layer 0 (single node tree)
 */
fn void test_build_single_block_tree() @test
{
    // Create 16 KiB of test data
    char[] data = mem::new_array(char, MERKLE_BLOCK_SIZE);
    defer free(data);

    foreach (i, &c : data) {
        *c = (char)(i % 256);
    }

    // Build Merkle tree
    MerkleTree* tree = merkle_tree::build(data);
    defer tree.free();

    // Verify structure
    assert(tree.num_blocks == 1, "Should have 1 block");
    assert(tree.tree_height == 0, "Single block tree has height 0");
    assert(tree.layers.len() == 1, "Should have 1 layer (leaf = root)");

    // Verify root hash matches direct SHA-256 of block
    char[32] expected_root = sha256::hash(data);
    assert(tree.pieces_root.len == 32, "Root hash should be 32 bytes");

    for (uint i = 0; i < 32; i++) {
        assert(tree.pieces_root[i] == expected_root[i],
               "Root hash mismatch at byte %d", i);
    }

    io::printfn("✓ Single block tree: root hash verified");
}

/**
 * Test 2: Build Merkle tree for 64 KiB (4 blocks)
 *
 * File: 64 KiB (4 blocks)
 * Expected tree:
 *   Layer 0: 4 hashes (H0, H1, H2, H3)
 *   Layer 1: 2 hashes (H01 = hash(H0||H1), H23 = hash(H2||H3))
 *   Layer 2: 1 hash (root = hash(H01||H23))
 */
fn void test_build_multi_block_tree() @test
{
    // Create 64 KiB of test data (4 blocks)
    uint file_size = MERKLE_BLOCK_SIZE * 4;
    char[] data = mem::new_array(char, file_size);
    defer free(data);

    foreach (i, &c : data) {
        *c = (char)(i % 256);
    }

    // Build Merkle tree
    MerkleTree* tree = merkle_tree::build(data);
    defer tree.free();

    // Verify structure
    assert(tree.num_blocks == 4, "Should have 4 blocks");
    assert(tree.tree_height == 2, "Height = log2(4) = 2");
    assert(tree.layers.len() == 3, "Should have 3 layers (0, 1, 2)");

    // Layer 0 should have 4 hashes
    assert(tree.layers[0].len() == 4, "Layer 0 should have 4 hashes");

    // Layer 1 should have 2 hashes
    assert(tree.layers[1].len() == 2, "Layer 1 should have 2 hashes");

    // Layer 2 (root) should have 1 hash
    assert(tree.layers[2].len() == 1, "Layer 2 (root) should have 1 hash");

    // Verify root hash is accessible
    assert(tree.pieces_root.len == 32, "Root hash should be 32 bytes");

    io::printfn("✓ Multi-block tree: 4 blocks → 3 layers");
}

/**
 * Test 3: Layer selection for different piece lengths
 *
 * Test that select_layer() returns the correct layer index
 * where one hash covers exactly piece_length bytes.
 *
 * Formula: blocks_per_piece = piece_length / 16384
 *          selected_layer = log2(blocks_per_piece)
 */
fn void test_layer_selection() @test
{
    // Create 1 MB file (64 blocks)
    uint file_size = MERKLE_BLOCK_SIZE * 64;
    char[] data = mem::new_array(char, file_size);
    defer free(data);

    foreach (i, &c : data) {
        *c = (char)(i % 256);
    }

    MerkleTree* tree = merkle_tree::build(data);
    defer tree.free();

    // Test 1: piece_length = 16 KiB → layer 0 (1 block per piece)
    uint layer = tree.select_layer(16384);
    assert(layer == 0, "16 KiB piece → layer 0, got %d", layer);

    // Test 2: piece_length = 64 KiB → layer 2 (4 blocks per piece)
    layer = tree.select_layer(65536);
    assert(layer == 2, "64 KiB piece → layer 2, got %d", layer);

    // Test 3: piece_length = 256 KiB → layer 4 (16 blocks per piece)
    layer = tree.select_layer(262144);
    assert(layer == 4, "256 KiB piece → layer 4, got %d", layer);

    // Test 4: piece_length = 1 MB → layer 6 (64 blocks per piece)
    layer = tree.select_layer(1048576);
    assert(layer == 6, "1 MB piece → layer 6, got %d", layer);

    io::printfn("✓ Layer selection: verified for 4 piece lengths");
}

/**
 * Test 4: Generate Merkle proof for a piece
 *
 * Proof contains uncle hashes needed to reconstruct root from piece data.
 */
fn void test_generate_proof() @test
{
    // Create 256 KiB file (16 blocks)
    uint file_size = MERKLE_BLOCK_SIZE * 16;
    char[] data = mem::new_array(char, file_size);
    defer free(data);

    foreach (i, &c : data) {
        *c = (char)(i % 256);
    }

    MerkleTree* tree = merkle_tree::build(data);
    defer tree.free();

    // Piece length = 64 KiB (4 blocks per piece)
    uint piece_length = 65536;
    tree.selected_layer = tree.select_layer(piece_length);

    // Generate proof for piece 0
    MerkleProof* proof = tree.generate_proof(0);
    defer proof.free();

    // Verify proof structure
    assert(proof.piece_index == 0, "Should be for piece 0");
    assert(proof.pieces_root.len == 32, "Should have 32-byte root");

    // Number of uncle hashes = tree_height - base_layer
    // For 16 blocks: height = 4, piece covers layer 2, so 2 uncle hashes needed
    uint expected_uncles = tree.tree_height - proof.base_layer;
    assert(proof.uncle_hashes.len() == expected_uncles,
           "Should have %d uncle hashes, got %d", expected_uncles, proof.uncle_hashes.len());

    // Each uncle hash should be 32 bytes
    foreach (i, hash : proof.uncle_hashes) {
        assert(hash.len == 32, "Uncle hash %d should be 32 bytes", i);
    }

    io::printfn("✓ Proof generation: %d uncle hashes for piece 0", proof.uncle_hashes.len());
}

/**
 * Test 5: Verify valid Merkle proof
 *
 * Given: piece data + proof
 * Expected: Verification succeeds (reconstructed root matches)
 */
fn void test_verify_proof_valid() @test
{
    // Create 64 KiB file (4 blocks)
    uint file_size = MERKLE_BLOCK_SIZE * 4;
    char[] file_data = mem::new_array(char, file_size);
    defer free(file_data);

    foreach (i, &c : file_data) {
        *c = (char)(i % 256);
    }

    MerkleTree* tree = merkle_tree::build(file_data);
    defer tree.free();

    // Piece length = 32 KiB (2 blocks per piece)
    uint piece_length = 32768;
    tree.selected_layer = tree.select_layer(piece_length);

    // Generate proof for piece 0
    MerkleProof* proof = tree.generate_proof(0);
    defer proof.free();

    // Extract piece 0 data (first 32 KiB)
    char[] piece_data = mem::new_array(char, piece_length);
    defer free(piece_data);
    foreach (i, &c : piece_data) {
        *c = file_data[i];
    }

    // Verify proof
    bool valid = merkle_tree::verify_proof(piece_data, proof);
    assert(valid, "Proof should be valid for correct piece data");

    io::printfn("✓ Proof verification: valid proof accepted");
}

/**
 * Test 6: Reject invalid Merkle proof
 *
 * Given: tampered piece data + valid proof
 * Expected: Verification fails (root mismatch)
 */
fn void test_verify_proof_invalid() @test
{
    // Create 64 KiB file (4 blocks)
    uint file_size = MERKLE_BLOCK_SIZE * 4;
    char[] file_data = mem::new_array(char, file_size);
    defer free(file_data);

    foreach (i, &c : file_data) {
        *c = (char)(i % 256);
    }

    MerkleTree* tree = merkle_tree::build(file_data);
    defer tree.free();

    // Piece length = 32 KiB (2 blocks per piece)
    uint piece_length = 32768;
    tree.selected_layer = tree.select_layer(piece_length);

    // Generate proof for piece 0
    MerkleProof* proof = tree.generate_proof(0);
    defer proof.free();

    // Create TAMPERED piece data
    char[] piece_data = mem::new_array(char, piece_length);
    defer free(piece_data);
    foreach (i, &c : piece_data) {
        *c = file_data[i];
    }

    // Tamper with byte 1000
    piece_data[1000] = (char)~piece_data[1000];

    // Verify proof should fail
    bool valid = merkle_tree::verify_proof(piece_data, proof);
    assert(!valid, "Proof should be INVALID for tampered piece data");

    io::printfn("✓ Proof verification: invalid proof rejected");
}

/**
 * Test 7: Handle incomplete block padding
 *
 * Last block < 16 KiB must be padded with zeros before hashing.
 */
fn void test_incomplete_block_padding() @test
{
    // Create file with incomplete final block: 20 KiB = 1 full block + 4 KiB
    uint file_size = MERKLE_BLOCK_SIZE + 4096;
    char[] data = mem::new_array(char, file_size);
    defer free(data);

    foreach (i, &c : data) {
        *c = (char)(i % 256);
    }

    MerkleTree* tree = merkle_tree::build(data);
    defer tree.free();

    // Should have 2 blocks (second block padded)
    assert(tree.num_blocks == 2, "Should have 2 blocks (1 full + 1 padded)");

    // Manually verify second block hash with padding
    char[MERKLE_BLOCK_SIZE] padded_block;
    foreach (i, &c : padded_block) {
        if (i < 4096) {
            *c = data[MERKLE_BLOCK_SIZE + i];
        } else {
            *c = 0;  // Zero padding
        }
    }

    char[32] expected_hash = sha256::hash(padded_block[..]);
    char[] layer0_hash1 = tree.layers[0][1];

    for (uint i = 0; i < 32; i++) {
        assert(layer0_hash1[i] == expected_hash[i],
               "Padded block hash mismatch at byte %d", i);
    }

    io::printfn("✓ Incomplete block: padding verified");
}

/**
 * Test 8: Large file tree (stress test)
 *
 * 1 MB file = 64 blocks → height 6 tree
 */
fn void test_large_file_tree() @test
{
    // Create 1 MB file (64 blocks)
    uint file_size = MERKLE_BLOCK_SIZE * 64;
    char[] data = mem::new_array(char, file_size);
    defer free(data);

    foreach (i, &c : data) {
        *c = (char)(i % 256);
    }

    MerkleTree* tree = merkle_tree::build(data);
    defer tree.free();

    // Verify structure
    assert(tree.num_blocks == 64, "Should have 64 blocks");
    assert(tree.tree_height == 6, "Height = log2(64) = 6");
    assert(tree.layers.len() == 7, "Should have 7 layers (0-6)");

    // Verify layer sizes
    assert(tree.layers[0].len() == 64, "Layer 0: 64 hashes");
    assert(tree.layers[1].len() == 32, "Layer 1: 32 hashes");
    assert(tree.layers[2].len() == 16, "Layer 2: 16 hashes");
    assert(tree.layers[3].len() == 8,  "Layer 3: 8 hashes");
    assert(tree.layers[4].len() == 4,  "Layer 4: 4 hashes");
    assert(tree.layers[5].len() == 2,  "Layer 5: 2 hashes");
    assert(tree.layers[6].len() == 1,  "Layer 6: 1 hash (root)");

    // Generate and verify proof for piece in middle (piece 2 out of 0-3)
    tree.selected_layer = tree.select_layer(262144);  // 256 KiB piece (4 pieces total)
    MerkleProof* proof = tree.generate_proof(2);
    defer proof.free();

    assert(proof.piece_index == 2, "Should be for piece 2");

    io::printfn("✓ Large file: 64 blocks → 7 layers verified");
}
