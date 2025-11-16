module libtorrent::utp::timeout_test;

import libtorrent::utp::timeout;
import libtorrent::utp::connection;
import libtorrent::utp::socket;
import libtorrent::utp::packet;
import libtorrent::utp::common;
import libtorrent::common;
import async::event_loop;
import std::time;
import std::io;

// Module alias
alias lib_common = module libtorrent::common;
alias utp_common = module libtorrent::utp::common;

<*
 μTP Timeout Tests
 ==================

 Tests timeout detection and retransmission logic.

 Week 4: Phase 1 timeout functionality:
 - Fixed 1-second timeout
 - Exponential backoff
 - Max 5 retries
 - Connection failure after max retries
*>

/**
 * Test 1: Timeout detection - packet times out after 1 second.
 */
fn void test_timeout_detection() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    // Add packet to send buffer
    char[10] data = { 't', 'e', 's', 't', 'd', 'a', 't', 'a', '1', '2' };
    conn.send_buf.add_packet(100, data[..]);

    // Get the packet
    connection::SentPacket* pkt = conn.send_buf.get_packet(100)!!;

    // Manually set send_time to 1001ms ago (simulate timeout)
    long now = (long)time::now().to_seconds() * 1_000_000;
    pkt.send_time = now - 1_001_000;  // 1.001 seconds ago

    // Check timeout with 1000ms timeout value
    bool timed_out = timeout::is_packet_timeout(pkt, 1000);

    assert(timed_out, "Packet should timeout after 1 second");

    // Verify packet hasn't timed out with shorter elapsed time
    pkt.send_time = now - 500_000;  // 0.5 seconds ago
    bool not_timed_out = timeout::is_packet_timeout(pkt, 1000);

    assert(!not_timed_out, "Packet should not timeout after 0.5 seconds");

    io::printn("✓ test_timeout_detection");
}

/**
 * Test 2: Exponential backoff - timeout doubles on each retransmission.
 */
fn void test_timeout_exponential_backoff() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    // Add packet
    char[10] data = { 't', 'e', 's', 't', 'd', 'a', 't', 'a', '1', '2' };
    conn.send_buf.add_packet(100, data[..]);

    connection::SentPacket* pkt = conn.send_buf.get_packet(100)!!;

    // Test exponential backoff calculation
    uint timeout0 = timeout::timeout_for_transmission(1000, 0);
    assert(timeout0 == 1000, "Transmission 0: 1000ms");

    uint timeout1 = timeout::timeout_for_transmission(1000, 1);
    assert(timeout1 == 2000, "Transmission 1: 2000ms");

    uint timeout2 = timeout::timeout_for_transmission(1000, 2);
    assert(timeout2 == 4000, "Transmission 2: 4000ms");

    uint timeout3 = timeout::timeout_for_transmission(1000, 3);
    assert(timeout3 == 8000, "Transmission 3: 8000ms");

    uint timeout4 = timeout::timeout_for_transmission(1000, 4);
    assert(timeout4 == 16000, "Transmission 4: 16000ms");

    io::printn("✓ test_timeout_exponential_backoff");
}

/**
 * Test 3: ACK cancels timeout - ACK removes packet before timeout.
 */
fn void test_ack_cancels_timeout() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    // Add packet at T=0
    char[10] data = { 't', 'e', 's', 't', 'd', 'a', 't', 'a', '1', '2' };
    conn.send_buf.add_packet(100, data[..]);

    // Verify packet exists
    connection::SentPacket* pkt_before = conn.send_buf.get_packet(100)!!;
    assert(pkt_before.seq_nr == 100, "Packet should exist");

    // Simulate ACK at T=500ms (before timeout)
    conn.send_buf.ack_packet(100);

    // Verify packet was removed
    if (catch err = conn.send_buf.get_packet(100))
    {
        // Good - packet was removed as expected
    }
    else
    {
        assert(false, "Packet should be removed by ACK");
    }

    // Check at T=1500ms - no timeout should occur (packet already ACKed)
    // (This would be checked by timeout manager, but packet is gone)

    io::printn("✓ test_ack_cancels_timeout");
}

/**
 * Test 4: Partial ACK timeout - only un-ACKed packets timeout.
 */
