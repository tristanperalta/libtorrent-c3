module libtorrent::torrent::test;

import std::io;
import std::io::file;
import libtorrent::torrent;
import libtorrent::bencode;

/**
 * Torrent Parser Test Suite
 * =========================
 * Tests for parsing .torrent (BitTorrent metainfo) files.
 */

// Helper function to load torrent file
fn String load_torrent_file(String path)
{
    // Load into temp allocator then copy to persistent memory
    char[] temp_buffer = file::load_temp(path)!!;
    char[] buffer = mem::new_array(char, temp_buffer.len);
    foreach (i, c : temp_buffer)
    {
        buffer[i] = c;
    }
    return (String)buffer;
}

// ============================================================================
// Basic Parsing Tests
// ============================================================================

// Create a minimal valid torrent for testing
fn String create_test_torrent()
{
    // Use bencode encoder to build a valid torrent
    BencodeValue* root = bencode::make_dict();
    defer bencode::free_bencode_value(root);

    // Add announce
    BencodeValue* announce = bencode::make_string("http://tracker.example.com:8080/announce");
    bencode::dict_set(root, "announce", announce);

    // Build info dictionary
    BencodeValue* info = bencode::make_dict();

    // Add name
    BencodeValue* name = bencode::make_string("test.txt");
    bencode::dict_set(info, "name", name);

    // Add length
    BencodeValue* length = bencode::make_integer(100);
    bencode::dict_set(info, "length", length);

    // Add piece length
    BencodeValue* piece_length = bencode::make_integer(16384);
    bencode::dict_set(info, "piece length", piece_length);

    // Add pieces (20 bytes - one SHA1 hash)
    char[20] dummy_hash;
    for (usz i = 0; i < 20; i++)
    {
        dummy_hash[i] = (char)i;
    }
    BencodeValue* pieces = bencode::make_string((String)dummy_hash[..]);
    bencode::dict_set(info, "pieces", pieces);

    // Add info to root
    bencode::dict_set(root, "info", info);

    // Encode and return
    String encoded = bencode::encode(root);
    return encoded;  // Already copied to persistent memory
}

fn void test_debug_torrent_structure() @test
{
    String data = create_test_torrent();
    defer free(data);

    // Just try to decode as bencode first
    BencodeValue* root = bencode::decode(data)!!;
    defer bencode::free_bencode_value(root);

    io::printfn("Root type: %d (DICT=%d)", root.type.ordinal, bencode::BencodeType.DICT.ordinal);
    if (root.type == bencode::BencodeType.DICT)
    {
        io::printfn("Number of keys: %d", root.dict.len);
        for (usz i = 0; i < root.dict.len; i++)
        {
            io::printfn("  Key: '%s'", (String)root.dict.keys[i]);
        }
    }
}

fn void test_parse_valid_torrent() @test
{
    String data = create_test_torrent();
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Verify we got a valid torrent
    assert(torrent != null, "Expected non-null torrent");
}

fn void test_parse_invalid_format() @test
{
    // Not valid bencode
    if (catch err = torrent::parse("invalid data"))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Expected parse to fail for invalid data");
    }
}

fn void test_parse_missing_announce() @test
{
    // Valid bencode but missing required 'announce' field
    String data = "de";  // Empty dictionary

    if (catch err = torrent::parse(data))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Expected parse to fail for missing announce");
    }
}

fn void test_parse_missing_info() @test
{
    // Has announce but no info dict
    String data = "d8:announce9:test:urbae";

    if (catch err = torrent::parse(data))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Expected parse to fail for missing info");
    }
}

// ============================================================================
// Field Extraction Tests
// ============================================================================

fn void test_extract_announce() @test
{
    String data = create_test_torrent();
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Check that announce field exists and is non-empty
    assert(torrent.announce.len > 0, "Expected non-empty announce URL");
    io::printfn("Announce: %s", torrent.announce);
}

fn void test_extract_info_name() @test
{
    String data = create_test_torrent();
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Check that name exists
    assert(torrent.info.name.len > 0, "Expected non-empty file name");
    io::printfn("Name: %s", torrent.info.name);
}

fn void test_extract_info_length() @test
{
    String data = create_test_torrent();
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Check that length is positive
    assert(torrent.info.length > 0, "Expected positive file length");
    io::printfn("Length: %d bytes", torrent.info.length);
}

fn void test_extract_piece_length() @test
{
    String data = create_test_torrent();
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Check that piece_length is positive
    assert(torrent.info.piece_length > 0, "Expected positive piece length");
    io::printfn("Piece length: %d bytes", torrent.info.piece_length);
}

fn void test_extract_pieces() @test
{
    String data = create_test_torrent();
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Check that pieces exist and are multiples of 20
    assert(torrent.info.pieces.len > 0, "Expected non-empty pieces");
    assert(torrent.info.pieces.len % 20 == 0, "Expected pieces to be multiple of 20");
    io::printfn("Pieces: %d bytes (%d hashes)", torrent.info.pieces.len, torrent.info.pieces.len / 20);
}

// ============================================================================
// Optional Field Tests
// ============================================================================

fn void test_optional_created_by() @test
{
    String data = create_test_torrent();
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // created_by is optional, just print it if it exists
    if (torrent.created_by.len > 0)
    {
        io::printfn("Created by: %s", torrent.created_by);
    }
    else
    {
        io::printn("Created by: (not specified)");
    }
}

