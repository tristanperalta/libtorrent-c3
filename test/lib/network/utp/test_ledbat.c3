/**
 * Tests for LEDBAT Congestion Control Algorithm
 *
 * Tests the delay-based LEDBAT (Low Extra Delay Background Transport)
 * congestion control implementation in connection.c3.
 *
 * Based on BEP 29 specification.
 */

module libtorrent::network::utp::test_ledbat;

import libtorrent::utp::connection;
import libtorrent::common;
import std::io;

/**
 * Test cwnd increases when delay < target (network has capacity)
 */
fn void test_ledbat_increase_below_target() @test
{
    common::SocketAddress addr = common::create_ipv4_address(127, 0, 0, 1, 5000);

    connection::UtpConnection* conn = connection::create_outgoing(addr, 1000);
    defer conn.free();

    conn.transition_to_connected();

    // Set initial state
    conn.cwnd = 10000;  // 10KB
    conn.slow_start = false;  // In congestion avoidance mode
    uint initial_cwnd = conn.cwnd;

    // Apply LEDBAT with delay BELOW target (50ms < 100ms target)
    // This should increase cwnd
    uint delay = 50000;  // 50ms (below 100ms target)
    usz bytes_acked = 1400;  // 1 MSS

    conn.apply_ledbat(bytes_acked, delay);

    // cwnd should have increased (we're below target delay)
    assert(conn.cwnd > initial_cwnd, "cwnd should increase when delay < target");
}

/**
 * Test cwnd decreases when delay > target (network congested)
 */
fn void test_ledbat_decrease_above_target() @test
{
    common::SocketAddress addr = common::create_ipv4_address(127, 0, 0, 1, 5001);

    connection::UtpConnection* conn = connection::create_outgoing(addr, 1001);
    defer conn.free();

    conn.transition_to_connected();

    // Set initial state
    conn.cwnd = 10000;  // 10KB
    conn.slow_start = false;  // In congestion avoidance mode
    uint initial_cwnd = conn.cwnd;

    // Apply LEDBAT with delay ABOVE target (150ms > 100ms target)
    // This should decrease cwnd
    uint delay = 150000;  // 150ms (above 100ms target)
    usz bytes_acked = 1400;  // 1 MSS

    conn.apply_ledbat(bytes_acked, delay);

    // cwnd should have decreased (we're above target delay)
    assert(conn.cwnd < initial_cwnd, "cwnd should decrease when delay > target");
}

/**
 * Test cwnd remains stable at target delay
 */
fn void test_ledbat_stable_at_target() @test
{
    common::SocketAddress addr = common::create_ipv4_address(127, 0, 0, 1, 5002);

    connection::UtpConnection* conn = connection::create_outgoing(addr, 1002);
    defer conn.free();

    conn.transition_to_connected();

    // Set initial state
    conn.cwnd = 10000;  // 10KB
    conn.slow_start = false;  // In congestion avoidance mode
    uint initial_cwnd = conn.cwnd;

    // Apply LEDBAT with delay AT target (100ms = 100ms target)
    // cwnd should remain relatively stable
    uint delay = 100000;  // 100ms (at target)
    usz bytes_acked = 1400;  // 1 MSS

    conn.apply_ledbat(bytes_acked, delay);

    // cwnd should be close to initial (small changes allowed due to rounding)
    int diff = (int)conn.cwnd - (int)initial_cwnd;
    assert(diff >= -100 && diff <= 100, "cwnd should remain stable at target delay");
}

/**
 * Test slow start exits when delay exceeds 90% of target
 */
fn void test_slow_start_exit_on_delay() @test
{
    common::SocketAddress addr = common::create_ipv4_address(127, 0, 0, 1, 5003);

    connection::UtpConnection* conn = connection::create_outgoing(addr, 1003);
    defer conn.free();

    conn.transition_to_connected();

    // Start in slow start
    conn.cwnd = 5000;
    conn.slow_start = true;
    conn.ssthresh = 0xFFFFFFFF;  // No threshold

    assert(conn.slow_start, "Should start in slow start mode");

    // Apply LEDBAT with delay at 95% of target (95ms > 90ms threshold)
    uint delay = 95000;  // 95ms (> 90% of 100ms)
    usz bytes_acked = 1400;

    conn.apply_ledbat(bytes_acked, delay);

    // Should have exited slow start
    assert(!conn.slow_start, "Should exit slow start when delay > 90% of target");
    assert(conn.ssthresh > 0 && conn.ssthresh < 0xFFFFFFFF, "ssthresh should be set");
}

