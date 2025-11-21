/**
 * LEDBAT Performance Benchmarks
 *
 * Measures key performance characteristics of the LEDBAT congestion control algorithm:
 * 1. Window growth speed (slow start → congestion avoidance)
 * 2. Delay response time (reaction to congestion)
 * 3. Throughput vs delay profile
 * 4. Recovery from timeout events
 *
 * These benchmarks validate that LEDBAT meets its design goals:
 * - Fast ramp-up when network is idle
 * - Quick backoff when delay exceeds target
 * - Efficient bandwidth utilization
 * - Rapid recovery from packet loss
 */

module libtorrent::utp::benchmark_ledbat;

import libtorrent::utp::connection;
import libtorrent::utp::socket;
import libtorrent::utp::packet;
import libtorrent::utp::common;
import libtorrent::common;
import async::event_loop;
import std::time;
import std::io;

alias lib_common = module libtorrent::common;

/**
 * Benchmark 1: Window Growth Speed
 *
 * Measures how quickly cwnd grows from initial value (2 MSS) to 1MB under ideal conditions.
 *
 * Expected behavior:
 * - Slow start (exponential growth) until cwnd reaches ssthresh or delay threshold
 * - Congestion avoidance (linear growth) after slow start
 * - Should reach 100KB within ~100 ACKs under zero delay
 *
 * Metrics:
 * - Time to reach 100KB cwnd
 * - Number of ACKs needed
 * - Growth rate (bytes/ACK)
 */
fn void benchmark_window_growth_speed() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 60000);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 60000);
    defer conn.free();

    conn.transition_to_connected();

    // Record initial state
    uint initial_cwnd = conn.cwnd;
    long start_time = (long)time::now().to_seconds() * 1_000_000;

    io::printfn("\n=== Benchmark 1: Window Growth Speed ===");
    io::printfn("Initial cwnd: %d bytes (%.2f MSS)", initial_cwnd, (double)initial_cwnd / 1400.0);

    // Simulate ACKs with zero delay (ideal network conditions)
    uint target_cwnd = 100_000;  // 100KB target
    uint ack_count = 0;
    uint[1000] cwnd_samples;  // Track cwnd growth over time
    usz sample_count = 0;

    // Initialize histories for realistic delay measurement
    ulong now_ms = (ulong)time::now().to_seconds() * 1000;
    conn.our_hist.add_sample(0, now_ms);      // Zero delay initially
    conn.their_hist.add_sample(0, now_ms);

    while (conn.cwnd < target_cwnd && ack_count < 10000)
    {
        // Simulate ACK for 1400-byte packet with zero queuing delay
        uint bytes_acked = 1400;
        uint delay = 0;  // Zero queuing delay (ideal conditions)

        conn.apply_ledbat(bytes_acked, delay);

        ack_count++;

        // Sample cwnd every 10 ACKs
        if (ack_count % 10 == 0 && sample_count < 1000)
        {
            cwnd_samples[sample_count++] = conn.cwnd;
        }
    }

    long end_time = (long)time::now().to_seconds() * 1_000_000;
    long elapsed_us = end_time - start_time;

    // Results
    io::printfn("\nResults:");
    io::printfn("  Final cwnd: %d bytes (%.2f MSS)", conn.cwnd, (double)conn.cwnd / 1400.0);
    io::printfn("  ACKs to reach target: %d", ack_count);
    io::printfn("  Elapsed time: %d microseconds", elapsed_us);
    io::printfn("  Growth rate: %.2f bytes/ACK", (double)(conn.cwnd - initial_cwnd) / ack_count);
    io::printfn("  Still in slow start: %s", conn.slow_start ? "yes" : "no");

    // Print cwnd growth samples
    io::printn("\nCwnd growth over time (every 10 ACKs):");
    for (usz i = 0; i < sample_count && i < 10; i++)
    {
        io::printfn("  ACK %d: %d bytes (%.2f MSS)",
                    (i + 1) * 10,
                    cwnd_samples[i],
                    (double)cwnd_samples[i] / 1400.0);
    }

    // Assertions
    assert(conn.cwnd >= target_cwnd, "Should reach target cwnd");
    assert(ack_count < 2000, "Should reach 100KB in reasonable time (<2000 ACKs)");

    io::printn("\n✓ benchmark_window_growth_speed");
}

