module libtorrent::utp::send_data_test;

import libtorrent::utp::connection;
import libtorrent::utp::socket;
import libtorrent::utp::common;
import libtorrent::common;
import async::event_loop;
import std::io;

// Module alias
alias lib_common = module libtorrent::common;
alias utp_common = module libtorrent::utp::common;

<*
 μTP Send Data Tests
 ====================

 Tests application-level data sending with congestion control.

 Application data transfer
 - send_data() method
 - Congestion window enforcement
 - Remote window enforcement
 - Packet splitting (MSS)
*>

/**
 * Test 1: Send single packet (data < MSS)
 */
fn void test_send_data_single_packet() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 50200);

    // Create connection
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50201);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 2000);
    utp_socket.register_connection(conn);  // Registered with socket

    defer {
        utp_socket.unregister_connection(conn);  // Unregister first
        conn.free();                              // Then free manually
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    // Transition to CONNECTED (bypass handshake for unit test)
    conn.transition_to_connected();

    // Initial state
    ushort initial_seq = conn.seq_nr;
    assert(conn.bytes_in_flight == 0, "Initial bytes_in_flight should be 0");

    // Send small data (< MSS)
    char[500] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i % 256);

    conn.send_data(data[..], utp_socket)!!;

    // Verify: seq_nr incremented by 1
    assert(conn.seq_nr == (ushort)(initial_seq + 1), "seq_nr should increment by 1");

    // Verify: bytes_in_flight updated
    assert(conn.bytes_in_flight > 0, "bytes_in_flight should be > 0");

    // Verify: packet added to send buffer
    connection::SentPacket* pkt = conn.send_buf.get_packet(initial_seq)!!;
    assert(pkt.seq_nr == initial_seq, "Packet should be in send buffer");

    io::printn("✓ test_send_data_single_packet");
}

/**
 * Test 2: Send large data (multiple packets due to MSS)
 */
fn void test_send_data_multiple_packets() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 50202);

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50203);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 2001);
    utp_socket.register_connection(conn);  // Registered with socket

    defer {
        utp_socket.unregister_connection(conn);  // Unregister first
        conn.free();                              // Then free manually
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    conn.transition_to_connected();

    // Set large cwnd to allow sending all packets
    conn.cwnd = 10000;

    ushort initial_seq = conn.seq_nr;

    // Send 5000 bytes (should split into ~4 packets at MSS=1400)
    char[5000] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i % 256);

    conn.send_data(data[..], utp_socket)!!;

    // Calculate expected packets: ceil(5000 / 1400) = 4
    ushort expected_packets = 4;
    ushort seq_increment = conn.seq_nr - initial_seq;

    assert(seq_increment == expected_packets, "Should send 4 packets (seq_nr += 4)");
    assert(conn.bytes_in_flight > 0, "bytes_in_flight should be updated");

    // Verify all packets are in send buffer
    for (ushort i = 0; i < expected_packets; i++)
    {
        ushort seq = (ushort)(initial_seq + i);
        connection::SentPacket* pkt = conn.send_buf.get_packet(seq)!!;
        assert(pkt.seq_nr == seq, "Packet %d should be in send buffer", seq);
    }

    io::printn("✓ test_send_data_multiple_packets");
}

/**
 * Test 3: Congestion window limit (backpressure)
 */
fn void test_send_data_cwnd_limit() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 50204);

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50205);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 2002);
    utp_socket.register_connection(conn);  // Registered with socket

    defer {
        utp_socket.unregister_connection(conn);  // Unregister first
        conn.free();                              // Then free manually
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    conn.transition_to_connected();

    // Set small congestion window (2800 bytes = 2 packets)
    conn.cwnd = 2800;
    conn.bytes_in_flight = 0;

    // Try to send 5000 bytes (would be 4 packets normally)
    char[5000] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i % 256);

    ushort initial_seq = conn.seq_nr;
    conn.send_data(data[..], utp_socket)!!;

    // Should only send 2 packets (cwnd = 2800 bytes)
    // Each packet is ~1400 bytes + 20 byte header = ~1420 bytes
    // 2800 / 1420 ≈ 2 packets
    ushort packets_sent = conn.seq_nr - initial_seq;

    // Should send at most 2 packets due to cwnd limit
    assert(packets_sent <= 2, "Should send at most 2 packets (cwnd limit)");
    assert(conn.bytes_in_flight <= conn.cwnd, "bytes_in_flight should not exceed cwnd");

    io::printn("✓ test_send_data_cwnd_limit");
}

/**
 * Test 4: Remote window limit
 */
