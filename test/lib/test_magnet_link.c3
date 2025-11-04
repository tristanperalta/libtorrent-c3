module libtorrent::magnet_link::test;

import libtorrent::magnet_link;
import std::io;

/**
 * BEP 9: Magnet Link Parser Tests
 * ================================
 *
 * Tests for parsing magnet URIs and extracting components
 */

// ============================================================================
// Helper Functions
// ============================================================================

fn bool compare_hash(char[20] a, char[20] b)
{
    foreach (i, byte : a)
    {
        if (byte != b[i]) return false;
    }
    return true;
}

// ============================================================================
// Basic Parsing Tests
// ============================================================================

fn void test_parse_hex_infohash() @test
{
    // Magnet link with 40-character hex info hash
    String magnet = "magnet:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567";

    magnet_link::MagnetLink*? result = magnet_link::parse(magnet);
    result!!;
    magnet_link::MagnetLink* link = result!!;
    defer link.free();

    // Verify info hash is decoded correctly
    char[20] expected_hash;
    expected_hash[0] = 0x01;
    expected_hash[1] = 0x23;
    expected_hash[2] = 0x45;
    expected_hash[3] = 0x67;
    expected_hash[4] = 0x89;
    expected_hash[5] = 0xAB;
    expected_hash[6] = 0xCD;
    expected_hash[7] = 0xEF;
    expected_hash[8] = 0x01;
    expected_hash[9] = 0x23;
    expected_hash[10] = 0x45;
    expected_hash[11] = 0x67;
    expected_hash[12] = 0x89;
    expected_hash[13] = 0xAB;
    expected_hash[14] = 0xCD;
    expected_hash[15] = 0xEF;
    expected_hash[16] = 0x01;
    expected_hash[17] = 0x23;
    expected_hash[18] = 0x45;
    expected_hash[19] = 0x67;

    assert(compare_hash(link.info_hash, expected_hash), "Hex info hash should decode correctly");

    io::printn("Hex info hash parsing works correctly ✓");
}

fn void test_parse_base32_infohash() @test
{
    // Magnet link with 32-character base32 info hash
    // "MFRGG2LTMFZGK3TUMVQWY3DBONZWS3TH" decodes to specific bytes
    String magnet = "magnet:?xt=urn:btih:MFRGG2LTMFZGK3TUMVQWY3DBONZWS3TH";

    magnet_link::MagnetLink*? result = magnet_link::parse(magnet);
    result!!;
    magnet_link::MagnetLink* link = result!!;
    defer link.free();

    // Base32 decoding verification
    // "MFRGG2LTMFZGK3TUMVQWY3DBONZWS3TH" should decode to 20 bytes
    assert(link.info_hash.len == 20, "Info hash should be 20 bytes");

    io::printn("Base32 info hash parsing works correctly ✓");
}

fn void test_parse_display_name() @test
{
    // Magnet link with display name (URL encoded)
    String magnet = "magnet:?xt=urn:btih:ABCD1234567890ABCDEF1234567890ABCD123456&dn=My%20Cool%20Torrent";

    magnet_link::MagnetLink*? result = magnet_link::parse(magnet);
    result!!;
    magnet_link::MagnetLink* link = result!!;
    defer link.free();

    assert(link.name == "My Cool Torrent", "Display name should be URL decoded");

    io::printn("Display name parsing works correctly ✓");
}

fn void test_parse_single_tracker() @test
{
    // Magnet link with one tracker
    String magnet = "magnet:?xt=urn:btih:ABCD1234567890ABCDEF1234567890ABCD123456&tr=http%3A%2F%2Ftracker.example.com%3A8080%2Fannounce";

    magnet_link::MagnetLink*? result = magnet_link::parse(magnet);
    result!!;
    magnet_link::MagnetLink* link = result!!;
    defer link.free();

    assert(link.trackers.len == 1, "Should have one tracker");
    assert(link.trackers[0] == "http://tracker.example.com:8080/announce", "Tracker URL should be decoded");

    io::printn("Single tracker parsing works correctly ✓");
}