/**
 * Benchmark 2: Delay Response Time
 *
 * Measures how quickly LEDBAT reacts to sudden delay increase (congestion event).
 *
 * Scenario:
 * - Start with cwnd = 100KB, zero delay
 * - Suddenly increase delay to 150ms (50ms above 100ms target)
 * - Measure how quickly cwnd decreases
 *
 * Expected behavior:
 * - cwnd should decrease on every ACK when delay > target
 * - Should reach new equilibrium within ~20-30 ACKs
 * - cwnd should stabilize at lower value
 *
 * Metrics:
 * - Time to first cwnd decrease
 * - Number of ACKs to reach equilibrium
 * - Final cwnd value
 */
fn void benchmark_delay_response_time() @test
{
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 60001);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 60001);
    defer conn.free();

    conn.transition_to_connected();

    io::printfn("\n=== Benchmark 2: Delay Response Time ===");

    // Setup: Grow cwnd to 100KB with zero delay
    ulong now_ms = (ulong)time::now().to_seconds() * 1000;
    conn.our_hist.add_sample(0, now_ms);
    conn.their_hist.add_sample(0, now_ms);

    while (conn.cwnd < 100_000)
    {
        conn.apply_ledbat(1400, 0);  // Zero delay
    }

    uint initial_cwnd = conn.cwnd;
    io::printfn("Initial cwnd: %d bytes (%.2f MSS)", initial_cwnd, (double)initial_cwnd / 1400.0);

    // Congestion event: Sudden delay increase to 150ms (50ms above target)
    io::printn("\nCongestion event: Delay increases to 150ms (target: 100ms)");

    long start_time = (long)time::now().to_seconds() * 1_000_000;
    uint congestion_delay = 150_000;  // 150ms in microseconds
    uint ack_count = 0;
    int first_decrease_ack = -1;
    uint[1000] cwnd_samples;
    usz sample_count = 0;

    // Update delay history with new baseline
    now_ms = (ulong)time::now().to_seconds() * 1000;
    conn.our_hist.add_sample(congestion_delay, now_ms);

    // Simulate ACKs with high delay
    while (ack_count < 100)
    {
        uint prev_cwnd = conn.cwnd;

        // ACK with 150ms queuing delay
        conn.apply_ledbat(1400, congestion_delay);

        if (conn.cwnd < prev_cwnd && first_decrease_ack < 0)
        {
            first_decrease_ack = (int)ack_count;
        }

        ack_count++;

        // Sample every 5 ACKs
        if (ack_count % 5 == 0 && sample_count < 1000)
        {
            cwnd_samples[sample_count++] = conn.cwnd;
        }
    }

    long end_time = (long)time::now().to_seconds() * 1_000_000;
    long elapsed_us = end_time - start_time;

    // Results
    io::printfn("\nResults:");
    io::printfn("  Initial cwnd: %d bytes", initial_cwnd);
    io::printfn("  Final cwnd: %d bytes (%.2f MSS)", conn.cwnd, (double)conn.cwnd / 1400.0);
    io::printfn("  Reduction: %d bytes (%.1f%%)",
                initial_cwnd - conn.cwnd,
                100.0 * (double)(initial_cwnd - conn.cwnd) / initial_cwnd);
    io::printfn("  First decrease at ACK: %d", first_decrease_ack);
    io::printfn("  Total ACKs: %d", ack_count);
    io::printfn("  Elapsed time: %d microseconds", elapsed_us);

    // Print cwnd reduction over time
    io::printn("\nCwnd reduction over time (every 5 ACKs):");
    for (usz i = 0; i < sample_count && i < 10; i++)
    {
        io::printfn("  ACK %d: %d bytes (%.2f MSS)",
                    (i + 1) * 5,
                    cwnd_samples[i],
                    (double)cwnd_samples[i] / 1400.0);
    }

    // Assertions
    assert(first_decrease_ack >= 0, "cwnd should decrease when delay > target");
    assert(first_decrease_ack < 10, "Should react within first 10 ACKs");
    assert(conn.cwnd < initial_cwnd, "cwnd should be reduced after congestion");

    io::printn("\n✓ benchmark_delay_response_time");
}

