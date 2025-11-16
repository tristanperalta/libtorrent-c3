module libtorrent::utp::connection_test;

import libtorrent::utp::connection;
import libtorrent::utp::packet;
import libtorrent::utp::common;
import libtorrent::utp::socket;
import libtorrent::common;  // For SocketAddress
import async::event_loop;
import std::io;
import std::time;

// Module alias to distinguish between libtorrent::common and libtorrent::utp::common
alias utp_common = module libtorrent::utp::common;
alias lib_common = module libtorrent::common;

<*
 μTP Connection State Machine Tests
 ===================================

 Tests connection lifecycle, state transitions, and packet processing.
*>

/**
 * Test 1: Create outgoing connection.
 */
fn void test_create_outgoing() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(192, 168, 1, 100, 6881);
    ushort conn_id_seed = 12345;

    UtpConnection* conn = connection::create_outgoing(addr, conn_id_seed);
    defer conn.free();

    // Verify state
    assert(conn.state == ConnectionState.SYN_SENT, "Outgoing connection should start in SYN_SENT");
    assert(conn.is_outgoing, "Should be marked as outgoing");

    // Verify connection IDs (outgoing uses odd recv_id)
    assert((conn.recv_id & 1) == 1, "Outgoing recv_id should be odd");
    assert(conn.send_id == (ushort)(conn.recv_id + 1), "Send ID should be recv_id + 1");

    // Verify remote address
    assert(conn.remote_addr == addr, "Remote address should match");

    // Verify initial window
    assert(conn.local_window == 1024 * 1024, "Local window should be 1MB");

    io::printn("✓ test_create_outgoing");
}

/**
 * Test 2: Create incoming connection from SYN.
 */
fn void test_create_incoming() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(10, 0, 0, 1, 8080);

    // Create a SYN packet header
    packet::UtpHeader syn;
    syn.packet_type = utp_common::ST_SYN;
    syn.version = utp_common::UTP_VERSION;
    syn.extension = 0;
    syn.connection_id = 5000;  // Their send_id
    syn.seq_nr = 100;
    syn.ack_nr = 0;
    syn.wnd_size = 512 * 1024;  // 512KB window
    syn.timestamp_microseconds = 1000000;
    syn.timestamp_difference_microseconds = 0;

    UtpConnection* conn = connection::create_incoming(addr, &syn);
    defer conn.free();

    // Verify state
    assert(conn.state == ConnectionState.CONNECTED, "Incoming connection should be CONNECTED after SYN");
    assert(!conn.is_outgoing, "Should NOT be marked as outgoing");

    // Verify connection IDs
    assert(conn.recv_id == syn.connection_id, "recv_id should match SYN connection_id");
    assert(conn.send_id == (ushort)(conn.recv_id + 1), "send_id should be recv_id + 1");

    // Verify ack_nr matches SYN seq_nr
    assert(conn.ack_nr == syn.seq_nr, "Should ACK the SYN sequence number");

    // Verify remote window
    assert(conn.remote_window == syn.wnd_size, "Remote window should match SYN");

    io::printn("✓ test_create_incoming");
}

/**
 * Test 3: State transition SYN_SENT → CONNECTED.
 */
fn void test_transition_syn_sent_to_connected() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 999);
    defer conn.free();

    assert(conn.state == ConnectionState.SYN_SENT, "Initial state should be SYN_SENT");

    // Transition to connected
    conn.transition_to_connected();

    assert(conn.state == ConnectionState.CONNECTED, "State should be CONNECTED");

    io::printn("✓ test_transition_syn_sent_to_connected");
}

/**
 * Test 4: State transition CONNECTED → FIN_SENT.
 */
fn void test_transition_connected_to_fin_sent() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(192, 168, 0, 1, 9000);
    UtpConnection* conn = connection::create_outgoing(addr, 5555);
    defer conn.free();

    // Move to connected first
    conn.transition_to_connected();
    assert(conn.state == ConnectionState.CONNECTED, "Should be CONNECTED");

    // Transition to FIN_SENT
    conn.transition_to_fin_sent();

    assert(conn.state == ConnectionState.FIN_SENT, "State should be FIN_SENT");

    io::printn("✓ test_transition_connected_to_fin_sent");
}

/**
 * Test 5: State transition to ERROR_WAIT.
 */
fn void test_transition_to_error() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(8, 8, 8, 8, 53);
    UtpConnection* conn = connection::create_outgoing(addr, 7777);
    defer conn.free();

    conn.transition_to_connected();
    assert(conn.state == ConnectionState.CONNECTED, "Should be CONNECTED");

    // Transition to error
    conn.transition_to_error();

    assert(conn.state == ConnectionState.ERROR_WAIT, "State should be ERROR_WAIT");

    io::printn("✓ test_transition_to_error");
}

/**
 * Test 6: State transition to DELETING.
 */
fn void test_transition_to_deleting() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(1, 1, 1, 1, 443);
    UtpConnection* conn = connection::create_outgoing(addr, 8888);
    defer conn.free();

    // Transition to deleting from any state
    conn.transition_to_deleting();

    assert(conn.state == ConnectionState.DELETING, "State should be DELETING");

    io::printn("✓ test_transition_to_deleting");
}

/**
 * Test 7: Process STATE packet (pure ACK).
 */
fn void test_process_state_packet() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(10, 0, 0, 50, 8080);
    UtpConnection* conn = connection::create_outgoing(addr, 1111);
    defer conn.free();

    conn.transition_to_connected();

    // Create a STATE packet
    packet::UtpHeader state;
    state.packet_type = utp_common::ST_STATE;
    state.version = utp_common::UTP_VERSION;
    state.extension = 0;
    state.connection_id = conn.recv_id;  // Must match
    state.seq_nr = 0;
    state.ack_nr = conn.seq_nr;
    state.wnd_size = 256 * 1024;  // 256KB
    state.timestamp_microseconds = 5000000;
    state.timestamp_difference_microseconds = 100;

    // Process first packet
    bool ok = conn.process_packet(&state);
    assert(ok, "STATE packet should be processed successfully");

    // Process 2 more packets with HIGHER delay to create queuing delay
    state.seq_nr++;
    state.timestamp_difference_microseconds = 150;  // 50μs queuing delay
    conn.process_packet(&state);

    state.seq_nr++;
    state.timestamp_difference_microseconds = 120;  // 20μs queuing delay
    conn.process_packet(&state);

    assert(conn.remote_window == state.wnd_size, "Remote window should be updated");
    // their_delay is now tracked in their_hist (LEDBAT Phase 2)
    // delay_hist tracks queuing delay (sample - delay_base)
    // delay_base = 100 (minimum of all samples)
    // Current samples: 100-100=0, 150-100=50, 120-100=20
    // get_value() returns min(0, 50, 20) = 0
    uint delay_value = conn.their_hist.get_value();
    assert(delay_value == 0, "Queuing delay should be 0 (min of recent samples)");

    io::printn("✓ test_process_state_packet");
}

