module test_peer_wire_v2;

import std::io;
import libtorrent::peer_wire;
import libtorrent::common;

/**
 * Test Suite: BEP 52 v2 Protocol Messages
 * ========================================
 * Tests for BitTorrent v2 network protocol messages:
 * - Message 21: HASH_REQUEST (request Merkle hashes)
 * - Message 22: HASHES (Merkle hash response)
 * - Message 23: HASH_REJECT (reject hash request)
 * - Handshake v2 bit detection (reserved bit 4)
 */

/**
 * Test 1: Handshake v2 bit detection
 */
fn void test_handshake_supports_v2() @test
{
    // Create handshake with v2 bit set (byte 7, bit 0x08)
    peer_wire::HandshakeMsg handshake;

    // Clear reserved bytes
    for (usz i = 0; i < 8; i++)
    {
        handshake.reserved[i] = 0;
    }

    // Test 1: No v2 bit set
    assert(!peer_wire::handshake_supports_v2(&handshake), "Should not support v2 without bit");

    // Test 2: Set v2 bit (byte 7, bit 4 = 0x08)
    handshake.reserved[7] = 0x08;
    assert(peer_wire::handshake_supports_v2(&handshake), "Should support v2 with bit set");

    // Test 3: v2 bit + other bits
    handshake.reserved[7] = 0x0C;  // Fast (0x04) + v2 (0x08)
    assert(peer_wire::handshake_supports_v2(&handshake), "Should support v2 with multiple bits");

    // Test 4: Other bits only (no v2)
    handshake.reserved[7] = 0x04;  // Fast only
    assert(!peer_wire::handshake_supports_v2(&handshake), "Should not support v2 with only Fast bit");

    io::printfn("✓ Handshake v2 bit detection working");
}

/**
 * Test 2: Encode/decode HASH_REQUEST message
 */
fn void test_encode_decode_hash_request() @test
{
    // Create test pieces_root (32-byte SHA-256 hash)
    common::InfoHashV2 pieces_root;
    for (usz i = 0; i < common::SHA256_HASH_SIZE; i++)
    {
        pieces_root[i] = (char)i;
    }

    // Create HASH_REQUEST message
    peer_wire::HashRequestMsg request;
    foreach (i, byte : pieces_root)
    {
        request.pieces_root[i] = byte;
    }
    request.base_layer = 4;
    request.index = 0;
    request.length = 16;
    request.proof_layers = 6;

    // Encode
    char[] encoded = peer_wire::encode_hash_request(&request);
    defer free(encoded);

    // Verify wire format
    assert(encoded.len == 4 + 1 + 32 + 4 + 4 + 4 + 4, "HASH_REQUEST should be 53 bytes");

    // Verify length field (49 = 1 + 32 + 4 + 4 + 4 + 4)
    uint length = peer_wire::read_u32_be(encoded, 0);
    assert(length == 49, "Length field should be 49");

    // Verify message ID
    assert(encoded[4] == (char)peer_wire::MessageType.HASH_REQUEST, "Message ID should be 21");

    // Decode (skip length and ID, pass payload only)
    peer_wire::HashRequestMsg? decoded_opt = peer_wire::decode_hash_request(encoded[5..]);
    assert(@ok(decoded_opt), "Should decode HASH_REQUEST successfully");

    peer_wire::HashRequestMsg decoded = decoded_opt!!;

    // Verify decoded values
    assert(decoded.base_layer == 4, "base_layer should be 4");
    assert(decoded.index == 0, "index should be 0");
    assert(decoded.length == 16, "length should be 16");
    assert(decoded.proof_layers == 6, "proof_layers should be 6");

    // Verify pieces_root
    foreach (i, byte : decoded.pieces_root)
    {
        assert(byte == (char)i, "pieces_root[%d] should match", i);
    }

    io::printfn("✓ HASH_REQUEST encode/decode working");
}

/**
 * Test 3: Encode/decode HASHES message
 */
