module test_bencode_v2_compat;

import std::io;
import std::hash::sha256;
import libtorrent::bencode;

/**
 * Test Suite: Bencode v2 Compatibility
 * =====================================
 * Verifies that the bencode module can handle BEP 52 v2 metadata requirements:
 * 1. 32-byte binary strings (Merkle roots / SHA-256 hashes)
 * 2. Nested dictionaries (hierarchical file tree)
 * 3. Large concatenated byte strings (piece layers)
 */

/**
 * Test 1: Encode and decode 32-byte binary string (Merkle root)
 */
fn void test_bencode_32byte_binary_string() @test
{
    // Create 32-byte hash (simulating a Merkle root)
    char[32] merkle_root;
    for (uint i = 0; i < 32; i++) {
        merkle_root[i] = (char)i;  // Pattern: 0, 1, 2, ..., 31
    }

    // Create bencode string value
    BencodeValue* val = bencode::make_string((String)merkle_root[..]);
    defer val.free();

    // Encode to bencode format
    String encoded = val.encode();
    defer free(encoded);

    // Verify encoding: should be "32:<32 bytes of data>"
    assert(encoded.len == 35, "Expected 35 bytes (3 + ':' + 32), got %d", encoded.len);
    assert(encoded[0] == '3', "First char should be '3'");
    assert(encoded[1] == '2', "Second char should be '2'");
    assert(encoded[2] == ':', "Third char should be ':'");

    // Decode back
    BencodeValue* decoded = bencode::decode(encoded)!!;
    defer decoded.free();

    // Verify decoded value
    assert(decoded.type == BencodeType.STRING, "Should be STRING type");
    assert(decoded.string.len == 32, "Should be 32 bytes");

    // Verify content matches
    for (uint i = 0; i < 32; i++) {
        assert(decoded.string[i] == (char)i, "Byte mismatch at index %d", i);
    }
}

/**
 * Test 2: Nested dictionaries (file tree structure)
 * Simulates: {"dir": {"file.txt": {"": {"length": 1024, "pieces root": <32 bytes>}}}}
 */
fn void test_bencode_nested_dictionaries() @test
{
    // Create Merkle root
    char[32] merkle_root;
    for (uint i = 0; i < 32; i++) {
        merkle_root[i] = (char)(i * 2);
    }

    // Build nested structure bottom-up
    // Inner dict: {"length": 1024, "pieces root": <hash>}
    BencodeValue* file_props = bencode::make_dict();
    file_props.dict_set("length", bencode::make_integer(1024));
    file_props.dict_set("pieces root", bencode::make_string((String)merkle_root[..]));

    // Level 2: {"": <file_props>}
    BencodeValue* file_dict = bencode::make_dict();
    file_dict.dict_set("", file_props);  // Takes ownership of file_props

    // Level 1: {"file.txt": <file_dict>}
    BencodeValue* dir_dict = bencode::make_dict();
    dir_dict.dict_set("file.txt", file_dict);  // Takes ownership of file_dict

    // Top level: {"dir": <dir_dict>}
    BencodeValue* root = bencode::make_dict();
    defer root.free();  // Only free root - it owns all children
    root.dict_set("dir", dir_dict);  // Takes ownership of dir_dict

    // Encode
    String encoded = root.encode();
    defer free(encoded);

    // Decode back
    BencodeValue* decoded = bencode::decode(encoded)!!;
    defer decoded.free();

    // Navigate down the structure
    assert(decoded.type == BencodeType.DICT, "Root should be dict");

    BencodeValue* dir = decoded.dict_get("dir");
    assert(dir != null, "Should have 'dir' key");
    assert(dir.type == BencodeType.DICT, "dir should be dict");

    BencodeValue* file = dir.dict_get("file.txt");
    assert(file != null, "Should have 'file.txt' key");
    assert(file.type == BencodeType.DICT, "file.txt should be dict");

    BencodeValue* props = file.dict_get("");
    assert(props != null, "Should have empty string key");
    assert(props.type == BencodeType.DICT, "Props should be dict");

    BencodeValue* length = props.dict_get("length");
    assert(length != null, "Should have 'length' key");
    assert(length.type == BencodeType.INTEGER, "length should be integer");
    assert(length.integer == 1024, "length should be 1024");

    BencodeValue* root_hash = props.dict_get("pieces root");
    assert(root_hash != null, "Should have 'pieces root' key");
    assert(root_hash.type == BencodeType.STRING, "pieces root should be string");
    assert(root_hash.string.len == 32, "pieces root should be 32 bytes");

    // Verify hash content
    for (uint i = 0; i < 32; i++) {
        assert(root_hash.string[i] == (char)(i * 2), "Hash byte mismatch at %d", i);
    }
}

/**
 * Test 3: Large concatenated byte string (piece layers)
 * Simulates piece layers: multiple 32-byte hashes concatenated
 */
