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

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Verify it's a multi-file torrent
    assert(torrent.info.is_multi_file, "Expected multi-file torrent");
    assert(torrent.info.files.len > 0, "Expected files list");

    io::printfn("=== numbers.torrent (multi-file) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  files: %d", torrent.info.files.len);
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

fn void test_parse_leaves() @test
{
    String data = load_torrent_file("test/fixtures/leaves.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Verify basic fields
    assert(torrent.info.name.len > 0, "Expected file name");
    assert(torrent.info.length > 0, "Expected file length");
    assert(torrent.info.piece_length > 0, "Expected piece length");
    assert(torrent.info.pieces.len > 0, "Expected pieces");
    assert(torrent.info.pieces.len % 20 == 0, "Expected pieces to be multiple of 20");

    io::printfn("=== leaves.torrent (WebTorrent) ===");
    if (torrent.announce.len > 0)
    {
        io::printfn("  announce: %s", torrent.announce);
    }
    else
    {
        io::printn("  announce: (not specified)");
    }
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  is_multi_file: %s", torrent.info.is_multi_file ? "true" : "false");
    io::printfn("  length: %d bytes", torrent.info.length);
    io::printfn("  piece length: %d bytes", torrent.info.piece_length);
    io::printfn("  pieces: %d hashes", torrent.info.pieces.len / 20);

    if (torrent.info.is_multi_file && torrent.info.files.len > 0)
    {
        io::printfn("  files: %d", torrent.info.files.len);
    }
}

fn void test_parse_libtorrent_base() @test
{
    String data = load_torrent_file("test/fixtures/base.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Verify basic fields
    assert(torrent.info.name.len > 0, "Expected file name");
    assert(torrent.info.length > 0, "Expected file length");
    assert(torrent.info.piece_length > 0, "Expected piece length");
    assert(torrent.info.pieces.len > 0, "Expected pieces");

    io::printfn("=== base.torrent (libtorrent test) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  length: %d bytes", torrent.info.length);
    io::printfn("  piece length: %d bytes", torrent.info.piece_length);
    io::printfn("  pieces: %d hashes", torrent.info.pieces.len / 20);
}

fn void test_parse_libtorrent_test1_single() @test
{
    String data = load_torrent_file("test/fixtures/test1_single.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Verify basic fields
    assert(torrent.info.name.len > 0, "Expected file name");
    assert(torrent.info.length > 0, "Expected file length");
    assert(torrent.info.piece_length > 0, "Expected piece length");
    assert(torrent.info.pieces.len > 0, "Expected pieces");

    io::printfn("=== test1_single.torrent (libtorrent test) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  length: %d bytes", torrent.info.length);
    io::printfn("  piece length: %d bytes", torrent.info.piece_length);
    io::printfn("  pieces: %d hashes", torrent.info.pieces.len / 20);
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

// ============================================================================
// Additional libtorrent Test Files
// ============================================================================

fn void test_parse_url_seed() @test
{
    String data = load_torrent_file("test/fixtures/url_seed.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");
    assert(torrent.info.length > 0, "Expected file length");
    assert(torrent.info.piece_length > 0, "Expected piece length");
    assert(torrent.info.pieces.len > 0, "Expected pieces");

    // Verify URL seed extraction
    assert(torrent.url_list.len > 0, "Expected at least one URL seed");
    assert(torrent.url_list[0] == "http://test.com/file", "Expected correct URL seed");

    io::printfn("=== url_seed.torrent ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  length: %d bytes", torrent.info.length);
    io::printfn("  url-list count: %d", torrent.url_list.len);
    for (usz i = 0; i < torrent.url_list.len; i++)
    {
        io::printfn("    [%d]: %s", i, torrent.url_list[i]);
    }
}

fn void test_parse_url_seed_multi() @test
{
    String data = load_torrent_file("test/fixtures/url_seed_multi.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");

    // Verify multiple URL seeds
    assert(torrent.url_list.len > 0, "Expected at least one URL seed");

    io::printfn("=== url_seed_multi.torrent ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  length: %d bytes", torrent.info.length);
    io::printfn("  url-list count: %d", torrent.url_list.len);
    for (usz i = 0; i < torrent.url_list.len; i++)
    {
        io::printfn("    [%d]: %s", i, torrent.url_list[i]);
    }
}

fn void test_parse_duplicate_web_seeds() @test
{
    String data = load_torrent_file("test/fixtures/duplicate_web_seeds.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");

    // Note: Currently we don't deduplicate, so we'll just verify parsing works
    io::printfn("=== duplicate_web_seeds.torrent ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  url-list count: %d", torrent.url_list.len);
    for (usz i = 0; i < torrent.url_list.len; i++)
    {
        io::printfn("    [%d]: %s", i, torrent.url_list[i]);
    }
    io::printfn("  httpseeds count: %d", torrent.httpseeds.len);
    for (usz i = 0; i < torrent.httpseeds.len; i++)
    {
        io::printfn("    [%d]: %s", i, torrent.httpseeds[i]);
    }
    // TODO: Implement deduplication - should have 3 total unique seeds
}

fn void test_parse_pad_file() @test
{
    String data = load_torrent_file("test/fixtures/pad_file.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");
    assert(torrent.info.is_multi_file, "Expected multi-file torrent");

    io::printfn("=== pad_file.torrent ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  files: %d", torrent.info.files.len);
    for (usz i = 0; i < torrent.info.files.len; i++)
    {
        FileEntry* file = &torrent.info.files[i];
        io::printf("    File %d: ", i);
        for (usz j = 0; j < file.path.len; j++)
        {
            if (j > 0) io::printf("/");
            io::printf("%s", file.path[j]);
        }
        io::printfn(" (%d bytes, offset %d)", file.length, file.offset);
    }
}

fn void test_parse_collection() @test
{
    String data = load_torrent_file("test/fixtures/collection.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");
    assert(torrent.collections.len > 0, "Expected collections");
    assert(torrent.collections.len == 2, "Expected 2 collections");
    assert(torrent.collections[0] == "bar", "Expected first collection 'bar'");
    assert(torrent.collections[1] == "foo", "Expected second collection 'foo'");

    io::printfn("=== collection.torrent ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  length: %d bytes", torrent.info.length);
    io::printfn("  collections: %d", torrent.collections.len);
    for (usz i = 0; i < torrent.collections.len; i++)
    {
        io::printfn("    [%d]: %s", i, torrent.collections[i]);
    }
}

fn void test_parse_similar() @test
{
    String data = load_torrent_file("test/fixtures/similar.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");
    assert(torrent.similar_count > 0, "Expected similar torrents");
    assert(torrent.similar_count == 1, "Expected 1 similar torrent");

    io::printfn("=== similar.torrent ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  length: %d bytes", torrent.info.length);
    io::printfn("  similar torrents: %d", torrent.similar_count);
    for (usz i = 0; i < torrent.similar_count; i++)
    {
        io::printf("    [%d]: ", i);
        usz offset = i * 20;
        for (usz j = 0; j < 20; j++)
        {
            io::printf("%02x", (char)torrent.similar[offset + j]);
        }
        io::printn("");
    }
}

fn void test_parse_dht_nodes() @test
{
    String data = load_torrent_file("test/fixtures/dht_nodes.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");
    assert(torrent.nodes.len > 0, "Expected DHT nodes");
    assert(torrent.nodes.len == 2, "Expected 2 DHT nodes");

    // Verify first node: 127.0.0.1:6881
    assert(torrent.nodes[0].host == "127.0.0.1", "Expected first node host");
    assert(torrent.nodes[0].port == 6881, "Expected first node port");

    // Verify second node: 192.168.1.1:6881
    assert(torrent.nodes[1].host == "192.168.1.1", "Expected second node host");
    assert(torrent.nodes[1].port == 6881, "Expected second node port");

    io::printfn("=== dht_nodes.torrent ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  DHT nodes: %d", torrent.nodes.len);
    for (usz i = 0; i < torrent.nodes.len; i++)
    {
        io::printfn("    [%d]: %s:%d", i, torrent.nodes[i].host, torrent.nodes[i].port);
    }
}

fn void test_inspect_announce_list() @test
{
    // Check if any of our torrents have announce-list
    String data = load_torrent_file("test/fixtures/zero2.torrent");
    defer free(data);

    BencodeValue* root = bencode::decode(data)!!;
    defer bencode::free_bencode_value(root);

    io::printfn("=== Checking for announce-list in zero2.torrent ===");

    // Check for announce-list
    BencodeValue* announce_list = bencode::dict_get(root, "announce-list");
    if (announce_list)
    {
        io::printfn("announce-list found! Type: %d", announce_list.type.ordinal);
        if (announce_list.type == bencode::BencodeType.LIST)
        {
            io::printfn("Tiers: %d", announce_list.list.len);
            for (usz i = 0; i < announce_list.list.len; i++)
            {
                BencodeValue* tier = announce_list.list[i];
                if (tier.type == bencode::BencodeType.LIST)
                {
                    io::printfn("  Tier %d (%d trackers):", i, tier.list.len);
                    for (usz j = 0; j < tier.list.len; j++)
                    {
                        if (tier.list[j].type == bencode::BencodeType.STRING)
                        {
                            io::printfn("    - %s", (String)tier.list[j].string);
                        }
                    }
                }
            }
        }
    }
    else
    {
        io::printn("No announce-list found");

        // Check for single announce
        BencodeValue* announce = bencode::dict_get(root, "announce");
        if (announce && announce.type == bencode::BencodeType.STRING)
        {
            io::printfn("Single announce: %s", (String)announce.string);
        }
    }

    // Inspect info dict
    io::printn("\n=== Info dictionary structure ===");
    BencodeValue* info = bencode::dict_get(root, "info");
    if (info && info.type == bencode::BencodeType.DICT)
    {
        io::printfn("Info dict keys (%d):", info.dict.len);
        for (usz i = 0; i < info.dict.len; i++)
        {
            String key = (String)info.dict.keys[i];
            BencodeValue* val = info.dict.values[i];
            io::printfn("  - %s (type: %d)", key, val.type.ordinal);

            if (key == "files" && val.type == bencode::BencodeType.LIST)
            {
                io::printfn("    Files list: %d files", val.list.len);
                for (usz j = 0; j < val.list.len; j++)
                {
                    BencodeValue* file = val.list[j];
                    if (file.type == bencode::BencodeType.DICT)
                    {
                        io::printfn("    File %d keys:", j);
                        for (usz k = 0; k < file.dict.len; k++)
                        {
                            io::printfn("      - %s", (String)file.dict.keys[k]);
                        }
                    }
                }
            }
        }
    }
}

fn void test_multitracker_numbers_torrent() @test
{
    String data = load_torrent_file("test/fixtures/zero2.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Verify announce-list is parsed
    assert(torrent.announce_list.len > 0, "Expected announce-list to be present");
    assert(torrent.announce_list.len == 2, "Expected 2 tiers in announce-list");

    io::printfn("=== zero2.torrent (multi-tracker) ===");
    io::printfn("  announce: %s", torrent.announce);
    io::printfn("  announce-list tiers: %d", torrent.announce_list.len);

    // Verify tier 0
    assert(torrent.announce_list[0].len == 1, "Expected 1 tracker in tier 0");
    assert(torrent.announce_list[0][0] == "udp://tracker.opentracker.com:80/announce",
           "Expected correct tier 0 tracker");
    io::printfn("  Tier 0 (%d trackers):", torrent.announce_list[0].len);
    for (usz j = 0; j < torrent.announce_list[0].len; j++)
    {
        io::printfn("    - %s", torrent.announce_list[0][j]);
    }

    // Verify tier 1
    assert(torrent.announce_list[1].len == 1, "Expected 1 tracker in tier 1");
    assert(torrent.announce_list[1][0] == "tracker.publicbt.com:80/announce",
           "Expected correct tier 1 tracker");
    io::printfn("  Tier 1 (%d trackers):", torrent.announce_list[1].len);
    for (usz j = 0; j < torrent.announce_list[1].len; j++)
    {
        io::printfn("    - %s", torrent.announce_list[1][j]);
    }
}

fn void test_inspect_creation_date() @test
{
    String data = load_torrent_file("test/fixtures/creation_date.torrent");
    defer free(data);

    // Inspect as bencode first
    BencodeValue* root = bencode::decode(data)!!;
    defer bencode::free_bencode_value(root);

    io::printfn("=== creation_date.torrent structure ===");
    if (root.type == bencode::BencodeType.DICT)
    {
        io::printfn("Top-level keys (%d):", root.dict.len);
        for (usz i = 0; i < root.dict.len; i++)
        {
            io::printfn("  - %s", (String)root.dict.keys[i]);
        }

        // Check info dict
        BencodeValue* info = bencode::dict_get(root, "info");
        if (info && info.type == bencode::BencodeType.DICT)
        {
            io::printfn("Info dict keys (%d):", info.dict.len);
            for (usz i = 0; i < info.dict.len; i++)
            {
                io::printfn("  - %s", (String)info.dict.keys[i]);
            }
        }
    }
}

fn void test_inspect_url_seed() @test
{
    String data = load_torrent_file("test/fixtures/url_seed.torrent");
    defer free(data);

    // Inspect as bencode first
    BencodeValue* root = bencode::decode(data)!!;
    defer bencode::free_bencode_value(root);

    io::printfn("=== url_seed.torrent structure ===");
    if (root.type == bencode::BencodeType.DICT)
    {
        io::printfn("Top-level keys (%d):", root.dict.len);
        for (usz i = 0; i < root.dict.len; i++)
        {
            io::printfn("  - %s", (String)root.dict.keys[i]);
        }

        // Check for url-list field
        BencodeValue* url_list = bencode::dict_get(root, "url-list");
        if (url_list)
        {
            io::printfn("url-list type: %d", url_list.type.ordinal);
            if (url_list.type == bencode::BencodeType.LIST)
            {
                io::printfn("url-list count: %d", url_list.list.len);
                for (usz i = 0; i < url_list.list.len; i++)
                {
                    if (url_list.list[i].type == bencode::BencodeType.STRING)
                    {
                        io::printfn("  [%d]: %s", i, (String)url_list.list[i].string);
                    }
                }
            }
            else if (url_list.type == bencode::BencodeType.STRING)
            {
                io::printfn("url-list (single): %s", (String)url_list.string);
            }
        }
    }
}

fn void test_inspect_httpseed() @test
{
    String data = load_torrent_file("test/fixtures/httpseed.torrent");
    defer free(data);

    // Inspect as bencode first
    BencodeValue* root = bencode::decode(data)!!;
    defer bencode::free_bencode_value(root);

    io::printfn("=== httpseed.torrent structure ===");
    if (root.type == bencode::BencodeType.DICT)
    {
        io::printfn("Top-level keys (%d):", root.dict.len);
        for (usz i = 0; i < root.dict.len; i++)
        {
            io::printfn("  - %s", (String)root.dict.keys[i]);
        }

        // Check for httpseeds field
        BencodeValue* httpseeds = bencode::dict_get(root, "httpseeds");
        if (httpseeds)
        {
            io::printfn("httpseeds type: %d", httpseeds.type.ordinal);
            if (httpseeds.type == bencode::BencodeType.LIST)
            {
                io::printfn("httpseeds count: %d", httpseeds.list.len);
                for (usz i = 0; i < httpseeds.list.len; i++)
                {
                    if (httpseeds.list[i].type == bencode::BencodeType.STRING)
                    {
                        io::printfn("  [%d]: %s", i, (String)httpseeds.list[i].string);
                    }
                }
            }
        }
    }
}

fn void test_parse_creation_date() @test
{
    String data = load_torrent_file("test/fixtures/creation_date.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Verify it's a multi-file torrent
    assert(torrent.info.is_multi_file, "Expected multi-file torrent");
    assert(torrent.info.files.len > 0, "Expected files list");
    assert(torrent.creation_date > 0, "Expected creation date");

    io::printfn("=== creation_date.torrent (multi-file) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  creation_date: %d", torrent.creation_date);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  files: %d", torrent.info.files.len);
}

fn void test_parse_no_creation_date() @test
{
    String data = load_torrent_file("test/fixtures/no_creation_date.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Verify it's a multi-file torrent
    assert(torrent.info.is_multi_file, "Expected multi-file torrent");
    assert(torrent.info.files.len > 0, "Expected files list");
    assert(torrent.creation_date == 0, "Expected no creation date");

    io::printfn("=== no_creation_date.torrent (multi-file) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  files: %d", torrent.info.files.len);
}

fn void test_parse_httpseed() @test
{
    String data = load_torrent_file("test/fixtures/httpseed.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");
    assert(torrent.info.length > 0, "Expected file length");

    // Verify HTTP seed extraction
    assert(torrent.httpseeds.len > 0, "Expected at least one HTTP seed");
    assert(torrent.httpseeds[0] == "http://foobar.com/", "Expected correct HTTP seed");

    io::printfn("=== httpseed.torrent ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  httpseeds count: %d", torrent.httpseeds.len);
    for (usz i = 0; i < torrent.httpseeds.len; i++)
    {
        io::printfn("    [%d]: %s", i, torrent.httpseeds[i]);
    }
}

fn void test_parse_long_name() @test
{
    String data = load_torrent_file("test/fixtures/long_name.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");
    // long_name.torrent should have a very long filename
    assert(torrent.info.name.len > 100, "Expected long filename");

    io::printfn("=== long_name.torrent ===");
    io::printfn("  name length: %d chars", torrent.info.name.len);
}

fn void test_parse_sample() @test
{
    String data = load_torrent_file("test/fixtures/sample.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Verify it's a multi-file torrent
    assert(torrent.info.is_multi_file, "Expected multi-file torrent");
    assert(torrent.info.files.len > 0, "Expected files list");

    io::printfn("=== sample.torrent (multi-file) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  files: %d", torrent.info.files.len);
}

fn void test_web_seeds_optional() @test
{
    // Test that web seeds are optional - torrents without them should parse fine
    String data = load_torrent_file("test/fixtures/base.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Verify torrent parses successfully
    assert(torrent.info.name.len > 0, "Expected file name");

    // Verify web seed fields are empty (not present in base.torrent)
    assert(torrent.url_list.len == 0, "Expected no URL seeds");
    assert(torrent.httpseeds.len == 0, "Expected no HTTP seeds");

    io::printfn("=== base.torrent (no web seeds) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  url-list: %d", torrent.url_list.len);
    io::printfn("  httpseeds: %d", torrent.httpseeds.len);
    io::printn("  Web seeds are optional ✓");
}

// ============================================================================
// Multi-File Path and Offset Tests
// ============================================================================

fn void test_multifile_file_details() @test
{
    String data = load_torrent_file("test/fixtures/sample.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    // Verify it's multi-file
    assert(torrent.info.is_multi_file, "Expected multi-file torrent");
    assert(torrent.info.files.len == 3, "Expected 3 files in sample.torrent");

    io::printfn("=== sample.torrent file details ===");

    // Validate each file has required fields
    for (usz i = 0; i < torrent.info.files.len; i++)
    {
        FileEntry* file = &torrent.info.files[i];

        // Verify path exists and has at least one component
        assert(file.path.len > 0, "File path must have at least one component");

        // Verify length is positive
        assert(file.length > 0, "File length must be positive");

        // Build full path for display
        io::printf("  File %d: ", i);
        for (usz j = 0; j < file.path.len; j++)
        {
            if (j > 0) io::printf("/");
            io::printf("%s", file.path[j]);
        }
        io::printfn("");
        io::printfn("    length: %d bytes", file.length);
        io::printfn("    offset: %d", file.offset);
    }
}

fn void test_multifile_offsets_sequential() @test
{
    String data = load_torrent_file("test/fixtures/sample.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    io::printfn("=== Validating file offsets ===");

    // First file should start at offset 0
    assert(torrent.info.files[0].offset == 0, "First file should start at offset 0");

    // Each subsequent file should start where the previous one ended
    for (usz i = 1; i < torrent.info.files.len; i++)
    {
        long expected_offset = torrent.info.files[i-1].offset + torrent.info.files[i-1].length;
        assert(torrent.info.files[i].offset == expected_offset,
               "File offsets must be sequential");
        io::printfn("  File %d offset: %d (correct)", i, torrent.info.files[i].offset);
    }
}

fn void test_multifile_total_length() @test
{
    String data = load_torrent_file("test/fixtures/sample.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    io::printfn("=== Validating total length ===");

    // Calculate sum of all file lengths
    long calculated_total = 0;
    for (usz i = 0; i < torrent.info.files.len; i++)
    {
        calculated_total += torrent.info.files[i].length;
    }

    // Verify it matches the torrent's total length
    assert(torrent.info.length == calculated_total,
           "Total length must equal sum of all file lengths");
    io::printfn("  Total length: %d bytes", torrent.info.length);
    io::printfn("  Sum of files: %d bytes", calculated_total);
    io::printfn("  Match: ✓");
}

fn void test_multifile_path_components() @test
{
    String data = load_torrent_file("test/fixtures/creation_date.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    io::printfn("=== Validating path components ===");

    // Verify all path components are valid strings
    for (usz i = 0; i < torrent.info.files.len; i++)
    {
        FileEntry* file = &torrent.info.files[i];

        for (usz j = 0; j < file.path.len; j++)
        {
            // Each component should be a non-empty string
            assert(file.path[j].len > 0, "Path components must be non-empty");

            // Verify it's a valid string (no nulls in the middle)
            for (usz k = 0; k < file.path[j].len; k++)
            {
                // Just access it to verify memory is valid
                char c = file.path[j][k];
                (void)c;  // Suppress unused variable warning
            }
        }

        io::printfn("  File %d: %d path components ✓", i, file.path.len);
    }
}

fn void test_multifile_numbers_torrent() @test
{
    String data = load_torrent_file("test/fixtures/numbers.torrent");
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    io::printfn("=== numbers.torrent file structure ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  is_multi_file: %s", torrent.info.is_multi_file ? "true" : "false");
    io::printfn("  total length: %d bytes", torrent.info.length);

    if (torrent.info.is_multi_file)
    {
        io::printfn("  files: %d", torrent.info.files.len);
        for (usz i = 0; i < torrent.info.files.len; i++)
        {
            FileEntry* file = &torrent.info.files[i];
            io::printf("    File %d: ", i);
            for (usz j = 0; j < file.path.len; j++)
            {
                if (j > 0) io::printf("/");
                io::printf("%s", file.path[j]);
            }
            io::printfn(" (%d bytes)", file.length);
        }
    }
}

fn void test_multifile_empty_files_rejected() @test
{
    // Test that we properly reject multi-file torrents with no files
    String data = load_torrent_file("test/fixtures/no_files.torrent");
    defer free(data);

    if (catch err = torrent::parse(data))
    {
        io::printn("=== no_files.torrent ===");
        io::printn("  Correctly rejected (multi-file with empty files list)");
    }
    else
    {
        assert(false, "Expected parse to fail for multi-file torrent with no files");
    }
}

// ============================================================================
// Error Case Tests
// ============================================================================

fn void test_error_missing_piece_len() @test
{
    String data = load_torrent_file("test/fixtures/missing_piece_len.torrent");
    defer free(data);

    if (catch err = torrent::parse(data))
    {
        io::printn("=== missing_piece_len.torrent ===");
        io::printn("  Correctly rejected (missing piece length)");
    }
    else
    {
        assert(false, "Expected parse to fail for missing piece length");
    }
}

fn void test_error_no_name() @test
{
    String data = load_torrent_file("test/fixtures/no_name.torrent");
    defer free(data);

    if (catch err = torrent::parse(data))
    {
        io::printn("=== no_name.torrent ===");
        io::printn("  Correctly rejected (missing name)");
    }
    else
    {
        assert(false, "Expected parse to fail for missing name");
    }
}

fn void test_error_invalid_pieces() @test
{
    String data = load_torrent_file("test/fixtures/invalid_pieces.torrent");
    defer free(data);

    if (catch err = torrent::parse(data))
    {
        io::printn("=== invalid_pieces.torrent ===");
        io::printn("  Correctly rejected (invalid pieces)");
    }
    else
    {
        assert(false, "Expected parse to fail for invalid pieces");
    }
}

fn void test_error_invalid_piece_len() @test
{
    String data = load_torrent_file("test/fixtures/invalid_piece_len.torrent");
    defer free(data);

    if (catch err = torrent::parse(data))
    {
        io::printn("=== invalid_piece_len.torrent ===");
        io::printn("  Correctly rejected (invalid piece length)");
    }
    else
    {
        assert(false, "Expected parse to fail for invalid piece length");
    }
}

fn void test_error_invalid_info() @test
{
    String data = load_torrent_file("test/fixtures/invalid_info.torrent");
    defer free(data);

    if (catch err = torrent::parse(data))
    {
        io::printn("=== invalid_info.torrent ===");
        io::printn("  Correctly rejected (invalid info)");
    }
    else
    {
        assert(false, "Expected parse to fail for invalid info");
    }
}

fn void test_error_negative_piece_len() @test
{
    String data = load_torrent_file("test/fixtures/negative_piece_len.torrent");
    defer free(data);

    if (catch err = torrent::parse(data))
    {
        io::printn("=== negative_piece_len.torrent ===");
        io::printn("  Correctly rejected (negative piece length)");
    }
    else
    {
        assert(false, "Expected parse to fail for negative piece length");
    }
}

fn void test_error_negative_size() @test
{
    String data = load_torrent_file("test/fixtures/negative_size.torrent");
    defer free(data);

    if (catch err = torrent::parse(data))
    {
        io::printn("=== negative_size.torrent ===");
        io::printn("  Correctly rejected (negative total size)");
    }
    else
    {
        assert(false, "Expected parse to fail for negative total size");
    }
}

fn void test_error_negative_file_size() @test
{
    String data = load_torrent_file("test/fixtures/negative_file_size.torrent");
    defer free(data);

    if (catch err = torrent::parse(data))
    {
        io::printn("=== negative_file_size.torrent ===");
        io::printn("  Correctly rejected (negative file size)");
    }
    else
    {
        assert(false, "Expected parse to fail for negative file size");
    }
}

fn void test_error_invalid_file_size() @test
{
    String data = load_torrent_file("test/fixtures/invalid_file_size.torrent");
    defer free(data);

    if (catch err = torrent::parse(data))
    {
        io::printn("=== invalid_file_size.torrent ===");
        io::printn("  Correctly rejected (invalid file size)");
    }
    else
    {
        assert(false, "Expected parse to fail for invalid file size");
    }
}

fn void test_error_unaligned_pieces() @test
{
    String data = load_torrent_file("test/fixtures/unaligned_pieces.torrent");
    defer free(data);

    if (catch err = torrent::parse(data))
    {
        io::printn("=== unaligned_pieces.torrent ===");
        io::printn("  Correctly rejected (pieces not aligned to 20 bytes)");
    }
    else
    {
        assert(false, "Expected parse to fail for unaligned pieces");
    }
}

fn void test_error_string_root() @test
{
    String data = load_torrent_file("test/fixtures/string.torrent");
    defer free(data);

    if (catch err = torrent::parse(data))
    {
        io::printn("=== string.torrent ===");
        io::printn("  Correctly rejected (root is string, not dict)");
    }
    else
    {
        assert(false, "Expected parse to fail for string root");
    }
}

fn void test_error_no_files() @test
{
    String data = load_torrent_file("test/fixtures/no_files.torrent");
    defer free(data);

    if (catch err = torrent::parse(data))
    {
        io::printn("=== no_files.torrent ===");
        io::printn("  Correctly rejected (multi-file with no files)");
    }
    else
    {
        assert(false, "Expected parse to fail for torrent with no files");
    }
}

fn void test_error_zero_length() @test
{
    String data = load_torrent_file("test/fixtures/zero.torrent");
    defer free(data);

    if (catch err = torrent::parse(data))
    {
        io::printn("=== zero.torrent ===");
        io::printn("  Correctly rejected (zero-length torrent)");
    }
    else
    {
        assert(false, "Expected parse to fail for zero-length torrent");
    }
}