fn void test_encode_decode_hashes() @test
{
    // Create test pieces_root
    common::InfoHashV2 pieces_root;
    for (usz i = 0; i < common::SHA256_HASH_SIZE; i++)
    {
        pieces_root[i] = (char)(i + 1);
    }

    // Create test hashes (4 requested + 2 proof hashes = 6 total)
    char[][] test_hashes = mem::new_array(char[], 6);
    for (usz i = 0; i < 6; i++)
    {
        test_hashes[i] = mem::new_array(char, 32);
        for (usz j = 0; j < 32; j++)
        {
            test_hashes[i][j] = (char)(i * 32 + j);
        }
    }
    defer {
        foreach (hash : test_hashes)
        {
            free(hash);
        }
        free(test_hashes);
    }

    // Create HASHES message
    peer_wire::HashesMsg hashes;
    foreach (i, byte : pieces_root)
    {
        hashes.pieces_root[i] = byte;
    }
    hashes.base_layer = 4;
    hashes.index = 0;
    hashes.length = 4;  // 4 requested hashes
    hashes.hashes = test_hashes;

    // Encode
    char[] encoded = peer_wire::encode_hashes(&hashes);
    defer free(encoded);

    // Verify wire format (4 + 1 + 32 + 4 + 4 + 4 + 6*32)
    assert(encoded.len == 4 + 1 + 32 + 4 + 4 + 4 + (6 * 32), "HASHES should be 241 bytes");

    // Verify message ID
    assert(encoded[4] == (char)peer_wire::MessageType.HASHES, "Message ID should be 22");

    // Decode (skip length and ID)
    peer_wire::HashesMsg? decoded_opt = peer_wire::decode_hashes(encoded[5..]);
    assert(@ok(decoded_opt), "Should decode HASHES successfully");

    peer_wire::HashesMsg decoded = decoded_opt!!;
    defer {
        foreach (hash : decoded.hashes)
        {
            free(hash);
        }
        free(decoded.hashes);
    }

    // Verify decoded values
    assert(decoded.base_layer == 4, "base_layer should be 4");
    assert(decoded.index == 0, "index should be 0");
    assert(decoded.length == 4, "length should be 4");
    assert(decoded.hashes.len == 6, "Should have 6 hashes");

    // Verify hash data
    foreach (i, hash : decoded.hashes)
    {
        foreach (j, byte : hash)
        {
            assert(byte == (char)(i * 32 + j), "Hash[%d][%d] should match", i, j);
        }
    }

    io::printfn("✓ HASHES encode/decode working");
}

/**
 * Test 4: Encode/decode HASH_REJECT message
 */
fn void test_encode_decode_hash_reject() @test
{
    // Create test pieces_root
    common::InfoHashV2 pieces_root;
    for (usz i = 0; i < common::SHA256_HASH_SIZE; i++)
    {
        pieces_root[i] = (char)(255 - i);
    }

    // Create HASH_REJECT message
    peer_wire::HashRejectMsg reject;
    foreach (i, byte : pieces_root)
    {
        reject.pieces_root[i] = byte;
    }
    reject.base_layer = 5;
    reject.index = 32;
    reject.length = 8;

    // Encode
    char[] encoded = peer_wire::encode_hash_reject(&reject);
    defer free(encoded);

    // Verify wire format (4 + 1 + 32 + 4 + 4 + 4)
    assert(encoded.len == 49, "HASH_REJECT should be 49 bytes");

    // Verify length field (45 = 1 + 32 + 4 + 4 + 4)
    uint length = peer_wire::read_u32_be(encoded, 0);
    assert(length == 45, "Length field should be 45");

    // Verify message ID
    assert(encoded[4] == (char)peer_wire::MessageType.HASH_REJECT, "Message ID should be 23");

    // Decode (skip length and ID)
    peer_wire::HashRejectMsg? decoded_opt = peer_wire::decode_hash_reject(encoded[5..]);
    assert(@ok(decoded_opt), "Should decode HASH_REJECT successfully");

    peer_wire::HashRejectMsg decoded = decoded_opt!!;

    // Verify decoded values
    assert(decoded.base_layer == 5, "base_layer should be 5");
    assert(decoded.index == 32, "index should be 32");
    assert(decoded.length == 8, "length should be 8");

    // Verify pieces_root
    foreach (i, byte : decoded.pieces_root)
    {
        assert(byte == (char)(255 - i), "pieces_root[%d] should match", i);
    }

    io::printfn("✓ HASH_REJECT encode/decode working");
}

/**
 * Test 5: Parameter validation for HASH_REQUEST
 */
fn void test_validate_hash_request_params() @test
{
    peer_wire::HashRequestMsg request;

    // Test 1: Valid request (index multiple of length, length power of 2)
    request.index = 0;
    request.length = 16;
    assert(peer_wire::validate_hash_request(&request), "Should be valid: index=0, length=16");

    // Test 2: Valid request (non-zero index)
    request.index = 32;
    request.length = 16;
    assert(peer_wire::validate_hash_request(&request), "Should be valid: index=32, length=16");

    // Test 3: Invalid - index not multiple of length
    request.index = 10;
    request.length = 16;
    assert(!peer_wire::validate_hash_request(&request), "Should be invalid: 10 % 16 != 0");

    // Test 4: Invalid - length not power of 2
    request.index = 0;
    request.length = 10;
    assert(!peer_wire::validate_hash_request(&request), "Should be invalid: 10 not power of 2");

    // Test 5: Invalid - length too small
    request.index = 0;
    request.length = 1;
    assert(!peer_wire::validate_hash_request(&request), "Should be invalid: length < 2");

    // Test 6: Invalid - length too large
    request.index = 0;
    request.length = 1024;
    assert(!peer_wire::validate_hash_request(&request), "Should be invalid: length > 512");

    // Test 7: Valid - edge cases
    request.index = 0;
    request.length = 2;
    assert(peer_wire::validate_hash_request(&request), "Should be valid: length=2 (min)");

    request.index = 0;
    request.length = 512;
    assert(peer_wire::validate_hash_request(&request), "Should be valid: length=512 (max)");

    io::printfn("✓ HASH_REQUEST parameter validation working");
}