/**
 * Test 8: Process in-order DATA packet.
 */
fn void test_process_data_packet_in_order() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(172, 16, 0, 10, 5000);
    UtpConnection* conn = connection::create_outgoing(addr, 2222);
    defer conn.free();

    conn.transition_to_connected();
    conn.ack_nr = 99;  // Last received seq

    // Create in-order DATA packet (seq = 100)
    packet::UtpHeader data;
    data.packet_type = utp_common::ST_DATA;
    data.version = utp_common::UTP_VERSION;
    data.extension = 0;
    data.connection_id = conn.recv_id;
    data.seq_nr = 100;  // In order: ack_nr + 1
    data.ack_nr = 0;
    data.wnd_size = 128 * 1024;
    data.timestamp_microseconds = 6000000;
    data.timestamp_difference_microseconds = 200;

    // Process packet
    bool ok = conn.process_packet(&data);

    assert(ok, "In-order DATA packet should be accepted");
    assert(conn.ack_nr == 100, "ack_nr should be updated to 100");

    io::printn("✓ test_process_data_packet_in_order");
}

/**
 * Test 9: Process out-of-order DATA packet (should be rejected in Phase 1).
 */
fn void test_process_data_packet_out_of_order() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(192, 0, 2, 1, 7000);
    UtpConnection* conn = connection::create_outgoing(addr, 3333);
    defer conn.free();

    conn.transition_to_connected();
    conn.ack_nr = 50;  // Last received seq

    // Create out-of-order DATA packet (seq = 55, expected 51)
    packet::UtpHeader data;
    data.packet_type = utp_common::ST_DATA;
    data.version = utp_common::UTP_VERSION;
    data.extension = 0;
    data.connection_id = conn.recv_id;
    data.seq_nr = 55;  // Gap: expected 51
    data.ack_nr = 0;
    data.wnd_size = 64 * 1024;
    data.timestamp_microseconds = 7000000;
    data.timestamp_difference_microseconds = 300;

    // Process packet
    bool ok = conn.process_packet(&data);

    assert(!ok, "Out-of-order DATA packet should be rejected in Phase 1");
    assert(conn.ack_nr == 50, "ack_nr should NOT be updated");

    io::printn("✓ test_process_data_packet_out_of_order");
}

/**
 * Test 10: Process FIN packet.
 */
fn void test_process_fin_packet() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(198, 51, 100, 1, 9999);
    UtpConnection* conn = connection::create_outgoing(addr, 4444);
    defer conn.free();

    conn.transition_to_connected();
    conn.ack_nr = 200;

    // Create FIN packet
    packet::UtpHeader fin;
    fin.packet_type = utp_common::ST_FIN;
    fin.version = utp_common::UTP_VERSION;
    fin.extension = 0;
    fin.connection_id = conn.recv_id;
    fin.seq_nr = 201;
    fin.ack_nr = 0;
    fin.wnd_size = 0;
    fin.timestamp_microseconds = 8000000;
    fin.timestamp_difference_microseconds = 400;

    // Process packet
    bool ok = conn.process_packet(&fin);

    assert(ok, "FIN packet should be processed");
    // With empty buffer and both FINs ready, transitions to DELETING
    assert(conn.state == ConnectionState.DELETING, "State should transition to DELETING");
    assert(conn.ack_nr == 201, "Should ACK the FIN");
    assert(conn.remote_fin_received, "Should mark remote FIN received");
    assert(conn.fin_sent, "Should mark our FIN sent");

    io::printn("✓ test_process_fin_packet");
}

/**
 * Test 11: Process RESET packet.
 */
fn void test_process_reset_packet() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(203, 0, 113, 1, 12345);
    UtpConnection* conn = connection::create_outgoing(addr, 5555);
    defer conn.free();

    conn.transition_to_connected();

    // Create RESET packet
    packet::UtpHeader reset;
    reset.packet_type = utp_common::ST_RESET;
    reset.version = utp_common::UTP_VERSION;
    reset.extension = 0;
    reset.connection_id = conn.recv_id;
    reset.seq_nr = 0;
    reset.ack_nr = 0;
    reset.wnd_size = 0;
    reset.timestamp_microseconds = 9000000;
    reset.timestamp_difference_microseconds = 0;

    // Process packet
    bool ok = conn.process_packet(&reset);

    assert(ok, "RESET packet should be processed");
    // With empty buffer, auto-transitions to DELETING
    assert(conn.state == ConnectionState.DELETING, "State should transition to DELETING");
    assert(conn.error_reason == connection::ErrorReason.RESET_RECEIVED, "Error reason should be set");

    io::printn("✓ test_process_reset_packet");
}

/**
 * Test 12: Reject packet with wrong connection ID.
 */
fn void test_reject_wrong_connection_id() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(192, 168, 100, 1, 6000);
    UtpConnection* conn = connection::create_outgoing(addr, 6666);
    defer conn.free();

    conn.transition_to_connected();

    // Create packet with WRONG connection ID
    packet::UtpHeader wrong;
    wrong.packet_type = utp_common::ST_STATE;
    wrong.version = utp_common::UTP_VERSION;
    wrong.extension = 0;
    wrong.connection_id = (ushort)(conn.recv_id + 100);  // Wrong!
    wrong.seq_nr = 0;
    wrong.ack_nr = 0;
    wrong.wnd_size = 100000;
    wrong.timestamp_microseconds = 1000000;
    wrong.timestamp_difference_microseconds = 0;

    // Process packet
    bool ok = conn.process_packet(&wrong);

    assert(!ok, "Packet with wrong connection ID should be rejected");

    io::printn("✓ test_reject_wrong_connection_id");
}

/**
 * Test 13: Connection state string representation.
 */
fn void test_state_string() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 8888);
    UtpConnection* conn = connection::create_outgoing(addr, 7777);
    defer conn.free();

    // Test various states
    assert(conn.state_string() == "SYN_SENT", "SYN_SENT state string");

    conn.transition_to_connected();
    assert(conn.state_string() == "CONNECTED", "CONNECTED state string");

    conn.transition_to_fin_sent();
    assert(conn.state_string() == "FIN_SENT", "FIN_SENT state string");

    conn.transition_to_error();
    assert(conn.state_string() == "ERROR_WAIT", "ERROR_WAIT state string");

    conn.transition_to_deleting();
    assert(conn.state_string() == "DELETING", "DELETING state string");

    io::printn("✓ test_state_string");
}

// ============================================================================
// Send Buffer Tests
// ============================================================================