/**
 * Benchmark 3: Throughput vs Delay Profile
 *
 * Measures steady-state throughput at different queuing delays.
 *
 * Tests delays: 0ms, 25ms, 50ms, 75ms, 100ms, 125ms, 150ms
 *
 * Expected behavior:
 * - 0-90ms: cwnd should grow (delay below target)
 * - 100ms: cwnd should stabilize (at target)
 * - >100ms: cwnd should decrease (delay above target)
 *
 * Metrics:
 * - Steady-state cwnd at each delay level
 * - Effective throughput (cwnd / RTT)
 * - Delay vs throughput curve
 */
fn void benchmark_throughput_vs_delay() @test
{
    io::printfn("\n=== Benchmark 3: Throughput vs Delay Profile ===");

    uint[] test_delays = { 0, 25_000, 50_000, 75_000, 100_000, 125_000, 150_000 };  // microseconds

    io::printn("\nTesting steady-state behavior at different delay levels:");
    io::printn("Delay (ms) | Cwnd (bytes) | Cwnd (MSS) | Throughput (Mbps) | Behavior");
    io::printn("-----------|--------------|------------|-------------------|----------");

    foreach (delay : test_delays)
    {
        lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 60002);
        connection::UtpConnection* conn = connection::create_outgoing(addr, 60002);
        defer conn.free();

        conn.transition_to_connected();

        // Initialize delay history
        ulong now_ms = (ulong)time::now().to_seconds() * 1000;
        conn.our_hist.add_sample(delay, now_ms);
        conn.their_hist.add_sample(0, now_ms);

        // Simulate 200 ACKs to reach steady state
        for (uint i = 0; i < 200; i++)
        {
            conn.apply_ledbat(1400, delay);
        }

        uint steady_cwnd = conn.cwnd;
        double cwnd_mss = (double)steady_cwnd / 1400.0;

        // Calculate effective throughput (assuming RTT = delay * 2)
        // Throughput = cwnd / RTT (bytes per second)
        // Convert to Mbps: (bytes/sec) * 8 / 1_000_000
        double rtt_sec = (double)(delay * 2) / 1_000_000.0;
        double throughput_mbps = 0.0;
        if (rtt_sec > 0.0)
        {
            throughput_mbps = ((double)steady_cwnd / rtt_sec) * 8.0 / 1_000_000.0;
        }
        else
        {
            // Zero delay: use 1ms as minimum RTT for calculation
            throughput_mbps = ((double)steady_cwnd / 0.001) * 8.0 / 1_000_000.0;
        }

        // Determine behavior
        String behavior;
        if (delay < 90_000) {
            behavior = "Growing";
        } else if (delay > 110_000) {
            behavior = "Shrinking";
        } else {
            behavior = "Stable";
        }

        io::printfn("%10d | %12d | %10.2f | %17.2f | %s",
                    delay / 1000,
                    steady_cwnd,
                    cwnd_mss,
                    throughput_mbps,
                    behavior);
    }

    // Verify expected behavior
    lib_common::SocketAddress addr_low = lib_common::create_ipv4_address(127, 0, 0, 1, 60010);
    connection::UtpConnection* conn_low = connection::create_outgoing(addr_low, 60010);
    defer conn_low.free();
    conn_low.transition_to_connected();

    ulong now_ms = (ulong)time::now().to_seconds() * 1000;
    conn_low.our_hist.add_sample(50_000, now_ms);  // 50ms - below target
    for (uint i = 0; i < 200; i++) conn_low.apply_ledbat(1400, 50_000);
    uint cwnd_low = conn_low.cwnd;

    lib_common::SocketAddress addr_high = lib_common::create_ipv4_address(127, 0, 0, 1, 60011);
    connection::UtpConnection* conn_high = connection::create_outgoing(addr_high, 60011);
    defer conn_high.free();
    conn_high.transition_to_connected();

    now_ms = (ulong)time::now().to_seconds() * 1000;
    conn_high.our_hist.add_sample(150_000, now_ms);  // 150ms - above target
    for (uint i = 0; i < 200; i++) conn_high.apply_ledbat(1400, 150_000);
    uint cwnd_high = conn_high.cwnd;

    // At low delay (50ms < 100ms target), cwnd should be larger
    // At high delay (150ms > 100ms target), cwnd should be smaller
    assert(cwnd_low > cwnd_high,
           "Cwnd at 50ms delay should be higher than at 150ms delay");

    io::printn("\n✓ benchmark_throughput_vs_delay");
}

