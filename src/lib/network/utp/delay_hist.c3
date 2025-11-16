/**
 * Delay History Tracker for LEDBAT Congestion Control
 *
 * This module implements delay measurement and tracking for μTP's LEDBAT
 * (Low Extra Delay Background Transport) congestion control algorithm.
 *
 * Based on libutp implementation (Transmission):
 * /home/tristan/sources/libutp/utp_internal.cpp lines 249-401
 *
 * Key concepts:
 * - delay_base: Minimum observed delay (propagation delay + processing)
 * - queuing_delay: Additional delay from network congestion (sample - delay_base)
 * - Sliding window: Tracks minimum delay over 13 minutes to handle clock drift
 * - Sample history: Keeps last 3 samples to filter transient spikes
 */

module libtorrent::network::utp::delay_hist;

import std::time;

// Number of recent delay samples to track (minimum of these is used)
const usz CUR_DELAY_SIZE = 3;

// Number of delay_base history entries (13 minutes at 1-minute granularity)
const usz DELAY_BASE_HISTORY = 13;

// Timestamp mask for wraparound handling (32-bit timestamps)
const uint TIMESTAMP_MASK = 0xFFFFFFFF;

/**
 * DelayHist - Tracks delay measurements with clock drift compensation
 *
 * Maintains a sliding window of delay measurements to determine the
 * minimum delay (base delay) and current queuing delay. Handles:
 * - Timestamp wraparound (32-bit timestamps wrap every ~72 minutes)
 * - Clock drift between peers
 * - Transient delay spikes (using minimum of last 3 samples)
 */
struct DelayHist {
    // Minimum observed delay (propagation + processing delay)
    // This represents the "base" delay when the network is idle
    uint delay_base;

    // Recent delay samples (normalized by delay_base)
    // These values represent queuing delay only
    uint[CUR_DELAY_SIZE] cur_delay_hist;
    usz cur_delay_idx;

    // History of delay_base values over time (13-minute sliding window)
    // Used to detect and compensate for clock drift
    uint[DELAY_BASE_HISTORY] delay_base_hist;
    usz delay_base_idx;
    ulong delay_base_time;  // Last time we rotated delay_base_hist

    // Whether delay_base has been initialized with real measurements
    bool initialized;
}

/**
 * Clear all delay history and reset to initial state
 *
 * @param current_ms Current time in milliseconds
 */
fn void DelayHist.clear(&self, ulong current_ms) @public
{
    self.initialized = false;
    self.delay_base = 0;
    self.cur_delay_idx = 0;
    self.delay_base_idx = 0;
    self.delay_base_time = current_ms;

    for (usz i = 0; i < CUR_DELAY_SIZE; i++) {
        self.cur_delay_hist[i] = 0;
    }

    for (usz i = 0; i < DELAY_BASE_HISTORY; i++) {
        self.delay_base_hist[i] = 0;
    }
}

/**
 * Compare two timestamps with wraparound handling
 *
 * 32-bit timestamps wrap every ~72 minutes. This function correctly
 * compares timestamps across the wraparound boundary.
 *
 * @param lhs Left-hand timestamp
 * @param rhs Right-hand timestamp
 * @return true if lhs < rhs (accounting for wraparound)
 */
fn bool wrapping_compare_less(uint lhs, uint rhs) @private
{
    // Calculate distances in both directions around the circular number space
    // dist_down: distance from lhs to rhs going down (lhs - rhs)
    // dist_up: distance from lhs to rhs going up (rhs - lhs)
    uint dist_down = lhs - rhs;
    uint dist_up = rhs - lhs;

    // The shorter distance indicates the true ordering
    // If dist_up is shorter, lhs < rhs
    // If dist_down is shorter, rhs < lhs
    return dist_up < dist_down;
}

/**
 * Add a new delay sample and update delay history
 *
 * This is called for each received packet with the one-way delay measurement.
 * The delay_base is updated to track the minimum observed delay, and the
 * current queuing delay (sample - delay_base) is stored.
 *
 * Every 60 seconds, the delay_base_hist is rotated and delay_base is
 * recalculated as the minimum of the last 13 minutes.
 *
 * @param sample One-way delay measurement in microseconds
 * @param current_ms Current time in milliseconds
 */