/**
 * Test 14: Send buffer add packet.
 */
fn void test_send_buffer_add_packet() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    // Create dummy packet data
    char[20] packet_data;
    for (usz i = 0; i < 20; i++) packet_data[i] = (char)i;

    // Add packet to send buffer
    conn.send_buf.add_packet(100, packet_data[..]);

    assert(conn.send_buf.packets_in_flight() == 1, "Should have 1 packet in flight");
    assert(conn.send_buf.oldest_seq == 100, "Oldest seq should be 100");

    io::printn("✓ test_send_buffer_add_packet");
}

/**
 * Test 15: Send buffer ACK single packet.
 */
fn void test_send_buffer_ack_single() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    char[20] packet_data;
    for (usz i = 0; i < 20; i++) packet_data[i] = (char)i;

    // Add packet
    conn.send_buf.add_packet(50, packet_data[..]);
    assert(conn.send_buf.packets_in_flight() == 1, "Should have 1 packet before ACK");

    // ACK the packet
    conn.send_buf.ack_packet(50);

    assert(conn.send_buf.packets_in_flight() == 0, "Should have 0 packets after ACK");

    io::printn("✓ test_send_buffer_ack_single");
}

/**
 * Test 16: Send buffer ACK multiple packets.
 */
fn void test_send_buffer_ack_multiple() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    char[20] packet_data;
    for (usz i = 0; i < 20; i++) packet_data[i] = (char)i;

    // Add 5 packets
    conn.send_buf.add_packet(100, packet_data[..]);
    conn.send_buf.add_packet(101, packet_data[..]);
    conn.send_buf.add_packet(102, packet_data[..]);
    conn.send_buf.add_packet(103, packet_data[..]);
    conn.send_buf.add_packet(104, packet_data[..]);

    assert(conn.send_buf.packets_in_flight() == 5, "Should have 5 packets");

    // ACK up to 102 (should remove 100, 101, 102)
    conn.send_buf.ack_packet(102);

    assert(conn.send_buf.packets_in_flight() == 2, "Should have 2 packets remaining");
    assert(conn.send_buf.oldest_seq == 103, "Oldest seq should be 103");

    io::printn("✓ test_send_buffer_ack_multiple");
}

/**
 * Test 17: Send buffer ACK with sequence wraparound (CRITICAL).
 */
fn void test_send_buffer_ack_wraparound() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    char[20] packet_data;
    for (usz i = 0; i < 20; i++) packet_data[i] = (char)i;

    // Add packets near wraparound boundary
    conn.send_buf.add_packet(65534, packet_data[..]);
    conn.send_buf.add_packet(65535, packet_data[..]);
    conn.send_buf.add_packet(0, packet_data[..]);      // Wraparound!
    conn.send_buf.add_packet(1, packet_data[..]);

    assert(conn.send_buf.packets_in_flight() == 4, "Should have 4 packets");

    // ACK through wraparound (should remove 65534, 65535, 0)
    conn.send_buf.ack_packet(0);

    assert(conn.send_buf.packets_in_flight() == 1, "Should have 1 packet remaining");
    assert(conn.send_buf.oldest_seq == 1, "Oldest seq should be 1");

    io::printn("✓ test_send_buffer_ack_wraparound");
}

/**
 * Test 18: Send buffer backpressure.
 */
fn void test_send_buffer_backpressure() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    // Reinitialize with small buffer for testing
    conn.send_buf.free();
    conn.send_buf.init(3);  // Max 3 packets

    char[20] packet_data;
    for (usz i = 0; i < 20; i++) packet_data[i] = (char)i;

    // Should be able to send initially
    assert(conn.send_buf.can_send(), "Should be able to send initially");

    // Add 3 packets (fill buffer)
    conn.send_buf.add_packet(10, packet_data[..]);
    conn.send_buf.add_packet(11, packet_data[..]);
    conn.send_buf.add_packet(12, packet_data[..]);

    // Buffer should be full now
    assert(!conn.send_buf.can_send(), "Should NOT be able to send when full");

    // ACK one packet
    conn.send_buf.ack_packet(10);

    // Should be able to send again
    assert(conn.send_buf.can_send(), "Should be able to send after ACK");

    io::printn("✓ test_send_buffer_backpressure");
}

/**
 * Test 19: Send buffer partial ACK (middle of buffer).
 */
fn void test_send_buffer_partial_ack() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    char[20] packet_data;
    for (usz i = 0; i < 20; i++) packet_data[i] = (char)i;

    // Add packets
    conn.send_buf.add_packet(200, packet_data[..]);
    conn.send_buf.add_packet(201, packet_data[..]);
    conn.send_buf.add_packet(202, packet_data[..]);
    conn.send_buf.add_packet(203, packet_data[..]);
    conn.send_buf.add_packet(204, packet_data[..]);

    // ACK middle (should remove 200, 201)
    conn.send_buf.ack_packet(201);

    assert(conn.send_buf.packets_in_flight() == 3, "Should have 3 packets remaining");
    assert(conn.send_buf.oldest_seq == 202, "Oldest should be 202");

    io::printn("✓ test_send_buffer_partial_ack");
}

/**
 * Test 20: Send buffer duplicate ACK (idempotent).
 */
fn void test_send_buffer_duplicate_ack() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    char[20] packet_data;
    for (usz i = 0; i < 20; i++) packet_data[i] = (char)i;

    conn.send_buf.add_packet(300, packet_data[..]);
    conn.send_buf.add_packet(301, packet_data[..]);
    conn.send_buf.add_packet(302, packet_data[..]);

    // ACK once
    conn.send_buf.ack_packet(301);
    assert(conn.send_buf.packets_in_flight() == 1, "Should have 1 packet after first ACK");

    // ACK same value again (should be idempotent)
    conn.send_buf.ack_packet(301);
    assert(conn.send_buf.packets_in_flight() == 1, "Should still have 1 packet after duplicate ACK");

    // ACK older value (should be no-op)
    conn.send_buf.ack_packet(300);
    assert(conn.send_buf.packets_in_flight() == 1, "Should still have 1 packet after old ACK");

    io::printn("✓ test_send_buffer_duplicate_ack");
}

/**
 * Test 21: Send buffer get packet (for retransmission).
 */
fn void test_send_buffer_get_packet() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    char[20] packet_data;
    for (usz i = 0; i < 20; i++) packet_data[i] = (char)i;

    // Add packets
    conn.send_buf.add_packet(400, packet_data[..]);
    conn.send_buf.add_packet(401, packet_data[..]);
    conn.send_buf.add_packet(402, packet_data[..]);

    // Get existing packet
    connection::SentPacket*? pkt_result = conn.send_buf.get_packet(401);
    if (catch err = pkt_result) {
        assert(false, "Should find packet 401");
    } else {
        connection::SentPacket* pkt = pkt_result;
        assert(pkt.seq_nr == 401, "Packet seq should be 401");
        assert(pkt.data.len == 20, "Packet data length should be 20");
    }

    // Get non-existent packet
    connection::SentPacket*? missing = conn.send_buf.get_packet(999);
    if (catch err = missing) {
        // Expected - packet not found
    } else {
        assert(false, "Should not find non-existent packet");
    }

    io::printn("✓ test_send_buffer_get_packet");
}

