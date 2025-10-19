module libtorrent::udp_tracker_test;
import libtorrent::udp_tracker;
import std::io;

<*
 Test network byte order conversion for 32-bit integers.
*>
fn void test_htonl_ntohl() @test {
    // Test known values
    int host_value = 0x12345678;
    int net_value = udp_tracker::htonl(host_value);
    int back_to_host = udp_tracker::ntohl(net_value);

    assert(back_to_host == host_value, "Round-trip conversion should preserve value");

    // Test that big-endian byte order is correct
    char* bytes = (char*)&net_value;
    // In network byte order (big-endian), most significant byte comes first
    assert(bytes[0] == (char)0x12, "First byte should be 0x12");
    assert(bytes[1] == (char)0x34, "Second byte should be 0x34");
    assert(bytes[2] == (char)0x56, "Third byte should be 0x56");
    assert(bytes[3] == (char)0x78, "Fourth byte should be 0x78");
}

<*
 Test network byte order conversion for 16-bit integers.
*>
fn void test_htons_ntohs() @test {
    ushort host_value = 0x1234;
    ushort net_value = udp_tracker::htons(host_value);
    ushort back_to_host = udp_tracker::ntohs(net_value);

    assert(back_to_host == host_value, "Round-trip conversion should preserve value");

    // Test that big-endian byte order is correct
    char* bytes = (char*)&net_value;
    assert(bytes[0] == (char)0x12, "First byte should be 0x12");
    assert(bytes[1] == (char)0x34, "Second byte should be 0x34");
}

<*
 Test network byte order conversion for 64-bit integers.
*>
fn void test_htonll_ntohll() @test {
    long host_value = 0x123456789ABCDEF0L;
    long net_value = udp_tracker::htonll(host_value);
    long back_to_host = udp_tracker::ntohll(net_value);

    assert(back_to_host == host_value, "Round-trip conversion should preserve value");

    // Test that big-endian byte order is correct
    char* bytes = (char*)&net_value;
    assert(bytes[0] == (char)0x12, "Byte 0 should be 0x12");
    assert(bytes[1] == (char)0x34, "Byte 1 should be 0x34");
    assert(bytes[2] == (char)0x56, "Byte 2 should be 0x56");
    assert(bytes[3] == (char)0x78, "Byte 3 should be 0x78");
    assert(bytes[4] == (char)0x9A, "Byte 4 should be 0x9A");
    assert(bytes[5] == (char)0xBC, "Byte 5 should be 0xBC");
    assert(bytes[6] == (char)0xDE, "Byte 6 should be 0xDE");
    assert(bytes[7] == (char)0xF0, "Byte 7 should be 0xF0");
}

<*
 Test packing connect request.
*>
fn void test_pack_connect_request() @test {
    char[16] buffer;
    int transaction_id = 0x12345678;

    udp_tracker::pack_connect_request(transaction_id, buffer[..]);

    // Check protocol_id (first 8 bytes)
    // 0x41727101980 = 0x0000000417 27101980
    assert(buffer[0] == (char)0x00, "Protocol ID byte 0");
    assert(buffer[1] == (char)0x00, "Protocol ID byte 1");
    assert(buffer[2] == (char)0x04, "Protocol ID byte 2");
    assert(buffer[3] == (char)0x17, "Protocol ID byte 3");
    assert(buffer[4] == (char)0x27, "Protocol ID byte 4");
    assert(buffer[5] == (char)0x10, "Protocol ID byte 5");
    assert(buffer[6] == (char)0x19, "Protocol ID byte 6");
    assert(buffer[7] == (char)0x80, "Protocol ID byte 7");

    // Check action (bytes 8-11, should be 0 for connect)
    assert(buffer[8] == (char)0x00, "Action byte 0");
    assert(buffer[9] == (char)0x00, "Action byte 1");
    assert(buffer[10] == (char)0x00, "Action byte 2");
    assert(buffer[11] == (char)0x00, "Action byte 3");

    // Check transaction_id (bytes 12-15)
    assert(buffer[12] == (char)0x12, "Transaction ID byte 0");
    assert(buffer[13] == (char)0x34, "Transaction ID byte 1");
    assert(buffer[14] == (char)0x56, "Transaction ID byte 2");
    assert(buffer[15] == (char)0x78, "Transaction ID byte 3");
}