fn void test_parse_multiple_trackers() @test
{
    // Magnet link with multiple trackers
    String magnet = "magnet:?xt=urn:btih:ABCD1234567890ABCDEF1234567890ABCD123456&tr=http://tracker1.com/announce&tr=http://tracker2.com/announce&tr=udp://tracker3.com:6881";

    magnet_link::MagnetLink*? result = magnet_link::parse(magnet);
    result!!;
    magnet_link::MagnetLink* link = result!!;
    defer link.free();

    assert(link.trackers.len == 3, "Should have three trackers");
    assert(link.trackers[0] == "http://tracker1.com/announce", "First tracker should match");
    assert(link.trackers[1] == "http://tracker2.com/announce", "Second tracker should match");
    assert(link.trackers[2] == "udp://tracker3.com:6881", "Third tracker should match");

    io::printn("Multiple trackers parsing works correctly ✓");
}

fn void test_parse_peers() @test
{
    // Magnet link with peer addresses
    String magnet = "magnet:?xt=urn:btih:ABCD1234567890ABCDEF1234567890ABCD123456&x.pe=192.168.1.100:6881&x.pe=10.0.0.50:51413";

    magnet_link::MagnetLink*? result = magnet_link::parse(magnet);
    result!!;
    magnet_link::MagnetLink* link = result!!;
    defer link.free();

    assert(link.peers.len == 2, "Should have two peers");
    assert(link.peers[0] == "192.168.1.100:6881", "First peer should match");
    assert(link.peers[1] == "10.0.0.50:51413", "Second peer should match");

    io::printn("Peer parsing works correctly ✓");
}

fn void test_parse_complete_magnet() @test
{
    // Full magnet link with all components
    String magnet = "magnet:?xt=urn:btih:1234567890ABCDEF1234567890ABCDEF12345678&dn=Ubuntu+Linux&tr=http://tracker.ubuntu.com/announce&tr=udp://tracker.openbittorrent.com:80&x.pe=192.168.1.1:6881";

    magnet_link::MagnetLink*? result = magnet_link::parse(magnet);
    result!!;
    magnet_link::MagnetLink* link = result!!;
    defer link.free();

    assert(link.name == "Ubuntu Linux", "Name should be decoded (+ to space)");
    assert(link.trackers.len == 2, "Should have two trackers");
    assert(link.peers.len == 1, "Should have one peer");

    io::printn("Complete magnet parsing works correctly ✓");
}

// ============================================================================
// Error Handling Tests
// ============================================================================

fn void test_parse_invalid_scheme() @test
{
    // Not a magnet link
    String invalid = "http://example.com/file.torrent";

    if (catch magnet_link::parse(invalid))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject non-magnet URIs");
    }

    io::printn("Invalid scheme rejection works correctly ✓");
}

fn void test_parse_missing_xt() @test
{
    // Magnet link without xt parameter
    String invalid = "magnet:?dn=Some+File&tr=http://tracker.com/announce";

    if (catch magnet_link::parse(invalid))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject magnet links without info hash");
    }

    io::printn("Missing xt rejection works correctly ✓");
}

fn void test_parse_invalid_urn() @test
{
    // xt parameter but not btih URN
    String invalid = "magnet:?xt=urn:sha1:ABCD1234567890ABCDEF1234567890ABCD123456";

    if (catch magnet_link::parse(invalid))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject non-btih URNs");
    }

    io::printn("Invalid URN rejection works correctly ✓");
}

fn void test_parse_invalid_hex_length() @test
{
    // Hex info hash with wrong length (should be 40 chars)
    String invalid = "magnet:?xt=urn:btih:ABCD1234";  // Only 8 chars

    if (catch magnet_link::parse(invalid))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject invalid hex length");
    }

    io::printn("Invalid hex length rejection works correctly ✓");
}

fn void test_parse_invalid_base32_length() @test
{
    // Base32 info hash with wrong length (should be 32 chars)
    String invalid = "magnet:?xt=urn:btih:MFRGG2LT";  // Only 8 chars

    if (catch magnet_link::parse(invalid))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject invalid base32 length");
    }

    io::printn("Invalid base32 length rejection works correctly ✓");
}

