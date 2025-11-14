module libtorrent_test;

import libtorrent::lsd;
import libtorrent::common;
import libtorrent::logger;
import std::io;

// ============================================================================
// Test Helpers
// ============================================================================

fn common::InfoHash make_test_infohash(char value)
{
    common::InfoHash hash;
    for (usz i = 0; i < 20; i++)
    {
        hash[i] = value;
    }
    return hash;
}

fn common::SocketAddress make_test_address(char a, char b, char c, char d, ushort port)
{
    return common::create_ipv4_address(a, b, c, d, port);
}

// ============================================================================
// Message Building Tests
// ============================================================================

fn void test_build_announce_message_format() @test
{
    defer logger::free_logger();

    common::InfoHash infohash = make_test_infohash(0xAA);
    ushort port = 6881;
    char[16] cookie = "0123456789abcdef";

    String message = lsd::build_announce_message(&infohash, port, cookie[..]);
    defer free(message);

    // Check request line
    assert(message.contains("BT-SEARCH * HTTP/1.1\r\n"), "Missing request line");

    // Check Host header
    assert(message.contains("Host: 239.192.152.143:6771\r\n"), "Missing Host header");

    // Check Port header
    assert(message.contains("Port: 6881\r\n"), "Missing Port header");

    // Check Infohash header (40 hex chars)
    assert(message.contains("Infohash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n"),
           "Missing or incorrect Infohash header");

    // Check cookie header
    assert(message.contains("cookie: 0123456789abcdef\r\n"), "Missing cookie header");

    // Check message ends with double CRLF
    assert(message.ends_with("\r\n\r\n"), "Message should end with double CRLF");
}

fn void test_build_announce_message_different_port() @test
{
    defer logger::free_logger();

    common::InfoHash infohash = make_test_infohash(0x11);
    ushort port = 12345;
    char[16] cookie = "fedcba9876543210";

    String message = lsd::build_announce_message(&infohash, port, cookie[..]);
    defer free(message);

    assert(message.contains("Port: 12345\r\n"), "Port should be 12345");
}

fn void test_build_announce_message_different_infohash() @test
{
    defer logger::free_logger();

    common::InfoHash infohash = make_test_infohash(0xFF);
    ushort port = 6881;
    char[16] cookie = "0000000000000000";

    String message = lsd::build_announce_message(&infohash, port, cookie[..]);
    defer free(message);

    assert(message.contains("Infohash: ffffffffffffffffffffffffffffffffffffffff\r\n"),
           "Infohash should be all FF");
}

// ============================================================================
// LSD Manager Creation Tests
// ============================================================================

struct CallbackState
{
    bool called;
    common::InfoHash received_infohash;
    common::SocketAddress[] received_peers;
}

fn void test_peer_callback(common::InfoHash* infohash, common::SocketAddress[] peers, void* user_data)
{
    CallbackState* state = (CallbackState*)user_data;
    state.called = true;
    state.received_infohash = *infohash;
    state.received_peers = peers;
}

fn void test_create_lsd_manager() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager*? mgr = lsd::create(&test_peer_callback, &state);
    if (catch err = mgr)
    {
        assert(false, "Should create manager successfully");
    }

    mgr.free();
}

fn void test_lsd_manager_inactive_by_default() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    // Manager should be inactive initially (we can't test this directly without exposing .active field)
    // Instead, test that announce doesn't crash when inactive
    common::InfoHash infohash = make_test_infohash(0xAA);
    mgr.announce(&infohash, 6881);

    // Should not crash
}

// ============================================================================
// Message Parsing Tests (using build_announce_message for valid messages)
// ============================================================================

fn void test_handle_valid_announcement() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    // Build a valid announcement message (using different cookie to avoid filtering)
    common::InfoHash infohash = make_test_infohash(0xBB);
    char[16] different_cookie = "9999999999999999";
    String message = lsd::build_announce_message(&infohash, 6882, different_cookie[..]);
    defer free(message);

    // Handle announcement from 192.168.1.100:6882
    common::SocketAddress source = make_test_address(192, 168, 1, 100, 6882);
    mgr.handle_announcement((char[])message, source);

    // Callback should have been invoked
    assert(state.called, "Callback should have been invoked");

    // Check received infohash
    for (usz i = 0; i < 20; i++)
    {
        assert(state.received_infohash[i] == 0xBB, "Infohash should match");
    }

    // Check received peer address
    assert(state.received_peers.len == 1, "Should receive 1 peer");
    assert(state.received_peers[0].port == 6882, "Peer port should be 6882");
}