<*
 Test unpacking connect response.
*>
fn void test_unpack_connect_response() @test {
    // Simulate a valid connect response
    char[16] buffer = {
        // action = 0 (connect)
        0x00, 0x00, 0x00, 0x00,
        // transaction_id = 0x12345678
        0x12, 0x34, 0x56, 0x78,
        // connection_id = 0x1234567890ABCDEF
        0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF
    };

    udp_tracker::ConnectResponse? response_opt = udp_tracker::unpack_connect_response(buffer[..]);
    if (catch excuse = response_opt) {
        assert(false, "Should successfully unpack valid response");
        return;
    }

    udp_tracker::ConnectResponse response = response_opt;
    assert(response.action == 0, "Action should be 0");
    assert(response.transaction_id == 0x12345678, "Transaction ID should match");
    assert(response.connection_id == 0x1234567890ABCDEFL, "Connection ID should match");
}

<*
 Test unpacking connect response with invalid buffer size.
*>
fn void test_unpack_connect_response_invalid_size() @test {
    char[10] buffer;  // Too small

    udp_tracker::ConnectResponse? response = udp_tracker::unpack_connect_response(buffer[..]);
    if (catch excuse = response) {
        // Expected failure - test passes
    } else {
        assert(false, "Should fail with buffer too small");
    }
}

<*
 Test unpacking error response.
*>
fn void test_unpack_connect_response_error() @test {
    // Simulate an error response (action = 3)
    char[16] buffer = {
        // action = 3 (error)
        0x00, 0x00, 0x00, 0x03,
        // transaction_id
        0x12, 0x34, 0x56, 0x78,
        // padding
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    };

    udp_tracker::ConnectResponse? response = udp_tracker::unpack_connect_response(buffer[..]);
    if (catch excuse = response) {
        // Expected failure - should detect error response
        assert(excuse == udp_tracker::UDP_TRACKER_PROTOCOL_ERROR, "Should return protocol error");
    } else {
        assert(false, "Should fail when action indicates error");
    }
}

<*
 Test packing announce request.
*>
fn void test_pack_announce_request() @test {
    udp_tracker::AnnounceRequest request;
    request.connection_id = 0x123456789ABCDEF0L;
    request.action = udp_tracker::ACTION_ANNOUNCE;
    request.transaction_id = 0x11223344;

    // Set info_hash
    for (usz i = 0; i < 20; i++) {
        request.info_hash[i] = (char)i;
    }

    // Set peer_id
    for (usz i = 0; i < 20; i++) {
        request.peer_id[i] = (char)(20 + i);
    }

    request.downloaded = 1000;
    request.left = 5000;
    request.uploaded = 500;
    request.event = udp_tracker::EVENT_STARTED;
    request.ip_address = 0;
    request.key = 0x55667788;
    request.num_want = 50;
    request.port = 6881;

    char[98] buffer;
    udp_tracker::pack_announce_request(&request, buffer[..]);

    // Verify connection_id (first 8 bytes)
    assert(buffer[0] == (char)0x12, "Connection ID byte 0");
    assert(buffer[1] == (char)0x34, "Connection ID byte 1");
    assert(buffer[2] == (char)0x56, "Connection ID byte 2");
    assert(buffer[3] == (char)0x78, "Connection ID byte 3");
    assert(buffer[4] == (char)0x9A, "Connection ID byte 4");
    assert(buffer[5] == (char)0xBC, "Connection ID byte 5");
    assert(buffer[6] == (char)0xDE, "Connection ID byte 6");
    assert(buffer[7] == (char)0xF0, "Connection ID byte 7");

    // Verify action (bytes 8-11, should be 1 for announce)
    assert(buffer[8] == (char)0x00, "Action byte 0");
    assert(buffer[9] == (char)0x00, "Action byte 1");
    assert(buffer[10] == (char)0x00, "Action byte 2");
    assert(buffer[11] == (char)0x01, "Action byte 3");

    // Verify transaction_id (bytes 12-15)
    assert(buffer[12] == (char)0x11, "Transaction ID byte 0");
    assert(buffer[13] == (char)0x22, "Transaction ID byte 1");
    assert(buffer[14] == (char)0x33, "Transaction ID byte 2");
    assert(buffer[15] == (char)0x44, "Transaction ID byte 3");

    // Verify info_hash (bytes 16-35)
    for (usz i = 0; i < 20; i++) {
        assert(buffer[16 + i] == (char)i, "Info hash should match");
    }

    // Verify peer_id (bytes 36-55)
    for (usz i = 0; i < 20; i++) {
        assert(buffer[36 + i] == (char)(20 + i), "Peer ID should match");
    }

    // Verify port (last 2 bytes, bytes 96-97)
    // Port 6881 = 0x1AE1 in network byte order
    assert(buffer[96] == (char)0x1A, "Port byte 0 should be 0x1A");
    assert(buffer[97] == (char)0xE1, "Port byte 1 should be 0xE1");
}