/**
 * Test slow start exits when cwnd exceeds ssthresh
 */
fn void test_slow_start_exit_on_threshold() @test
{
    common::SocketAddress addr = common::create_ipv4_address(127, 0, 0, 1, 5004);

    connection::UtpConnection* conn = connection::create_outgoing(addr, 1004);
    defer conn.free();

    conn.transition_to_connected();

    // Start in slow start with low threshold
    conn.cwnd = 5000;
    conn.slow_start = true;
    conn.ssthresh = 6000;  // Low threshold

    assert(conn.slow_start, "Should start in slow start mode");

    // Apply LEDBAT with low delay multiple times to grow past threshold
    uint delay = 10000;  // 10ms (well below target)
    usz bytes_acked = 1400;

    // Apply multiple times - slow start grows exponentially but needs multiple ACKs
    for (int i = 0; i < 10 && conn.slow_start; i++) {
        conn.apply_ledbat(bytes_acked, delay);
    }

    // Should have exited slow start (cwnd grew past ssthresh)
    assert(!conn.slow_start, "Should exit slow start when cwnd > ssthresh");
}

/**
 * Test slow start growth is exponential
 */
fn void test_slow_start_exponential_growth() @test
{
    common::SocketAddress addr = common::create_ipv4_address(127, 0, 0, 1, 5005);

    connection::UtpConnection* conn = connection::create_outgoing(addr, 1005);
    defer conn.free();

    conn.transition_to_connected();

    // Start in slow start
    conn.cwnd = 2800;  // 2 MSS
    conn.slow_start = true;
    conn.ssthresh = 100000;  // High threshold
    uint initial_cwnd = conn.cwnd;

    // Apply LEDBAT with low delay multiple times
    uint delay = 10000;  // 10ms (well below target)
    usz bytes_acked = 1400;

    for (int i = 0; i < 5; i++) {
        conn.apply_ledbat(bytes_acked, delay);
    }

    // cwnd should have grown significantly (exponential growth)
    assert(conn.cwnd > initial_cwnd * 2, "Slow start should grow exponentially");
}

/**
 * Test congestion avoidance growth is linear
 */
fn void test_congestion_avoidance_linear_growth() @test
{
    common::SocketAddress addr = common::create_ipv4_address(127, 0, 0, 1, 5006);

    connection::UtpConnection* conn = connection::create_outgoing(addr, 1006);
    defer conn.free();

    conn.transition_to_connected();

    // Start in congestion avoidance
    conn.cwnd = 10000;
    conn.slow_start = false;
    uint initial_cwnd = conn.cwnd;

    // Apply LEDBAT with low delay multiple times
    uint delay = 10000;  // 10ms (well below target)
    usz bytes_acked = 1400;

    for (int i = 0; i < 10; i++) {
        conn.apply_ledbat(bytes_acked, delay);
    }

    // cwnd should have grown, but not exponentially
    uint growth = conn.cwnd - initial_cwnd;
    assert(growth > 0, "Congestion avoidance should grow");
    assert(growth < initial_cwnd, "Growth should be linear (not exponential)");
}

/**
 * Test cwnd clamped to minimum (1 MSS)
 */
fn void test_cwnd_minimum_clamp() @test
{
    common::SocketAddress addr = common::create_ipv4_address(127, 0, 0, 1, 5007);

    connection::UtpConnection* conn = connection::create_outgoing(addr, 1007);
    defer conn.free();

    conn.transition_to_connected();

    // Set very small cwnd
    conn.cwnd = 1500;
    conn.slow_start = false;

    // Apply LEDBAT with VERY high delay (should try to shrink cwnd)
    uint delay = 500000;  // 500ms (way above target)
    usz bytes_acked = 1400;

    conn.apply_ledbat(bytes_acked, delay);

    // cwnd should not go below 1 MSS
    assert(conn.cwnd >= conn.mss, "cwnd should not go below 1 MSS");
}

/**
 * Test cwnd clamped to maximum (1MB)
 */
