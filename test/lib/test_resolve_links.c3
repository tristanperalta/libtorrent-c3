module libtorrent::resolve_links_test;

import libtorrent::resolve_links;
import libtorrent::metainfo;
import libtorrent::common;
import std::io;
import std::collections::list;

<*
 Tests for resolve_links module (BEP 38 file matching).

 Tests piece hash comparison algorithm for file reuse.
*>

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
 * Helper: Create a test TorrentFile with specified parameters.
 *
 * @param name Torrent name
 * @param piece_length Piece length in bytes
 * @param files Array of file lengths
 * @param pieces Piece hashes (concatenated 20-byte SHA1 hashes)
 * @return TorrentFile* - caller must free with torrent.free()
 */
fn metainfo::TorrentFile* create_test_torrent(
    String name,
    long piece_length,
    long[] file_lengths,
    char[] pieces
)
{
    metainfo::TorrentFile* torrent = mem::new(metainfo::TorrentFile);
    torrent.arena.init(mem, 4096);

    // Set info fields
    torrent.info.name = copy_string(&torrent.arena, name);
    torrent.info.piece_length = piece_length;
    // Always treat as multi-file for testing (resolve_links doesn't support single-file yet)
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

    return torrent;
}

/**
 * Test: Basic file matching with identical files.
 */
fn void test_match_file_identical() @test
{
    // Create identical piece hashes for 2 files
    // File 1: 512 bytes (1 piece)
    // File 2: 1024 bytes (2 pieces)
    char[60] pieces;  // 3 pieces total
    for (usz i = 0; i < 60; i++)
    {
        pieces[i] = (char)(i % 256);
    }

    long[] file_sizes = { 512, 1024 };

    // Source torrent
    metainfo::TorrentFile* source = create_test_torrent(
        "source",
        512,
        file_sizes,
        pieces[..]
    );
    defer source.free();

    // Target torrent (identical)
    metainfo::TorrentFile* target = create_test_torrent(
        "target",
        512,
        file_sizes,
        pieces[..]
    );
    defer target.free();

    // Create ResolveLinks
    resolve_links::ResolveLinks links = resolve_links::create(target);
    defer links.free();

    // Try to match first file (512 bytes)
    links.match_file(source, "/tmp/source", 0)!!;

    // Should have one match
    assert(links.get_match_count() == 1, "Should have 1 match");

    resolve_links::FileMatch[] matches = links.get_matches();
    assert(matches[0].file_index == 0, "Should match file 0");
    assert(matches[0].piece_count == 1, "Should span 1 piece");

    io::printn("✓ match_file finds identical files");
}

/**
 * Test: File matching with size mismatch.
 */
fn void test_match_file_size_mismatch() @test
{
    char[60] pieces;
    for (usz i = 0; i < 60; i++)
    {
        pieces[i] = (char)(i % 256);
    }

    // Source: 512 bytes
    long[] source_sizes = { 512 };
    metainfo::TorrentFile* source = create_test_torrent(
        "source",
        512,
        source_sizes,
        pieces[..]
    );
    defer source.free();

    // Target: 1024 bytes (different size!)
    long[] target_sizes = { 1024 };
    metainfo::TorrentFile* target = create_test_torrent(
        "target",
        512,
        target_sizes,
        pieces[..]
    );
    defer target.free();

    // Create ResolveLinks
    resolve_links::ResolveLinks links = resolve_links::create(target);
    defer links.free();

    // Try to match - should fail due to size mismatch
    links.match_file(source, "/tmp/source", 0)!!;

    // Should have no matches
    assert(links.get_match_count() == 0, "Should have 0 matches (size mismatch)");

    io::printn("✓ match_file rejects size mismatches");
}

/**
 * Test: File matching with piece length mismatch.
 */
fn void test_match_file_piece_length_mismatch() @test
{
    char[60] pieces;
    for (usz i = 0; i < 60; i++)
    {
        pieces[i] = (char)(i % 256);
    }

    long[] file_sizes = { 512 };

    // Source: piece_length = 512
    metainfo::TorrentFile* source = create_test_torrent(
        "source",
        512,
        file_sizes,
        pieces[..]
    );
    defer source.free();

    // Target: piece_length = 1024 (different!)
    metainfo::TorrentFile* target = create_test_torrent(
        "target",
        1024,
        file_sizes,
        pieces[..]
    );
    defer target.free();

    // Create ResolveLinks
    resolve_links::ResolveLinks links = resolve_links::create(target);
    defer links.free();

    // Try to match - should fail due to piece length mismatch
    if (catch err = links.match_file(source, "/tmp/source", 0))
    {
        // Expected to fail
        io::printn("✓ match_file rejects piece length mismatches");
    }
    else
    {
        assert(false, "Should fail for piece length mismatch");
    }
}

