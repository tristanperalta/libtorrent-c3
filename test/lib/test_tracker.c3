module libtorrent::tracker_test;
import libtorrent::tracker;
import libtorrent::common;
import libtorrent::bencode;
import std::io;
import std::net::url;

<*
 Test peer ID generation format.
 Verifies that peer IDs have the correct -C30001- prefix.
*>
fn void test_generate_peer_id() @test {
    char[20] peer_id = tracker::generate_peer_id();

    // Check prefix
    assert(peer_id[0] == '-', "First char should be '-'");
    assert(peer_id[1] == 'C', "Second char should be 'C'");
    assert(peer_id[2] == '3', "Third char should be '3'");
    assert(peer_id[3] == '0', "Fourth char should be '0'");
    assert(peer_id[4] == '0', "Fifth char should be '0'");
    assert(peer_id[5] == '0', "Sixth char should be '0'");
    assert(peer_id[6] == '1', "Seventh char should be '1'");
    assert(peer_id[7] == '-', "Eighth char should be '-'");

    // Remaining 12 bytes should be present (we can't test randomness easily)
    // Just verify the length is correct by checking last byte is accessible
    char last = peer_id[19];  // Should not crash
}

<*
 Test URL building with query parameters.
 Verifies that announce URLs are built correctly with proper encoding.
*>
fn void test_build_announce_url() @test {
    char[20] info_hash = {
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
        0x12, 0x34, 0x56, 0x78
    };

    char[20] peer_id = {
        '-', 'C', '3', '0', '0', '0', '1', '-',
        'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x',
        'x', 'x', 'x', 'x'
    };

    String url = tracker::build_announce_url(
        "http://tracker.example.com/announce",
        &info_hash,
        &peer_id,
        6881,
        0,
        0,
        1000000,
        "started",
        50  // numwant
    );
    defer free(url);

    // Check that URL starts with tracker URL
    assert(url.starts_with("http://tracker.example.com/announce?"),
           "URL should start with tracker URL and ?");

    // Check that required parameters are present
    assert(url.contains("info_hash="), "URL should contain info_hash");
    assert(url.contains("peer_id="), "URL should contain peer_id");
    assert(url.contains("port=6881"), "URL should contain port=6881");
    assert(url.contains("uploaded=0"), "URL should contain uploaded=0");
    assert(url.contains("downloaded=0"), "URL should contain downloaded=0");
    assert(url.contains("left=1000000"), "URL should contain left=1000000");
    assert(url.contains("compact=1"), "URL should contain compact=1");
    assert(url.contains("event=started"), "URL should contain event=started");
}

<*
 Test URL building with existing query parameters.
 Verifies that & is used instead of ? when tracker URL has query params.
*>
fn void test_build_announce_url_with_existing_query() @test {
    char[20] info_hash = {
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00
    };

    char[20] peer_id = {
        '-', 'C', '3', '0', '0', '0', '1', '-',
        'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h',
        'i', 'j', 'k', 'l'
    };

    String url = tracker::build_announce_url(
        "http://tracker.example.com/announce?key=value",
        &info_hash,
        &peer_id,
        6881,
        0,
        0,
        0,
        "",
        50  // numwant
    );
    defer free(url);

    // Should use & after existing query param
    assert(url.contains("?key=value&info_hash="),
           "URL should append with & not ?");
}

<*
 Test compact peer parsing with valid data.
 Verifies that 6-byte peer format is parsed correctly.
*>
fn void test_parse_compact_peers() @test {
    // Two peers: 192.168.1.1:6881 and 10.0.0.1:51413
    char[] peer_data = {
        192, 168, 1, 1,   0x1A, 0xE1,  // 192.168.1.1:6881 (0x1AE1 = 6881)
        10,  0,   0, 1,   0xC8, 0xD5   // 10.0.0.1:51413 (0xC8D5 = 51413)
    };

    common::SocketAddress[]? peers_opt = tracker::parse_compact_peers(peer_data);
    if (catch excuse = peers_opt) {
        assert(false, "Should parse valid peer data");
        return;
    }

    common::SocketAddress[] peers = peers_opt;
    assert(peers.len == 2, "Should parse 2 peers");

    // Check first peer
    assert(peers[0].addr.ipv4.a == (char)192, "First peer IP byte 0 should be 192");
    assert(peers[0].addr.ipv4.b == (char)168, "First peer IP byte 1 should be 168");
    assert(peers[0].addr.ipv4.c == (char)1, "First peer IP byte 2 should be 1");
    assert(peers[0].addr.ipv4.d == (char)1, "First peer IP byte 3 should be 1");
    assert(peers[0].port == 6881, "First peer port should be 6881");

    // Check second peer
    assert(peers[1].addr.ipv4.a == (char)10, "Second peer IP byte 0 should be 10");
    assert(peers[1].addr.ipv4.b == (char)0, "Second peer IP byte 1 should be 0");
    assert(peers[1].addr.ipv4.c == (char)0, "Second peer IP byte 2 should be 0");
    assert(peers[1].addr.ipv4.d == (char)1, "Second peer IP byte 3 should be 1");
    assert(peers[1].port == 51413, "Second peer port should be 51413");

    free(peers);
}

