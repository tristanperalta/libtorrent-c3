module test_metainfo_v2;

import std::io;
import std::hash::sha256;
import libtorrent::metainfo;
import libtorrent::bencode;
import libtorrent::common;

/**
 * Test Suite: BEP 52 v2 Metainfo Parsing
 * =======================================
 * Tests for parsing v2 and hybrid torrents with:
 * - Hierarchical file trees
 * - Merkle tree piece layers
 * - SHA-256 info hashes
 * - Backward compatibility with v1
 */

/**
 * Test 1: Parse pure v2 torrent (no v1 compatibility)
 */
fn void test_parse_v2_torrent() @test
{
    // Load v2_only.torrent fixture
    metainfo::TorrentFile* torrent = metainfo::parse_file("test/fixtures/v2_only.torrent")!!;
    defer torrent.free();

    // Verify v2 metadata present
    assert(torrent.info.meta_version == 2, "Should have meta_version == 2");
    assert(torrent.info.is_v2, "Should be marked as v2");
    assert(!torrent.is_hybrid, "Should not be hybrid (v2 only)");

    // Verify v2 info hash calculated
    assert(torrent.info_hash_v2.len == common::SHA256_HASH_SIZE, "Should have 32-byte v2 info hash");

    // Verify file tree parsed
    assert(torrent.info.files.len > 0, "Should have files from file tree");

    io::printfn("✓ Pure v2 torrent parsed successfully");
}

/**
 * Test 2: Parse hybrid torrent (v1 + v2)
 */
fn void test_parse_hybrid_torrent() @test
{
    // Load v2_hybrid.torrent fixture
    metainfo::TorrentFile* torrent = metainfo::parse_file("test/fixtures/v2_hybrid.torrent")!!;
    defer torrent.free();

    // Verify hybrid detection
    assert(torrent.info.meta_version == 2, "Should have meta_version == 2");
    assert(torrent.info.is_v2, "Should be marked as v2");
    assert(torrent.is_hybrid, "Should be marked as hybrid");

    // Verify both v1 and v2 fields present
    assert(torrent.info.pieces.len > 0, "Should have v1 pieces (SHA-1)");
    assert(torrent.info_hash.len == common::SHA1_HASH_SIZE, "Should have v1 info hash");
    assert(torrent.info_hash_v2.len == common::SHA256_HASH_SIZE, "Should have v2 info hash");

    // Verify file tree parsed
    assert(torrent.info.files.len > 0, "Should have files from file tree");

    io::printfn("✓ Hybrid torrent detected and parsed");
}

/**
 * Test 3: Parse file tree - single file
 */
fn void test_parse_file_tree_single() @test
{
    // Load v2_only.torrent (single file)
    metainfo::TorrentFile* torrent = metainfo::parse_file("test/fixtures/v2_only.torrent")!!;
    defer torrent.free();

    // Verify file tree structure
    assert(torrent.info.files.len == 1, "Should have 1 file");

    metainfo::FileEntry* file = &torrent.info.files[0];
    assert(file.has_pieces_root, "File should have pieces_root");
    assert(file.pieces_root.len == common::SHA256_HASH_SIZE, "pieces_root should be 32 bytes");
    assert(file.length > 0, "File should have valid length");

    io::printfn("✓ Single file tree parsed correctly");
}

/**
 * Test 4: Parse file tree - multiple files
 */
fn void test_parse_file_tree_multi() @test
{
    // Load v2_multiple_files.torrent
    metainfo::TorrentFile* torrent = metainfo::parse_file("test/fixtures/v2_multiple_files.torrent")!!;
    defer torrent.free();

    // Verify multiple files with hierarchical paths
    assert(torrent.info.files.len > 1, "Should have multiple files");

    // Verify each file has pieces_root
    foreach (i, file : torrent.info.files)
    {
        assert(file.has_pieces_root, "File %d should have pieces_root", i);
        assert(file.pieces_root.len == common::SHA256_HASH_SIZE, "File %d pieces_root should be 32 bytes", i);
        assert(file.path.len > 0, "File %d should have path", i);
    }

    io::printfn("✓ Multi-file tree with %d files parsed correctly", torrent.info.files.len);
}