// ============================================================================
// Receive Buffer Tests
// ============================================================================

/**
 * Test 22: Add packet to receive buffer
 */
fn void test_receive_buffer_add_packet() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    // Set expected sequence
    conn.recv_buf.expected_seq = 100;

    char[10] data = { 'h', 'e', 'l', 'l', 'o', 'w', 'o', 'r', 'l', 'd' };

    // Add packet with correct seq
    bool added = conn.recv_buf.add_packet(100, data[..]);
    assert(added, "Should accept in-order packet");
    assert(conn.recv_buf.has_data(), "Buffer should have data");
    assert(conn.recv_buf.bytes_available() == 10, "Should have 10 bytes available");
    assert(conn.recv_buf.expected_seq == 101, "Expected seq should increment");

    io::printn("✓ test_receive_buffer_add_packet");
}

/**
 * Test 23: Read single chunk from buffer
 */
fn void test_receive_buffer_read_single() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    char[5] data = { 'h', 'e', 'l', 'l', 'o' };
    conn.recv_buf.add_packet(0, data[..]);

    // Read entire chunk
    char[] result = conn.recv_buf.read(100);
    defer free(result);

    assert(result.len == 5, "Should read 5 bytes");
    assert(result[0] == 'h', "First byte should be 'h'");
    assert(result[4] == 'o', "Last byte should be 'o'");
    assert(!conn.recv_buf.has_data(), "Buffer should be empty after read");
    assert(conn.recv_buf.bytes_available() == 0, "Zero bytes available");

    io::printn("✓ test_receive_buffer_read_single");
}

/**
 * Test 24: Read partial chunk (Option B specific test)
 */
fn void test_receive_buffer_read_partial() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    char[10] data = { '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' };
    conn.recv_buf.add_packet(0, data[..]);

    // Read first 3 bytes
    char[] part1 = conn.recv_buf.read(3);
    defer free(part1);
    assert(part1.len == 3, "Should read 3 bytes");
    assert(part1[0] == '0' && part1[1] == '1' && part1[2] == '2', "First part correct");
    assert(conn.recv_buf.has_data(), "Buffer should still have data");
    assert(conn.recv_buf.bytes_available() == 7, "7 bytes remaining");

    // Read next 4 bytes
    char[] part2 = conn.recv_buf.read(4);
    defer free(part2);
    assert(part2.len == 4, "Should read 4 bytes");
    assert(part2[0] == '3' && part2[3] == '6', "Second part correct");
    assert(conn.recv_buf.bytes_available() == 3, "3 bytes remaining");

    // Read remaining bytes
    char[] part3 = conn.recv_buf.read(100);
    defer free(part3);
    assert(part3.len == 3, "Should read 3 bytes");
    assert(part3[0] == '7' && part3[2] == '9', "Third part correct");
    assert(!conn.recv_buf.has_data(), "Buffer should be empty");

    io::printn("✓ test_receive_buffer_read_partial");
}

/**
 * Test 25: Read multiple chunks
 */
fn void test_receive_buffer_read_multiple() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    char[5] data1 = { 'h', 'e', 'l', 'l', 'o' };
    char[5] data2 = { 'w', 'o', 'r', 'l', 'd' };

    conn.recv_buf.add_packet(0, data1[..]);
    conn.recv_buf.add_packet(1, data2[..]);

    assert(conn.recv_buf.bytes_available() == 10, "10 bytes total");

    // Read first chunk
    char[] chunk1 = conn.recv_buf.read(100);
    defer free(chunk1);
    assert(chunk1.len == 5, "First chunk is 5 bytes");
    assert(chunk1[0] == 'h', "First chunk starts with 'h'");

    // Read second chunk
    char[] chunk2 = conn.recv_buf.read(100);
    defer free(chunk2);
    assert(chunk2.len == 5, "Second chunk is 5 bytes");
    assert(chunk2[0] == 'w', "Second chunk starts with 'w'");

    assert(!conn.recv_buf.has_data(), "Buffer empty after reading both chunks");

    io::printn("✓ test_receive_buffer_read_multiple");
}

/**
 * Test 26: Receive buffer wraparound (CRITICAL)
 */
fn void test_receive_buffer_wraparound() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    char[4] data = { 'a', 'b', 'c', 'd' };

    // Test wraparound: 65534 → 65535 → 0 → 1
    conn.recv_buf.expected_seq = 65534;

    bool added1 = conn.recv_buf.add_packet(65534, data[..]);
    assert(added1, "Should accept seq 65534");
    assert(conn.recv_buf.expected_seq == 65535, "Expected seq should be 65535");

    bool added2 = conn.recv_buf.add_packet(65535, data[..]);
    assert(added2, "Should accept seq 65535");
    assert(conn.recv_buf.expected_seq == 0, "Expected seq should wrap to 0");

    bool added3 = conn.recv_buf.add_packet(0, data[..]);
    assert(added3, "Should accept seq 0");
    assert(conn.recv_buf.expected_seq == 1, "Expected seq should be 1");

    bool added4 = conn.recv_buf.add_packet(1, data[..]);
    assert(added4, "Should accept seq 1");
    assert(conn.recv_buf.expected_seq == 2, "Expected seq should be 2");

    assert(conn.recv_buf.bytes_available() == 16, "Should have 16 bytes (4 packets * 4 bytes)");

    io::printn("✓ test_receive_buffer_wraparound");
}

/**
 * Test 27: Receive buffer backpressure
 */
fn void test_receive_buffer_backpressure() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    // Set small buffer limit
    conn.recv_buf.max_buffered = 10;

    char[8] data = { 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' };

    // Add first packet (8 bytes)
    bool added1 = conn.recv_buf.add_packet(0, data[..]);
    assert(added1, "Should accept first packet (8 bytes)");

    // Try to add second packet (would be 16 bytes total, exceeds limit of 10)
    bool added2 = conn.recv_buf.add_packet(1, data[..]);
    assert(!added2, "Should reject packet when buffer would exceed limit");

    assert(conn.recv_buf.bytes_available() == 8, "Should only have 8 bytes");

    io::printn("✓ test_receive_buffer_backpressure");
}

/**
 * Test 28: Reject out-of-order packets
 */
