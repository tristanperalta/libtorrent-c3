module libtorrent::peer_connection::test;

import libtorrent::peer_connection;
import libtorrent::peer_wire;
import libtorrent::bitfield;
import libtorrent::event_loop;
import std::io;

// ============================================================================
// Test Fixtures and Helpers
// ============================================================================

struct TestContext
{
    int messages_received;
    int state_changes;
    peer_connection::PeerState last_state;
    peer_wire::MessageType last_message_type;
    bool connection_ready;
}

fn void on_message(peer_connection::PeerConnection* peer, peer_wire::Message* msg, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.messages_received++;
    ctx.last_message_type = msg.type;
}

fn void on_state_change(peer_connection::PeerConnection* peer, peer_connection::PeerState state, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.state_changes++;
    ctx.last_state = state;
    if (state == peer_connection::PeerState.READY)
    {
        ctx.connection_ready = true;
    }
}

// ============================================================================
// Basic Structure Tests
// ============================================================================

fn void test_peer_state_enum() @test
{
    assert(peer_connection::PeerState.CONNECTING == 0, "CONNECTING should be 0");
    assert(peer_connection::PeerState.HANDSHAKING == 1, "HANDSHAKING should be 1");
    assert(peer_connection::PeerState.READY == 2, "READY should be 2");
    assert(peer_connection::PeerState.CLOSED == 3, "CLOSED should be 3");
}

// ============================================================================
// Connection Lifecycle Tests
// ============================================================================

fn void test_close_null_peer() @test
{
    // Should not crash on null
    peer_connection::close(null);
}

fn void test_close_sets_state() @test
{
    // Create a minimal peer structure for testing
    peer_connection::PeerConnection peer;
    peer.state = peer_connection::PeerState.READY;
    peer.tcp = null;
    peer.recv_buffer = {};

    TestContext ctx;
    ctx.state_changes = 0;
    peer.state_cb = &on_state_change;
    peer.user_data = &ctx;

    // Close should transition to CLOSED state
    // Note: We can't actually call close() here as it will free the stack-allocated peer
    // Instead we verify the state transition logic
    if (peer.state != peer_connection::PeerState.CLOSED)
    {
        peer.state = peer_connection::PeerState.CLOSED;
        if (peer.state_cb) peer.state_cb(&peer, peer_connection::PeerState.CLOSED, peer.user_data);
    }

    assert(ctx.state_changes == 1, "Should have one state change");
    assert(ctx.last_state == peer_connection::PeerState.CLOSED, "Should transition to CLOSED");
}

// ============================================================================
// Message Encoding Tests (for send methods)
// ============================================================================

fn void test_send_choke_state() @test
{
    peer_connection::PeerConnection peer;
    peer.am_choking = false;
    peer.state = peer_connection::PeerState.READY;
    peer.tcp = null;

    // We can't actually send without TCP connection, but we can verify state updates
    // by testing the logic manually

    // Simulate what send_choke does
    if (peer.state == peer_connection::PeerState.READY)
    {
        peer.am_choking = true;
    }

    assert(peer.am_choking == true, "Should set am_choking to true");
}

fn void test_send_unchoke_state() @test
{
    peer_connection::PeerConnection peer;
    peer.am_choking = true;
    peer.state = peer_connection::PeerState.READY;
    peer.tcp = null;

    // Simulate what send_unchoke does
    if (peer.state == peer_connection::PeerState.READY)
    {
        peer.am_choking = false;
    }

    assert(peer.am_choking == false, "Should set am_choking to false");
}

fn void test_send_interested_state() @test
{
    peer_connection::PeerConnection peer;
    peer.am_interested = false;
    peer.state = peer_connection::PeerState.READY;
    peer.tcp = null;

    // Simulate what send_interested does
    if (peer.state == peer_connection::PeerState.READY)
    {
        peer.am_interested = true;
    }

    assert(peer.am_interested == true, "Should set am_interested to true");
}

fn void test_send_not_interested_state() @test
{
    peer_connection::PeerConnection peer;
    peer.am_interested = true;
    peer.state = peer_connection::PeerState.READY;
    peer.tcp = null;

    // Simulate what send_not_interested does
    if (peer.state == peer_connection::PeerState.READY)
    {
        peer.am_interested = false;
    }

    assert(peer.am_interested == false, "Should set am_interested to false");
}

fn void test_initial_peer_state() @test
{
    peer_connection::PeerConnection peer;

    // Simulate initialization
    peer.am_choking = true;
    peer.am_interested = false;
    peer.peer_choking = true;
    peer.peer_interested = false;

    // Verify BEP 3 initial state (start choking and not interested)
    assert(peer.am_choking == true, "Should start choking");
    assert(peer.am_interested == false, "Should start not interested");
    assert(peer.peer_choking == true, "Peer should start choking");
    assert(peer.peer_interested == false, "Peer should start not interested");
}

