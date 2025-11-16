module libtorrent::utp::congestion_control_test;

import libtorrent::utp::connection;
import libtorrent::utp::socket;
import libtorrent::utp::packet;
import libtorrent::utp::common;
import libtorrent::utp::timeout;
import libtorrent::common;
import async::event_loop;
import std::time;
import std::io;

// Module alias
alias lib_common = module libtorrent::common;

<*
 μTP Congestion Control Tests
 ==============================

 Tests AIMD (Additive Increase Multiplicative Decrease) congestion control.

 Week 5 Day 3: Simple AIMD implementation
 - Additive increase on ACK: cwnd += MSS * bytes_acked / cwnd
 - Multiplicative decrease on timeout: cwnd /= 2
 - Minimum cwnd = 1 MSS
 - Maximum cwnd = 1MB
*>

/**
 * Test 1: Additive increase on ACK (DEPRECATED - replaced by LEDBAT in Phase 2)
 *
 * This test validated the old AIMD congestion control. Now that we use LEDBAT,
 * this test is no longer applicable. See test_ledbat.c3 for LEDBAT tests.
 */
fn void test_aimd_additive_increase() @test
{
    // Phase 2: This test is deprecated. on_packet_acked() now uses LEDBAT,
    // not the old AIMD formula. See test_ledbat.c3 for LEDBAT algorithm tests.
    return;
}

/**
 * Test 2: Multiplicative decrease on timeout
 */
fn void test_aimd_multiplicative_decrease() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 4001);
    defer conn.free();

    conn.transition_to_connected();
    conn.cwnd = 10000;  // Set larger cwnd

    // Simulate timeout
    conn.on_timeout();

    // cwnd should be cut in half
    assert(conn.cwnd == 5000, "cwnd should be cut in half");

    // Another timeout
    conn.on_timeout();

    assert(conn.cwnd == 2500, "cwnd should be cut in half again");

    io::printn("✓ test_aimd_multiplicative_decrease");
}

/**
 * Test 3: cwnd never goes below 1 MSS
 */
fn void test_cwnd_minimum() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 4002);
    defer conn.free();

    conn.transition_to_connected();
    conn.cwnd = 1400;  // Set to 1 MSS

    // Multiple timeouts
    conn.on_timeout();
    assert(conn.cwnd >= 1400, "cwnd should not go below MSS");

    conn.on_timeout();
    assert(conn.cwnd >= 1400, "cwnd should not go below MSS");

    io::printn("✓ test_cwnd_minimum");
}

/**
 * Test 4: cwnd capped at maximum
 */
fn void test_cwnd_maximum() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 4003);
    defer conn.free();

    conn.transition_to_connected();
    conn.cwnd = 1024 * 1024 - 1000;  // Just below max

    // ACK a lot of bytes
    conn.on_packet_acked(100000);

    // Should be capped at 1MB
    assert(conn.cwnd <= 1024 * 1024, "cwnd should be capped at 1MB");

    io::printn("✓ test_cwnd_maximum");
}

/**
 * Test 5: cwnd affects send rate
 */
fn void test_cwnd_limits_sending() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 50400);

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50401);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 4004);
    utp_socket.register_connection(conn);

    defer {
        utp_socket.unregister_connection(conn);
        conn.free();
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    conn.transition_to_connected();

    // Set small cwnd
    conn.cwnd = 1500;  // Only ~1 packet
    conn.bytes_in_flight = 0;

    // Try to send 5000 bytes
    char[5000] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i % 256);

    ushort initial_seq = conn.seq_nr;
    conn.send_data(data[..], utp_socket)!!;

    // Should only send 1 packet due to cwnd limit
    ushort packets_sent = conn.seq_nr - initial_seq;
    assert(packets_sent == 1, "Should send only 1 packet (cwnd limit)");

    io::printn("✓ test_cwnd_limits_sending");
}

/**
 * Test 6: ACK increases cwnd, allowing more sending
 */
fn void test_ack_increases_send_capacity() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 50402);

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50403);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 4005);
    utp_socket.register_connection(conn);

    defer {
        utp_socket.unregister_connection(conn);
        conn.free();
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    conn.transition_to_connected();

    // Initial cwnd
    uint initial_cwnd = conn.cwnd;

    // Send one packet
    char[500] data;
    ushort pkt_seq = conn.seq_nr;
    conn.send_data(data[..], utp_socket)!!;

    // Simulate ACK
    packet::UtpHeader ack;
    ack.packet_type = common::ST_STATE;
    ack.connection_id = conn.recv_id;
    ack.wnd_size = 65535;
    ack.ack_nr = pkt_seq;

    conn.process_packet(&ack);

    // cwnd should have increased
    assert(conn.cwnd > initial_cwnd, "cwnd should increase after ACK");

    io::printn("✓ test_ack_increases_send_capacity");
}

/**
 * Test 7: Timeout integration test
 */
fn void test_timeout_decreases_cwnd() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 50404);

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50405);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 4006);
    utp_socket.register_connection(conn);

    defer {
        utp_socket.unregister_connection(conn);
        conn.free();
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    conn.transition_to_connected();
    conn.cwnd = 10000;

    // Send packet
    char[500] data;
    conn.send_data(data[..], utp_socket)!!;

    // Get the sent packet from send buffer
    ushort seq = (ushort)(conn.seq_nr - 1);
    connection::SentPacket* pkt = conn.send_buf.get_packet(seq)!!;

    // Simulate timeout by setting old send time
    long now = (long)time::now().to_seconds() * 1_000_000;
    pkt.send_time = now - 2_000_000;  // 2 seconds ago

    uint cwnd_before = conn.cwnd;

    // Trigger timeout handling
    timeout::handle_packet_timeout(utp_socket.timeout_mgr, conn, pkt);

    // cwnd should be reduced
    assert(conn.cwnd < cwnd_before, "cwnd should decrease after timeout");
    assert(conn.cwnd == cwnd_before / 2, "cwnd should be cut in half");

    io::printn("✓ test_timeout_decreases_cwnd");
}