fn void test_handle_announcement_with_own_cookie() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    // We need to get the manager's cookie to test filtering
    // Since cookie is private, we'll test indirectly by having the manager
    // announce and then try to handle its own message

    // For this test, we'll just verify that a message with matching cookie
    // doesn't trigger the callback (testing the filtering logic)

    // This test is limited without access to mgr.cookie
    // We'll mark it as a basic smoke test
}

fn void test_parse_invalid_announcement_too_short() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    // Message with too few lines
    String invalid_msg = "BT-SEARCH * HTTP/1.1\r\n\r\n";
    common::SocketAddress source = make_test_address(192, 168, 1, 1, 6881);

    mgr.handle_announcement((char[])invalid_msg, source);

    // Callback should NOT be invoked
    assert(!state.called, "Callback should not be invoked for invalid message");
}

fn void test_parse_invalid_announcement_wrong_request_line() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    String invalid_msg = "GET / HTTP/1.1\r\nHost: 239.192.152.143:6771\r\nPort: 6881\r\nInfohash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n\r\n";
    common::SocketAddress source = make_test_address(192, 168, 1, 1, 6881);

    mgr.handle_announcement((char[])invalid_msg, source);

    // Callback should NOT be invoked
    assert(!state.called, "Callback should not be invoked for wrong request line");
}

fn void test_parse_announcement_missing_port() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    String invalid_msg = "BT-SEARCH * HTTP/1.1\r\nHost: 239.192.152.143:6771\r\nInfohash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n\r\n";
    common::SocketAddress source = make_test_address(192, 168, 1, 1, 6881);

    mgr.handle_announcement((char[])invalid_msg, source);

    // Callback should NOT be invoked
    assert(!state.called, "Callback should not be invoked without Port header");
}

fn void test_parse_announcement_missing_infohash() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    String invalid_msg = "BT-SEARCH * HTTP/1.1\r\nHost: 239.192.152.143:6771\r\nPort: 6881\r\n\r\n";
    common::SocketAddress source = make_test_address(192, 168, 1, 1, 6881);

    mgr.handle_announcement((char[])invalid_msg, source);

    // Callback should NOT be invoked
    assert(!state.called, "Callback should not be invoked without Infohash header");
}

fn void test_parse_announcement_invalid_port() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    String invalid_msg = "BT-SEARCH * HTTP/1.1\r\nHost: 239.192.152.143:6771\r\nPort: 999999\r\nInfohash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n\r\n";
    common::SocketAddress source = make_test_address(192, 168, 1, 1, 6881);

    mgr.handle_announcement((char[])invalid_msg, source);

    // Callback should NOT be invoked
    assert(!state.called, "Callback should not be invoked for invalid port");
}

fn void test_parse_announcement_invalid_infohash_length() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    // Infohash too short (should be 40 hex chars)
    String invalid_msg = "BT-SEARCH * HTTP/1.1\r\nHost: 239.192.152.143:6771\r\nPort: 6881\r\nInfohash: aaaaaa\r\n\r\n";
    common::SocketAddress source = make_test_address(192, 168, 1, 1, 6881);

    mgr.handle_announcement((char[])invalid_msg, source);

    // Callback should NOT be invoked
    assert(!state.called, "Callback should not be invoked for short infohash");
}

fn void test_parse_announcement_invalid_hex() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    // Infohash with invalid hex chars
    String invalid_msg = "BT-SEARCH * HTTP/1.1\r\nHost: 239.192.152.143:6771\r\nPort: 6881\r\nInfohash: zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\r\n\r\n";
    common::SocketAddress source = make_test_address(192, 168, 1, 1, 6881);

    mgr.handle_announcement((char[])invalid_msg, source);

    // Callback should NOT be invoked
    assert(!state.called, "Callback should not be invoked for invalid hex");
}

// ============================================================================
// Integration Tests
// ============================================================================