fn void test_receive_buffer_out_of_order() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    conn.recv_buf.expected_seq = 100;

    char[5] data = { 'h', 'e', 'l', 'l', 'o' };

    // Try to add packet with wrong seq (102 instead of 100)
    bool added_wrong = conn.recv_buf.add_packet(102, data[..]);
    assert(!added_wrong, "Should reject out-of-order packet");
    assert(!conn.recv_buf.has_data(), "Buffer should be empty");
    assert(conn.recv_buf.expected_seq == 100, "Expected seq should not change");

    // Add correct packet
    bool added_correct = conn.recv_buf.add_packet(100, data[..]);
    assert(added_correct, "Should accept in-order packet");
    assert(conn.recv_buf.has_data(), "Buffer should have data");
    assert(conn.recv_buf.expected_seq == 101, "Expected seq should increment");

    io::printn("✓ test_receive_buffer_out_of_order");
}

// ============================================================================
// Handshake Tests
// ============================================================================

/**
 * Test 29: Unit test - Process SYN-ACK and transition to CONNECTED
 */
fn void test_handshake_syn_ack_received() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    // Connection starts in SYN_SENT state
    assert(conn.state == connection::ConnectionState.SYN_SENT, "Should start in SYN_SENT");

    // Build SYN-ACK packet (ST_STATE packet with ack_nr)
    packet::UtpHeader syn_ack;
    syn_ack.packet_type = common::ST_STATE;
    syn_ack.version = 1;
    syn_ack.extension = 0;
    syn_ack.connection_id = conn.recv_id;
    syn_ack.timestamp_microseconds = 12345;
    syn_ack.timestamp_difference_microseconds = 0;
    syn_ack.wnd_size = 65536;
    syn_ack.seq_nr = 100;  // Their sequence number
    syn_ack.ack_nr = conn.seq_nr;  // They ACK our SYN

    // Process SYN-ACK
    bool processed = conn.process_packet(&syn_ack);
    assert(processed, "Should process SYN-ACK");

    // Verify state transition
    assert(conn.state == connection::ConnectionState.CONNECTED, "Should transition to CONNECTED");
    assert(conn.ack_nr == 100, "Should update ack_nr from SYN-ACK");

    io::printn("✓ test_handshake_syn_ack_received");
}

/**
 * Test 30: Unit test - Reject SYN-ACK with wrong connection ID
 */
fn void test_handshake_reject_wrong_connection_id() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    assert(conn.state == connection::ConnectionState.SYN_SENT, "Should start in SYN_SENT");

    // Build SYN-ACK with WRONG connection ID
    packet::UtpHeader syn_ack;
    syn_ack.packet_type = common::ST_STATE;
    syn_ack.version = 1;
    syn_ack.extension = 0;
    syn_ack.connection_id = (ushort)(conn.recv_id + 100);  // Wrong ID!
    syn_ack.timestamp_microseconds = 12345;
    syn_ack.timestamp_difference_microseconds = 0;
    syn_ack.wnd_size = 65536;
    syn_ack.seq_nr = 100;
    syn_ack.ack_nr = conn.seq_nr;

    // Process SYN-ACK
    bool processed = conn.process_packet(&syn_ack);
    assert(!processed, "Should reject packet with wrong connection ID");

    // Verify state unchanged
    assert(conn.state == connection::ConnectionState.SYN_SENT, "Should remain in SYN_SENT");

    io::printn("✓ test_handshake_reject_wrong_connection_id");
}

/**
 * Test 31: Integration test - Full SYN → SYN-ACK handshake
 */
fn void test_handshake_full_outgoing() @test
{
    // Create event loop
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // Create socket
    socket::UtpSocket*? socket_result = socket::create(&loop);
    if (catch err = socket_result)
    {
        assert(false, "Should create socket");
    }
    socket::UtpSocket* utp_socket = socket_result;
    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    // Create outgoing connection
    lib_common::SocketAddress remote_addr = lib_common::create_ipv4_address(127, 0, 0, 1, 7881);
    connection::UtpConnection* conn = connection::create_outgoing(remote_addr, 5000);
    defer conn.free();

    // Verify initial state
    assert(conn.state == connection::ConnectionState.SYN_SENT, "Should be in SYN_SENT");
    ushort initial_seq = conn.seq_nr;

    // Send SYN
    utp_socket.send_syn(conn);

    // Verify send timestamp updated
    assert(conn.last_send_time > 0, "Should update last_send_time");

    // Simulate receiving SYN-ACK
    packet::UtpHeader syn_ack;
    syn_ack.packet_type = common::ST_STATE;
    syn_ack.version = 1;
    syn_ack.extension = 0;
    syn_ack.connection_id = conn.recv_id;
    syn_ack.timestamp_microseconds = 12345;
    syn_ack.timestamp_difference_microseconds = 100;
    syn_ack.wnd_size = 1024 * 1024;
    syn_ack.seq_nr = 200;
    syn_ack.ack_nr = initial_seq;

    bool processed = conn.process_packet(&syn_ack);
    assert(processed, "Should process SYN-ACK");

    // Verify handshake complete
    assert(conn.state == connection::ConnectionState.CONNECTED, "Should be CONNECTED");
    assert(conn.ack_nr == 200, "Should have ack_nr from SYN-ACK");
    assert(conn.remote_window == 1024 * 1024, "Should update remote window");

    io::printn("✓ test_handshake_full_outgoing");
}

/**
 * Test 32: Integration test - Full incoming SYN → SYN-ACK handshake
 */
fn void test_handshake_full_incoming() @test
{
    // Create event loop
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // Create socket
    socket::UtpSocket*? socket_result = socket::create(&loop);
    if (catch err = socket_result)
    {
        assert(false, "Should create socket");
    }
    socket::UtpSocket* utp_socket = socket_result;
    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    // Simulate receiving SYN packet
    packet::UtpHeader syn;
    syn.packet_type = common::ST_SYN;
    syn.version = 1;
    syn.extension = 0;
    syn.connection_id = 1234;  // Peer's recv_id
    syn.timestamp_microseconds = 9999;
    syn.timestamp_difference_microseconds = 0;
    syn.wnd_size = 512 * 1024;
    syn.seq_nr = 300;
    syn.ack_nr = 0;

    // Create incoming connection from SYN
    lib_common::SocketAddress remote_addr = lib_common::create_ipv4_address(127, 0, 0, 1, 8881);
    connection::UtpConnection* conn = connection::create_incoming(remote_addr, &syn);
    defer conn.free();

    // Verify connection created in CONNECTED state
    assert(conn.state == connection::ConnectionState.CONNECTED, "Should be CONNECTED");
    assert(conn.recv_id == 1234, "Should use peer's send_id as our recv_id");
    assert(conn.send_id == 1235, "Should use recv_id + 1 as send_id");
    assert(conn.ack_nr == 300, "Should ACK the SYN");
    assert(conn.remote_window == 512 * 1024, "Should use peer's window");

    // Send SYN-ACK
    utp_socket.send_syn_ack(conn);

    // Verify send timestamp updated
    assert(conn.last_send_time > 0, "Should update last_send_time");

    io::printn("✓ test_handshake_full_incoming");
}