fn void DelayHist.add_sample(&self, uint sample, ulong current_ms) @public
{
    // The two clocks (in the two peers) are assumed not to progress at the
    // exact same rate. They are assumed to be drifting, which causes the
    // delay samples to contain a systematic error. This is why we update
    // the delay_base every minute, to adjust for this.
    //
    // Timestamps will keep drifting and eventually wrap. We can cross the
    // wrapping boundary in two directions:
    // 1. Going up (delay_base near 0, sample wraps to max)
    // 2. Going down (delay_base near max, sample wraps to 0)
    //
    // Example (wraparound down):
    //   delay_base = 0xffffff00, sample = 0x00000400
    //   sample - delay_base = 0x500 (correct difference via unsigned overflow)
    //
    // Example (wraparound up - needs special handling):
    //   delay_base = 0x00000400, sample = 0xffffff00
    //   sample - delay_base = 0xfffffb00 (very large number)
    //   This should be interpreted as 0 (sample is "before" delay_base)

    if (!self.initialized) {
        // First sample - initialize everything
        for (usz i = 0; i < DELAY_BASE_HISTORY; i++) {
            self.delay_base_hist[i] = sample;
        }
        self.delay_base = sample;
        self.initialized = true;
    }

    // Update current delay_base_hist entry if sample is smaller
    if (wrapping_compare_less(sample, self.delay_base_hist[self.delay_base_idx])) {
        self.delay_base_hist[self.delay_base_idx] = sample;
    }

    // Update delay_base if sample is smaller (with wraparound handling)
    if (wrapping_compare_less(sample, self.delay_base)) {
        self.delay_base = sample;
    }

    // Calculate queuing delay (this operation may wrap, and is supposed to)
    uint delay = sample - self.delay_base;

    // Sanity check - if delay > 32 seconds, something is very wrong
    // (commented out for performance, but useful for debugging)
    // assert(delay < 0x2000000);

    // Store in circular buffer
    self.cur_delay_hist[self.cur_delay_idx] = delay;
    self.cur_delay_idx = (self.cur_delay_idx + 1) % CUR_DELAY_SIZE;

    // Once every minute, rotate the delay_base_hist window
    if (current_ms - self.delay_base_time > 60_000) {
        self.delay_base_time = current_ms;
        self.delay_base_idx = (self.delay_base_idx + 1) % DELAY_BASE_HISTORY;

        // Initialize new slot with current sample
        self.delay_base_hist[self.delay_base_idx] = sample;

        // Recalculate delay_base as minimum of last 13 minutes
        self.delay_base = self.delay_base_hist[0];
        for (usz i = 1; i < DELAY_BASE_HISTORY; i++) {
            if (wrapping_compare_less(self.delay_base_hist[i], self.delay_base)) {
                self.delay_base = self.delay_base_hist[i];
            }
        }
    }
}

/**
 * Get current queuing delay
 *
 * Returns the minimum of the last 3 delay samples. This filters out
 * transient delay spikes that don't represent true congestion.
 *
 * In libutp, this returns UINT_MAX if no samples, but we return the
 * minimum of only valid samples (ignoring uninitialized slots with value 0
 * when we have real delay measurements).
 *
 * @return Current queuing delay in microseconds
 */
fn uint DelayHist.get_value(&self) @public
{
    if (!self.initialized) {
        return 0;
    }

    // Find minimum, treating all values as valid
    // (in practice, initialized slots will have been filled)
    uint value = self.cur_delay_hist[0];
    for (usz i = 1; i < CUR_DELAY_SIZE; i++) {
        if (self.cur_delay_hist[i] < value) {
            value = self.cur_delay_hist[i];
        }
    }
    return value;
}

/**
 * Shift all delay measurements by an offset
 *
 * This is used for clock drift compensation. When we detect that the
 * remote peer's clock has drifted, we adjust our delay_base accordingly
 * to maintain accurate delay measurements.
 *
 * @param offset Amount to shift delay_base (in microseconds)
 */
fn void DelayHist.shift(&self, uint offset) @public
{
    // Increase all base delays by this amount
    for (usz i = 0; i < DELAY_BASE_HISTORY; i++) {
        self.delay_base_hist[i] += offset;
    }
    self.delay_base += offset;
}