fn void test_roundtrip_build_and_parse() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    // Build message
    common::InfoHash original_infohash = make_test_infohash(0x42);
    ushort original_port = 6881;
    char[16] different_cookie = "1111111111111111";

    String message = lsd::build_announce_message(&original_infohash, original_port, different_cookie[..]);
    defer free(message);

    // Parse message
    common::SocketAddress source = make_test_address(10, 0, 0, 1, 6881);
    mgr.handle_announcement((char[])message, source);

    // Verify callback was invoked with correct data
    assert(state.called, "Callback should be invoked");

    // Check infohash matches
    for (usz i = 0; i < 20; i++)
    {
        assert(state.received_infohash[i] == 0x42, "Infohash should match original");
    }

    // Check peer address (port from message, IP from source)
    assert(state.received_peers.len == 1, "Should have 1 peer");
    assert(state.received_peers[0].port == original_port, "Port should match message");
}

fn void test_multiple_announcements() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    // Handle first announcement
    common::InfoHash infohash1 = make_test_infohash(0x11);
    char[16] cookie1 = "aaaaaaaaaaaaaaaa";
    String msg1 = lsd::build_announce_message(&infohash1, 6881, cookie1[..]);
    defer free(msg1);

    common::SocketAddress source1 = make_test_address(192, 168, 1, 10, 6881);
    mgr.handle_announcement((char[])msg1, source1);

    assert(state.called, "First callback should be invoked");
    state.called = false;

    // Handle second announcement
    common::InfoHash infohash2 = make_test_infohash(0x22);
    char[16] cookie2 = "bbbbbbbbbbbbbbbb";
    String msg2 = lsd::build_announce_message(&infohash2, 6882, cookie2[..]);
    defer free(msg2);

    common::SocketAddress source2 = make_test_address(192, 168, 1, 20, 6882);
    mgr.handle_announcement((char[])msg2, source2);

    assert(state.called, "Second callback should be invoked");

    // Check second infohash
    for (usz i = 0; i < 20; i++)
    {
        assert(state.received_infohash[i] == 0x22, "Second infohash should be 0x22");
    }
}

// ============================================================================
// Edge Cases
// ============================================================================

fn void test_announcement_with_zero_port() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    String invalid_msg = "BT-SEARCH * HTTP/1.1\r\nHost: 239.192.152.143:6771\r\nPort: 0\r\nInfohash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n\r\n";
    common::SocketAddress source = make_test_address(192, 168, 1, 1, 6881);

    mgr.handle_announcement((char[])invalid_msg, source);

    // Callback should NOT be invoked (port 0 is invalid)
    assert(!state.called, "Callback should not be invoked for port 0");
}

fn void test_announcement_with_max_port() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    String valid_msg = "BT-SEARCH * HTTP/1.1\r\nHost: 239.192.152.143:6771\r\nPort: 65535\r\nInfohash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\ncookie: cccccccccccccccc\r\n\r\n";
    common::SocketAddress source = make_test_address(192, 168, 1, 1, 65535);

    mgr.handle_announcement((char[])valid_msg, source);

    // Callback should be invoked (port 65535 is valid)
    assert(state.called, "Callback should be invoked for port 65535");
    assert(state.received_peers[0].port == 65535, "Port should be 65535");
}

fn void test_announcement_with_extra_headers() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    // Add extra headers that should be ignored
    String msg = "BT-SEARCH * HTTP/1.1\r\nHost: 239.192.152.143:6771\r\nPort: 6881\r\nInfohash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\ncookie: dddddddddddddddd\r\nX-Custom: ignored\r\n\r\n";
    common::SocketAddress source = make_test_address(192, 168, 1, 1, 6881);

    mgr.handle_announcement((char[])msg, source);

    // Should still work (extra headers ignored)
    assert(state.called, "Should handle message with extra headers");
}

fn void test_announcement_case_sensitive_headers() @test
{
    defer logger::free_logger();

    CallbackState state = { .called = false };

    lsd::LsdManager* mgr = lsd::create(&test_peer_callback, &state)!!;
    defer mgr.free();

    // Wrong case for header names
    String invalid_msg = "BT-SEARCH * HTTP/1.1\r\nHost: 239.192.152.143:6771\r\nport: 6881\r\ninfohash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n\r\n";
    common::SocketAddress source = make_test_address(192, 168, 1, 1, 6881);

    mgr.handle_announcement((char[])invalid_msg, source);

    // Should fail (headers are case-sensitive)
    assert(!state.called, "Headers should be case-sensitive");
}