<*
 Test unpacking announce response.
*>
fn void test_unpack_announce_response() @test {
    // Simulate an announce response with 2 peers
    char[] buffer = {
        // action = 1 (announce)
        0x00, 0x00, 0x00, 0x01,
        // transaction_id = 0x12345678
        0x12, 0x34, 0x56, 0x78,
        // interval = 1800 seconds
        0x00, 0x00, 0x07, 0x08,
        // leechers = 10
        0x00, 0x00, 0x00, 0x0A,
        // seeders = 50
        0x00, 0x00, 0x00, 0x32,
        // Peer 1: 192.168.1.1:6881
        192, 168, 1, 1, 0x1A, 0xE1,
        // Peer 2: 10.0.0.1:51413
        10, 0, 0, 1, 0xC8, 0xD5
    };

    char[] peers;
    udp_tracker::AnnounceResponse? response_opt = udp_tracker::unpack_announce_response(buffer, &peers);
    if (catch excuse = response_opt) {
        assert(false, "Should successfully unpack valid response");
        return;
    }

    udp_tracker::AnnounceResponse response = response_opt;
    assert(response.action == 1, "Action should be 1");
    assert(response.transaction_id == 0x12345678, "Transaction ID should match");
    assert(response.interval == 1800, "Interval should be 1800");
    assert(response.leechers == 10, "Leechers should be 10");
    assert(response.seeders == 50, "Seeders should be 50");

    // Verify peer data
    assert(peers.len == 12, "Should have 12 bytes of peer data (2 peers)");
    assert(peers[0] == (char)192, "Peer 1 IP byte 0");
    assert(peers[1] == (char)168, "Peer 1 IP byte 1");
    assert(peers[2] == (char)1, "Peer 1 IP byte 2");
    assert(peers[3] == (char)1, "Peer 1 IP byte 3");
}

<*
 Test unpacking announce response with no peers.
*>
fn void test_unpack_announce_response_no_peers() @test {
    // Announce response with no peers (exactly 20 bytes)
    char[20] buffer = {
        // action = 1
        0x00, 0x00, 0x00, 0x01,
        // transaction_id
        0xAA, 0xBB, 0xCC, 0xDD,
        // interval = 1800
        0x00, 0x00, 0x07, 0x08,
        // leechers = 0
        0x00, 0x00, 0x00, 0x00,
        // seeders = 0
        0x00, 0x00, 0x00, 0x00
    };

    char[] peers;
    udp_tracker::AnnounceResponse? response_opt = udp_tracker::unpack_announce_response(buffer[..], &peers);
    if (catch excuse = response_opt) {
        assert(false, "Should successfully unpack response with no peers");
        return;
    }

    udp_tracker::AnnounceResponse response = response_opt;
    assert(response.interval == 1800, "Interval should be 1800");
    assert(peers.len == 0, "Should have no peer data");
}

<*
 Test transaction ID generation.
*>
fn void test_generate_transaction_id() @test {
    int tid1 = udp_tracker::generate_transaction_id();
    int tid2 = udp_tracker::generate_transaction_id();

    // Transaction IDs should be generated (we can't test randomness,
    // but we can verify they're valid integers)
    // Just verify the function doesn't crash
}