fn void test_bencode_large_concatenated_bytes() @test
{
    // Create 100 concatenated 32-byte hashes (3200 bytes total)
    const uint NUM_HASHES = 100;
    const uint HASH_SIZE = 32;
    const uint TOTAL_SIZE = NUM_HASHES * HASH_SIZE;

    char[] piece_layers = mem::new_array(char, TOTAL_SIZE);
    defer free(piece_layers);

    // Fill with pattern
    for (uint i = 0; i < NUM_HASHES; i++) {
        for (uint j = 0; j < HASH_SIZE; j++) {
            piece_layers[i * HASH_SIZE + j] = (char)((i + j) % 256);
        }
    }

    // Create bencode value
    BencodeValue* val = bencode::make_string((String)piece_layers);
    defer val.free();

    // Encode
    String encoded = val.encode();
    defer free(encoded);

    // Verify encoding starts with "3200:"
    assert(encoded[0] == '3', "First char should be '3'");
    assert(encoded[1] == '2', "Second char should be '2'");
    assert(encoded[2] == '0', "Third char should be '0'");
    assert(encoded[3] == '0', "Fourth char should be '0'");
    assert(encoded[4] == ':', "Fifth char should be ':'");

    // Decode back
    BencodeValue* decoded = bencode::decode(encoded)!!;
    defer decoded.free();

    // Verify
    assert(decoded.type == BencodeType.STRING, "Should be STRING");
    assert(decoded.string.len == TOTAL_SIZE, "Should be 3200 bytes");

    // Verify all bytes match
    for (uint i = 0; i < TOTAL_SIZE; i++) {
        uint hash_idx = i / HASH_SIZE;
        uint byte_idx = i % HASH_SIZE;
        char expected = (char)((hash_idx + byte_idx) % 256);
        assert(decoded.string[i] == expected, "Byte mismatch at %d", i);
    }
}

/**
 * Test 4: SHA-256 hash as bencode string (real-world scenario)
 */
fn void test_bencode_real_sha256_hash() @test
{
    // Create real SHA-256 hash of some data
    char[1024] data;
    for (uint i = 0; i < 1024; i++) {
        data[i] = (char)(i % 256);
    }

    char[32] hash = sha256::hash(data[..]);

    // Encode hash as bencode string
    BencodeValue* val = bencode::make_string((String)hash[..]);
    defer val.free();

    String encoded = val.encode();
    defer free(encoded);

    // Decode
    BencodeValue* decoded = bencode::decode(encoded)!!;
    defer decoded.free();

    // Verify
    assert(decoded.type == BencodeType.STRING, "Should be STRING");
    assert(decoded.string.len == 32, "Should be 32 bytes");

    // Verify hash matches
    for (uint i = 0; i < 32; i++) {
        assert(decoded.string[i] == hash[i], "Hash byte mismatch at %d", i);
    }
}

/**
 * Test 5: v2 piece layers dictionary
 * Simulates: {"file1.txt": <hashes>, "dir/file2.txt": <hashes>}
 */
fn void test_bencode_piece_layers_dict() @test
{
    // Create piece layers for file1 (4 hashes)
    char[] file1_layers = mem::new_array(char, 4 * 32);
    defer free(file1_layers);
    for (uint i = 0; i < 128; i++) {
        file1_layers[i] = (char)i;
    }

    // Create piece layers for file2 (8 hashes)
    char[] file2_layers = mem::new_array(char, 8 * 32);
    defer free(file2_layers);
    for (uint i = 0; i < 256; i++) {
        file2_layers[i] = (char)(255 - i);
    }

    // Build dictionary
    BencodeValue* piece_layers = bencode::make_dict();
    defer piece_layers.free();  // Only free root - it owns the string values

    piece_layers.dict_set("file1.txt", bencode::make_string((String)file1_layers));  // Takes ownership
    piece_layers.dict_set("dir/file2.txt", bencode::make_string((String)file2_layers));  // Takes ownership

    // Encode
    String encoded = piece_layers.encode();
    defer free(encoded);

    // Decode
    BencodeValue* decoded = bencode::decode(encoded)!!;
    defer decoded.free();

    // Verify structure
    assert(decoded.type == BencodeType.DICT, "Should be dict");

    BencodeValue* file1 = decoded.dict_get("file1.txt");
    assert(file1 != null, "Should have file1.txt");
    assert(file1.type == BencodeType.STRING, "file1 should be string");
    assert(file1.string.len == 128, "file1 should be 128 bytes (4 hashes)");

    BencodeValue* file2 = decoded.dict_get("dir/file2.txt");
    assert(file2 != null, "Should have dir/file2.txt");
    assert(file2.type == BencodeType.STRING, "file2 should be string");
    assert(file2.string.len == 256, "file2 should be 256 bytes (8 hashes)");

    // Verify content
    for (uint i = 0; i < 128; i++) {
        assert(file1.string[i] == (char)i, "file1 byte mismatch at %d", i);
    }
    for (uint i = 0; i < 256; i++) {
        assert(file2.string[i] == (char)(255 - i), "file2 byte mismatch at %d", i);
    }
}