/**
 * Test: Match multiple files in one torrent.
 */
fn void test_match_torrent_multiple_files() @test
{
    // Create identical piece hashes
    char[80] pieces;  // 4 pieces
    for (usz i = 0; i < 80; i++)
    {
        pieces[i] = (char)(i % 256);
    }

    // Two files: 512 bytes, 1024 bytes
    long[] file_sizes = { 512, 1024, 512 };

    // Source torrent
    metainfo::TorrentFile* source = create_test_torrent(
        "source",
        512,
        file_sizes,
        pieces[..]
    );
    defer source.free();

    // Target torrent (identical)
    metainfo::TorrentFile* target = create_test_torrent(
        "target",
        512,
        file_sizes,
        pieces[..]
    );
    defer target.free();

    // Create ResolveLinks
    resolve_links::ResolveLinks links = resolve_links::create(target);
    defer links.free();

    // Match entire torrent
    links.match_torrent(source, "/tmp/source");

    // Should have 3 matches (all files)
    assert(links.get_match_count() == 3, "Should match all 3 files");

    io::printn("✓ match_torrent finds multiple files");
}

/**
 * Test: Partial hash mismatch (some pieces match, some don't).
 */
fn void test_match_file_partial_mismatch() @test
{
    // Create piece hashes where first piece matches, second doesn't
    char[40] source_pieces;  // 2 pieces
    char[40] target_pieces;
    for (usz i = 0; i < 20; i++)
    {
        // First piece: identical
        source_pieces[i] = (char)(i % 256);
        target_pieces[i] = (char)(i % 256);
    }
    for (usz i = 20; i < 40; i++)
    {
        // Second piece: different
        source_pieces[i] = (char)(i % 256);
        target_pieces[i] = (char)((i + 1) % 256);
    }

    long[] file_sizes = { 1024 };  // 2 pieces

    metainfo::TorrentFile* source = create_test_torrent(
        "source",
        512,
        file_sizes,
        source_pieces[..]
    );
    defer source.free();

    metainfo::TorrentFile* target = create_test_torrent(
        "target",
        512,
        file_sizes,
        target_pieces[..]
    );
    defer target.free();

    // Create ResolveLinks
    resolve_links::ResolveLinks links = resolve_links::create(target);
    defer links.free();

    // Try to match - should fail due to hash mismatch
    links.match_file(source, "/tmp/source", 0)!!;

    // Should have no matches (partial mismatch = no match)
    assert(links.get_match_count() == 0, "Partial mismatch should not match");

    io::printn("✓ match_file rejects partial hash mismatches");
}

/**
 * Test: Empty file matching.
 */
fn void test_match_file_empty() @test
{
    char[20] pieces;  // 1 piece for non-empty file
    for (usz i = 0; i < 20; i++)
    {
        pieces[i] = (char)(i % 256);
    }

    // Empty file (0 bytes) + non-empty file (512 bytes)
    long[] file_sizes = { 0, 512 };

    metainfo::TorrentFile* source = create_test_torrent(
        "source",
        512,
        file_sizes,
        pieces[..]
    );
    defer source.free();

    metainfo::TorrentFile* target = create_test_torrent(
        "target",
        512,
        file_sizes,
        pieces[..]
    );
    defer target.free();

    // Create ResolveLinks
    resolve_links::ResolveLinks links = resolve_links::create(target);
    defer links.free();

    // Try to match empty file (should skip - no pieces to compare)
    links.match_file(source, "/tmp/source", 0)!!;
    assert(links.get_match_count() == 0, "Empty file should not match");

    // Try to match non-empty file (should match)
    links.match_file(source, "/tmp/source", 1)!!;
    assert(links.get_match_count() == 1, "Non-empty file should match");

    io::printn("✓ Empty files are skipped correctly");
}
