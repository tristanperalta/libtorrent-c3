module test_parse_v2_torrent;

import std::io;
import std::io::file;
import libtorrent::bencode;

/**
 * Test Suite: Parse Real BitTorrent v2 Torrent
 * ============================================
 * Verify that we can parse the v2.torrent fixture file and extract:
 * 1. Meta version field (should be 2)
 * 2. File tree structure (v2 hierarchical format)
 * 3. Pieces root (32-byte SHA-256 Merkle root)
 * 4. Piece layers dictionary
 * 5. Traditional pieces field (v1 backward compatibility)
 */

fn void test_parse_v2_torrent_file() @test
{
    // Load the v2.torrent fixture file
    char[] temp_buffer = file::load_temp("test/fixtures/v2.torrent")!!;
    char[] data = mem::new_array(char, temp_buffer.len);
    defer free(data);
    foreach (i, c : temp_buffer)
    {
        data[i] = c;
    }

    io::printfn("Read %d bytes from v2.torrent", data.len);

    // Parse the bencode data
    BencodeValue* root = bencode::decode((String)data)!!;
    defer root.free();

    // Verify it's a dictionary
    assert(root.type == BencodeType.DICT, "Root should be a dictionary");

    // Extract the info dictionary
    BencodeValue* info = root.dict_get("info");
    assert(info != null, "Should have 'info' key");
    assert(info.type == BencodeType.DICT, "info should be a dictionary");

    // Test 1: Verify meta version = 2
    BencodeValue* meta_version = info.dict_get("meta version");
    assert(meta_version != null, "Should have 'meta version' key");
    assert(meta_version.type == BencodeType.INTEGER, "meta version should be integer");
    assert(meta_version.integer == 2, "meta version should be 2, got %lld", meta_version.integer);
    io::printfn("✓ Meta version = 2");

    // Test 2: Verify file tree exists
    BencodeValue* file_tree = info.dict_get("file tree");
    assert(file_tree != null, "Should have 'file tree' key");
    assert(file_tree.type == BencodeType.DICT, "file tree should be a dictionary");
    io::printfn("✓ File tree structure present");

    // Test 3: Verify traditional pieces field (v1 compatibility)
    BencodeValue* pieces = info.dict_get("pieces");
    assert(pieces != null, "Should have 'pieces' key (v1 compatibility)");
    assert(pieces.type == BencodeType.STRING, "pieces should be a string");
    assert(pieces.string.len == 20, "v1 pieces should be 20 bytes (SHA-1), got %d", pieces.string.len);
    io::printfn("✓ v1 pieces field present (20-byte SHA-1)");

    // Test 4: Verify piece layers dictionary
    BencodeValue* piece_layers = root.dict_get("piece layers");
    assert(piece_layers != null, "Should have 'piece layers' key");
    assert(piece_layers.type == BencodeType.DICT, "piece layers should be a dictionary");
    io::printfn("✓ Piece layers dictionary present");

    // Test 5: Navigate into file tree and verify structure
    // The v2.torrent has structure: {"test64K": {"": {...}}}
    BencodeValue* test64k = file_tree.dict_get("test64K");
    assert(test64k != null, "Should have 'test64K' entry in file tree");
    assert(test64k.type == BencodeType.DICT, "File entry should be a dictionary");

    BencodeValue* file_props = test64k.dict_get("");
    assert(file_props != null, "Should have empty string key for file properties");
    assert(file_props.type == BencodeType.DICT, "File properties should be a dictionary");

    // Test 6: Verify file has pieces root (32-byte SHA-256)
    BencodeValue* pieces_root = file_props.dict_get("pieces root");
    assert(pieces_root != null, "Should have 'pieces root' key");
    assert(pieces_root.type == BencodeType.STRING, "pieces root should be a string");
    assert(pieces_root.string.len == 32, "pieces root should be 32 bytes (SHA-256), got %d", pieces_root.string.len);
    io::printfn("✓ Pieces root present (32-byte SHA-256)");

    // Test 7: Verify file has length
    BencodeValue* length = file_props.dict_get("length");
    assert(length != null, "Should have 'length' key");
    assert(length.type == BencodeType.INTEGER, "length should be integer");
    assert(length.integer == 65536, "File length should be 65536 bytes, got %lld", length.integer);
    io::printfn("✓ File length = 65536 bytes");

    io::printfn("\n✅ Successfully parsed v2.torrent hybrid torrent file!");
}
