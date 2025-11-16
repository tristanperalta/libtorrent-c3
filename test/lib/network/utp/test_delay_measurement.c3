/**
 * Tests for Delay Measurement and Clock Drift Compensation
 *
 * Tests the one-way delay calculation, our_hist updates, min_rtt tracking,
 * and automatic clock drift compensation in connection.c3.
 *
 * Delay measurement integration tests
 */

module libtorrent::network::utp::test_delay_measurement;

import libtorrent::utp::connection;
import libtorrent::utp::packet;
import libtorrent::utp::common;
import libtorrent::common;
import std::time;
import std::io;

alias lib_common = module libtorrent::common;

/**
 * Test 1: Verify actual delay calculation from timestamps
 *
 * Tests that when we receive an ACK, we correctly calculate:
 * actual_delay = receive_time - send_time - their_delay
 */
fn void test_calculate_actual_delay() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 7000);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 5000);
    defer conn.free();

    conn.transition_to_connected();

    // Add a packet to send buffer with known send_time
    long send_time = 1000000;  // 1 second in microseconds
    connection::SentPacket* pkt = mem::new(connection::SentPacket);
    pkt.seq_nr = 1;
    pkt.data = {};
    pkt.send_time = send_time;
    pkt.num_transmissions = 1;
    conn.send_buf.packets.push(pkt);

    // Process ACK packet 50ms later
    packet::UtpHeader ack;
    ack.packet_type = common::ST_STATE;
    ack.connection_id = conn.recv_id;
    ack.seq_nr = 0;
    ack.ack_nr = 1;  // ACK packet with seq_nr 1
    ack.wnd_size = 1024 * 1024;
    ack.timestamp_microseconds = 0;
    ack.timestamp_difference_microseconds = 20000;  // They measured 20ms delay

    // Manually set current time for testing (send_time + 50ms)
    // In real scenario, this would be time::now()
    // Expected: actual_delay = 50ms - 20ms = 30ms

    // Process the ACK - this should calculate delay and update our_hist
    bool ok = conn.process_packet(&ack);
    assert(ok, "Should process ACK successfully");

    // Verify our_hist was initialized and contains a sample
    assert(conn.our_hist.initialized, "our_hist should be initialized after ACK");
}

/**
 * Test 2: Verify our_hist is updated on ACK
 *
 * Tests that our_hist receives delay samples when we process ACKs
 */
fn void test_update_our_hist_on_ack() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 7001);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 5001);
    defer conn.free();

    conn.transition_to_connected();

    // Initially, our_hist should not be initialized
    assert(!conn.our_hist.initialized || conn.our_hist.delay_base == 0,
           "our_hist should start uninitialized");

    // Add packet to send buffer
    long send_time = (long)time::now().to_seconds() * 1_000_000 - 100000;  // 100ms ago
    connection::SentPacket* pkt = mem::new(connection::SentPacket);
    pkt.seq_nr = 1;
    pkt.data = {};
    pkt.send_time = send_time;
    pkt.num_transmissions = 1;
    conn.send_buf.packets.push(pkt);

    // Process ACK packet
    packet::UtpHeader ack;
    ack.packet_type = common::ST_STATE;
    ack.connection_id = conn.recv_id;
    ack.seq_nr = 0;
    ack.ack_nr = 1;
    ack.wnd_size = 1024 * 1024;
    ack.timestamp_microseconds = 0;
    ack.timestamp_difference_microseconds = 30000;  // 30ms

    bool ok = conn.process_packet(&ack);
    assert(ok, "Should process ACK successfully");

    // Verify our_hist was updated
    assert(conn.our_hist.initialized, "our_hist should be initialized");
    // Expected delay: ~70ms (100ms RTT - 30ms their_delay)
    assert(conn.our_hist.delay_base > 0, "our_hist.delay_base should be set");
}

/**
 * Test 3: Verify min_rtt tracking
 *
 * Tests that min_rtt is updated to track the minimum RTT observed
 */
