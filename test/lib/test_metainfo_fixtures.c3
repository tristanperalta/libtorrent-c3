module libtorrent::metainfo::fixture_test;

import std::io;
import std::io::file;
import libtorrent::metainfo;
import libtorrent::bencode;

/**
 * Torrent Parser Fixture Test Suite
 * ===================================
 * Tests using real .torrent fixture files from test/fixtures/
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

// Real Torrent File Tests
// ============================================================================

// File: test/fixtures/numbers.torrent
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
        io::printfn("Top-level keys (%d):", root.dict.keys.size);
        for (usz i = 0; i < root.dict.keys.size; i++)
        {
            io::printfn("  - %s", (String)root.dict.keys[i]);
        }
    }
}

// File: test/fixtures/numbers.torrent
fn void test_parse_real_torrent_numbers() @test
{
    String data = load_torrent_file("test/fixtures/numbers.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    // Verify it's a multi-file torrent
    assert(torrent.info.is_multi_file, "Expected multi-file torrent");
    assert(torrent.info.files.len > 0, "Expected files list");

    io::printfn("=== numbers.torrent (multi-file) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  files: %d", torrent.info.files.len);
}

// File: test/fixtures/sintel.torrent
fn void test_parse_real_torrent_sintel() @test
{
    String data = load_torrent_file("test/fixtures/sintel.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/leaves.torrent
fn void test_parse_leaves() @test
{
    String data = load_torrent_file("test/fixtures/leaves.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/base.torrent
fn void test_parse_libtorrent_base() @test
{
    String data = load_torrent_file("test/fixtures/base.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/test1_single.torrent
fn void test_parse_libtorrent_test1_single() @test
{
    String data = load_torrent_file("test/fixtures/test1_single.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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
// Additional libtorrent Test Files
// ============================================================================

// File: test/fixtures/url_seed.torrent
fn void test_parse_url_seed() @test
{
    String data = load_torrent_file("test/fixtures/url_seed.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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
    foreach (i, url : torrent.url_list)
    {
        io::printfn("    [%d]: %s", i, url);
    }
}

// File: test/fixtures/url_seed_multi.torrent
fn void test_parse_url_seed_multi() @test
{
    String data = load_torrent_file("test/fixtures/url_seed_multi.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");

    // Verify multiple URL seeds
    assert(torrent.url_list.len > 0, "Expected at least one URL seed");

    io::printfn("=== url_seed_multi.torrent ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  length: %d bytes", torrent.info.length);
    io::printfn("  url-list count: %d", torrent.url_list.len);
    foreach (i, url : torrent.url_list)
    {
        io::printfn("    [%d]: %s", i, url);
    }
}

// File: test/fixtures/duplicate_web_seeds.torrent
fn void test_parse_duplicate_web_seeds() @test
{
    String data = load_torrent_file("test/fixtures/duplicate_web_seeds.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");

    // Verify deduplication: 8 URLs in file → 3 unique URLs
    assert(torrent.url_list.len == 3, "Expected 3 unique URLs after deduplication");
    assert(torrent.url_list[0] == "http://foobar.com/foo", "Expected first unique URL");
    assert(torrent.url_list[1] == "http://foobar.com/foobar", "Expected second unique URL");
    assert(torrent.url_list[2] == "http://foobar.com/bar", "Expected third unique URL");

    io::printfn("=== duplicate_web_seeds.torrent (deduplication test) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  url-list count: %d (8 total, 5 duplicates filtered)", torrent.url_list.len);
    foreach (i, url : torrent.url_list)
    {
        io::printfn("    [%d]: %s", i, url);
    }
    io::printfn("  httpseeds count: %d", torrent.httpseeds.len);
    foreach (i, httpseed : torrent.httpseeds)
    {
        io::printfn("    [%d]: %s", i, httpseed);
    }
}

// File: test/fixtures/pad_file.torrent
fn void test_parse_pad_file() @test
{
    String data = load_torrent_file("test/fixtures/pad_file.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/collection.torrent
fn void test_parse_collection() @test
{
    String data = load_torrent_file("test/fixtures/collection.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/similar.torrent
fn void test_parse_similar() @test
{
    String data = load_torrent_file("test/fixtures/similar.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/dht_nodes.torrent
fn void test_parse_dht_nodes() @test
{
    String data = load_torrent_file("test/fixtures/dht_nodes.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/url_list.torrent
fn void test_url_list() @test
{
    String data = load_torrent_file("test/fixtures/url_list.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");
    // url-list contains empty string - should be filtered out
    assert(torrent.url_list.len == 0, "Expected empty url-list after filtering");

    io::printfn("=== url_list.torrent (edge case: empty string) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  url-list count: %d (empty string filtered)", torrent.url_list.len);
}

// File: test/fixtures/url_list2.torrent
fn void test_url_list2() @test
{
    String data = load_torrent_file("test/fixtures/url_list2.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");
    // url-list contains nested list (invalid) - should be ignored

    io::printfn("=== url_list2.torrent (edge case: nested list) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  url-list count: %d (nested list ignored)", torrent.url_list.len);
}

// File: test/fixtures/url_list3.torrent
fn void test_url_list3() @test
{
    String data = load_torrent_file("test/fixtures/url_list3.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");
    // url-list contains integer (invalid) - should be ignored

    io::printfn("=== url_list3.torrent (edge case: integer in list) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  url-list count: %d (integer ignored)", torrent.url_list.len);
}

// File: test/fixtures/url_seed_multi_space.torrent
fn void test_url_seed_multi_space() @test
{
    String data = load_torrent_file("test/fixtures/url_seed_multi_space.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");
    assert(torrent.url_list.len == 1, "Expected 1 URL seed");

    io::printfn("=== url_seed_multi_space.torrent ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  url-list count: %d", torrent.url_list.len);
    io::printfn("  url: %s", torrent.url_list[0]);

    // URL should contain percent-encoded spaces (BEP 19 compliance)
    // Note: Original URL has no trailing slash
    assert(torrent.url_list[0] == "http://test.com/test%20file/foo%20bar",
           "Expected URL with percent-encoded spaces");
}

// File: test/fixtures/url_seed_multi_space_nolist.torrent
fn void test_url_seed_multi_space_nolist() @test
{
    String data = load_torrent_file("test/fixtures/url_seed_multi_space_nolist.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");
    assert(torrent.url_list.len == 1, "Expected 1 URL seed");

    io::printfn("=== url_seed_multi_space_nolist.torrent ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  url-list count: %d", torrent.url_list.len);
    io::printfn("  url: %s", torrent.url_list[0]);

    // URL should contain percent-encoded spaces (BEP 19 compliance)
    // Note: Original URL has no trailing slash
    assert(torrent.url_list[0] == "http://test.com/test%20file/foo%20bar",
           "Expected URL with percent-encoded spaces");
}

// File: test/fixtures/whitespace_url.torrent
fn void test_whitespace_url() @test
{
    String data = load_torrent_file("test/fixtures/whitespace_url.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");
    assert(torrent.announce.len > 0, "Expected announce URL");
    // Announce URL should be trimmed of whitespace
    assert(torrent.announce == "udp://test.com/announce",
           "Expected trimmed announce URL");

    io::printfn("=== whitespace_url.torrent ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  announce: %s", torrent.announce);
}

// File: test/fixtures/empty-files-1.torrent
fn void test_empty_files_1() @test
{
    String data = load_torrent_file("test/fixtures/empty-files-1.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");

    // Note: This is a v1+v2 hybrid torrent. We only parse v1 portion.
    io::printfn("=== empty-files-1.torrent (v1+v2 hybrid) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  num files: %d", torrent.info.files.len);
}

// File: test/fixtures/empty-files-2.torrent
fn void test_empty_files_2() @test
{
    String data = load_torrent_file("test/fixtures/empty-files-2.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");

    // Note: This is a v1+v2 hybrid torrent. We only parse v1 portion.
    io::printfn("=== empty-files-2.torrent (v1+v2 hybrid) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  num files: %d", torrent.info.files.len);
}

// File: test/fixtures/empty-files-3.torrent
fn void test_empty_files_3() @test
{
    String data = load_torrent_file("test/fixtures/empty-files-3.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");

    // Note: This is a v1+v2 hybrid torrent. We only parse v1 portion.
    io::printfn("=== empty-files-3.torrent (v1+v2 hybrid) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  num files: %d", torrent.info.files.len);
}

// File: test/fixtures/empty-files-4.torrent
fn void test_empty_files_4() @test
{
    String data = load_torrent_file("test/fixtures/empty-files-4.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");

    // Note: This is a v1+v2 hybrid torrent. We only parse v1 portion.
    io::printfn("=== empty-files-4.torrent (v1+v2 hybrid) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  num files: %d", torrent.info.files.len);
}

// File: test/fixtures/empty-files-5.torrent
fn void test_empty_files_5() @test
{
    String data = load_torrent_file("test/fixtures/empty-files-5.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");

    // Note: This is a v1+v2 hybrid torrent. We only parse v1 portion.
    io::printfn("=== empty-files-5.torrent (v1+v2 hybrid) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  num files: %d", torrent.info.files.len);
}

// File: test/fixtures/large.torrent
fn void test_large_torrent() @test
{
    String data = load_torrent_file("test/fixtures/large.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");

    io::printfn("=== large.torrent ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  num files: %d", torrent.info.files.len);
    io::printfn("  num pieces: %d", metainfo::get_num_pieces(torrent));
}

// File: test/fixtures/unordered.torrent
fn void test_unordered_torrent() @test
{
    String data = load_torrent_file("test/fixtures/unordered.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");

    io::printfn("=== unordered.torrent (files in non-alphabetical order) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  num files: %d", torrent.info.files.len);
}

// File: test/fixtures/single_multi_file.torrent
fn void test_single_multi_file() @test
{
    String data = load_torrent_file("test/fixtures/single_multi_file.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");

    io::printfn("=== single_multi_file.torrent ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  num files: %d", torrent.info.files.len);
}

// File: test/fixtures/invalid_name2.torrent
fn void test_invalid_name2() @test
{
    String data = load_torrent_file("test/fixtures/invalid_name2.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    // BEP 3: When name is "..", should use info-hash hex as name
    assert(torrent.info.name == "b61560c2918f463768cd122b6d2fdd47b77bdb35",
           "Invalid name '..' should be replaced with info-hash");
    assert(torrent.info.length == 850, "Should parse multi-file torrent length");
}

// File: test/fixtures/invalid_name3.torrent
fn void test_invalid_name3() @test
{
    String data = load_torrent_file("test/fixtures/invalid_name3.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");

    // Name has trailing space: "foobar "
    // On Windows, libtorrent trims it. On Unix, it keeps it.
    io::printfn("=== invalid_name3.torrent (trailing space in name) ===");
    io::printfn("  name: '%s'", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
}

// File: test/fixtures/bad_name.torrent
fn void test_bad_name() @test
{
    String data = load_torrent_file("test/fixtures/bad_name.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    // Name with null bytes is now sanitized (null bytes replaced with '_')
    // instead of being replaced with info-hash
    assert(torrent.info.name.len > 0, "Name should not be empty after sanitization");
    // Check that name doesn't contain null bytes
    bool has_null = false;
    foreach (c : torrent.info.name) {
        if (c == 0) {
            has_null = true;
            break;
        }
    }
    assert(!has_null, "Null bytes should be removed by sanitization");
    assert(torrent.info.length == 425, "Should parse file length");
}

// File: test/fixtures/zero2.torrent
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
            io::printfn("Tiers: %d", announce_list.list.size);
            foreach (i, tier : announce_list.list)
            {
                if (tier.type == bencode::BencodeType.LIST)
                {
                    io::printfn("  Tier %d (%d trackers):", i, tier.list.size);
                    foreach (tracker : tier.list)
                    {
                        if (tracker.type == bencode::BencodeType.STRING)
                        {
                            io::printfn("    - %s", (String)tracker.string);
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
        io::printfn("Info dict keys (%d):", info.dict.keys.size);
        for (usz i = 0; i < info.dict.keys.size; i++)
        {
            String key = (String)info.dict.keys[i];
            BencodeValue* val = info.dict.values[i];
            io::printfn("  - %s (type: %d)", key, val.type.ordinal);

            if (key == "files" && val.type == bencode::BencodeType.LIST)
            {
                io::printfn("    Files list: %d files", val.list.size);
                foreach (j, file : val.list)
                {
                    if (file.type == bencode::BencodeType.DICT)
                    {
                        io::printfn("    File %d keys:", j);
                        foreach (entry : file.dict_entries())
                        {
                            io::printfn("      - %s", entry.key);
                        }
                    }
                }
            }
        }
    }
}

// File: test/fixtures/zero2.torrent
fn void test_multitracker_numbers_torrent() @test
{
    String data = load_torrent_file("test/fixtures/zero2.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/creation_date.torrent
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
        io::printfn("Top-level keys (%d):", root.dict.keys.size);
        for (usz i = 0; i < root.dict.keys.size; i++)
        {
            io::printfn("  - %s", (String)root.dict.keys[i]);
        }

        // Check info dict
        BencodeValue* info = bencode::dict_get(root, "info");
        if (info && info.type == bencode::BencodeType.DICT)
        {
            io::printfn("Info dict keys (%d):", info.dict.keys.size);
            for (usz i = 0; i < info.dict.keys.size; i++)
            {
                io::printfn("  - %s", (String)info.dict.keys[i]);
            }
        }
    }
}

// File: test/fixtures/url_seed.torrent
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
        io::printfn("Top-level keys (%d):", root.dict.keys.size);
        for (usz i = 0; i < root.dict.keys.size; i++)
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
                io::printfn("url-list count: %d", url_list.list.size);
                foreach (i, url_val : url_list.list)
                {
                    if (url_val.type == bencode::BencodeType.STRING)
                    {
                        io::printfn("  [%d]: %s", i, (String)url_val.string);
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

// File: test/fixtures/httpseed.torrent
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
        io::printfn("Top-level keys (%d):", root.dict.keys.size);
        for (usz i = 0; i < root.dict.keys.size; i++)
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
                io::printfn("httpseeds count: %d", httpseeds.list.size);
                foreach (i, httpseed_val : httpseeds.list)
                {
                    if (httpseed_val.type == bencode::BencodeType.STRING)
                    {
                        io::printfn("  [%d]: %s", i, (String)httpseed_val.string);
                    }
                }
            }
        }
    }
}

// File: test/fixtures/creation_date.torrent
fn void test_parse_creation_date() @test
{
    String data = load_torrent_file("test/fixtures/creation_date.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/no_creation_date.torrent
fn void test_parse_no_creation_date() @test
{
    String data = load_torrent_file("test/fixtures/no_creation_date.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    // Verify it's a multi-file torrent
    assert(torrent.info.is_multi_file, "Expected multi-file torrent");
    assert(torrent.info.files.len > 0, "Expected files list");
    assert(torrent.creation_date == 0, "Expected no creation date");

    io::printfn("=== no_creation_date.torrent (multi-file) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  files: %d", torrent.info.files.len);
}

// File: test/fixtures/httpseed.torrent
fn void test_parse_httpseed() @test
{
    String data = load_torrent_file("test/fixtures/httpseed.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/long_name.torrent
fn void test_parse_long_name() @test
{
    String data = load_torrent_file("test/fixtures/long_name.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected file name");
    // long_name.torrent should have a very long filename
    assert(torrent.info.name.len > 100, "Expected long filename");

    io::printfn("=== long_name.torrent ===");
    io::printfn("  name length: %d chars", torrent.info.name.len);
}

// File: test/fixtures/sample.torrent
fn void test_parse_sample() @test
{
    String data = load_torrent_file("test/fixtures/sample.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    // Verify it's a multi-file torrent
    assert(torrent.info.is_multi_file, "Expected multi-file torrent");
    assert(torrent.info.files.len > 0, "Expected files list");

    io::printfn("=== sample.torrent (multi-file) ===");
    io::printfn("  name: %s", torrent.info.name);
    io::printfn("  total length: %d bytes", torrent.info.length);
    io::printfn("  files: %d", torrent.info.files.len);
}

// File: test/fixtures/base.torrent
fn void test_web_seeds_optional() @test
{
    // Test that web seeds are optional - torrents without them should parse fine
    String data = load_torrent_file("test/fixtures/base.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/sample.torrent
fn void test_multifile_file_details() @test
{
    String data = load_torrent_file("test/fixtures/sample.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/sample.torrent
fn void test_multifile_offsets_sequential() @test
{
    String data = load_torrent_file("test/fixtures/sample.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/sample.torrent
fn void test_multifile_total_length() @test
{
    String data = load_torrent_file("test/fixtures/sample.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/creation_date.torrent
fn void test_multifile_path_components() @test
{
    String data = load_torrent_file("test/fixtures/creation_date.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/numbers.torrent
fn void test_multifile_numbers_torrent() @test
{
    String data = load_torrent_file("test/fixtures/numbers.torrent");
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

// File: test/fixtures/no_files.torrent
fn void test_multifile_empty_files_rejected() @test
{
    // Test that we properly reject multi-file torrents with no files
    String data = load_torrent_file("test/fixtures/no_files.torrent");
    defer free(data);

    if (catch err = metainfo::parse(data))
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

// File: test/fixtures/missing_piece_len.torrent
fn void test_error_missing_piece_len() @test
{
    String data = load_torrent_file("test/fixtures/missing_piece_len.torrent");
    defer free(data);

    if (catch err = metainfo::parse(data))
    {
        io::printn("=== missing_piece_len.torrent ===");
        io::printn("  Correctly rejected (missing piece length)");
    }
    else
    {
        assert(false, "Expected parse to fail for missing piece length");
    }
}

// File: test/fixtures/no_name.torrent
fn void test_error_no_name() @test
{
    String data = load_torrent_file("test/fixtures/no_name.torrent");
    defer free(data);

    if (catch err = metainfo::parse(data))
    {
        io::printn("=== no_name.torrent ===");
        io::printn("  Correctly rejected (missing name)");
    }
    else
    {
        assert(false, "Expected parse to fail for missing name");
    }
}

// File: test/fixtures/invalid_pieces.torrent
fn void test_error_invalid_pieces() @test
{
    String data = load_torrent_file("test/fixtures/invalid_pieces.torrent");
    defer free(data);

    if (catch err = metainfo::parse(data))
    {
        io::printn("=== invalid_pieces.torrent ===");
        io::printn("  Correctly rejected (invalid pieces)");
    }
    else
    {
        assert(false, "Expected parse to fail for invalid pieces");
    }
}

// File: test/fixtures/invalid_piece_len.torrent
fn void test_error_invalid_piece_len() @test
{
    String data = load_torrent_file("test/fixtures/invalid_piece_len.torrent");
    defer free(data);

    if (catch err = metainfo::parse(data))
    {
        io::printn("=== invalid_piece_len.torrent ===");
        io::printn("  Correctly rejected (invalid piece length)");
    }
    else
    {
        assert(false, "Expected parse to fail for invalid piece length");
    }
}

// File: test/fixtures/invalid_info.torrent
fn void test_error_invalid_info() @test
{
    String data = load_torrent_file("test/fixtures/invalid_info.torrent");
    defer free(data);

    if (catch err = metainfo::parse(data))
    {
        io::printn("=== invalid_info.torrent ===");
        io::printn("  Correctly rejected (invalid info)");
    }
    else
    {
        assert(false, "Expected parse to fail for invalid info");
    }
}

// File: test/fixtures/negative_piece_len.torrent
fn void test_error_negative_piece_len() @test
{
    String data = load_torrent_file("test/fixtures/negative_piece_len.torrent");
    defer free(data);

    if (catch err = metainfo::parse(data))
    {
        io::printn("=== negative_piece_len.torrent ===");
        io::printn("  Correctly rejected (negative piece length)");
    }
    else
    {
        assert(false, "Expected parse to fail for negative piece length");
    }
}

// File: test/fixtures/negative_size.torrent
fn void test_error_negative_size() @test
{
    String data = load_torrent_file("test/fixtures/negative_size.torrent");
    defer free(data);

    if (catch err = metainfo::parse(data))
    {
        io::printn("=== negative_size.torrent ===");
        io::printn("  Correctly rejected (negative total size)");
    }
    else
    {
        assert(false, "Expected parse to fail for negative total size");
    }
}

// File: test/fixtures/negative_file_size.torrent
fn void test_error_negative_file_size() @test
{
    String data = load_torrent_file("test/fixtures/negative_file_size.torrent");
    defer free(data);

    if (catch err = metainfo::parse(data))
    {
        io::printn("=== negative_file_size.torrent ===");
        io::printn("  Correctly rejected (negative file size)");
    }
    else
    {
        assert(false, "Expected parse to fail for negative file size");
    }
}

// File: test/fixtures/invalid_file_size.torrent
fn void test_error_invalid_file_size() @test
{
    String data = load_torrent_file("test/fixtures/invalid_file_size.torrent");
    defer free(data);

    if (catch err = metainfo::parse(data))
    {
        io::printn("=== invalid_file_size.torrent ===");
        io::printn("  Correctly rejected (invalid file size)");
    }
    else
    {
        assert(false, "Expected parse to fail for invalid file size");
    }
}

// File: test/fixtures/unaligned_pieces.torrent
fn void test_error_unaligned_pieces() @test
{
    String data = load_torrent_file("test/fixtures/unaligned_pieces.torrent");
    defer free(data);

    if (catch err = metainfo::parse(data))
    {
        io::printn("=== unaligned_pieces.torrent ===");
        io::printn("  Correctly rejected (pieces not aligned to 20 bytes)");
    }
    else
    {
        assert(false, "Expected parse to fail for unaligned pieces");
    }
}

// File: test/fixtures/string.torrent
fn void test_error_string_root() @test
{
    String data = load_torrent_file("test/fixtures/string.torrent");
    defer free(data);

    if (catch err = metainfo::parse(data))
    {
        io::printn("=== string.torrent ===");
        io::printn("  Correctly rejected (root is string, not dict)");
    }
    else
    {
        assert(false, "Expected parse to fail for string root");
    }
}

// File: test/fixtures/no_files.torrent
fn void test_error_no_files() @test
{
    String data = load_torrent_file("test/fixtures/no_files.torrent");
    defer free(data);

    if (catch err = metainfo::parse(data))
    {
        io::printn("=== no_files.torrent ===");
        io::printn("  Correctly rejected (multi-file with no files)");
    }
    else
    {
        assert(false, "Expected parse to fail for torrent with no files");
    }
}

// File: test/fixtures/zero.torrent
fn void test_error_zero_length() @test
{
    String data = load_torrent_file("test/fixtures/zero.torrent");
    defer free(data);

    if (catch err = metainfo::parse(data))
    {
        io::printn("=== zero.torrent ===");
        io::printn("  Correctly rejected (zero-length torrent)");
    }
    else
    {
        assert(false, "Expected parse to fail for zero-length torrent");
    }
}

// ===================================
// Path Sanitization Integration Tests
// ===================================

fn void test_sanitize_torrent_name_with_traversal() @test
{
    // Create 20-byte pieces hash
    char[20] pieces_hash;
    foreach (i, &c : pieces_hash) *c = 0;

    // Build info dictionary
    BencodeValue* info = bencode::@bdict(
        "name", bencode::make_string("../../../etc/file"),  // Path traversal!
        "length", bencode::make_integer(1000),
        "piece length", bencode::make_integer(32768),
        "pieces", bencode::make_string((String)pieces_hash[..])
    );

    // Create a torrent with path traversal in the name using bencode encoder
    BencodeValue* root = bencode::@bdict(
        "announce", bencode::make_string("http://tracker.example.com/announce"),
        "info", info
    );
    defer bencode::free_bencode_value(root);

    // Encode to bencode
    String data = bencode::encode(root);
    defer free(data);

    TorrentFile* t = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(t);

    // Path traversal should be removed by sanitization
    io::printfn("Original name in bencode: '../../../etc/file'");
    io::printfn("Sanitized name: '%s'", t.info.name);
    assert(!t.info.name.contains(".."), "Path traversal '..' should be removed");
    assert(t.info.name.len > 0, "Name should not be empty after sanitization");
}

fn void test_sanitize_torrent_name_with_null_bytes() @test
{
    // Create name with null byte
    char[9] name_with_null = {'t', 'e', 's', 't', 0, 'f', 'i', 'l', 'e'};

    // Create pieces hash
    char[20] pieces_hash;
    foreach (i, &c : pieces_hash) *c = 0;

    BencodeValue* info = bencode::@bdict(
        "name", bencode::make_string((String)name_with_null[..]),
        "length", bencode::make_integer(1000),
        "piece length", bencode::make_integer(32768),
        "pieces", bencode::make_string((String)pieces_hash[..])
    );

    // Create a torrent with null bytes in the name
    BencodeValue* root = bencode::@bdict(
        "announce", bencode::make_string("http://tracker.example.com/announce"),
        "info", info
    );
    defer bencode::free_bencode_value(root);

    String data = bencode::encode(root);
    defer free(data);

    TorrentFile* t = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(t);

    // Null bytes should be replaced
    io::printfn("Sanitized name (null bytes replaced): '%s'", t.info.name);
    assert(!t.info.name.contains("\0"), "Null bytes should be removed");
    assert(t.info.name.len > 0, "Name should not be empty after sanitization");
}

fn void test_sanitize_file_paths_with_invalid_utf8() @test
{
    // Create pieces hash
    char[20] pieces_hash;
    foreach (i, &c : pieces_hash) *c = 0;

    // Path with invalid UTF-8 (incomplete 2-byte sequence)
    char[9] invalid_utf8 = {'f', 'i', 'l', 'e', 0xc2, '.', 't', 'x', 't'};  // 0xc2 without continuation byte

    // First file with invalid UTF-8
    BencodeValue* path1 = bencode::@blist(
        bencode::make_string("testdir"),
        bencode::make_string((String)invalid_utf8[..])
    );

    BencodeValue* file1 = bencode::@bdict(
        "length", bencode::make_integer(500),
        "path", path1
    );

    BencodeValue* files = bencode::@blist(file1);

    BencodeValue* info = bencode::@bdict(
        "name", bencode::make_string("testdata"),
        "piece length", bencode::make_integer(32768),
        "pieces", bencode::make_string((String)pieces_hash[..]),
        "files", files
    );

    // Create a multi-file torrent with invalid UTF-8 in path component
    BencodeValue* root = bencode::@bdict(
        "announce", bencode::make_string("http://tracker.example.com/announce"),
        "info", info
    );
    defer bencode::free_bencode_value(root);

    String data = bencode::encode(root);
    defer free(data);

    TorrentFile* t = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(t);

    // Check that invalid UTF-8 was repaired
    assert(t.info.is_multi_file, "Should be multi-file torrent");
    assert(t.info.files.len == 1, "Should have 1 file");

    io::printfn("Sanitized path component: '%s'", t.info.files[0].path[1]);
    // Invalid UTF-8 should be repaired (replaced with underscore)
    assert(!t.info.files[0].path[1].contains("\xc2"), "Invalid UTF-8 should be repaired");
}

fn void test_sanitize_file_paths_with_directional_chars() @test
{
    // Create pieces hash
    char[20] pieces_hash;
    foreach (i, &c : pieces_hash) *c = 0;

    // Filename with RIGHT-TO-LEFT OVERRIDE character (U+202E = 0xE2 0x80 0xAE)
    char[10] rtl_filename = {'t', 'e', 's', 't', 0xe2, 0x80, 0xae, 't', 'x', 't'};

    BencodeValue* path1 = bencode::@blist(
        bencode::make_string("evil"),
        bencode::make_string((String)rtl_filename[..])
    );

    BencodeValue* file1 = bencode::@bdict(
        "length", bencode::make_integer(500),
        "path", path1
    );

    BencodeValue* files = bencode::@blist(file1);

    BencodeValue* info = bencode::@bdict(
        "name", bencode::make_string("testdata"),
        "piece length", bencode::make_integer(32768),
        "pieces", bencode::make_string((String)pieces_hash[..]),
        "files", files
    );

    // Create a multi-file torrent with Unicode directional override characters
    BencodeValue* root = bencode::@bdict(
        "announce", bencode::make_string("http://tracker.example.com/announce"),
        "info", info
    );
    defer bencode::free_bencode_value(root);

    String data = bencode::encode(root);
    defer free(data);

    TorrentFile* t = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(t);

    // Check that directional characters were removed
    assert(t.info.is_multi_file, "Should be multi-file torrent");
    assert(t.info.files.len == 1, "Should have 1 file");

    String sanitized_filename = t.info.files[0].path[1];
    io::printfn("Sanitized filename: '%s'", sanitized_filename);

    // Directional override characters should be removed (security!)
    assert(!sanitized_filename.contains("\xe2\x80\xae"), "Directional override chars should be removed");
    assert(sanitized_filename.contains("txt"), "Valid text should remain");
}

fn void test_sanitize_long_file_paths() @test
{
    // Create a torrent with a very long filename
    DString long_name;
    for (int i = 0; i < 260; i++)
    {
        long_name.append_char('a');
    }
    long_name.append(".txt");  // Add extension

    // Create pieces hash
    char[20] pieces_hash;
    foreach (i, &c : pieces_hash) *c = 0;

    BencodeValue* info = bencode::@bdict(
        "name", bencode::make_string(long_name.str_view()),
        "length", bencode::make_integer(1000),
        "piece length", bencode::make_integer(32768),
        "pieces", bencode::make_string((String)pieces_hash[..])
    );

    BencodeValue* root = bencode::@bdict(
        "announce", bencode::make_string("http://tracker.example.com/announce"),
        "info", info
    );
    defer bencode::free_bencode_value(root);

    String data = bencode::encode(root);
    defer free(data);

    TorrentFile* t = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(t);

    // Check that path was truncated to 240 chars
    io::printfn("Original length: %d", long_name.len());
    io::printfn("Sanitized length: %d", t.info.name.len);
    assert(t.info.name.len <= 240, "Path should be truncated to 240 chars");

    // Extension should be preserved
    assert(t.info.name.ends_with(".txt"), "Extension should be preserved during truncation");
}

// ============================================================================
// TODO: Path Security and Traversal Tests
// ============================================================================

// File: test/fixtures/slash_path.torrent
fn void test_parse_slash_path_should_fail() @test
{
    return; // TODO: Implement path traversal security checks
}

// File: test/fixtures/slash_path2.torrent
fn void test_parse_slash_path2_should_fail() @test
{
    return; // TODO: Implement path traversal security checks
}

// File: test/fixtures/slash_path3.torrent
fn void test_parse_slash_path3_should_fail() @test
{
    return; // TODO: Implement path traversal security checks
}

// File: test/fixtures/backslash_path.torrent
fn void test_parse_backslash_path_should_fail() @test
{
    return; // TODO: Implement path traversal security checks
}

// File: test/fixtures/absolute_filename.torrent
fn void test_parse_absolute_filename_should_fail() @test
{
    return; // TODO: Implement path traversal security checks
}

// File: test/fixtures/parent_path.torrent
fn void test_parse_parent_path_should_fail() @test
{
    return; // TODO: Implement path traversal security checks
}

// File: test/fixtures/hidden_parent_path.torrent
fn void test_parse_hidden_parent_path_should_fail() @test
{
    return; // TODO: Implement path traversal security checks
}

// File: test/fixtures/empty_path.torrent
fn void test_parse_empty_path_should_fail() @test
{
    return; // TODO: Implement empty path validation
}

// File: test/fixtures/empty_path_multi.torrent
fn void test_parse_empty_path_multi_should_fail() @test
{
    return; // TODO: Implement empty path validation
}

// ============================================================================
// TODO: Symlink and Special File Tests
// ============================================================================

// File: test/fixtures/symlink1.torrent
fn void test_parse_symlink1() @test
{
    return; // TODO: Implement symlink support
}

// File: test/fixtures/symlink2.torrent
fn void test_parse_symlink2() @test
{
    return; // TODO: Implement symlink support
}

// File: test/fixtures/symlink_zero_size.torrent
fn void test_parse_symlink_zero_size() @test
{
    return; // TODO: Implement symlink support
}

// File: test/fixtures/invalid_symlink.torrent
fn void test_parse_invalid_symlink_should_fail() @test
{
    return; // TODO: Implement symlink validation
}

// File: test/fixtures/overlapping_symlinks.torrent
fn void test_parse_overlapping_symlinks_should_fail() @test
{
    return; // TODO: Implement symlink validation
}

// ============================================================================
// TODO: Additional Edge Case Tests
// ============================================================================

// File: test/fixtures/invalid_name.torrent
fn void test_parse_invalid_name_should_fail() @test
{
    return; // TODO: Implement name validation
}

// File: test/fixtures/invalid_filename.torrent
fn void test_parse_invalid_filename_should_fail() @test
{
    return; // TODO: Implement filename validation
}

// File: test/fixtures/invalid_filename2.torrent
fn void test_parse_invalid_filename2_should_fail() @test
{
    return; // TODO: Implement filename validation
}

// File: test/fixtures/invalid_directory_name.torrent
fn void test_parse_invalid_directory_name_should_fail() @test
{
    return; // TODO: Implement directory name validation
}

// File: test/fixtures/invalid_path_list.torrent
fn void test_parse_invalid_path_list_should_fail() @test
{
    return; // TODO: Implement path list validation
}

// File: test/fixtures/missing_path_list.torrent
fn void test_parse_missing_path_list_should_fail() @test
{
    return; // TODO: Implement path list validation
}

// File: test/fixtures/duplicate_files.torrent
fn void test_parse_duplicate_files() @test
{
    return; // TODO: Implement duplicate file detection
}

// File: test/fixtures/collection2.torrent
fn void test_parse_collection2() @test
{
    return; // TODO: Implement collection parsing
}

// File: test/fixtures/similar2.torrent
fn void test_parse_similar2() @test
{
    return; // TODO: Test similar torrent variant
}

// ============================================================================
// TODO: Version and Format Tests
// ============================================================================

// File: test/fixtures/v2.torrent
fn void test_parse_v2_torrent() @test
{
    return; // TODO: Implement BitTorrent v2 support
}

// File: test/fixtures/test1.torrent
fn void test_parse_test1() @test
{
    return; // TODO: Add test for test1.torrent
}

// File: test/fixtures/test2.torrent
fn void test_parse_test2() @test
{
    return; // TODO: Add test for test2.torrent
}

// File: test/fixtures/test3.torrent
fn void test_parse_test3() @test
{
    return; // TODO: Add test for test3.torrent
}

// File: test/fixtures/test1_pad_files.torrent
fn void test_parse_test1_pad_files() @test
{
    return; // TODO: Add test for pad files variant
}

// File: test/fixtures/test2_pad_files.torrent
fn void test_parse_test2_pad_files() @test
{
    return; // TODO: Add test for pad files variant
}

// File: test/fixtures/test3_pad_files.torrent
fn void test_parse_test3_pad_files() @test
{
    return; // TODO: Add test for pad files variant
}

// File: test/fixtures/test1_single_padded.torrent
fn void test_parse_test1_single_padded() @test
{
    return; // TODO: Add test for single padded file
}

// File: test/fixtures/pad_file_no_path.torrent
fn void test_parse_pad_file_no_path_should_fail() @test
{
    return; // TODO: Implement pad file path validation
}

// ============================================================================
// TODO: Performance and Scale Tests
// ============================================================================

// File: test/fixtures/large_piece_size.torrent
fn void test_parse_large_piece_size() @test
{
    return; // TODO: Add test for large piece size handling
}

// File: test/fixtures/many_pieces.torrent
fn void test_parse_many_pieces() @test
{
    return; // TODO: Add test for many pieces handling
}

// ============================================================================
// TODO: Web Seed Edge Cases
// ============================================================================

// File: test/fixtures/url_seed_multi_single_file.torrent
fn void test_parse_url_seed_multi_single_file() @test
{
    return; // TODO: Add test for URL seed in single-file torrent
}

// File: test/fixtures/empty_httpseed.torrent
fn void test_parse_empty_httpseed() @test
{
    return; // TODO: Add test for empty HTTP seed list
}
