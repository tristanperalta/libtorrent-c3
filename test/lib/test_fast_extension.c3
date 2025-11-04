module libtorrent::test_fast_extension @test;

import std::io;
import std::collections::list;
import libtorrent::fast_extension;
import libtorrent::common;
import libtorrent::peer_wire;

/**
 * Tests for BEP 6: Fast Extension - Allowed Fast Set Generation
 *
 * Verifies that the canonical algorithm produces correct and deterministic
 * piece indices for a given peer IP and torrent info_hash.
 */

// ============================================================================
// Allowed Fast Set Generation Tests
// ============================================================================

/**
 * Test allowed_fast set generation with known values from BEP 6 specification.
 *
 * BEP 6 provides example outputs:
 * - Torrent: 1313 pieces, info_hash = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (hex)
 * - Peer IP: 80.4.4.200
 * - Expected 7-piece set: [1059, 431, 808, 1217, 287, 376, 1188]
 * - Expected 9-piece set: [1059, 431, 808, 1217, 287, 376, 1188, 353, 508]
 */
fn void test_allowed_fast_bep6_example() @test
{
    // Setup from BEP 6 example
    common::Ipv4Addr peer_ip = {80, 4, 4, 200};
    common::InfoHash info_hash;

    // info_hash = 0xAAAAAAAA... (all 0xAA bytes)
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)0xAA;
    }

    uint num_pieces = 1313;

    // Test 7-piece set
    uint[] allowed_fast_7 = fast_extension::generate_allowed_fast_set(
        peer_ip, info_hash, num_pieces, 7);
    defer free(allowed_fast_7);

    // Expected results from BEP 6
    uint[7] expected_7 = {1059, 431, 808, 1217, 287, 376, 1188};

    assert(allowed_fast_7.len == 7, "Should generate 7 pieces");
    for (uint i = 0; i < 7; i++)
    {
        assert(allowed_fast_7[i] == expected_7[i],
               "Piece index should match BEP 6 example");
    }

    // Test 9-piece set (should include all 7 from above plus 2 more)
    uint[] allowed_fast_9 = fast_extension::generate_allowed_fast_set(
        peer_ip, info_hash, num_pieces, 9);
    defer free(allowed_fast_9);

    uint[9] expected_9 = {1059, 431, 808, 1217, 287, 376, 1188, 353, 508};

    assert(allowed_fast_9.len == 9, "Should generate 9 pieces");
    for (uint i = 0; i < 9; i++)
    {
        assert(allowed_fast_9[i] == expected_9[i],
               "Piece index should match BEP 6 example");
    }

    io::printn("BEP 6 example allowed_fast set generation works ✓");
}

/**
 * Test that allowed_fast sets are deterministic (same inputs = same outputs)
 */
fn void test_allowed_fast_deterministic() @test
{
    common::Ipv4Addr peer_ip = {192, 168, 1, 100};
    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)(i * 13 + 7);  // Arbitrary values
    }
    uint num_pieces = 500;
    uint k = 10;

    // Generate twice with same inputs
    uint[] set1 = fast_extension::generate_allowed_fast_set(peer_ip, info_hash, num_pieces, k);
    defer free(set1);

    uint[] set2 = fast_extension::generate_allowed_fast_set(peer_ip, info_hash, num_pieces, k);
    defer free(set2);

    // Should be identical
    assert(set1.len == set2.len, "Sets should have same length");
    for (usz i = 0; i < set1.len; i++)
    {
        assert(set1[i] == set2[i], "Piece indices should match exactly");
    }

    io::printn("Allowed_fast set generation is deterministic ✓");
}

/**
 * Test that all piece indices are unique (no duplicates)
 */
fn void test_allowed_fast_no_duplicates() @test
{
    common::Ipv4Addr peer_ip = {10, 0, 0, 1};
    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)(i + 1);
    }
    uint num_pieces = 1000;
    uint k = 50;  // Large set to stress-test duplicate detection

    uint[] allowed_fast = fast_extension::generate_allowed_fast_set(
        peer_ip, info_hash, num_pieces, k);
    defer free(allowed_fast);

    assert(allowed_fast.len == k, "Should generate requested number of pieces");

    // Check for duplicates
    for (usz i = 0; i < allowed_fast.len; i++)
    {
        for (usz j = i + 1; j < allowed_fast.len; j++)
        {
            assert(allowed_fast[i] != allowed_fast[j],
                   "No duplicate piece indices allowed");
        }
    }

    io::printn("Allowed_fast set has no duplicates ✓");
}

/**
 * Test that all piece indices are within valid range [0, num_pieces)
 */