<*
 Test compact peer parsing with invalid length.
 Should fail if data length is not a multiple of 6.
*>
fn void test_parse_compact_peers_invalid_length() @test {
    // Invalid: 7 bytes (not divisible by 6)
    char[] peer_data = { 192, 168, 1, 1, 0x1A, 0xE1, 0xFF };

    common::SocketAddress[]? peers = tracker::parse_compact_peers(peer_data);
    if (catch excuse = peers) {
        // Expected failure - test passes
    } else {
        assert(false, "Should fail with invalid length");
    }
}

<*
 Test compact peer parsing with empty data.
 Should return empty array, not fail.
*>
fn void test_parse_compact_peers_empty() @test {
    char[] empty;

    common::SocketAddress[]? peers_opt = tracker::parse_compact_peers(empty);
    if (catch excuse = peers_opt) {
        assert(false, "Should handle empty data");
        return;
    }

    common::SocketAddress[] peers = peers_opt;
    assert(peers.len == 0, "Should return empty array");
}

<*
 Test tracker response parsing with success response.
 Verifies that bencode tracker responses are parsed correctly.
*>
fn void test_parse_tracker_response_success() @test {
    // Build a bencode response: d8:intervali1800e8:completei5e10:incompletei10e5:peers12:...e
    // We'll use simple values for testing
    DString response;
    response.append("d");
    response.append("8:intervali1800e");      // interval: 1800
    response.append("8:completei5e");         // complete (seeders): 5
    response.append("10:incompletei10e");     // incomplete (leechers): 10
    // Compact peers: 2 peers (12 bytes)
    char[] compact_peers = {
        127, 0, 0, 1,   0x1A, 0xE1,  // 127.0.0.1:6881
        127, 0, 0, 2,   0x1A, 0xE2   // 127.0.0.2:6882
    };
    response.appendf("5:peers12:");
    response.append((String)compact_peers);
    response.append("e");

    tracker::TrackerResponse? result_opt = tracker::parse_tracker_response(response.str_view());
    if (catch excuse = result_opt) {
        assert(false, "Should parse valid response");
        return;
    }

    tracker::TrackerResponse result = result_opt;
    assert(result.interval == 1800, "Interval should be 1800");
    assert(result.complete == 5, "Complete should be 5");
    assert(result.incomplete == 10, "Incomplete should be 10");
    assert(result.peers.len == 2, "Should have 2 peers");
    assert(result.failure_reason.len == 0, "Should have no failure reason");

    // Free allocated memory
    free(result.peers);
    if (result.failure_reason.len > 0) free(result.failure_reason);
    if (result.warning_message.len > 0) free(result.warning_message);
}

<*
 Test tracker response parsing with failure response.
 Verifies that failure_reason is extracted correctly.
*>
fn void test_parse_tracker_response_failure() @test {
    // Build a bencode failure response: d14:failure reason27:Tracker is down temporarilye
    DString response;
    response.append("d14:failure reason27:Tracker is down temporarilye");

    tracker::TrackerResponse? result_opt = tracker::parse_tracker_response(response.str_view());
    if (catch excuse = result_opt) {
        assert(false, "Should parse failure response");
        return;
    }

    tracker::TrackerResponse result = result_opt;
    assert(result.failure_reason.len > 0, "Should have failure reason");
    assert(result.failure_reason == "Tracker is down temporarily",
           "Failure reason should match");

    free(result.failure_reason);
}

<*
 Test tracker response parsing with warning message.
 Verifies that optional warning_message is extracted.
*>
fn void test_parse_tracker_response_warning() @test {
    // Build a bencode response with warning
    DString response;
    response.append("d");
    response.append("8:intervali1800e");
    response.append("15:warning message27:Tracker will shut down soone");
    response.append("5:peers0:");  // Empty peers
    response.append("e");

    tracker::TrackerResponse? result_opt = tracker::parse_tracker_response(response.str_view());
    if (catch excuse = result_opt) {
        assert(false, "Should parse response with warning");
        return;
    }

    tracker::TrackerResponse result = result_opt;
    assert(result.warning_message.len > 0, "Should have warning message");
    assert(result.warning_message == "Tracker will shut down soon",
           "Warning message should match");

    free(result.warning_message);
}

