module libtorrent::tracker_test;
import libtorrent::tracker;
import libtorrent::bencode;
import std::io;

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
        "started"
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
        ""
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

    tracker::Peer[]? peers_opt = tracker::parse_compact_peers(peer_data);
    if (catch excuse = peers_opt) {
        assert(false, "Should parse valid peer data");
        return;
    }

    tracker::Peer[] peers = peers_opt;
    assert(peers.len == 2, "Should parse 2 peers");

    // Check first peer
    assert(peers[0].ip[0] == (char)192, "First peer IP byte 0 should be 192");
    assert(peers[0].ip[1] == (char)168, "First peer IP byte 1 should be 168");
    assert(peers[0].ip[2] == (char)1, "First peer IP byte 2 should be 1");
    assert(peers[0].ip[3] == (char)1, "First peer IP byte 3 should be 1");
    assert(peers[0].port == 6881, "First peer port should be 6881");

    // Check second peer
    assert(peers[1].ip[0] == (char)10, "Second peer IP byte 0 should be 10");
    assert(peers[1].ip[1] == (char)0, "Second peer IP byte 1 should be 0");
    assert(peers[1].ip[2] == (char)0, "Second peer IP byte 2 should be 0");
    assert(peers[1].ip[3] == (char)1, "Second peer IP byte 3 should be 1");
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

    tracker::Peer[]? peers = tracker::parse_compact_peers(peer_data);
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

    tracker::Peer[]? peers_opt = tracker::parse_compact_peers(empty);
    if (catch excuse = peers_opt) {
        assert(false, "Should handle empty data");
        return;
    }

    tracker::Peer[] peers = peers_opt;
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

    free(result.peers);
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