fn void test_allowed_fast_valid_range() @test
{
    common::Ipv4Addr peer_ip = {172, 16, 0, 50};
    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)(255 - i);
    }
    uint num_pieces = 256;
    uint k = 10;

    uint[] allowed_fast = fast_extension::generate_allowed_fast_set(
        peer_ip, info_hash, num_pieces, k);
    defer free(allowed_fast);

    // Verify all indices are valid
    for (usz i = 0; i < allowed_fast.len; i++)
    {
        assert(allowed_fast[i] < num_pieces,
               "Piece index must be less than num_pieces");
    }

    io::printn("Allowed_fast piece indices are in valid range ✓");
}

/**
 * Test default allowed_fast set generation (k=10)
 */
fn void test_allowed_fast_default() @test
{
    common::Ipv4Addr peer_ip = {8, 8, 8, 8};
    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)(i * i);
    }
    uint num_pieces = 2000;

    uint[] allowed_fast = fast_extension::generate_default_allowed_fast_set(
        peer_ip, info_hash, num_pieces);
    defer free(allowed_fast);

    assert(allowed_fast.len == 10, "Default should be 10 pieces");

    // Verify no duplicates
    for (usz i = 0; i < allowed_fast.len; i++)
    {
        assert(allowed_fast[i] < num_pieces, "Valid piece index");
        for (usz j = i + 1; j < allowed_fast.len; j++)
        {
            assert(allowed_fast[i] != allowed_fast[j], "No duplicates");
        }
    }

    io::printn("Default allowed_fast set generation works ✓");
}

/**
 * Test edge case: more allowed_fast pieces requested than exist
 */
fn void test_allowed_fast_small_torrent() @test
{
    common::Ipv4Addr peer_ip = {127, 0, 0, 1};
    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)42;
    }
    uint num_pieces = 5;  // Very small torrent

    // Request default 10 pieces
    uint[] allowed_fast = fast_extension::generate_default_allowed_fast_set(
        peer_ip, info_hash, num_pieces);
    defer free(allowed_fast);

    // Should only get 5 pieces (all of them)
    assert(allowed_fast.len == 5, "Should cap at num_pieces");

    // Verify all pieces are unique and valid
    for (usz i = 0; i < allowed_fast.len; i++)
    {
        assert(allowed_fast[i] < num_pieces, "Valid piece index");
    }

    io::printn("Allowed_fast handles small torrents correctly ✓");
}

/**
 * Test is_piece_allowed_fast helper function
 */
fn void test_is_piece_allowed_fast() @test
{
    uint[] allowed_fast = {10, 20, 30, 40, 50};

    // Test pieces in the set
    assert(fast_extension::is_piece_allowed_fast(10, allowed_fast), "10 should be allowed");
    assert(fast_extension::is_piece_allowed_fast(30, allowed_fast), "30 should be allowed");
    assert(fast_extension::is_piece_allowed_fast(50, allowed_fast), "50 should be allowed");

    // Test pieces not in the set
    assert(!fast_extension::is_piece_allowed_fast(0, allowed_fast), "0 should not be allowed");
    assert(!fast_extension::is_piece_allowed_fast(15, allowed_fast), "15 should not be allowed");
    assert(!fast_extension::is_piece_allowed_fast(100, allowed_fast), "100 should not be allowed");

    io::printn("is_piece_allowed_fast helper function works ✓");
}

/**
 * Test that different peer IPs (different subnets) produce different allowed_fast sets
 */
fn void test_allowed_fast_different_peers() @test
{
    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)(i + 50);
    }
    uint num_pieces = 1000;
    uint k = 10;

    // Use different subnets - last octet is masked, so these are genuinely different
    common::Ipv4Addr peer1 = {192, 168, 1, 0};
    common::Ipv4Addr peer2 = {192, 168, 2, 0};

    uint[] set1 = fast_extension::generate_allowed_fast_set(peer1, info_hash, num_pieces, k);
    defer free(set1);

    uint[] set2 = fast_extension::generate_allowed_fast_set(peer2, info_hash, num_pieces, k);
    defer free(set2);

    // Sets should be different (with very high probability)
    bool different = false;
    for (usz i = 0; i < k; i++)
    {
        if (set1[i] != set2[i])
        {
            different = true;
            break;
        }
    }

    assert(different, "Different peers should get different sets");

    io::printn("Different peers get different allowed_fast sets ✓");
}

/**
 * Test that IP address masking works (last octet is masked)
 */