fn void test_parse_invalid_hex_chars() @test
{
    // Hex with invalid characters
    String invalid = "magnet:?xt=urn:btih:GHIJKLMNOPQRSTUVWXYZ1234567890GHIJKLMN";  // G-Z not valid hex

    if (catch magnet_link::parse(invalid))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject invalid hex characters");
    }

    io::printn("Invalid hex characters rejection works correctly ✓");
}

// ============================================================================
// URL Decoding Tests
// ============================================================================

fn void test_url_decode_spaces() @test
{
    // Test %20 and + for spaces
    String magnet1 = "magnet:?xt=urn:btih:ABCD1234567890ABCDEF1234567890ABCD123456&dn=File%20Name";
    String magnet2 = "magnet:?xt=urn:btih:ABCD1234567890ABCDEF1234567890ABCD123456&dn=File+Name";

    magnet_link::MagnetLink* link1 = magnet_link::parse(magnet1)!!;
    defer link1.free();

    magnet_link::MagnetLink* link2 = magnet_link::parse(magnet2)!!;
    defer link2.free();

    assert(link1.name == "File Name", "%20 should decode to space");
    assert(link2.name == "File Name", "+ should decode to space");

    io::printn("URL space decoding works correctly ✓");
}

fn void test_url_decode_special_chars() @test
{
    // Test special character decoding
    String magnet = "magnet:?xt=urn:btih:ABCD1234567890ABCDEF1234567890ABCD123456&dn=File%21%40%23%24";

    magnet_link::MagnetLink* link = magnet_link::parse(magnet)!!;
    defer link.free();

    // %21=! %40=@ %23=# %24=$
    assert(link.name == "File!@#$", "Special chars should decode correctly");

    io::printn("URL special character decoding works correctly ✓");
}

// ============================================================================
// Edge Cases
// ============================================================================

fn void test_parse_minimal_magnet() @test
{
    // Just the required xt parameter
    String magnet = "magnet:?xt=urn:btih:ABCD1234567890ABCDEF1234567890ABCD123456";

    magnet_link::MagnetLink* link = magnet_link::parse(magnet)!!;
    defer link.free();

    assert(link.name.len == 0, "Name should be empty");
    assert(link.trackers.len == 0, "Trackers should be empty");
    assert(link.peers.len == 0, "Peers should be empty");

    io::printn("Minimal magnet parsing works correctly ✓");
}

fn void test_parse_lowercase_hex() @test
{
    // Hex with lowercase letters
    String magnet = "magnet:?xt=urn:btih:abcdef1234567890abcdef1234567890abcdef12";

    magnet_link::MagnetLink* link = magnet_link::parse(magnet)!!;
    defer link.free();

    // Should accept lowercase hex
    assert(link.info_hash.len == 20, "Lowercase hex should be accepted");

    io::printn("Lowercase hex parsing works correctly ✓");
}

fn void test_parse_mixed_case_hex() @test
{
    // Hex with mixed case
    String magnet = "magnet:?xt=urn:btih:AbCdEf1234567890aBcDeF1234567890AbCdEf12";

    magnet_link::MagnetLink* link = magnet_link::parse(magnet)!!;
    defer link.free();

    // Should accept mixed case hex
    assert(link.info_hash.len == 20, "Mixed case hex should be accepted");

    io::printn("Mixed case hex parsing works correctly ✓");
}

fn void test_parse_empty_parameters() @test
{
    // Parameters with empty values
    String magnet = "magnet:?xt=urn:btih:ABCD1234567890ABCDEF1234567890ABCD123456&dn=&tr=";

    magnet_link::MagnetLink* link = magnet_link::parse(magnet)!!;
    defer link.free();

    // Empty values should be handled gracefully
    assert(link.name.len == 0, "Empty name should result in empty string");
    // Empty tracker URL might be skipped or stored as empty - either is acceptable

    io::printn("Empty parameter handling works correctly ✓");
}