fn void test_cwnd_maximum_clamp() @test
{
    common::SocketAddress addr = common::create_ipv4_address(127, 0, 0, 1, 5008);

    connection::UtpConnection* conn = connection::create_outgoing(addr, 1008);
    defer conn.free();

    conn.transition_to_connected();

    // Set cwnd near maximum
    conn.cwnd = 1024 * 1024 - 1000;  // Just below 1MB
    conn.slow_start = true;

    // Apply LEDBAT with very low delay (should try to grow cwnd)
    uint delay = 1000;  // 1ms (way below target)
    usz bytes_acked = 100000;  // Large ACK

    conn.apply_ledbat(bytes_acked, delay);

    // cwnd should not exceed 1MB
    const uint MAX_CWND = 1024 * 1024;
    assert(conn.cwnd <= MAX_CWND, "cwnd should not exceed maximum");
}

/**
 * Test delay clamped to min_rtt
 */
fn void test_delay_clamped_to_rtt() @test
{
    common::SocketAddress addr = common::create_ipv4_address(127, 0, 0, 1, 5009);

    connection::UtpConnection* conn = connection::create_outgoing(addr, 1009);
    defer conn.free();

    conn.transition_to_connected();

    // Set min_rtt
    conn.min_rtt = 50000;  // 50ms
    conn.cwnd = 10000;
    conn.slow_start = false;
    uint initial_cwnd = conn.cwnd;

    // Try to apply LEDBAT with delay GREATER than RTT
    // (shouldn't happen in practice, but algorithm should handle it)
    uint delay = 200000;  // 200ms (> min_rtt)
    usz bytes_acked = 1400;

    conn.apply_ledbat(bytes_acked, delay);

    // LEDBAT should clamp delay to min_rtt internally
    // So it uses 50ms instead of 200ms
    // At 50ms (< 100ms target), cwnd should increase
    assert(conn.cwnd > initial_cwnd, "Delay should be clamped to min_rtt");
}

/**
 * Test zero bytes_acked does nothing
 */
fn void test_zero_bytes_acked() @test
{
    common::SocketAddress addr = common::create_ipv4_address(127, 0, 0, 1, 5010);

    connection::UtpConnection* conn = connection::create_outgoing(addr, 1010);
    defer conn.free();

    conn.transition_to_connected();

    conn.cwnd = 10000;
    conn.slow_start = false;
    uint initial_cwnd = conn.cwnd;

    // Apply LEDBAT with zero bytes acked
    uint delay = 50000;
    usz bytes_acked = 0;

    conn.apply_ledbat(bytes_acked, delay);

    // cwnd should not change
    assert(conn.cwnd == initial_cwnd, "cwnd should not change with zero bytes acked");
}

/**
 * Test window_factor calculation with large ACK
 */
fn void test_window_factor_large_ack() @test
{
    common::SocketAddress addr = common::create_ipv4_address(127, 0, 0, 1, 5011);

    connection::UtpConnection* conn = connection::create_outgoing(addr, 1011);
    defer conn.free();

    conn.transition_to_connected();

    conn.cwnd = 10000;
    conn.slow_start = false;
    uint initial_cwnd = conn.cwnd;

    // ACK more bytes than cwnd (shouldn't happen normally, but algorithm handles it)
    uint delay = 50000;  // Below target
    usz bytes_acked = 20000;  // More than cwnd

    conn.apply_ledbat(bytes_acked, delay);

    // Should still work (window_factor = min(bytes_acked, cwnd) / max(bytes_acked, cwnd))
    assert(conn.cwnd > initial_cwnd, "Should handle large ACK gracefully");
}

/**
 * Test LEDBAT behavior during consecutive ACKs
 */
fn void test_consecutive_acks() @test
{
    common::SocketAddress addr = common::create_ipv4_address(127, 0, 0, 1, 5012);

    connection::UtpConnection* conn = connection::create_outgoing(addr, 1012);
    defer conn.free();

    conn.transition_to_connected();

    conn.cwnd = 10000;
    conn.slow_start = false;

    // Simulate multiple ACKs with varying delays
    uint[5] delays = { 30000, 50000, 70000, 90000, 110000 };  // 30ms, 50ms, 70ms, 90ms, 110ms
    usz bytes_acked = 1400;

    for (usz i = 0; i < 5; i++) {
        uint prev_cwnd = conn.cwnd;
        conn.apply_ledbat(bytes_acked, delays[i]);

        if (delays[i] < 100000) {
            // Below target - should increase (or stay same)
            assert(conn.cwnd >= prev_cwnd, "cwnd should increase or stay same below target");
        } else {
            // Above target - should decrease
            assert(conn.cwnd < prev_cwnd, "cwnd should decrease above target");
        }
    }
}
