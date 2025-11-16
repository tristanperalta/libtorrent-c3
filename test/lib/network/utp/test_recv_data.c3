module libtorrent::utp::recv_data_test;

import libtorrent::utp::connection;
import libtorrent::utp::socket;
import libtorrent::utp::packet;
import libtorrent::utp::common;
import libtorrent::common;
import async::event_loop;
import std::io;

// Module alias
alias lib_common = module libtorrent::common;
alias utp_common = module libtorrent::utp::common;

<*
 μTP Receive Data Tests
 =======================

 Tests application-level data reception and bytes_in_flight tracking.

 Receive data wrapper and ACK handling
 - recv_data() method
 - has_data() and bytes_available() helpers
 - ACK processing reduces bytes_in_flight
 - bytes_in_flight tracking accuracy
*>

/**
 * Test 1: Receive single data packet
 */
fn void test_recv_data_single_packet() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 50300);

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50301);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 3000);
    utp_socket.register_connection(conn);

    defer {
        utp_socket.unregister_connection(conn);
        conn.free();
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    conn.transition_to_connected();

    // Manually add data to receive buffer
    char[100] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i % 256);

    // The receive buffer expects packets in order starting from expected_seq (initially 0)
    ushort expected = conn.recv_buf.expected_seq;
    bool added = conn.recv_buf.add_packet(expected, data[..]);
    assert(added, "Should add packet to recv buffer");

    // Check data availability
    assert(conn.has_data(), "Should have data available");
    assert(conn.bytes_available() == 100, "Should have 100 bytes available");

    // Read data
    char[] received = conn.recv_data(100);
    defer free(received);  // recv_data() returns allocated memory
    assert(received.len == 100, "Should receive 100 bytes");

    // Verify data contents
    for (usz i = 0; i < received.len; i++)
    {
        assert(received[i] == (char)(i % 256), "Data should match");
    }

    // No more data
    assert(!conn.has_data(), "Should have no more data");

    io::printn("✓ test_recv_data_single_packet");
}

/**
 * Test 2: Receive multiple packets
 */
fn void test_recv_data_multiple_packets() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 50302);

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50303);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 3001);
    utp_socket.register_connection(conn);

    defer {
        utp_socket.unregister_connection(conn);
        conn.free();
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    conn.transition_to_connected();

    // Add 3 packets
    char[100] data1;
    char[200] data2;
    char[150] data3;

    for (usz i = 0; i < data1.len; i++) data1[i] = (char)(i % 256);
    for (usz i = 0; i < data2.len; i++) data2[i] = (char)((i + 100) % 256);
    for (usz i = 0; i < data3.len; i++) data3[i] = (char)((i + 50) % 256);

    // Add packets in order (expected_seq auto-increments)
    ushort seq = conn.recv_buf.expected_seq;
    conn.recv_buf.add_packet(seq++, data1[..]);
    conn.recv_buf.add_packet(seq++, data2[..]);
    conn.recv_buf.add_packet(seq++, data3[..]);

    // Should have 450 bytes total
    assert(conn.bytes_available() == 450, "Should have 450 bytes available");

    // Read() returns one chunk at a time, up to max_bytes
    // First read: gets all 100 bytes from chunk 1
    char[] received1 = conn.recv_data(250);
    defer free(received1);
    assert(received1.len == 100, "Should receive 100 bytes (first chunk)");
    assert(conn.bytes_available() == 350, "Should have 350 bytes remaining");

    // Second read: gets all 200 bytes from chunk 2
    char[] received2 = conn.recv_data(500);
    defer free(received2);
    assert(received2.len == 200, "Should receive 200 bytes (second chunk)");
    assert(conn.bytes_available() == 150, "Should have 150 bytes remaining");

    // Third read: gets all 150 bytes from chunk 3
    char[] received3 = conn.recv_data(500);
    defer free(received3);
    assert(received3.len == 150, "Should receive 150 bytes (third chunk)");

    // No more data
    assert(!conn.has_data(), "Should have no more data");

    io::printn("✓ test_recv_data_multiple_packets");
}

/**
 * Test 3: ACK reduces bytes_in_flight
 */