fn void test_allowed_fast_ip_masking() @test
{
    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)100;
    }
    uint num_pieces = 500;
    uint k = 10;

    // Same first 3 octets, different last octet (should produce same set)
    common::Ipv4Addr peer1 = {10, 20, 30, 40};
    common::Ipv4Addr peer2 = {10, 20, 30, 99};

    uint[] set1 = fast_extension::generate_allowed_fast_set(peer1, info_hash, num_pieces, k);
    defer free(set1);

    uint[] set2 = fast_extension::generate_allowed_fast_set(peer2, info_hash, num_pieces, k);
    defer free(set2);

    // Sets should be identical (last octet is masked)
    for (usz i = 0; i < k; i++)
    {
        assert(set1[i] == set2[i], "Same /24 subnet should produce same set");
    }

    io::printn("IP address masking (last octet) works correctly ✓");
}

// ============================================================================
// Integration Tests for Fast Extension Behaviors
// ============================================================================

/**
 * Test that List-based allowed_fast checking works correctly
 */
fn void test_allowed_fast_list_checking() @test
{
    // Create a List with some allowed pieces
    List{uint} allowed_fast_set;
    allowed_fast_set.init(mem);
    defer allowed_fast_set.free();

    allowed_fast_set.push(10);
    allowed_fast_set.push(25);
    allowed_fast_set.push(42);
    allowed_fast_set.push(99);

    // Test checking if pieces are in the list (inline check pattern from download_session.c3)
    // Check piece 25 (should be in set)
    bool is_allowed_25 = false;
    foreach (allowed_piece : allowed_fast_set)
    {
        if (allowed_piece == 25)
        {
            is_allowed_25 = true;
            break;
        }
    }
    assert(is_allowed_25, "Piece 25 should be in allowed_fast set");

    // Check piece 50 (should NOT be in set)
    bool is_allowed_50 = false;
    foreach (allowed_piece : allowed_fast_set)
    {
        if (allowed_piece == 50)
        {
            is_allowed_50 = true;
            break;
        }
    }
    assert(!is_allowed_50, "Piece 50 should NOT be in allowed_fast set");

    io::printn("List-based allowed_fast checking works ✓");
}

/**
 * Test that allowed_fast sets can be empty
 */
fn void test_allowed_fast_empty_set() @test
{
    // Create an empty List
    List{uint} allowed_fast_set;
    allowed_fast_set.init(mem);
    defer allowed_fast_set.free();

    // Check that iterating over empty list works
    bool is_allowed = false;
    foreach (allowed_piece : allowed_fast_set)
    {
        is_allowed = true;  // Should never execute
    }
    assert(!is_allowed, "Empty set should not allow any pieces");

    io::printn("Empty allowed_fast set works correctly ✓");
}

/**
 * Test that duplicate pieces in allowed_fast set are handled
 */
fn void test_allowed_fast_duplicate_handling() @test
{
    // Create a List with duplicates
    List{uint} allowed_fast_set;
    allowed_fast_set.init(mem);
    defer allowed_fast_set.free();

    allowed_fast_set.push(10);
    allowed_fast_set.push(20);
    allowed_fast_set.push(10);  // Duplicate
    allowed_fast_set.push(30);

    // Count how many times piece 10 appears
    int count_10 = 0;
    foreach (allowed_piece : allowed_fast_set)
    {
        if (allowed_piece == 10) count_10++;
    }

    // The list should contain duplicates (not dedup'd)
    assert(count_10 == 2, "Duplicates should be in list");

    // But the check still works correctly (returns true on first match)
    bool is_allowed_10 = false;
    foreach (allowed_piece : allowed_fast_set)
    {
        if (allowed_piece == 10)
        {
            is_allowed_10 = true;
            break;
        }
    }
    assert(is_allowed_10, "Piece 10 should be found");

    io::printn("Duplicate pieces in allowed_fast set handled correctly ✓");
}

/**
 * Test that allowed_fast set generation produces unique pieces
 */
fn void test_allowed_fast_generation_uniqueness() @test
{
    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)(i * 7 + 3);
    }

    common::Ipv4Addr peer_ip = {192, 168, 1, 100};
    uint num_pieces = 1000;
    uint k = 20;

    uint[] allowed_fast = fast_extension::generate_allowed_fast_set(peer_ip, info_hash, num_pieces, k);
    defer free(allowed_fast);

    // Verify all pieces are unique (no duplicates in generated set)
    for (usz i = 0; i < allowed_fast.len; i++)
    {
        for (usz j = i + 1; j < allowed_fast.len; j++)
        {
            assert(allowed_fast[i] != allowed_fast[j], "Generated set should have no duplicates");
        }
    }

    io::printn("Generated allowed_fast set has no duplicates ✓");
}

/**
 * Test that allowed_fast set respects num_pieces boundary
 */
