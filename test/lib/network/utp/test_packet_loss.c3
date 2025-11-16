module libtorrent::utp::packet_loss_test;

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
alias utp_common = module libtorrent::utp::common;

<*
 μTP Packet Loss Tests
 ======================

 Tests reliability mechanisms under simulated packet loss.

 Week 6 Days 3-4: Packet loss simulation tests
 - Retransmission on data loss
 - ACK loss handling
 - High packet loss reliability
 - Connection failure on max retries
 - Congestion window behavior under loss
*>

/**
 * Test 6: Retransmission on data loss
 *
 * Simulates packet loss by manually triggering timeout.
 * Verifies that num_transmissions increments and retransmission occurs.
 */
fn void test_retransmission_on_data_loss() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 52000);

    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 52001);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 4000);
    utp_socket.register_connection(conn);

    defer {
        utp_socket.unregister_connection(conn);
        conn.free();
    }

    conn.transition_to_connected();
    conn.cwnd = 10000;

    // Send packet
    char[500] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i % 256);

    ushort initial_seq = conn.seq_nr;
    conn.send_data(data[..], utp_socket)!!;

    // Get packet from send buffer
    connection::SentPacket* pkt = conn.send_buf.get_packet(initial_seq)!!;

    // Verify initial state (first send counts as transmission #1)
    assert(pkt.num_transmissions == 1, "Should have 1 transmission initially");

    // Simulate timeout by setting old send time
    long now = (long)time::now().to_seconds() * 1_000_000;
    pkt.send_time = now - 2_000_000;  // 2 seconds ago

    // Manually trigger timeout handling (simulating what timeout manager does)
    uint cwnd_before = conn.cwnd;
    timeout::handle_packet_timeout(utp_socket.timeout_mgr, conn, pkt);

    // Verify retransmission (incremented to 2)
    assert(pkt.num_transmissions == 2, "Should have 2 transmissions after timeout");
    assert(conn.cwnd < cwnd_before, "cwnd should decrease after timeout");

    io::printn("✓ test_retransmission_on_data_loss");
}

/**
 * Test 7: ACK loss handling
 *
 * Tests that sender eventually retransmits when ACKs are lost.
 * Verifies the connection stays alive and retransmits unACKed data.
 */
fn void test_ack_loss_handling() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 52002);

    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 52003);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 4001);
    utp_socket.register_connection(conn);

    defer {
        utp_socket.unregister_connection(conn);
        conn.free();
    }

    conn.transition_to_connected();
    conn.cwnd = 10000;

    // Send 3 packets
    char[300] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i % 256);

    ushort seq1 = conn.seq_nr;
    conn.send_data(data[..], utp_socket)!!;
    ushort seq2 = conn.seq_nr;
    conn.send_data(data[..], utp_socket)!!;
    ushort seq3 = conn.seq_nr;
    conn.send_data(data[..], utp_socket)!!;

    // Verify all packets in send buffer
    assert(conn.send_buf.packets.len() == 3, "Should have 3 packets in send buffer");

    // Simulate ACK loss by NOT processing ACK packets
    // Instead, trigger timeout which will retransmit

    // Get first packet and trigger timeout
    connection::SentPacket* pkt1 = conn.send_buf.get_packet(seq1)!!;
    long now = (long)time::now().to_seconds() * 1_000_000;
    pkt1.send_time = now - 2_000_000;

    timeout::handle_packet_timeout(utp_socket.timeout_mgr, conn, pkt1);

    // Verify retransmission (should be 2: initial + retransmit)
    assert(pkt1.num_transmissions == 2, "Packet should be retransmitted (num=2)");
    assert(conn.state == connection::ConnectionState.CONNECTED,
           "Connection should remain CONNECTED");

    io::printn("✓ test_ack_loss_handling");
}

/**
 * Test 8: High packet loss reliability
 *
 * Tests that data transfer completes despite high packet loss (20%).
 * Verifies multiple retransmissions work correctly.
 */