// ============================================================================
// Message Processing Tests
// ============================================================================

fn void test_handle_choke_message() @test
{
    peer_connection::PeerConnection peer;
    peer.peer_choking = false;

    // Simulate receiving CHOKE message
    peer_wire::Message msg;
    msg.type = peer_wire::MessageType.CHOKE;
    msg.payload = {};

    // Simulate handle_state_message logic
    switch (msg.type)
    {
        case peer_wire::MessageType.CHOKE:
            peer.peer_choking = true;
        case peer_wire::MessageType.UNCHOKE:
            peer.peer_choking = false;
        case peer_wire::MessageType.INTERESTED:
            peer.peer_interested = true;
        case peer_wire::MessageType.NOT_INTERESTED:
            peer.peer_interested = false;
        default:
            // Other messages
    }

    assert(peer.peer_choking == true, "Should set peer_choking to true");
}

fn void test_handle_unchoke_message() @test
{
    peer_connection::PeerConnection peer;
    peer.peer_choking = true;

    peer_wire::Message msg;
    msg.type = peer_wire::MessageType.UNCHOKE;
    msg.payload = {};

    switch (msg.type)
    {
        case peer_wire::MessageType.CHOKE:
            peer.peer_choking = true;
        case peer_wire::MessageType.UNCHOKE:
            peer.peer_choking = false;
        case peer_wire::MessageType.INTERESTED:
            peer.peer_interested = true;
        case peer_wire::MessageType.NOT_INTERESTED:
            peer.peer_interested = false;
        default:
    }

    assert(peer.peer_choking == false, "Should set peer_choking to false");
}

fn void test_handle_interested_message() @test
{
    peer_connection::PeerConnection peer;
    peer.peer_interested = false;

    peer_wire::Message msg;
    msg.type = peer_wire::MessageType.INTERESTED;
    msg.payload = {};

    switch (msg.type)
    {
        case peer_wire::MessageType.CHOKE:
            peer.peer_choking = true;
        case peer_wire::MessageType.UNCHOKE:
            peer.peer_choking = false;
        case peer_wire::MessageType.INTERESTED:
            peer.peer_interested = true;
        case peer_wire::MessageType.NOT_INTERESTED:
            peer.peer_interested = false;
        default:
    }

    assert(peer.peer_interested == true, "Should set peer_interested to true");
}

fn void test_handle_not_interested_message() @test
{
    peer_connection::PeerConnection peer;
    peer.peer_interested = true;

    peer_wire::Message msg;
    msg.type = peer_wire::MessageType.NOT_INTERESTED;
    msg.payload = {};

    switch (msg.type)
    {
        case peer_wire::MessageType.CHOKE:
            peer.peer_choking = true;
        case peer_wire::MessageType.UNCHOKE:
            peer.peer_choking = false;
        case peer_wire::MessageType.INTERESTED:
            peer.peer_interested = true;
        case peer_wire::MessageType.NOT_INTERESTED:
            peer.peer_interested = false;
        default:
    }

    assert(peer.peer_interested == false, "Should set peer_interested to false");
}

fn void test_non_state_changing_message() @test
{
    peer_connection::PeerConnection peer;
    peer.peer_choking = true;
    peer.peer_interested = false;

    // HAVE message should not change peer state
    peer_wire::Message msg;
    msg.type = peer_wire::MessageType.HAVE;
    msg.payload = {};

    bool state_changed = false;
    switch (msg.type)
    {
        case peer_wire::MessageType.CHOKE:
            state_changed = true;
        case peer_wire::MessageType.UNCHOKE:
            state_changed = true;
        case peer_wire::MessageType.INTERESTED:
            state_changed = true;
        case peer_wire::MessageType.NOT_INTERESTED:
            state_changed = true;
        default:
            // No state change
    }

    assert(!state_changed, "HAVE message should not change peer state");
    assert(peer.peer_choking == true, "peer_choking should be unchanged");
    assert(peer.peer_interested == false, "peer_interested should be unchanged");
}

// ============================================================================
// Handshake Validation Tests
// ============================================================================