<*
 Test URL building includes the full path.
 This is a regression test for the bug where the path was incorrectly stripped.
*>
fn void test_build_announce_url_preserves_path() @test {
    char[20] info_hash;
    char[20] peer_id;

    // Initialize with simple values
    for (usz i = 0; i < 20; i++) {
        info_hash[i] = (char)i;
        peer_id[i] = (char)('A' + i);
    }

    // Test with HTTPS tracker that has /announce path
    String url = tracker::build_announce_url(
        "https://torrent.ubuntu.com/announce",
        &info_hash,
        &peer_id,
        6881,
        0,
        0,
        1000000,
        "started",
        50  // numwant
    );
    defer free(url);

    // The URL should contain the full path
    assert(url.starts_with("https://torrent.ubuntu.com/announce?"),
           "URL should preserve the /announce path");

    // Should not have scheme://host appearing twice
    usz first_https = url.index_of("https://") ?? 0;
    usz second_https = url[first_https + 8..].index_of("https://") ?? url.len;
    assert(second_https == url.len, "Scheme should appear only once");
}

<*
 Test URL building with tracker that has deeper path.
*>
fn void test_build_announce_url_deep_path() @test {
    char[20] info_hash;
    char[20] peer_id;

    for (usz i = 0; i < 20; i++) {
        info_hash[i] = (char)i;
        peer_id[i] = (char)('X');
    }

    String url = tracker::build_announce_url(
        "http://tracker.example.com/path/to/announce",
        &info_hash,
        &peer_id,
        6881,
        0,
        0,
        1000,
        "",
        50  // numwant
    );
    defer free(url);

    assert(url.starts_with("http://tracker.example.com/path/to/announce?"),
           "URL should preserve full path");
    assert(url.contains("info_hash="), "URL should have info_hash");
}

<*
 Test URL building with non-standard port.
*>
fn void test_build_announce_url_custom_port() @test {
    char[20] info_hash;
    char[20] peer_id;

    for (usz i = 0; i < 20; i++) {
        info_hash[i] = 0;
        peer_id[i] = 0;
    }

    String url = tracker::build_announce_url(
        "http://tracker.example.com:8080/announce",
        &info_hash,
        &peer_id,
        6881,
        0,
        0,
        1000,
        "",
        50  // numwant
    );
    defer free(url);

    // Should preserve both port and path
    assert(url.starts_with("http://tracker.example.com:8080/announce?"),
           "URL should preserve port and path");
}

<*
 Test CORRECT path extraction from announce URL.
 The path should include the full path from the URL, not just the query string.

 This is currently BROKEN - the announce() function incorrectly extracts the path.
 Expected to FAIL until the bug is fixed.
*>
fn void test_correct_path_extraction_from_announce_url() @test {
    // Simulate what happens in announce() function
    String tracker_url = "https://torrent.ubuntu.com/announce";

    char[20] info_hash;
    char[20] peer_id;
    for (usz i = 0; i < 20; i++) {
        info_hash[i] = (char)i;
        peer_id[i] = (char)('A' + i);
    }

    String announce_url = tracker::build_announce_url(
        tracker_url,
        &info_hash,
        &peer_id,
        6881,
        0, 0, 1000,
        "started",
        50  // numwant
    );
    defer free(announce_url);

    // Extract path the CORRECT way (using URL parser)
    Url? parsed = url::parse(mem, announce_url);
    if (catch err = parsed) {
        assert(false, "Should parse URL");
        return;
    }
    defer parsed.free();

    DString correct_path;
    correct_path.append(parsed.path);
    if (parsed.query.len > 0) {
        correct_path.append_char('?');
        correct_path.append(parsed.query);
    }

    io::printfn("Original tracker URL: %s", tracker_url);
    io::printfn("Full announce URL: %s", announce_url);
    io::printfn("Correct path+query: '%s'", correct_path.str_view());

    // The path SHOULD start with /announce?
    assert(correct_path.str_view().starts_with("/announce?"),
           "Path should start with /announce?");

    // Should contain the query parameters
    assert(correct_path.str_view().contains("info_hash="),
           "Path should contain query parameters");

    // Should NOT start with just '?'
    assert(correct_path.str_view()[0] != '?',
           "Path should not start with '?' - it needs the /announce part");
}

<*
 * BEP 31: Test parsing retry_in as integer (minutes).
 * Verifies that integer retry_in values are parsed correctly.
 *>