/**
 * Test 6: HASH_REQUEST roundtrip (encode → decode → encode)
 */
fn void test_hash_request_roundtrip() @test
{
    // Create original message
    peer_wire::HashRequestMsg original;
    for (usz i = 0; i < 32; i++)
    {
        original.pieces_root[i] = (char)(i * 7 % 256);
    }
    original.base_layer = 3;
    original.index = 64;
    original.length = 32;
    original.proof_layers = 8;

    // First encode
    char[] encoded1 = peer_wire::encode_hash_request(&original);
    defer free(encoded1);

    // Decode
    peer_wire::HashRequestMsg decoded = peer_wire::decode_hash_request(encoded1[5..])!!;

    // Second encode
    char[] encoded2 = peer_wire::encode_hash_request(&decoded);
    defer free(encoded2);

    // Compare encoded messages
    assert(encoded1.len == encoded2.len, "Encoded lengths should match");
    foreach (i, byte : encoded1)
    {
        assert(byte == encoded2[i], "Byte %d should match in roundtrip", i);
    }

    io::printfn("✓ HASH_REQUEST roundtrip successful");
}

/**
 * Test 7: HASHES message with proof hashes
 */
fn void test_hashes_with_proofs() @test
{
    // Simulate realistic scenario: 16 requested hashes + 4 proof hashes
    uint num_requested = 16;
    uint num_proofs = 4;
    uint total_hashes = num_requested + num_proofs;

    // Create hash array
    char[][] hashes = mem::new_array(char[], total_hashes);
    for (usz i = 0; i < total_hashes; i++)
    {
        hashes[i] = mem::new_array(char, 32);
        // Fill with pattern
        for (usz j = 0; j < 32; j++)
        {
            hashes[i][j] = (char)((i + j) % 256);
        }
    }
    defer {
        foreach (hash : hashes)
        {
            free(hash);
        }
        free(hashes);
    }

    // Create HASHES message
    peer_wire::HashesMsg msg;
    for (usz i = 0; i < 32; i++)
    {
        msg.pieces_root[i] = (char)(i + 100);
    }
    msg.base_layer = 4;
    msg.index = 0;
    msg.length = num_requested;
    msg.hashes = hashes;

    // Encode
    char[] encoded = peer_wire::encode_hashes(&msg);
    defer free(encoded);

    // Expected size: 4 (length) + 1 (id) + 32 (root) + 4*3 (ints) + 20*32 (hashes)
    usz expected_size = 4 + 1 + 32 + 12 + ((usz)total_hashes * 32);
    assert(encoded.len == expected_size, "Size should be %d bytes", expected_size);

    // Decode
    peer_wire::HashesMsg decoded = peer_wire::decode_hashes(encoded[5..])!!;
    defer {
        foreach (hash : decoded.hashes)
        {
            free(hash);
        }
        free(decoded.hashes);
    }

    // Verify all hashes preserved
    assert(decoded.hashes.len == total_hashes, "Should have %d hashes", total_hashes);

    foreach (i, hash : decoded.hashes)
    {
        foreach (j, byte : hash)
        {
            assert(byte == (char)((i + j) % 256), "Hash[%d][%d] should match pattern", i, j);
        }
    }

    io::printfn("✓ HASHES with proof hashes working");
}

/**
 * Test 8: Invalid message handling
 */
fn void test_invalid_message_handling() @test
{
    // Test 1: Invalid HASH_REQUEST payload length (too short)
    char[] short_payload = mem::new_array(char, 30);  // Should be 48
    defer free(short_payload);

    peer_wire::HashRequestMsg? result1 = peer_wire::decode_hash_request(short_payload);
    assert(@catch(result1), "Should reject short HASH_REQUEST payload");

    // Test 2: Invalid HASH_REJECT payload length (too long)
    char[] long_payload = mem::new_array(char, 100);  // Should be 44
    defer free(long_payload);

    peer_wire::HashRejectMsg? result2 = peer_wire::decode_hash_reject(long_payload);
    assert(@catch(result2), "Should reject long HASH_REJECT payload");

    // Test 3: Invalid HASHES payload (not enough data for hashes)
    char[] invalid_hashes = mem::new_array(char, 44 + 10);  // Header + partial hash
    defer free(invalid_hashes);

    // Write valid header
    for (usz i = 0; i < 32; i++) invalid_hashes[i] = 0;  // pieces_root
    peer_wire::write_u32_be(invalid_hashes, 32, 4);  // base_layer
    peer_wire::write_u32_be(invalid_hashes, 36, 0);  // index
    peer_wire::write_u32_be(invalid_hashes, 40, 2);  // length = 2 hashes (needs 64 bytes)
    // Only 10 bytes follow (should be 64)

    peer_wire::HashesMsg? result3 = peer_wire::decode_hashes(invalid_hashes);
    assert(@catch(result3), "Should reject HASHES with incomplete hash data");

    io::printfn("✓ Invalid message handling working");
}