/**
 * Benchmark 4: Recovery from Timeout
 *
 * Measures how quickly LEDBAT recovers after a timeout event (which halves cwnd).
 *
 * Scenario:
 * - Start with cwnd = 100KB
 * - Trigger timeout (cwnd → 50KB)
 * - Measure recovery time to get back to 100KB
 *
 * Expected behavior:
 * - Should enter slow start mode after timeout
 * - Exponential growth should quickly recover lost cwnd
 * - Should recover to 100KB within 50-100 ACKs
 *
 * Metrics:
 * - Time to recover to pre-timeout cwnd
 * - Number of ACKs needed
 * - Recovery rate (bytes/ACK)
 */
fn void benchmark_recovery_from_timeout() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* utp_socket = socket::create(&loop)!!;
    utp_socket.bind("127.0.0.1", 60100);

    defer {
        utp_socket.close();
        loop.run_once();
        utp_socket.free();
    }

    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 60101);
    connection::UtpConnection* conn = connection::create_outgoing(addr, 60100);
    utp_socket.register_connection(conn);

    defer {
        utp_socket.unregister_connection(conn);
        conn.free();
    }

    conn.transition_to_connected();

    io::printfn("\n=== Benchmark 4: Recovery from Timeout ===");

    // Setup: Grow cwnd to 100KB with zero delay
    ulong now_ms = (ulong)time::now().to_seconds() * 1000;
    conn.our_hist.add_sample(0, now_ms);
    conn.their_hist.add_sample(0, now_ms);

    while (conn.cwnd < 100_000)
    {
        conn.apply_ledbat(1400, 0);
    }

    uint pre_timeout_cwnd = conn.cwnd;
    io::printfn("Pre-timeout cwnd: %d bytes (%.2f MSS)",
                pre_timeout_cwnd, (double)pre_timeout_cwnd / 1400.0);

    // Trigger timeout event
    io::printn("\nTimeout event: cwnd halved");
    conn.on_timeout();

    uint post_timeout_cwnd = conn.cwnd;
    io::printfn("Post-timeout cwnd: %d bytes (%.2f MSS)",
                post_timeout_cwnd, (double)post_timeout_cwnd / 1400.0);

    assert(post_timeout_cwnd == pre_timeout_cwnd / 2,
           "Timeout should halve cwnd");

    // Measure recovery time
    long start_time = (long)time::now().to_seconds() * 1_000_000;
    uint ack_count = 0;
    uint[1000] cwnd_samples;
    usz sample_count = 0;

    while (conn.cwnd < pre_timeout_cwnd && ack_count < 1000)
    {
        // Simulate ACK with zero delay (ideal recovery conditions)
        conn.apply_ledbat(1400, 0);

        ack_count++;

        // Sample every 10 ACKs
        if (ack_count % 10 == 0 && sample_count < 1000)
        {
            cwnd_samples[sample_count++] = conn.cwnd;
        }
    }

    long end_time = (long)time::now().to_seconds() * 1_000_000;
    long elapsed_us = end_time - start_time;

    // Results
    io::printfn("\nRecovery Results:");
    io::printfn("  Pre-timeout cwnd: %d bytes", pre_timeout_cwnd);
    io::printfn("  Post-timeout cwnd: %d bytes", post_timeout_cwnd);
    io::printfn("  Recovered cwnd: %d bytes (%.2f MSS)",
                conn.cwnd, (double)conn.cwnd / 1400.0);
    io::printfn("  ACKs to recover: %d", ack_count);
    io::printfn("  Elapsed time: %d microseconds", elapsed_us);
    io::printfn("  Recovery rate: %.2f bytes/ACK",
                (double)(conn.cwnd - post_timeout_cwnd) / ack_count);

    // Print recovery progress
    io::printn("\nRecovery progress (every 10 ACKs):");
    for (usz i = 0; i < sample_count && i < 10; i++)
    {
        io::printfn("  ACK %d: %d bytes (%.2f MSS, %.1f%% recovered)",
                    (i + 1) * 10,
                    cwnd_samples[i],
                    (double)cwnd_samples[i] / 1400.0,
                    100.0 * (double)(cwnd_samples[i] - post_timeout_cwnd) /
                            (double)(pre_timeout_cwnd - post_timeout_cwnd));
    }

    // Assertions
    assert(conn.cwnd >= pre_timeout_cwnd, "Should recover to pre-timeout cwnd");
    assert(ack_count < 1000, "Should recover within reasonable time (<1000 ACKs)");

    io::printn("\n✓ benchmark_recovery_from_timeout");
}
