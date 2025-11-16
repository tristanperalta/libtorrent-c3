module libtorrent::utp::socket_test;

import libtorrent::utp::socket;
import libtorrent::utp::packet;
import libtorrent::utp::connection;
import libtorrent::utp::common;
import libtorrent::common;
import async::event_loop;
import std::io;

// Module alias
alias utp_common = module libtorrent::utp::common;

<*
 μTP Socket Tests
 ================

 Tests UDP socket integration and packet dispatch.
 Phase 1: Basic socket operations and connection management.
*>

/**
 * Test 1: Create and bind μTP socket.
 */
fn void test_create_and_bind() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;

    // Bind to localhost on a random high port
    utp_socket.bind("127.0.0.1", 50000);

    assert(!utp_socket.is_closed, "Socket should not be closed");

    // Cleanup
    utp_socket.close();
    loop.run_once();  // Drain close callback
    utp_socket.free();

    io::printn("✓ test_create_and_bind");
}

/**
 * Test 2: Register and unregister connections.
 */
fn void test_register_unregister_connections() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    utp_socket.bind("127.0.0.1", 50001);

    // Create a connection
    common::SocketAddress addr = common::create_ipv4_address(127, 0, 0, 1, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 12345);
    defer conn.free();

    // Register connection
    utp_socket.register_connection(conn);

    // Verify it's registered (we can't directly check HashMap, but we can test dispatch later)
    assert(!utp_socket.is_closed, "Socket should not be closed");

    // Unregister connection
    utp_socket.unregister_connection(conn);

    io::printn("✓ test_register_unregister_connections");
}

// Dummy callbacks for test_set_callbacks
fn void new_conn_cb(socket::UtpSocket* socket, common::SocketAddress remote_addr,
                    packet::UtpHeader* syn_header, void* user_data)
{
    // Callback received
}

fn void packet_recv_cb(socket::UtpSocket* socket, connection::UtpConnection* conn,
                       packet::UtpHeader* header, char[] payload, void* user_data)
{
    // Callback received
}

/**
 * Test 3: Set callbacks.
 */
fn void test_set_callbacks() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    // Set callbacks
    utp_socket.set_callbacks(&new_conn_cb, &packet_recv_cb, null);

    assert(utp_socket.new_conn_cb != null, "New connection callback should be set");
    assert(utp_socket.packet_recv_cb != null, "Packet received callback should be set");

    io::printn("✓ test_set_callbacks");
}

/**
 * Test 4: Send packet (fire-and-forget).
 */
fn void test_send_packet() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    utp_socket.bind("127.0.0.1", 50002);

    // Create a SYN packet
    packet::UtpHeader header;
    header.packet_type = utp_common::ST_SYN;
    header.version = utp_common::UTP_VERSION;
    header.extension = 0;
    header.connection_id = 1000;
    header.seq_nr = 1;
    header.ack_nr = 0;
    header.wnd_size = 1024 * 1024;
    header.timestamp_microseconds = 1000000;
    header.timestamp_difference_microseconds = 0;

    // Send to localhost (will likely fail to deliver since nothing is listening, but shouldn't crash)
    common::SocketAddress dest = common::create_ipv4_address(127, 0, 0, 1, 50003);
    utp_socket.send_packet(dest, &header);

    // Note: Not running loop here - send is fire-and-forget, and loop would block on recv_start

    io::printn("✓ test_send_packet");
}

/**
 * Test 5: Create connection and send packet through socket.
 */
fn void test_connection_send() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    utp_socket.bind("127.0.0.1", 50004);

    // Create outgoing connection
    common::SocketAddress remote = common::create_ipv4_address(192, 168, 1, 100, 6881);
    connection::UtpConnection* conn = connection::create_outgoing(remote, 5000);

    // Register connection (socket takes ownership, will free on close)
    utp_socket.register_connection(conn);

    // Create a DATA packet
    packet::UtpHeader header;
    header.packet_type = utp_common::ST_DATA;
    header.version = utp_common::UTP_VERSION;
    header.extension = 0;
    header.connection_id = conn.send_id;
    header.seq_nr = conn.seq_nr;
    header.ack_nr = conn.ack_nr;
    header.wnd_size = conn.local_window;
    header.timestamp_microseconds = 2000000;
    header.timestamp_difference_microseconds = 0;

    // Send packet
    char[] payload = (char[])"Hello μTP!";
    utp_socket.send_packet(remote, &header, payload);

    // Note: Not running loop here - send is fire-and-forget, and loop would block on recv_start

    io::printn("✓ test_connection_send");
}

/**
 * Test 6: Socket cleanup.
 */
fn void test_socket_cleanup() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;

    utp_socket.bind("127.0.0.1", 50005);

    // Create multiple connections
    common::SocketAddress addr1 = common::create_ipv4_address(10, 0, 0, 1, 8080);
    connection::UtpConnection* conn1 = connection::create_outgoing(addr1, 100);
    utp_socket.register_connection(conn1);

    common::SocketAddress addr2 = common::create_ipv4_address(10, 0, 0, 2, 8080);
    connection::UtpConnection* conn2 = connection::create_outgoing(addr2, 200);
    utp_socket.register_connection(conn2);

    // Close socket (should clean up connections)
    utp_socket.close();
    loop.run_once();  // Drain close callback
    utp_socket.free();

    // Connections are freed by socket.close(), so we don't free them manually

    io::printn("✓ test_socket_cleanup");
}