fn void test_send_data_rwnd_limit() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 50206);

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50207);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 2003);
    utp_socket.register_connection(conn);  // Registered with socket

    defer {
        utp_socket.unregister_connection(conn);  // Unregister first
        conn.free();                              // Then free manually
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    conn.transition_to_connected();

    // Set small remote window (1000 bytes - less than 1 full packet)
    conn.remote_window = 1000;
    conn.cwnd = 10000;  // Large cwnd (not the limiting factor)
    conn.bytes_in_flight = 0;

    // Try to send 3000 bytes
    char[3000] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i % 256);

    ushort initial_seq = conn.seq_nr;
    io::printfn("Before send: seq_nr=%d, bytes_in_flight=%d, cwnd=%d, rwnd=%d",
                conn.seq_nr, conn.bytes_in_flight, conn.cwnd, conn.remote_window);

    conn.send_data(data[..], utp_socket)!!;

    io::printfn("After send: seq_nr=%d, bytes_in_flight=%d",
                conn.seq_nr, conn.bytes_in_flight);

    // Should be limited by remote_window (1000 bytes)
    ushort packets_sent = conn.seq_nr - initial_seq;
    io::printfn("Packets sent: %d", packets_sent);

    // With rwnd=1000, we can send 1 packet with 1000 bytes payload
    // bytes_in_flight will be 1020 (1000 payload + 20 header)
    // Note: remote_window limits payload, but bytes_in_flight includes headers
    assert(packets_sent == 1, "Should send 1 packet (rwnd limit allows 1000 bytes)");
    assert(conn.bytes_in_flight == 1020, "Should be 1000 payload + 20 header");

    io::printn("✓ test_send_data_rwnd_limit");
}

/**
 * Test 5: Reject send when not connected
 */
fn void test_send_data_not_connected() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    utp_socket.bind("127.0.0.1", 50208);

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50209);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 2004);
    utp_socket.register_connection(conn);

    // Connection is in SYN_SENT state (not CONNECTED)
    assert(conn.state == connection::ConnectionState.SYN_SENT, "Should be in SYN_SENT");

    char[100] data;

    // Try to send - should fail
    if (catch err = conn.send_data(data[..], utp_socket))
    {
        // Expected - send should fail when not connected
        io::printn("✓ test_send_data_not_connected (correctly rejected)");
    }
    else
    {
        assert(false, "send_data() should fail when not CONNECTED");
    }
}

/**
 * Test 6: Backpressure when cwnd full (bytes_in_flight == cwnd)
 */
fn void test_send_data_backpressure_cwnd_full() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    utp_socket.bind("127.0.0.1", 50210);

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50211);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 2005);
    utp_socket.register_connection(conn);
    conn.transition_to_connected();

    // Fill congestion window completely
    conn.cwnd = 2800;
    conn.bytes_in_flight = 2800;  // Window is full

    char[1000] data;

    // Try to send - should fail (backpressure)
    if (catch err = conn.send_data(data[..], utp_socket))
    {
        // Expected - window is full
        io::printn("✓ test_send_data_backpressure_cwnd_full (correctly blocked)");
    }
    else
    {
        assert(false, "send_data() should fail when cwnd is full");
    }
}

/**
 * Test 7: max_bytes_to_send calculation
 */
fn void test_max_bytes_to_send() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 2006);
    defer conn.free();

    // Test 1: cwnd is limiting factor
    conn.cwnd = 5000;
    conn.bytes_in_flight = 2000;
    conn.remote_window = 10000;

    uint max_send = conn.max_bytes_to_send();
    assert(max_send == 3000, "max_send should be cwnd - bytes_in_flight = 3000");

    // Test 2: remote_window is limiting factor
    conn.cwnd = 10000;
    conn.bytes_in_flight = 2000;
    conn.remote_window = 4000;

    max_send = conn.max_bytes_to_send();
    assert(max_send == 4000, "max_send should be remote_window = 4000");

    // Test 3: bytes_in_flight == cwnd (full)
    conn.cwnd = 5000;
    conn.bytes_in_flight = 5000;
    conn.remote_window = 10000;

    max_send = conn.max_bytes_to_send();
    assert(max_send == 0, "max_send should be 0 when cwnd full");

    // Test 4: Both very large (no limit)
    conn.cwnd = 1000000;
    conn.bytes_in_flight = 0;
    conn.remote_window = 1000000;

    max_send = conn.max_bytes_to_send();
    assert(max_send == 1000000, "max_send should be min of both large values");

    io::printn("✓ test_max_bytes_to_send");
}