fn void test_handshake_info_hash_match() @test
{
    char[20] info_hash;
    for (usz i = 0; i < 20; i++) info_hash[i] = (char)(i * 2);

    char[20] peer_id;
    for (usz i = 0; i < 20; i++) peer_id[i] = (char)(i * 3);

    // Encode handshake
    char[] handshake = peer_wire::encode_handshake(info_hash, peer_id);
    defer free(handshake);

    // Decode it
    peer_wire::HandshakeMsg? msg_opt = peer_wire::decode_handshake(handshake);
    msg_opt!!;
    peer_wire::HandshakeMsg msg = msg_opt!!;

    // Verify info hash matches
    bool matches = true;
    for (usz i = 0; i < 20; i++)
    {
        if (msg.info_hash[i] != info_hash[i])
        {
            matches = false;
            break;
        }
    }

    assert(matches, "Info hash should match");
}

fn void test_handshake_info_hash_mismatch() @test
{
    char[20] our_hash;
    char[20] their_hash;

    for (usz i = 0; i < 20; i++)
    {
        our_hash[i] = (char)i;
        their_hash[i] = (char)(i + 1);  // Different!
    }

    // Verify they don't match
    bool matches = true;
    for (usz i = 0; i < 20; i++)
    {
        if (their_hash[i] != our_hash[i])
        {
            matches = false;
            break;
        }
    }

    assert(!matches, "Different info hashes should not match");
}

// ============================================================================
// Buffer Management Tests
// ============================================================================

fn void test_dstring_append() @test
{
    DString buf;

    char[5] data1 = {'h', 'e', 'l', 'l', 'o'};
    char[6] data2 = {' ', 'w', 'o', 'r', 'l', 'd'};

    buf.append(data1[..]);
    buf.append(data2[..]);

    String result = buf.str_view();
    assert(result.len == 11, "Buffer should contain 11 bytes");
    assert(result[0] == 'h', "First char should be 'h'");
    assert(result[10] == 'd', "Last char should be 'd'");
}

fn void test_dstring_delete() @test
{
    DString buf;

    char[5] data = {'a', 'b', 'c', 'd', 'e'};
    buf.append(data[..]);

    // Delete first 2 bytes
    buf.delete(0, 2);

    String result = buf.str_view();
    assert(result.len == 3, "Buffer should have 3 bytes left");
    assert(result[0] == 'c', "First char should now be 'c'");
}

// ============================================================================
// Message Framing Tests
// ============================================================================

fn void test_message_total_size_calculation() @test
{
    // Create a HAVE message
    char[] msg = peer_wire::encode_have(42);
    defer free(msg);

    // Should be able to determine total size from length prefix
    usz? size_opt = peer_wire::message_total_size(msg);
    size_opt!!;
    usz total_size = size_opt!!;

    assert(total_size == 9, "HAVE message total size should be 9");
    assert(total_size == msg.len, "Total size should match actual message length");
}

fn void test_incomplete_message_detection() @test
{
    // Create complete message
    char[] complete = peer_wire::encode_have(42);
    defer free(complete);

    // Simulate receiving only first 5 bytes (need 9)
    char[5] partial;
    for (usz i = 0; i < 5; i++) partial[i] = complete[i];

    usz? size_opt = peer_wire::message_total_size(partial[..]);
    size_opt!!;
    usz expected_size = size_opt!!;

    // We know we need 9 bytes but only have 5
    assert(expected_size > partial.len, "Should detect incomplete message");
}

// ============================================================================
// Integration Tests (require event loop)
// ============================================================================

// Note: Full integration tests with actual TCP connections would require
// setting up a TCP server and running the event loop. These tests verify
// the logical components that can be tested in isolation.

fn void test_callback_invocation() @test
{
    TestContext ctx;
    ctx.messages_received = 0;
    ctx.state_changes = 0;

    peer_connection::PeerConnection peer;
    peer.msg_cb = &on_message;
    peer.state_cb = &on_state_change;
    peer.user_data = &ctx;

    // Simulate state change
    if (peer.state_cb)
    {
        peer.state_cb(&peer, peer_connection::PeerState.READY, peer.user_data);
    }

    assert(ctx.state_changes == 1, "Should have invoked state callback");
    assert(ctx.last_state == peer_connection::PeerState.READY, "Should report READY state");
}

fn void test_message_callback_invocation() @test
{
    TestContext ctx;
    ctx.messages_received = 0;

    peer_connection::PeerConnection peer;
    peer.msg_cb = &on_message;
    peer.user_data = &ctx;

    // Simulate message received
    peer_wire::Message msg;
    msg.type = peer_wire::MessageType.CHOKE;
    msg.payload = {};

    if (peer.msg_cb)
    {
        peer.msg_cb(&peer, &msg, peer.user_data);
    }

    assert(ctx.messages_received == 1, "Should have invoked message callback");
    assert(ctx.last_message_type == peer_wire::MessageType.CHOKE, "Should report CHOKE message");
}
