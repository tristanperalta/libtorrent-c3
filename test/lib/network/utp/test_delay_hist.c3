/**
 * Tests for delay_hist.c3 - Delay History Tracker
 *
 * Tests delay measurement, sliding window tracking, timestamp wraparound,
 * and clock drift compensation.
 */

module libtorrent::network::utp::test_delay_hist;

import libtorrent::network::utp::delay_hist;
import std::io;

/**
 * Test basic initialization and clearing
 */
fn void test_clear() @test
{
    DelayHist hist;
    hist.clear(0);

    assert(!hist.initialized, "Should not be initialized after clear");
    assert(hist.delay_base == 0, "delay_base should be 0");
    assert(hist.cur_delay_idx == 0, "cur_delay_idx should be 0");
    assert(hist.delay_base_idx == 0, "delay_base_idx should be 0");
    assert(hist.delay_base_time == 0, "delay_base_time should be 0");

    // Verify all arrays are zeroed
    for (usz i = 0; i < delay_hist::CUR_DELAY_SIZE; i++) {
        assert(hist.cur_delay_hist[i] == 0, "cur_delay_hist should be zeroed");
    }
    for (usz i = 0; i < delay_hist::DELAY_BASE_HISTORY; i++) {
        assert(hist.delay_base_hist[i] == 0, "delay_base_hist should be zeroed");
    }
}

/**
 * Test adding first sample initializes delay_base
 */
fn void test_first_sample_initialization() @test
{
    DelayHist hist;
    hist.clear(0);

    // Add first sample
    uint sample = 50000;  // 50ms
    hist.add_sample(sample, 0);

    assert(hist.initialized, "Should be initialized after first sample");
    assert(hist.delay_base == sample, "delay_base should equal first sample");

    // All delay_base_hist entries should be initialized to first sample
    for (usz i = 0; i < delay_hist::DELAY_BASE_HISTORY; i++) {
        assert(hist.delay_base_hist[i] == sample, "delay_base_hist should be initialized");
    }

    // Queuing delay should be 0 (sample == delay_base)
    uint queuing_delay = hist.get_value();
    assert(queuing_delay == 0, "Queuing delay should be 0 for first sample");
}

/**
 * Test delay_base tracks minimum sample
 */
fn void test_delay_base_tracks_minimum() @test
{
    DelayHist hist;
    hist.clear(0);

    // Add samples in decreasing order
    hist.add_sample(100000, 0);  // 100ms - becomes delay_base
    assert(hist.delay_base == 100000);

    hist.add_sample(80000, 0);   // 80ms - new minimum
    assert(hist.delay_base == 80000);

    hist.add_sample(60000, 0);   // 60ms - new minimum
    assert(hist.delay_base == 60000);

    // Add higher sample - delay_base should NOT change
    hist.add_sample(90000, 0);
    assert(hist.delay_base == 60000, "delay_base should remain at minimum");
}

/**
 * Test queuing delay calculation
 */
fn void test_queuing_delay() @test
{
    DelayHist hist;
    hist.clear(0);

    // Establish base delay of 50ms
    hist.add_sample(50000, 0);
    assert(hist.delay_base == 50000);

    // Add 3 samples with queuing delay to fill all slots
    // (get_value() returns min of 3 slots, so we need to fill them)
    hist.add_sample(75000, 0);  // queuing_delay = 25000
    hist.add_sample(70000, 0);  // queuing_delay = 20000
    hist.add_sample(80000, 0);  // queuing_delay = 30000

    // Queuing delay should be minimum: 20000
    uint queuing_delay = hist.get_value();
    assert(queuing_delay == 20000, "Queuing delay should be 20ms (minimum of 3 samples)");
}

/**
 * Test get_value() returns minimum of last 3 samples
 */
fn void test_get_value_minimum_of_three() @test
{
    DelayHist hist;
    hist.clear(0);

    // Establish base delay
    hist.add_sample(50000, 0);  // delay_base = 50000

    // Add 3 samples with different queuing delays
    hist.add_sample(65000, 0);  // queuing_delay = 15000
    hist.add_sample(75000, 0);  // queuing_delay = 25000
    hist.add_sample(70000, 0);  // queuing_delay = 20000

    // get_value() should return minimum (15000)
    uint min_delay = hist.get_value();
    assert(min_delay == 15000, "Should return minimum of last 3 samples");

    // Add another sample - oldest (15000) should be replaced
    hist.add_sample(68000, 0);  // queuing_delay = 18000
    // Now we have: 25000, 20000, 18000

    min_delay = hist.get_value();
    assert(min_delay == 18000, "Should return new minimum after rotation");
}

/**
 * Test sliding window rotation (every 60 seconds)
 */
fn void test_sliding_window_rotation() @test
{
    DelayHist hist;
    hist.clear(0);

    // Add initial sample at time 0
    hist.add_sample(100000, 0);
    assert(hist.delay_base_idx == 0);

    // Add sample at 30 seconds - should NOT rotate
    hist.add_sample(105000, 30_000);
    assert(hist.delay_base_idx == 0, "Should not rotate before 60 seconds");

    // Add sample at 61 seconds - SHOULD rotate
    hist.add_sample(110000, 61_000);
    assert(hist.delay_base_idx == 1, "Should rotate after 60 seconds");

    // Add sample at 122 seconds - SHOULD rotate again
    hist.add_sample(115000, 122_000);
    assert(hist.delay_base_idx == 2, "Should rotate again after another 60 seconds");
}

/**
 * Test delay_base recalculated from history on rotation
 */