fn void test_ack_reduces_bytes_in_flight() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 50304);

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50305);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 3002);
    utp_socket.register_connection(conn);

    defer {
        utp_socket.unregister_connection(conn);
        conn.free();
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    conn.transition_to_connected();
    conn.cwnd = 10000;  // Large cwnd

    // Send 3 packets
    char[500] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i % 256);

    ushort initial_seq = conn.seq_nr;
    conn.send_data(data[..], utp_socket)!!;  // Packet 1

    uint bytes_after_send = conn.bytes_in_flight;
    assert(bytes_after_send > 0, "Should have bytes in flight after send");

    // Simulate ACK for the first packet
    packet::UtpHeader ack_header;
    ack_header.packet_type = common::ST_STATE;
    ack_header.version = 1;
    ack_header.extension = 0;
    ack_header.connection_id = conn.recv_id;
    ack_header.timestamp_microseconds = 12345;
    ack_header.timestamp_difference_microseconds = 0;
    ack_header.wnd_size = 65535;
    ack_header.seq_nr = 0;
    ack_header.ack_nr = initial_seq;  // ACK the packet we sent

    conn.process_packet(&ack_header);

    // bytes_in_flight should be reduced
    assert(conn.bytes_in_flight < bytes_after_send, "bytes_in_flight should decrease after ACK");
    assert(conn.bytes_in_flight == 0, "bytes_in_flight should be 0 (all packets ACKed)");

    io::printn("✓ test_ack_reduces_bytes_in_flight");
}

/**
 * Test 4: ACK multiple packets
 */
fn void test_ack_multiple_packets() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 50306);

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50307);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 3003);
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

    // Send 3 small packets
    char[300] data1;
    for (usz i = 0; i < data1.len; i++) data1[i] = (char)(i % 256);

    // Capture seq_nr BEFORE each send (this is the seq_nr that will be used)
    ushort pkt1_seq = conn.seq_nr;
    conn.send_data(data1[..], utp_socket)!!;
    ushort pkt2_seq = conn.seq_nr;
    conn.send_data(data1[..], utp_socket)!!;
    ushort pkt3_seq = conn.seq_nr;
    conn.send_data(data1[..], utp_socket)!!;

    uint total_bytes = conn.bytes_in_flight;
    assert(total_bytes > 0, "Should have bytes in flight");

    // ACK first packet only
    packet::UtpHeader ack1;
    ack1.packet_type = common::ST_STATE;
    ack1.connection_id = conn.recv_id;
    ack1.wnd_size = 65535;
    ack1.ack_nr = pkt1_seq;

    conn.process_packet(&ack1);
    uint after_first_ack = conn.bytes_in_flight;
    assert(after_first_ack < total_bytes, "bytes_in_flight should decrease");

    // ACK second packet (cumulative ACK also ACKs first)
    packet::UtpHeader ack2;
    ack2.packet_type = common::ST_STATE;
    ack2.connection_id = conn.recv_id;
    ack2.wnd_size = 65535;
    ack2.ack_nr = pkt2_seq;

    conn.process_packet(&ack2);
    uint after_second_ack = conn.bytes_in_flight;
    assert(after_second_ack < after_first_ack, "bytes_in_flight should decrease more");

    // ACK all packets
    packet::UtpHeader ack3;
    ack3.packet_type = common::ST_STATE;
    ack3.connection_id = conn.recv_id;
    ack3.wnd_size = 65535;
    ack3.ack_nr = pkt3_seq;

    conn.process_packet(&ack3);
    assert(conn.bytes_in_flight == 0, "All packets should be ACKed");

    io::printn("✓ test_ack_multiple_packets");
}

/**
 * Test 5: No data available initially
 */
fn void test_recv_data_no_data() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 3004);
    defer conn.free();

    conn.transition_to_connected();

    // No data available
    assert(!conn.has_data(), "Should have no data initially");
    assert(conn.bytes_available() == 0, "Should have 0 bytes available");

    char[] received = conn.recv_data(100);
    assert(received.len == 0, "Should receive empty slice");

    io::printn("✓ test_recv_data_no_data");
}