fn void test_partial_ack_timeout() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    // Send packets 100, 101, 102
    char[10] data = { 't', 'e', 's', 't', 'd', 'a', 't', 'a', '1', '2' };
    conn.send_buf.add_packet(100, data[..]);
    conn.send_buf.add_packet(101, data[..]);
    conn.send_buf.add_packet(102, data[..]);

    // ACK packets 100 and 101
    conn.send_buf.ack_packet(101);

    // Verify packets 100 and 101 are removed
    if (catch err = conn.send_buf.get_packet(100))
    {
        // Good - packet 100 was removed
    }
    else
    {
        assert(false, "Packet 100 should be ACKed");
    }

    if (catch err = conn.send_buf.get_packet(101))
    {
        // Good - packet 101 was removed
    }
    else
    {
        assert(false, "Packet 101 should be ACKed");
    }

    // Verify packet 102 remains
    connection::SentPacket* pkt102 = conn.send_buf.get_packet(102)!!;
    assert(pkt102.seq_nr == 102, "Packet 102 should remain");

    // Simulate timeout on packet 102
    long now = (long)time::now().to_seconds() * 1_000_000;
    pkt102.send_time = now - 1_100_000;  // 1.1 seconds ago

    // Check timeout
    assert(timeout::is_packet_timeout(pkt102, 1000), "Only packet 102 should timeout");

    io::printn("✓ test_partial_ack_timeout");
}

/**
 * Test 5: Max retries - connection fails after 5 retries.
 */
fn void test_timeout_max_retries() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    utp_socket.bind("127.0.0.1", 50100);

    // Create connection
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    utp_socket.register_connection(conn);

    // Transition to CONNECTED (required for timeout processing)
    conn.transition_to_connected();

    // Add packet
    char[10] data = { 't', 'e', 's', 't', 'd', 'a', 't', 'a', '1', '2' };
    conn.send_buf.add_packet(100, data[..]);

    connection::SentPacket* pkt = conn.send_buf.get_packet(100)!!;

    // Simulate 5 retransmissions (num_transmissions = 5)
    pkt.num_transmissions = 5;

    // Set packet as timed out
    long now = (long)time::now().to_seconds() * 1_000_000;
    pkt.send_time = now - 17_000_000;  // 17 seconds ago (exceeds max timeout)

    // Manually trigger timeout handling
    timeout::handle_packet_timeout(utp_socket.timeout_mgr, conn, pkt);

    // Verify connection transitioned to error state
    assert(conn.state == connection::ConnectionState.ERROR_WAIT ||
           conn.state == connection::ConnectionState.DELETING,
           "Connection should fail after max retries");
    assert(conn.error_reason == connection::ErrorReason.TIMEOUT, "Error reason should be TIMEOUT");

    io::printn("✓ test_timeout_max_retries");
}

/**
 * Test 6: Timeout manager lifecycle - create, start, stop, free.
 */
fn void test_timeout_manager_lifecycle() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // Create timeout manager
    timeout::TimeoutManager* mgr = timeout::create(&loop)!!;
    assert(mgr.timeout_ms == 1000, "Initial timeout should be 1000ms");

    // Create socket
    socket::UtpSocket* utp_socket = socket::create(&loop)!!;

    // Start timeout checking
    mgr.start(utp_socket);
    assert(mgr.socket == utp_socket, "Socket should be set");
    assert(mgr.check_timer != null, "Timer should be created");

    // Stop timeout checking (async close)
    mgr.stop();
    assert(mgr.check_timer == null, "Timer should be cleared");

    // Drain event loop to complete async close
    loop.run_once();

    // Free manager
    mgr.free();

    // Clean up socket
    utp_socket.close();
    loop.run_once();
    utp_socket.free();

    io::printn("✓ test_timeout_manager_lifecycle");
}

/**
 * Test 7: Timer cleanup - no memory leaks on shutdown.
 */
fn void test_timer_cleanup() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;

    // Verify timeout manager was created
    assert(utp_socket.timeout_mgr != null, "Timeout manager should be created");

    // Bind socket (starts timeout checking)
    utp_socket.bind("127.0.0.1", 50101);

    // Verify timer is running
    assert(utp_socket.timeout_mgr.check_timer != null, "Timer should be running");

    // Close socket (should stop timer)
    utp_socket.close();

    // Verify timer was stopped
    assert(utp_socket.timeout_mgr.check_timer == null, "Timer should be stopped");

    // Drain event loop (completes async close)
    loop.run_once();

    // Free socket (should free timeout manager)
    utp_socket.free();

    // No crashes or leaks = success
    io::printn("✓ test_timer_cleanup");
}