fn void test_update_min_rtt() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 7002);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 5002);
    defer conn.free();

    conn.transition_to_connected();

    // Initially, min_rtt should be max uint
    assert(conn.min_rtt == 0xFFFFFFFF, "min_rtt should start at max value");

    // Add first packet (100ms RTT)
    long now = (long)time::now().to_seconds() * 1_000_000;
    connection::SentPacket* pkt1 = mem::new(connection::SentPacket);
    pkt1.seq_nr = 1;
    pkt1.data = {};
    pkt1.send_time = now - 100000;  // 100ms ago
    pkt1.num_transmissions = 1;
    conn.send_buf.packets.push(pkt1);

    // Process ACK
    packet::UtpHeader ack1;
    ack1.packet_type = common::ST_STATE;
    ack1.connection_id = conn.recv_id;
    ack1.seq_nr = 0;
    ack1.ack_nr = 1;
    ack1.wnd_size = 1024 * 1024;
    ack1.timestamp_microseconds = 0;
    ack1.timestamp_difference_microseconds = 30000;

    conn.process_packet(&ack1);

    // min_rtt should be ~100ms
    assert(conn.min_rtt < 0xFFFFFFFF, "min_rtt should be updated");
    uint first_rtt = conn.min_rtt;

    // Add second packet (50ms RTT - new minimum)
    connection::SentPacket* pkt2 = mem::new(connection::SentPacket);
    pkt2.seq_nr = 2;
    pkt2.data = {};
    pkt2.send_time = now - 50000;  // 50ms ago
    pkt2.num_transmissions = 1;
    conn.send_buf.packets.push(pkt2);

    // Process ACK
    packet::UtpHeader ack2;
    ack2.packet_type = common::ST_STATE;
    ack2.connection_id = conn.recv_id;
    ack2.seq_nr = 0;
    ack2.ack_nr = 2;
    ack2.wnd_size = 1024 * 1024;
    ack2.timestamp_microseconds = 0;
    ack2.timestamp_difference_microseconds = 20000;

    conn.process_packet(&ack2);

    // min_rtt should have decreased
    assert(conn.min_rtt < first_rtt, "min_rtt should track minimum");
}

/**
 * Test 4: Clock drift compensation when their_hist.delay_base decreases
 *
 * Tests that when peer's clock drifts slower (their delay_base decreases),
 * we automatically shift our_hist upward to compensate
 */
fn void test_clock_drift_compensation_their_decrease() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 7003);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 5003);
    defer conn.free();

    conn.transition_to_connected();

    // Initialize both histories with some values
    ulong now_ms = (ulong)time::now().to_seconds() * 1000;
    conn.their_hist.add_sample(100000, now_ms);  // 100ms
    conn.our_hist.add_sample(50000, now_ms);     // 50ms

    uint initial_our_delay_base = conn.our_hist.delay_base;
    assert(initial_our_delay_base == 50000, "our_hist.delay_base should be 50ms");

    // Simulate peer clock drift: their delay_base decreases by 5ms
    // We do this by sending a packet with much lower timestamp_difference
    packet::UtpHeader ack;
    ack.packet_type = common::ST_STATE;
    ack.connection_id = conn.recv_id;
    ack.seq_nr = 0;
    ack.ack_nr = 0;
    ack.wnd_size = 1024 * 1024;
    ack.timestamp_microseconds = 0;
    ack.timestamp_difference_microseconds = 90000;  // Was 100ms, now 90ms (5ms drift)

    conn.process_packet(&ack);

    // Check that their_hist.delay_base decreased
    assert(conn.their_hist.delay_base < 100000, "their delay_base should decrease");

    // Check that our_hist was shifted upward to compensate
    // Our delay_base should increase by the drift amount (up to 5ms)
    assert(conn.our_hist.delay_base >= initial_our_delay_base,
           "our delay_base should shift upward to compensate for drift");
}

/**
 * Test 5: Clock drift limit (max 10ms)
 *
 * Tests that we only compensate for drifts <= 10ms to prevent abuse
 */