fn void test_delay_base_recalculation() @test
{
    DelayHist hist;
    hist.clear(0);

    // Establish initial delay_base of 50ms
    hist.add_sample(50000, 0);

    // Add higher samples for first minute
    for (int i = 1; i < 10; i++) {
        hist.add_sample(80000, (ulong)(i * 5000));  // Every 5 seconds
    }

    // delay_base should still be 50000
    assert(hist.delay_base == 50000);

    // After 60 seconds, add a new minimum sample
    hist.add_sample(40000, 61_000);

    // delay_base should now be 40000
    assert(hist.delay_base == 40000, "delay_base should update to new minimum");
}

/**
 * Test timestamp wraparound (32-bit timestamps wrap every ~72 minutes)
 */
fn void test_timestamp_wraparound() @test
{
    DelayHist hist;
    hist.clear(0);

    // Start near max uint32 value
    uint near_max = 0xFFFF_FFF0;  // Close to wraparound
    hist.add_sample(near_max, 0);

    assert(hist.delay_base == near_max);

    // Add sample that wraps around to small value
    uint after_wrap = 0x0000_0100;  // After wraparound
    hist.add_sample(after_wrap, 0);

    // delay_base should still be near_max (smaller when accounting for wraparound)
    // The queuing delay should be small (after_wrap - near_max with wraparound)
    uint queuing_delay = hist.get_value();

    // Expected: after_wrap - near_max = 0x0100 - 0xFFFFFFF0 = 0x110 (272)
    // But with unsigned arithmetic: 0x0100 + (0xFFFFFFFF - 0xFFFFFFF0 + 1) = 0x110
    assert(queuing_delay < 1000, "Queuing delay should be small across wraparound");
}

/**
 * Test clock drift compensation via shift()
 */
fn void test_clock_drift_shift() @test
{
    DelayHist hist;
    hist.clear(0);

    // Establish delay_base
    hist.add_sample(50000, 0);
    assert(hist.delay_base == 50000);

    // Shift by +10ms (compensate for detected clock drift)
    uint shift_offset = 10000;
    hist.shift(shift_offset);

    // delay_base should increase by offset
    assert(hist.delay_base == 60000, "delay_base should increase by shift offset");

    // All delay_base_hist entries should also shift
    for (usz i = 0; i < delay_hist::DELAY_BASE_HISTORY; i++) {
        assert(hist.delay_base_hist[i] == 60000, "delay_base_hist should shift");
    }
}

/**
 * Test shift() preserves relative delays
 */
fn void test_shift_preserves_relative_delays() @test
{
    DelayHist hist;
    hist.clear(0);

    // Establish delay_base of 50ms
    hist.add_sample(50000, 0);

    // Add 3 samples with 20ms queuing delay to fill slots
    hist.add_sample(70000, 0);  // queuing_delay = 20000
    hist.add_sample(70000, 0);  // queuing_delay = 20000
    hist.add_sample(70000, 0);  // queuing_delay = 20000
    uint delay_before = hist.get_value();
    assert(delay_before == 20000);

    // Shift by 10ms
    hist.shift(10000);

    // Add 3 new samples with same absolute delay (70ms)
    // But now delay_base is 60ms, so queuing delay should be 10ms
    hist.add_sample(70000, 0);  // queuing_delay = 10000
    hist.add_sample(70000, 0);  // queuing_delay = 10000
    hist.add_sample(70000, 0);  // queuing_delay = 10000
    uint delay_after = hist.get_value();

    // All samples now have adjusted queuing delay
    assert(delay_after == 10000, "New samples should have adjusted queuing delay");
}

/**
 * Test full 13-minute history window wraparound
 */
fn void test_full_history_wraparound() @test
{
    DelayHist hist;
    hist.clear(0);

    // Fill all 13 history slots
    // First sample at time 0 doesn't trigger rotation
    hist.add_sample(50000, 0);  // idx stays 0

    // Next 13 samples (at 61s, 122s, ... 793s) will rotate through all slots
    for (usz i = 1; i <= delay_hist::DELAY_BASE_HISTORY; i++) {
        uint sample = 50000 + (uint)(i * 1000);  // Increasing delays
        hist.add_sample(sample, (ulong)(i * 61_000));  // Every 61 seconds
    }

    // After 13 rotations, should wrap back to index 0
    // (started at 0, rotated 13 times: 1, 2, ..., 12, 0)
    assert(hist.delay_base_idx == 0, "Should wrap to index 0 after 13 rotations");

    // delay_base should be the minimum of current history
    // The oldest entry (50000) was overwritten by the last sample (63000)
    // So the minimum is now 51000 (from i=1)
    assert(hist.delay_base == 51000, "delay_base should be minimum of all history");

    // Add one more sample to overwrite oldest slot (at index 0)
    hist.add_sample(40000, (ulong)((delay_hist::DELAY_BASE_HISTORY + 1) * 61_000));

    // delay_base should update to new minimum
    assert(hist.delay_base == 40000, "delay_base should update after slot overwrite");
}

/**
 * Test behavior with zero delay_base (edge case)
 */
fn void test_zero_delay_base() @test
{
    DelayHist hist;
    hist.clear(0);

    // Add sample with value 0
    hist.add_sample(0, 0);

    assert(hist.delay_base == 0);
    assert(hist.get_value() == 0);

    // Add 3 samples with 10ms delay to fill all slots
    hist.add_sample(10000, 0);  // queuing_delay = 10000
    hist.add_sample(10000, 0);  // queuing_delay = 10000
    hist.add_sample(10000, 0);  // queuing_delay = 10000

    // delay_base should remain 0
    assert(hist.delay_base == 0);

    // Queuing delay should be 10000 (all 3 slots now have 10000)
    assert(hist.get_value() == 10000);
}