fn void test_optional_creation_date() @test
{
    String data = create_test_torrent();
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // creation_date is optional
    if (torrent.creation_date > 0)
    {
        io::printfn("Creation date: %d", torrent.creation_date);
    }
    else
    {
        io::printn("Creation date: (not specified)");
    }
}

// ============================================================================
// Piece Hash Tests
// ============================================================================

fn void test_get_num_pieces() @test
{
    String data = create_test_torrent();
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    usz num_pieces = torrent::get_num_pieces(torrent);
    assert(num_pieces > 0, "Expected at least one piece");
    io::printfn("Number of pieces: %d", num_pieces);
}

fn void test_get_piece_hash_valid() @test
{
    String data = create_test_torrent();
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Get first piece hash
    char[] hash = torrent::get_piece_hash(torrent, 0)!!;
    assert(hash.len == 20, "Expected 20-byte hash");

    io::printf("First piece hash: ");
    for (usz i = 0; i < hash.len; i++)
    {
        io::printf("%02x", hash[i] & 0xFF);
    }
    io::printn("");
}

fn void test_get_piece_hash_invalid_index() @test
{
    String data = create_test_torrent();
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    usz num_pieces = torrent::get_num_pieces(torrent);

    // Try to get hash beyond the last piece
    if (catch err = torrent::get_piece_hash(torrent, num_pieces))
    {
        // Expected to fail
        io::printn("Correctly rejected out-of-bounds index");
    }
    else
    {
        assert(false, "Expected get_piece_hash to fail for invalid index");
    }
}

// ============================================================================
// Real Torrent File Tests
// ============================================================================

fn void test_inspect_real_torrent_numbers() @test
{
    String data = load_torrent_file("test/fixtures/numbers.torrent");
    defer free(data);

    // Decode as bencode first to see structure
    BencodeValue* root = bencode::decode(data)!!;
    defer bencode::free_bencode_value(root);

    io::printfn("=== numbers.torrent structure ===");
    if (root.type == bencode::BencodeType.DICT)
    {
        io::printfn("Top-level keys (%d):", root.dict.len);
        for (usz i = 0; i < root.dict.len; i++)
        {
            io::printfn("  - %s", (String)root.dict.keys[i]);
        }
    }
}

fn void test_parse_real_torrent_numbers() @test
{
    String data = load_torrent_file("test/fixtures/numbers.torrent");
    defer free(data);

    // numbers.torrent is multi-file, which we don't support yet
    if (catch err = torrent::parse(data))
    {
        io::printn("=== numbers.torrent ===");
        io::printn("  Multi-file torrent (not yet supported)");
        return;
    }

    assert(false, "Expected parse to fail for multi-file torrent");
}

fn void test_parse_real_torrent_sintel() @test
{
    String data = load_torrent_file("test/fixtures/sintel.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Verify basic fields (announce is optional)
    assert(torrent.info.name.len > 0, "Expected file name");
    assert(torrent.info.length > 0, "Expected file length");
    assert(torrent.info.piece_length > 0, "Expected piece length");
    assert(torrent.info.pieces.len > 0, "Expected pieces");
    assert(torrent.info.pieces.len % 20 == 0, "Expected pieces to be multiple of 20");

    io::printfn("=== sintel.torrent ===");
    if (torrent.announce.len > 0)
    {
        io::printfn("  announce: %s", torrent.announce);
    }
    else
    {
        io::printn("  announce: (not specified)");
    }
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  length: %d bytes", torrent.info.length);
    io::printfn("  piece length: %d bytes", torrent.info.piece_length);
    io::printfn("  pieces: %d hashes", torrent.info.pieces.len / 20);
    io::printf("  info_hash: ");
    for (usz i = 0; i < 20; i++)
    {
        io::printf("%02x", torrent.info_hash[i] & 0xFF);
    }
    io::printn("");
}

// ============================================================================
// Info Hash Tests
// ============================================================================

fn void test_info_hash_calculated() @test
{
    String data = create_test_torrent();
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Verify info_hash is not all zeros
    bool all_zeros = true;
    for (usz i = 0; i < 20; i++)
    {
        if (torrent.info_hash[i] != 0)
        {
            all_zeros = false;
            break;
        }
    }
    assert(!all_zeros, "Expected non-zero info_hash");

    // Print the info_hash
    io::printf("Info hash: ");
    for (usz i = 0; i < 20; i++)
    {
        io::printf("%02x", torrent.info_hash[i] & 0xFF);
    }
    io::printn("");
}

fn void test_info_hash_deterministic() @test
{
    // Parse the same torrent twice
    String data1 = create_test_torrent();
    defer free(data1);

    TorrentFile* torrent1 = torrent::parse(data1)!!;
    defer torrent::free_torrent_file(torrent1);

    String data2 = create_test_torrent();
    defer free(data2);

    TorrentFile* torrent2 = torrent::parse(data2)!!;
    defer torrent::free_torrent_file(torrent2);

    // Verify both have the same info_hash
    for (usz i = 0; i < 20; i++)
    {
        assert(torrent1.info_hash[i] == torrent2.info_hash[i],
               "Expected identical info_hash for identical torrents");
    }

    io::printn("Info hash is deterministic ✓");
}