fn void test_parse_retry_in_integer() @test {
    // Build a bencode response with retry_in as integer
    DString response;
    response.append("d");
    response.append("8:intervali1800e");
    response.append("8:retry ini5e");  // retry in 5 minutes
    response.append("5:peers0:");  // Empty peers
    response.append("e");

    tracker::TrackerResponse? result_opt = tracker::parse_tracker_response(response.str_view());
    if (catch excuse = result_opt) {
        assert(false, "Should parse response with retry_in integer");
        return;
    }

    tracker::TrackerResponse result = result_opt;
    assert(result.retry_in_minutes == 5, "retry_in should be 5 minutes");
    assert(result.interval == 1800, "Interval should be 1800");

    // Cleanup
    if (result.peers.len > 0) free(result.peers);
    if (result.failure_reason.len > 0) free(result.failure_reason);
    if (result.warning_message.len > 0) free(result.warning_message);
}

<*
 * BEP 31: Test parsing retry_in as string "never".
 * Verifies that the special "never" value is parsed as -1.
 *>
fn void test_parse_retry_in_never() @test {
    // Build a bencode response with retry_in: "never"
    DString response;
    response.append("d");
    response.append("8:intervali1800e");
    response.append("8:retry in5:nevere");  // retry in: "never"
    response.append("5:peers0:");  // Empty peers
    response.append("e");

    tracker::TrackerResponse? result_opt = tracker::parse_tracker_response(response.str_view());
    if (catch excuse = result_opt) {
        assert(false, "Should parse response with retry_in 'never'");
        return;
    }

    tracker::TrackerResponse result = result_opt;
    assert(result.retry_in_minutes == -1, "retry_in 'never' should be -1");
    assert(result.interval == 1800, "Interval should be 1800");

    // Cleanup
    if (result.peers.len > 0) free(result.peers);
    if (result.failure_reason.len > 0) free(result.failure_reason);
    if (result.warning_message.len > 0) free(result.warning_message);
}

<*
 * BEP 31: Test parsing when retry_in field is missing.
 * Verifies that missing retry_in defaults to 0.
 *>
fn void test_parse_retry_in_missing() @test {
    // Build a bencode response without retry_in field
    DString response;
    response.append("d");
    response.append("8:intervali1800e");
    response.append("5:peers0:");  // Empty peers
    response.append("e");

    tracker::TrackerResponse? result_opt = tracker::parse_tracker_response(response.str_view());
    if (catch excuse = result_opt) {
        assert(false, "Should parse response without retry_in");
        return;
    }

    tracker::TrackerResponse result = result_opt;
    assert(result.retry_in_minutes == 0, "retry_in should default to 0 when missing");
    assert(result.interval == 1800, "Interval should be 1800");

    // Cleanup
    if (result.peers.len > 0) free(result.peers);
    if (result.failure_reason.len > 0) free(result.failure_reason);
    if (result.warning_message.len > 0) free(result.warning_message);
}

<*
 * BEP 31: Test parsing retry_in as zero (retry immediately).
 * Verifies that zero value is handled correctly.
 *>
fn void test_parse_retry_in_zero() @test {
    // Build a bencode response with retry_in: 0
    DString response;
    response.append("d");
    response.append("8:intervali1800e");
    response.append("8:retry ini0e");  // retry in 0 minutes (immediate)
    response.append("5:peers0:");  // Empty peers
    response.append("e");

    tracker::TrackerResponse? result_opt = tracker::parse_tracker_response(response.str_view());
    if (catch excuse = result_opt) {
        assert(false, "Should parse response with retry_in 0");
        return;
    }

    tracker::TrackerResponse result = result_opt;
    assert(result.retry_in_minutes == 0, "retry_in should be 0");
    assert(result.interval == 1800, "Interval should be 1800");

    // Cleanup
    if (result.peers.len > 0) free(result.peers);
    if (result.failure_reason.len > 0) free(result.failure_reason);
    if (result.warning_message.len > 0) free(result.warning_message);
}

<*
 * BEP 31: Test parsing retry_in with failure_reason.
 * Verifies that retry_in is parsed even when failure_reason is present.
 *>
fn void test_parse_retry_in_with_failure() @test {
    // Build a bencode failure response with retry_in
    DString response;
    response.append("d");
    response.append("14:failure reason20:Too many connections");
    response.append("8:retry ini10e");  // retry in 10 minutes
    response.append("e");

    tracker::TrackerResponse? result_opt = tracker::parse_tracker_response(response.str_view());
    if (catch excuse = result_opt) {
        assert(false, "Should parse failure response with retry_in");
        return;
    }

    tracker::TrackerResponse result = result_opt;
    assert(result.failure_reason.len > 0, "Should have failure reason");
    assert(result.failure_reason == "Too many connections", "Failure reason should match");
    assert(result.retry_in_minutes == 10, "retry_in should be 10 minutes");

    // Cleanup
    if (result.failure_reason.len > 0) free(result.failure_reason);
}