fn void test_allowed_fast_respects_boundaries() @test
{
    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)42;
    }

    common::Ipv4Addr peer_ip = {10, 0, 0, 1};
    uint num_pieces = 100;
    uint k = 50;  // Request half of available pieces

    uint[] allowed_fast = fast_extension::generate_allowed_fast_set(peer_ip, info_hash, num_pieces, k);
    defer free(allowed_fast);

    // All pieces must be within valid range [0, num_pieces)
    foreach (piece_index : allowed_fast)
    {
        assert(piece_index < num_pieces, "All pieces must be < num_pieces");
    }

    io::printn("Allowed_fast set respects piece boundaries ✓");
}

/**
 * Test allowed_fast behavior with very small k
 */
fn void test_allowed_fast_small_k() @test
{
    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)(i + 1);
    }

    common::Ipv4Addr peer_ip = {172, 16, 0, 1};
    uint num_pieces = 1000;
    uint k = 1;  // Request only 1 piece

    uint[] allowed_fast = fast_extension::generate_allowed_fast_set(peer_ip, info_hash, num_pieces, k);
    defer free(allowed_fast);

    assert(allowed_fast.len == 1, "Should generate exactly 1 piece for k=1");
    assert(allowed_fast[0] < num_pieces, "Single piece must be valid");

    io::printn("Allowed_fast works with k=1 ✓");
}

/**
 * Test REJECT_REQUEST message encoding/decoding
 * BEP 6: Every REQUEST must get exactly one response (PIECE or REJECT_REQUEST)
 */
fn void test_reject_request_message() @test
{
    // Encode REJECT_REQUEST message
    uint piece_index = 42;
    uint begin = 16384;
    uint length = 16384;

    char[] msg = peer_wire::encode_reject_request(piece_index, begin, length);
    defer free(msg);

    // Verify message structure
    // Format: <length:4><id:1><payload:12>
    // length = 1 + 12 = 13
    assert(msg.len == 17, "REJECT_REQUEST message should be 17 bytes (4 + 1 + 12)");

    // Decode length prefix (big-endian)
    uint msg_length = ((uint)(msg[0] & 0xFF) << 24) |
                      ((uint)(msg[1] & 0xFF) << 16) |
                      ((uint)(msg[2] & 0xFF) << 8) |
                      ((uint)(msg[3] & 0xFF));

    assert(msg_length == 13, "Message length should be 13 (1 + 12)");

    // Check message type
    assert((uint)msg[4] == 16, "Message type should be REJECT_REQUEST (16)");

    // Decode payload (3 big-endian uint32s)
    uint decoded_index = ((uint)(msg[5] & 0xFF) << 24) |
                         ((uint)(msg[6] & 0xFF) << 16) |
                         ((uint)(msg[7] & 0xFF) << 8) |
                         ((uint)(msg[8] & 0xFF));

    uint decoded_begin = ((uint)(msg[9] & 0xFF) << 24) |
                         ((uint)(msg[10] & 0xFF) << 16) |
                         ((uint)(msg[11] & 0xFF) << 8) |
                         ((uint)(msg[12] & 0xFF));

    uint decoded_length = ((uint)(msg[13] & 0xFF) << 24) |
                          ((uint)(msg[14] & 0xFF) << 16) |
                          ((uint)(msg[15] & 0xFF) << 8) |
                          ((uint)(msg[16] & 0xFF));

    assert(decoded_index == piece_index, "Decoded piece index should match");
    assert(decoded_begin == begin, "Decoded begin offset should match");
    assert(decoded_length == length, "Decoded length should match");

    io::printn("REJECT_REQUEST message encoding/decoding works ✓");
}

/**
 * Test REQUEST message encoding/decoding
 * Used to verify we can decode incoming REQUEST messages
 */
fn void test_request_message_decode() @test
{
    // Encode REQUEST message
    uint piece_index = 10;
    uint begin = 32768;
    uint length = 16384;

    char[] msg = peer_wire::encode_request(piece_index, begin, length);
    defer free(msg);

    // Verify message structure
    assert(msg.len == 17, "REQUEST message should be 17 bytes (4 + 1 + 12)");

    // Extract payload (skip 4-byte length prefix and 1-byte message type)
    char[] payload = msg[5..];

    // Decode payload using peer_wire::decode_request
    peer_wire::RequestMsg? req_opt = peer_wire::decode_request(payload);
    if (catch err = req_opt)
    {
        assert(false, "Should successfully decode REQUEST message");
        return;
    }

    peer_wire::RequestMsg req = req_opt;

    assert(req.index == piece_index, "Decoded piece index should match");
    assert(req.begin == begin, "Decoded begin offset should match");
    assert(req.length == length, "Decoded length should match");

    io::printn("REQUEST message decoding works ✓");
}