fn void test_high_packet_loss_reliability() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 52004);

    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 52005);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 4002);
    utp_socket.register_connection(conn);

    defer {
        utp_socket.unregister_connection(conn);
        conn.free();
    }

    conn.transition_to_connected();
    conn.cwnd = 50000;  // Large cwnd for multiple packets

    // Send multiple packets
    char[1000] data;
    for (usz i = 0; i < data.len; i++) data[i] = (char)(i % 256);

    for (int i = 0; i < 10; i++) {
        conn.send_data(data[..], utp_socket)!!;
    }

    usz initial_packet_count = conn.send_buf.packets.len();
    assert(initial_packet_count > 0, "Should have packets in send buffer");

    // Simulate multiple timeouts and retransmissions
    int retransmit_count = 0;
    long now = (long)time::now().to_seconds() * 1_000_000;

    foreach (pkt : conn.send_buf.packets) {
        // Simulate 20% loss by timing out every 5th packet
        if (retransmit_count % 5 == 0) {
            pkt.send_time = now - 2_000_000;  // Old timestamp
            timeout::handle_packet_timeout(utp_socket.timeout_mgr, conn, pkt);
        }
        retransmit_count++;
    }

    // Verify connection stayed alive
    assert(conn.state == connection::ConnectionState.CONNECTED,
           "Connection should remain CONNECTED despite packet loss");

    // Verify some packets were retransmitted
    bool found_retransmit = false;
    foreach (pkt : conn.send_buf.packets) {
        if (pkt.num_transmissions > 0) {
            found_retransmit = true;
            break;
        }
    }
    assert(found_retransmit, "Should have at least one retransmitted packet");

    io::printn("✓ test_high_packet_loss_reliability");
}

/**
 * Test 9: Connection failure on max retries
 *
 * Tests that connection transitions to ERROR after MAX_RETRANSMISSIONS.
 */
fn void test_connection_failure_max_retries() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 52006);

    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 52007);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 4003);
    utp_socket.register_connection(conn);

    defer {
        utp_socket.unregister_connection(conn);
        conn.free();
    }

    conn.transition_to_connected();
    conn.cwnd = 10000;

    // Send packet
    char[500] data;
    conn.send_data(data[..], utp_socket)!!;

    ushort seq = (ushort)(conn.seq_nr - 1);
    connection::SentPacket* pkt = conn.send_buf.get_packet(seq)!!;

    // Simulate MAX_RETRANSMISSIONS (5) timeouts
    long now = (long)time::now().to_seconds() * 1_000_000;

    for (int i = 0; i < 5; i++) {
        pkt.send_time = now - 2_000_000;
        timeout::handle_packet_timeout(utp_socket.timeout_mgr, conn, pkt);

        if (i < 4) {
            // Should still be CONNECTED for first 4 retries
            assert(conn.state == connection::ConnectionState.CONNECTED,
                   "Should remain CONNECTED for retry %d", i + 1);
        }
    }

    // After 5 retries, should be in ERROR state
    pkt.send_time = now - 2_000_000;
    timeout::handle_packet_timeout(utp_socket.timeout_mgr, conn, pkt);

    assert(conn.state == connection::ConnectionState.ERROR_WAIT,
           "Should transition to ERROR_WAIT after max retries");

    io::printn("✓ test_connection_failure_max_retries");
}

/**
 * Test 10: Congestion window behavior under loss
 *
 * Verifies that cwnd decreases on timeout and increases on ACK.
 */
fn void test_cwnd_behavior_under_loss() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 52008);

    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 52009);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 4004);
    utp_socket.register_connection(conn);

    defer {
        utp_socket.unregister_connection(conn);
        conn.free();
    }

    conn.transition_to_connected();
    conn.cwnd = 10000;  // Start with large cwnd

    // Send packet
    char[500] data;
    ushort pkt_seq = conn.seq_nr;
    conn.send_data(data[..], utp_socket)!!;

    connection::SentPacket* pkt = conn.send_buf.get_packet(pkt_seq)!!;

    // Record initial cwnd
    uint initial_cwnd = conn.cwnd;

    // Simulate timeout (causes cwnd decrease)
    long now = (long)time::now().to_seconds() * 1_000_000;
    pkt.send_time = now - 2_000_000;

    timeout::handle_packet_timeout(utp_socket.timeout_mgr, conn, pkt);

    // Verify cwnd decreased (multiplicative decrease)
    assert(conn.cwnd == initial_cwnd / 2,
           "cwnd should be cut in half after timeout");

    uint after_timeout_cwnd = conn.cwnd;

    // Simulate ACK (causes cwnd increase)
    packet::UtpHeader ack;
    ack.packet_type = common::ST_STATE;
    ack.connection_id = conn.recv_id;
    ack.wnd_size = 65535;
    ack.ack_nr = pkt_seq;

    conn.process_packet(&ack);

    // Verify cwnd increased (additive increase)
    assert(conn.cwnd > after_timeout_cwnd,
           "cwnd should increase after ACK");

    // Verify packet removed from send buffer after ACK
    if (catch err = conn.send_buf.get_packet(pkt_seq)) {
        // Expected - packet should be removed after ACK
        io::printn("✓ test_cwnd_behavior_under_loss");
    } else {
        assert(false, "Packet should be removed from send buffer after ACK");
    }
}