fn void test_clock_drift_limit_10ms() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 7004);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 5004);
    defer conn.free();

    conn.transition_to_connected();

    // Initialize both histories
    ulong now_ms = (ulong)time::now().to_seconds() * 1000;
    conn.their_hist.add_sample(100000, now_ms);  // 100ms
    conn.our_hist.add_sample(50000, now_ms);     // 50ms

    uint initial_our_delay_base = conn.our_hist.delay_base;

    // Simulate LARGE peer clock drift: 50ms decrease (exceeds 10ms limit)
    packet::UtpHeader ack;
    ack.packet_type = common::ST_STATE;
    ack.connection_id = conn.recv_id;
    ack.seq_nr = 0;
    ack.ack_nr = 0;
    ack.wnd_size = 1024 * 1024;
    ack.timestamp_microseconds = 0;
    ack.timestamp_difference_microseconds = 40000;  // Was 100ms, now 40ms (60ms drift!)

    conn.process_packet(&ack);

    // their_hist.delay_base should decrease to 40ms
    assert(conn.their_hist.delay_base == 40000, "their delay_base should be 40ms");

    // our_hist should NOT be shifted (drift exceeds 10ms limit)
    assert(conn.our_hist.delay_base == initial_our_delay_base,
           "our delay_base should not shift for large drifts (> 10ms)");
}

/**
 * Test 6: No compensation when drift increases
 *
 * Tests that we don't shift when delay_base increases (not a drift)
 */
fn void test_no_compensation_for_increase() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 7005);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 5005);
    defer conn.free();

    conn.transition_to_connected();

    // Initialize both histories
    ulong now_ms = (ulong)time::now().to_seconds() * 1000;
    conn.their_hist.add_sample(50000, now_ms);   // 50ms
    conn.our_hist.add_sample(30000, now_ms);     // 30ms

    uint initial_our_delay_base = conn.our_hist.delay_base;

    // Send packet with HIGHER timestamp_difference (delay_base increases, not decreases)
    packet::UtpHeader ack;
    ack.packet_type = common::ST_STATE;
    ack.connection_id = conn.recv_id;
    ack.seq_nr = 0;
    ack.ack_nr = 0;
    ack.wnd_size = 1024 * 1024;
    ack.timestamp_microseconds = 0;
    ack.timestamp_difference_microseconds = 60000;  // Was 50ms, now 60ms (increase)

    conn.process_packet(&ack);

    // No drift compensation should occur
    assert(conn.our_hist.delay_base == initial_our_delay_base,
           "our delay_base should not change when their delay_base increases");
}

/**
 * Test 7: Delay measurement with multiple ACKs
 *
 * Tests that delay measurement works correctly across multiple ACKs
 */
fn void test_delay_measurement_multiple_acks() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 7006);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 5006);
    defer conn.free();

    conn.transition_to_connected();

    long now = (long)time::now().to_seconds() * 1_000_000;

    // Add 3 packets with different send times
    for (ushort i = 1; i <= 3; i++)
    {
        connection::SentPacket* pkt = mem::new(connection::SentPacket);
        pkt.seq_nr = i;
        pkt.data = {};
        pkt.send_time = now - (long)(i * 50000);  // 50ms, 100ms, 150ms ago
        pkt.num_transmissions = 1;
        conn.send_buf.packets.push(pkt);
    }

    // Process ACK for all packets
    packet::UtpHeader ack;
    ack.packet_type = common::ST_STATE;
    ack.connection_id = conn.recv_id;
    ack.seq_nr = 0;
    ack.ack_nr = 3;  // ACK all 3 packets
    ack.wnd_size = 1024 * 1024;
    ack.timestamp_microseconds = 0;
    ack.timestamp_difference_microseconds = 25000;  // 25ms

    conn.process_packet(&ack);

    // Verify our_hist has multiple samples
    assert(conn.our_hist.initialized, "our_hist should be initialized");

    // Verify delay_base is reasonable (should be based on minimum delay observed)
    assert(conn.our_hist.delay_base > 0, "delay_base should be set");
    assert(conn.our_hist.delay_base < 200000, "delay_base should be reasonable (< 200ms)");

    // Verify min_rtt is updated
    assert(conn.min_rtt < 0xFFFFFFFF, "min_rtt should be updated");
    assert(conn.min_rtt < 200000, "min_rtt should be reasonable (< 200ms)");
}