/**
 * Test 33: Integration test - Handshake with sequence number wraparound
 */
fn void test_handshake_wraparound() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    // Manually set seq_nr near wraparound point
    conn.seq_nr = 65535;

    // Build SYN-ACK with wraparound seq_nr
    packet::UtpHeader syn_ack;
    syn_ack.packet_type = common::ST_STATE;
    syn_ack.version = 1;
    syn_ack.extension = 0;
    syn_ack.connection_id = conn.recv_id;
    syn_ack.timestamp_microseconds = 12345;
    syn_ack.timestamp_difference_microseconds = 0;
    syn_ack.wnd_size = 65536;
    syn_ack.seq_nr = 0;  // Wraparound: seq starts at 0
    syn_ack.ack_nr = 65535;  // ACKs our high seq_nr

    // Process SYN-ACK
    bool processed = conn.process_packet(&syn_ack);
    assert(processed, "Should process SYN-ACK with wraparound");

    // Verify state transition
    assert(conn.state == connection::ConnectionState.CONNECTED, "Should transition to CONNECTED");
    assert(conn.ack_nr == 0, "Should handle wraparound ack_nr");

    io::printn("✓ test_handshake_wraparound");
}

// ============================================================================
// Connection ID Management & Socket Integration
// ============================================================================

/**
 * Test 34: Connection ID allocation (odd for outgoing, even for incoming)
 */
fn void test_connection_id_allocation() @test
{
    // Test outgoing ID allocation (should be odd)
    ushort seed1 = 1000;
    ushort outgoing_id = connection::allocate_outgoing_id(seed1);
    assert((outgoing_id & 1) == 1, "Outgoing ID should be odd");

    ushort seed2 = 1001;  // Already odd
    ushort outgoing_id2 = connection::allocate_outgoing_id(seed2);
    assert((outgoing_id2 & 1) == 1, "Outgoing ID should be odd");

    // Test recv_id calculation
    ushort recv_id = connection::get_recv_id_for_send_id(outgoing_id, true);
    assert((recv_id & 1) == 0, "Recv ID for outgoing should be even");
    assert(recv_id == (ushort)(outgoing_id + 1), "Recv ID should be send_id + 1");

    // Test incoming connection ID relationship
    ushort incoming_send_id = 1234;  // Even
    ushort incoming_recv_id = connection::get_recv_id_for_send_id(incoming_send_id, false);
    assert((incoming_recv_id & 1) == 1, "Recv ID for incoming should be odd");
    assert(incoming_recv_id == (ushort)(incoming_send_id - 1), "Recv ID should be send_id - 1");

    io::printn("✓ test_connection_id_allocation");
}

/**
 * Test 35: Connection ID validation
 */
fn void test_connection_id_validation() @test
{
    // Validate odd IDs
    assert(connection::validate_connection_id(1, true), "1 should be valid odd ID");
    assert(connection::validate_connection_id(1001, true), "1001 should be valid odd ID");
    assert(!connection::validate_connection_id(2, true), "2 should not be valid odd ID");

    // Validate even IDs
    assert(connection::validate_connection_id(2, false), "2 should be valid even ID");
    assert(connection::validate_connection_id(1000, false), "1000 should be valid even ID");
    assert(!connection::validate_connection_id(1, false), "1 should not be valid even ID");

    io::printn("✓ test_connection_id_validation");
}

/**
 * Test 36: Multiple concurrent connections in socket
 */
fn void test_multiple_connections() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    // Create and register multiple connections
    lib_common::SocketAddress addr1 = lib_common::create_ipv4_address(127, 0, 0, 1, 8001);
    lib_common::SocketAddress addr2 = lib_common::create_ipv4_address(127, 0, 0, 1, 8002);
    lib_common::SocketAddress addr3 = lib_common::create_ipv4_address(127, 0, 0, 1, 8003);

    connection::UtpConnection* conn1 = connection::create_outgoing(addr1, 1000);
    connection::UtpConnection* conn2 = connection::create_outgoing(addr2, 2000);
    connection::UtpConnection* conn3 = connection::create_outgoing(addr3, 3000);

    // Register all connections
    utp_socket.register_connection(conn1);
    utp_socket.register_connection(conn2);
    utp_socket.register_connection(conn3);

    // Connections should have different IDs
    assert(conn1.recv_id != conn2.recv_id, "Connections should have different recv_ids");
    assert(conn1.recv_id != conn3.recv_id, "Connections should have different recv_ids");
    assert(conn2.recv_id != conn3.recv_id, "Connections should have different recv_ids");

    // Unregister and free
    utp_socket.unregister_connection(conn1);
    utp_socket.unregister_connection(conn2);
    utp_socket.unregister_connection(conn3);

    conn1.free();
    conn2.free();
    conn3.free();

    io::printn("✓ test_multiple_connections");
}

/**
 * Test 37: Unknown connection ID handling (RESET packet)
 */
fn void test_unknown_connection_id_reset() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    // Bind to a port
    utp_socket.bind("127.0.0.1", 60000);

    // Create a DATA packet for an unknown connection ID
    lib_common::SocketAddress remote_addr = lib_common::create_ipv4_address(127, 0, 0, 1, 9999);

    // Manually test send_reset method
    utp_socket.send_reset(remote_addr, 12345, 0, 100);

    // RESET packet should be sent (verified by not crashing)
    // In a real test, we'd capture the sent packet and verify its type

    io::printn("✓ test_unknown_connection_id_reset");
}

/**
 * Test 38: Duplicate SYN handling (idempotent connection creation)
 */
fn void test_duplicate_syn_handling() @test
{
    // Test that receiving duplicate SYN packets doesn't create multiple connections
    // This is handled by the application layer (callback), not the socket itself

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);

    // Create two "connections" from same SYN
    packet::UtpHeader syn;
    syn.packet_type = common::ST_SYN;
    syn.version = 1;
    syn.extension = 0;
    syn.connection_id = 1234;
    syn.timestamp_microseconds = 9999;
    syn.timestamp_difference_microseconds = 0;
    syn.wnd_size = 65536;
    syn.seq_nr = 100;
    syn.ack_nr = 0;

    connection::UtpConnection* conn1 = connection::create_incoming(addr, &syn);
    connection::UtpConnection* conn2 = connection::create_incoming(addr, &syn);

    // Both should have same recv_id (from SYN)
    assert(conn1.recv_id == conn2.recv_id, "Both connections from same SYN should have same recv_id");
    assert(conn1.recv_id == 1234, "Recv_id should match SYN connection_id");

    // In practice, socket should only register one connection per ID
    // (Application layer handles deduplication)

    conn1.free();
    conn2.free();

    io::printn("✓ test_duplicate_syn_handling");
}

