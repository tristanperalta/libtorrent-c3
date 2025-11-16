module libtorrent::utp::connection_test;

import libtorrent::utp::connection;
import libtorrent::utp::packet;
import libtorrent::utp::common;
import libtorrent::common;  // For SocketAddress
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

    // Process packet
    bool ok = conn.process_packet(&state);

    assert(ok, "STATE packet should be processed successfully");
    assert(conn.remote_window == state.wnd_size, "Remote window should be updated");
    assert(conn.their_delay == 100, "Their delay should be updated");

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
    assert(conn.state == ConnectionState.FIN_SENT, "State should transition to FIN_SENT");
    assert(conn.ack_nr == 201, "Should ACK the FIN");

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
    assert(conn.state == ConnectionState.ERROR_WAIT, "State should transition to ERROR_WAIT");

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