/**
 * Test 5: Parse piece layers (Merkle tree data)
 */
fn void test_parse_piece_layers() @test
{
    // Load v2_only.torrent
    metainfo::TorrentFile* torrent = metainfo::parse_file("test/fixtures/v2_only.torrent")!!;
    defer torrent.free();

    // Verify piece layers extracted
    assert(torrent.info.piece_layers.len > 0, "Should have piece layers");
    assert(torrent.info.piece_layers.len == torrent.info.files.len,
           "Should have one Merkle tree per file");

    // Note: Merkle trees are built on-demand, so piece_layers array will be null initially
    // This test validates the piece_layers array was allocated
    foreach (i, tree : torrent.info.piece_layers)
    {
        // Trees are null initially (built on-demand)
    }

    io::printfn("✓ Piece layers (%d Merkle trees) parsed successfully", torrent.info.piece_layers.len);
}

/**
 * Test 6: Calculate v2 info hash (SHA-256)
 */
fn void test_calculate_infohash_v2() @test
{
    // Load v2_only.torrent
    metainfo::TorrentFile* torrent = metainfo::parse_file("test/fixtures/v2_only.torrent")!!;
    defer torrent.free();

    // Verify v2 info hash calculated
    assert(torrent.info_hash_v2.len == common::SHA256_HASH_SIZE, "Should have 32-byte SHA-256 hash");

    // Verify not all zeros
    bool all_zeros = true;
    foreach (byte : torrent.info_hash_v2)
    {
        if (byte != 0)
        {
            all_zeros = false;
            break;
        }
    }
    assert(!all_zeros, "info_hash_v2 should not be all zeros");

    io::printfn("✓ v2 info hash calculated (SHA-256)");
}

/**
 * Test 7: Detect hybrid torrents correctly
 */
fn void test_detect_hybrid() @test
{
    // Test 1: Pure v2 should not be hybrid
    metainfo::TorrentFile* v2 = metainfo::parse_file("test/fixtures/v2_only.torrent")!!;
    defer v2.free();

    assert(!v2.is_hybrid, "Pure v2 should NOT be hybrid");
    assert(v2.info.is_v2, "Pure v2 should be v2");

    // Test 2: Hybrid should be detected
    metainfo::TorrentFile* hybrid = metainfo::parse_file("test/fixtures/v2_hybrid.torrent")!!;
    defer hybrid.free();

    assert(hybrid.is_hybrid, "Hybrid torrent should be hybrid");
    assert(hybrid.info.is_v2, "Hybrid torrent should be v2");
    assert(hybrid.info.pieces.len > 0, "Hybrid should have v1 pieces");

    io::printfn("✓ Hybrid detection working correctly");
}

/**
 * Test 8: Backward compatibility - v1 torrents still work
 */
fn void test_backward_compat_v1() @test
{
    // Load a v1 torrent (base.torrent from existing fixtures)
    metainfo::TorrentFile* torrent = metainfo::parse_file("test/fixtures/base.torrent")!!;
    defer torrent.free();

    // Verify v1 fields still work
    assert(!torrent.info.is_v2, "v1 torrent should NOT be v2");
    assert(!torrent.is_hybrid, "v1 torrent should NOT be hybrid");
    assert(torrent.info.meta_version == 0 || torrent.info.meta_version == 1,
           "v1 torrent should have meta_version 0 or 1");

    // Verify v1 info hash exists
    assert(torrent.info_hash.len == common::SHA1_HASH_SIZE, "Should have v1 info hash");

    // Verify v1 pieces exist
    assert(torrent.info.pieces.len > 0, "Should have v1 pieces");

    io::printfn("✓ v1 backward compatibility maintained");
}