// ============================================================================
// FIN/Close Handling Tests
// ============================================================================

/**
 * Test 39: Initiate close from CONNECTED state
 */
fn void test_close_initiate() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    // Manually set to CONNECTED state
    conn.state = connection::ConnectionState.CONNECTED;

    // Initiate close
    bool closed = conn.initiate_close();
    assert(closed, "Should successfully initiate close");
    assert(conn.state == connection::ConnectionState.FIN_SENT, "Should transition to FIN_SENT");
    assert(conn.fin_sent, "fin_sent flag should be set");

    // Try to close again (should be idempotent)
    bool closed_again = conn.initiate_close();
    assert(!closed_again, "Should not allow double close");

    io::printn("✓ test_close_initiate");
}

/**
 * Test 40: Remote-initiated close (receive FIN)
 */
fn void test_close_remote_initiated() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    // Set to CONNECTED state
    conn.state = connection::ConnectionState.CONNECTED;

    // Receive FIN packet from remote
    packet::UtpHeader fin;
    fin.packet_type = common::ST_FIN;
    fin.version = 1;
    fin.extension = 0;
    fin.connection_id = conn.recv_id;
    fin.timestamp_microseconds = 12345;
    fin.timestamp_difference_microseconds = 0;
    fin.wnd_size = 65536;
    fin.seq_nr = 200;
    fin.ack_nr = conn.seq_nr;

    bool processed = conn.process_packet(&fin);
    assert(processed, "Should process FIN packet");
    assert(conn.remote_fin_received, "Should mark remote FIN received");
    assert(conn.fin_sent, "Should mark that we'll send FIN in response");
    // With empty buffer, transitions directly to DELETING (both FINs ready)
    assert(conn.state == connection::ConnectionState.DELETING, "Should transition to DELETING");
    assert(conn.ack_nr == 200, "Should ACK the FIN");

    io::printn("✓ test_close_remote_initiated");
}

/**
 * Test 41: Close with pending data (buffer draining)
 */
fn void test_close_with_pending_data() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    conn.state = connection::ConnectionState.CONNECTED;

    // Add some packets to send buffer (simulating pending data)
    char[10] data = { 'h', 'e', 'l', 'l', 'o', 'w', 'o', 'r', 'l', 'd' };
    conn.send_buf.add_packet(100, data[..]);
    conn.send_buf.add_packet(101, data[..]);

    // Initiate close
    conn.initiate_close();
    assert(conn.state == connection::ConnectionState.FIN_SENT, "Should be in FIN_SENT");

    // Can't delete yet - buffer not empty
    assert(!conn.can_delete(), "Should not be able to delete with pending data");

    // ACK the packets
    conn.send_buf.ack_packet(101);

    // Still can't delete - remote FIN not received
    assert(!conn.can_delete(), "Should wait for remote FIN");

    // Receive remote FIN
    conn.remote_fin_received = true;

    // Now can delete
    assert(conn.can_delete(), "Should be able to delete now");

    io::printn("✓ test_close_with_pending_data");
}

/**
 * Test 42: Simultaneous close (both send FIN)
 */
fn void test_close_simultaneous() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    conn.state = connection::ConnectionState.CONNECTED;

    // We initiate close
    conn.initiate_close();
    assert(conn.state == connection::ConnectionState.FIN_SENT, "Should be in FIN_SENT");
    assert(conn.fin_sent, "We sent FIN");

    // Remote also sends FIN (simultaneous close)
    packet::UtpHeader fin;
    fin.packet_type = common::ST_FIN;
    fin.version = 1;
    fin.extension = 0;
    fin.connection_id = conn.recv_id;
    fin.timestamp_microseconds = 12345;
    fin.timestamp_difference_microseconds = 0;
    fin.wnd_size = 65536;
    fin.seq_nr = 300;
    fin.ack_nr = conn.seq_nr;

    bool processed = conn.process_packet(&fin);
    assert(processed, "Should process remote FIN");
    assert(conn.remote_fin_received, "Remote FIN received");

    // With empty buffer, should transition to DELETING
    assert(conn.state == connection::ConnectionState.DELETING, "Should transition to DELETING");

    io::printn("✓ test_close_simultaneous");
}

/**
 * Test 43: can_delete() logic
 */
fn void test_can_delete() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    // Can't delete from CONNECTED state
    conn.state = connection::ConnectionState.CONNECTED;
    assert(!conn.can_delete(), "Can't delete from CONNECTED");

    // Can't delete from SYN_SENT
    conn.state = connection::ConnectionState.SYN_SENT;
    assert(!conn.can_delete(), "Can't delete from SYN_SENT");

    // Can delete from ERROR_WAIT if buffer empty
    conn.state = connection::ConnectionState.ERROR_WAIT;
    assert(conn.can_delete(), "Can delete from ERROR_WAIT with empty buffer");

    // Add pending data
    char[10] data = { 'h', 'e', 'l', 'l', 'o', 'w', 'o', 'r', 'l', 'd' };
    conn.send_buf.add_packet(100, data[..]);

    assert(!conn.can_delete(), "Can't delete with pending data");

    // Clear buffer
    conn.send_buf.ack_packet(100);
    assert(conn.can_delete(), "Can delete after buffer cleared");

    // FIN_SENT requires remote FIN
    conn.state = connection::ConnectionState.FIN_SENT;
    conn.fin_sent = true;
    conn.remote_fin_received = false;
    assert(!conn.can_delete(), "FIN_SENT requires remote FIN");

    conn.remote_fin_received = true;
    assert(conn.can_delete(), "Can delete when both FINs exchanged");

    io::printn("✓ test_can_delete");
}

// ============================================================================
// Error Handling and Cleanup Tests
// ============================================================================

/**
 * Test 44: RESET packet sets error reason
 */
fn void test_reset_packet_error_reason() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    conn.transition_to_connected();

    // Create RESET packet
    packet::UtpHeader reset;
    reset.packet_type = utp_common::ST_RESET;
    reset.version = utp_common::UTP_VERSION;
    reset.extension = 0;
    reset.connection_id = conn.recv_id;
    reset.seq_nr = 100;
    reset.ack_nr = 0;
    reset.wnd_size = 0;
    reset.timestamp_microseconds = 5000000;
    reset.timestamp_difference_microseconds = 0;

    // Process RESET
    bool ok = conn.process_packet(&reset);

    assert(ok, "RESET should be processed");
    // With empty buffer, automatically transitions to DELETING
    assert(conn.state == connection::ConnectionState.DELETING, "Should transition to DELETING");
    assert(conn.error_reason == connection::ErrorReason.RESET_RECEIVED, "Error reason should be RESET_RECEIVED");

    io::printn("✓ test_reset_packet_error_reason");
}

/**
 * Test 45: Idempotent error calls
 */
fn void test_idempotent_error_calls() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    conn.state = connection::ConnectionState.CONNECTED;

    // Add pending data so we stay in ERROR_WAIT
    char[10] data = { 't', 'e', 's', 't', 'd', 'a', 't', 'a', '1', '2' };
    conn.send_buf.add_packet(100, data[..]);

    // First error call
    conn.transition_to_error(connection::ErrorReason.TIMEOUT);
    assert(conn.state == connection::ConnectionState.ERROR_WAIT, "Should be in ERROR_WAIT");
    assert(conn.error_reason == connection::ErrorReason.TIMEOUT, "Error reason should be TIMEOUT");

    // Second error call with different reason - should be ignored (idempotent)
    conn.transition_to_error(connection::ErrorReason.PROTOCOL_ERROR);
    assert(conn.state == connection::ConnectionState.ERROR_WAIT, "Should still be in ERROR_WAIT");
    assert(conn.error_reason == connection::ErrorReason.TIMEOUT, "Error reason should not change");

    // Clear buffer
    conn.send_buf.ack_packet(100);

    // Now buffer is empty, can delete
    assert(conn.can_delete(), "Should be able to delete with empty buffer");

    // Manually transition to DELETING
    conn.transition_to_deleting();
    assert(conn.state == connection::ConnectionState.DELETING, "Should be in DELETING");

    // Fourth error call - should still be idempotent, already in DELETING
    conn.transition_to_error(connection::ErrorReason.UNKNOWN);
    assert(conn.state == connection::ConnectionState.DELETING, "Should stay in DELETING");
    assert(conn.error_reason == connection::ErrorReason.TIMEOUT, "Error reason should not change");

    io::printn("✓ test_idempotent_error_calls");
}

/**
 * Test 46: ERROR_WAIT to DELETING transition when buffers empty
 */
fn void test_error_wait_to_deleting() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    conn.state = connection::ConnectionState.CONNECTED;

    // Transition to error - stays in ERROR_WAIT
    conn.transition_to_error(connection::ErrorReason.PROTOCOL_ERROR);
    assert(conn.state == connection::ConnectionState.ERROR_WAIT, "Should be in ERROR_WAIT");
    assert(conn.error_reason == connection::ErrorReason.PROTOCOL_ERROR, "Error reason set");

    // With empty buffer, can delete
    assert(conn.can_delete(), "Should be able to delete with empty buffer");

    // Transition to deleting
    conn.transition_to_deleting();
    assert(conn.state == connection::ConnectionState.DELETING, "Should transition to DELETING");
    assert(conn.error_reason == connection::ErrorReason.PROTOCOL_ERROR, "Error reason preserved");

    io::printn("✓ test_error_wait_to_deleting");
}

/**
 * Test 47: close() method from various states
 */
fn void test_close_method() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);

    // Test 1: Close from CONNECTED state
    connection::UtpConnection* conn1 = connection::create_outgoing(addr, 1000);
    conn1.transition_to_connected();
    conn1.close();
    assert(conn1.state == connection::ConnectionState.FIN_SENT, "Should initiate graceful close");
    assert(conn1.fin_sent, "FIN should be sent");
    conn1.free();

    // Test 2: Close from ERROR_WAIT state
    connection::UtpConnection* conn2 = connection::create_outgoing(addr, 2000);
    char[5] data = { 'h', 'e', 'l', 'l', 'o' };
    conn2.send_buf.add_packet(100, data[..]);
    conn2.transition_to_error(connection::ErrorReason.TIMEOUT);
    assert(conn2.state == connection::ConnectionState.ERROR_WAIT, "Should be in ERROR_WAIT");
    conn2.close();
    assert(conn2.state == connection::ConnectionState.DELETING, "Should transition to DELETING");
    conn2.free();

    // Test 3: Close from SYN_SENT state
    connection::UtpConnection* conn3 = connection::create_outgoing(addr, 3000);
    assert(conn3.state == connection::ConnectionState.SYN_SENT, "Should be in SYN_SENT");
    conn3.close();
    assert(conn3.state == connection::ConnectionState.DELETING, "Should mark for deletion");
    conn3.free();

    // Test 4: Idempotent close (call twice)
    connection::UtpConnection* conn4 = connection::create_outgoing(addr, 4000);
    conn4.transition_to_connected();
    conn4.close();
    connection::ConnectionState state1 = conn4.state;
    conn4.close();  // Second call
    assert(conn4.state == state1, "State should not change on second close");
    conn4.free();

    io::printn("✓ test_close_method");
}

/**
 * Test 48: Resource cleanup from all states
 */
fn void test_resource_cleanup() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);

    // Test cleanup from each state
    connection::ConnectionState[] states = {
        connection::ConnectionState.SYN_SENT,
        connection::ConnectionState.CONNECTED,
        connection::ConnectionState.FIN_SENT,
        connection::ConnectionState.ERROR_WAIT,
        connection::ConnectionState.DELETING
    };

    foreach (state : states)
    {
        connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
        conn.state = state;

        // Add some data to buffers
        char[8] send_data = { 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' };
        if (state != connection::ConnectionState.DELETING)
        {
            conn.send_buf.add_packet(100, send_data[..]);
        }

        // Should be able to free from any state
        conn.free();
    }

    io::printn("✓ test_resource_cleanup");
}

/**
 * Test 49: Error during handshake
 */
fn void test_error_during_handshake() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    // Connection starts in SYN_SENT
    assert(conn.state == connection::ConnectionState.SYN_SENT, "Should start in SYN_SENT");

    // Receive RESET during handshake
    packet::UtpHeader reset;
    reset.packet_type = utp_common::ST_RESET;
    reset.version = utp_common::UTP_VERSION;
    reset.extension = 0;
    reset.connection_id = conn.recv_id;
    reset.seq_nr = 1;
    reset.ack_nr = 0;
    reset.wnd_size = 0;
    reset.timestamp_microseconds = 1000000;
    reset.timestamp_difference_microseconds = 0;

    bool ok = conn.process_packet(&reset);

    assert(ok, "RESET should be processed");
    assert(conn.state == connection::ConnectionState.DELETING, "Should transition to DELETING");
    assert(conn.error_reason == connection::ErrorReason.RESET_RECEIVED, "Error reason should be set");

    io::printn("✓ test_error_during_handshake");
}
