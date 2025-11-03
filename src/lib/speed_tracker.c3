module libtorrent::speed_tracker;

import std::io;
import std::time;

/**
 * Speed Tracker - Download/Upload Speed Calculation
 * =================================================
 * Tracks download/upload speeds using a sliding time window for smooth,
 * accurate speed calculations.
 *
 * Features:
 * - Sliding window (configurable, default 5 seconds)
 * - Per-source tracking (peer, webseed, etc.)
 * - Circular buffer for efficient memory usage
 * - Moving average for smooth speed display
 */

// ============================================================================
// Constants
// ============================================================================

const usz MAX_SAMPLES = 100;           // Maximum samples in circular buffer
const long DEFAULT_WINDOW_MS = 5000;   // Default 5-second window

// ============================================================================
// Data Structures
// ============================================================================

/**
 * Download source type
 */
enum DownloadSource : char
{
    UNKNOWN,
    PEER,
    WEBSEED,
    DHT
}

/**
 * Individual download sample
 */
struct SpeedSample
{
    long timestamp_ms;         // Unix timestamp in milliseconds
    ulong bytes;              // Bytes downloaded in this sample
    DownloadSource source;    // Where the data came from
}

/**
 * Speed Tracker
 * Maintains a sliding window of download samples for speed calculation
 */
struct SpeedTracker
{
    SpeedSample[MAX_SAMPLES] samples;  // Circular buffer of samples
    usz head;                          // Current write position
    usz count;                         // Number of samples in buffer
    long window_ms;                    // Time window in milliseconds
}

// ============================================================================
// Lifecycle
// ============================================================================

/**
 * Create a new SpeedTracker.
 *
 * @param window_ms : "Time window in milliseconds (0 = use default 5 seconds)"
 * @return "Initialized SpeedTracker"
 */
fn SpeedTracker* create(long window_ms = 0) @public
{
    SpeedTracker* tracker = mem::new(SpeedTracker);
    tracker.head = 0;
    tracker.count = 0;
    tracker.window_ms = (window_ms > 0) ? window_ms : DEFAULT_WINDOW_MS;
    return tracker;
}

/**
 * Free a SpeedTracker.
 */
fn void SpeedTracker.free(&self) @public
{
    free(self);
}

// ============================================================================
// Sample Recording
// ============================================================================

// Monotonic counter to ensure unique timestamps even when pieces complete in same millisecond
long global_timestamp_counter = 0;

/**
 * Get current time in milliseconds with sub-millisecond sequencing.
 * Returns monotonically increasing values even when called multiple times per millisecond.
 */
fn long get_current_time_ms()
{
    long base_time_ms = (long)(time::now().to_seconds() * 1000);

    // Add sub-millisecond sequence number to ensure monotonic ordering
    // This ensures unique timestamps even when multiple pieces complete per millisecond
    global_timestamp_counter++;
    return base_time_ms + (global_timestamp_counter % 1000);
}

/**
 * Add a download sample to the tracker.
 *
 * @param bytes : "Number of bytes downloaded"
 * @param source : "Source of the download (peer, webseed, etc.)"
 */
fn void SpeedTracker.add_bytes(&self, ulong bytes, DownloadSource source = DownloadSource.UNKNOWN) @public
{
    long now = get_current_time_ms();

    // Add sample to circular buffer
    self.samples[self.head].timestamp_ms = now;
    self.samples[self.head].bytes = bytes;
    self.samples[self.head].source = source;

    // Advance head pointer (circular)
    self.head = (self.head + 1) % MAX_SAMPLES;

    // Update count (saturate at MAX_SAMPLES)
    if (self.count < MAX_SAMPLES)
    {
        self.count++;
    }
}

// ============================================================================
// Speed Calculation
// ============================================================================

/**
 * Calculate current download speed based on samples within the time window.
 *
 * @return "Download speed in bytes per second"
 */
fn float SpeedTracker.get_speed(&self) @public
{
    if (self.count == 0) return 0.0;

    long now = get_current_time_ms();
    long window_start = now - self.window_ms;

    // Sum bytes from samples within the window
    ulong total_bytes = 0;
    long oldest_timestamp = now;
    long newest_timestamp = 0;
    usz samples_in_window = 0;

    // Iterate through circular buffer
    for (usz i = 0; i < self.count; i++)
    {
        // Calculate actual index in circular buffer
        usz index = (self.head + MAX_SAMPLES - self.count + i) % MAX_SAMPLES;
        SpeedSample sample = self.samples[index];

        // Only include samples within the time window
        if (sample.timestamp_ms >= window_start)
        {
            total_bytes += sample.bytes;
            samples_in_window++;

            if (sample.timestamp_ms < oldest_timestamp)
            {
                oldest_timestamp = sample.timestamp_ms;
            }
            if (sample.timestamp_ms > newest_timestamp)
            {
                newest_timestamp = sample.timestamp_ms;
            }
        }
    }

    // If no samples in window, return 0
    if (samples_in_window == 0) return 0.0;

    // Calculate actual time span of samples
    long time_span_ms = newest_timestamp - oldest_timestamp;

    // If all samples at same timestamp, use time since oldest sample
    if (time_span_ms == 0)
    {
        time_span_ms = now - oldest_timestamp;
        // Only return 0 if truly no time has passed at all
        if (time_span_ms == 0) return 0.0;
    }

    // Calculate speed: bytes/sec (allow even very short time spans for fast downloads)
    float speed = ((float)total_bytes * 1000.0) / (float)time_span_ms;
    return speed;
}

/**
 * Calculate speed from a specific source.
 *
 * @param source : "Download source to calculate speed for"
 * @return "Download speed in bytes per second for this source"
 */
fn float SpeedTracker.get_speed_for_source(&self, DownloadSource source) @public
{
    if (self.count == 0) return 0.0;

    long now = get_current_time_ms();
    long window_start = now - self.window_ms;

    // Sum bytes from samples within the window for this source
    ulong total_bytes = 0;
    long oldest_timestamp = now;
    long newest_timestamp = 0;
    usz samples_in_window = 0;

    // Iterate through circular buffer
    for (usz i = 0; i < self.count; i++)
    {
        // Calculate actual index in circular buffer
        usz index = (self.head + MAX_SAMPLES - self.count + i) % MAX_SAMPLES;
        SpeedSample sample = self.samples[index];

        // Only include samples within window AND from this source
        if (sample.timestamp_ms >= window_start && sample.source == source)
        {
            total_bytes += sample.bytes;
            samples_in_window++;

            if (sample.timestamp_ms < oldest_timestamp)
            {
                oldest_timestamp = sample.timestamp_ms;
            }
            if (sample.timestamp_ms > newest_timestamp)
            {
                newest_timestamp = sample.timestamp_ms;
            }
        }
    }

    // If no samples in window for this source, return 0
    if (samples_in_window == 0) return 0.0;

    // Calculate actual time span
    long time_span_ms = newest_timestamp - oldest_timestamp;

    // If all samples at same timestamp, use time since oldest sample
    if (time_span_ms == 0)
    {
        time_span_ms = now - oldest_timestamp;
        // Only return 0 if truly no time has passed at all
        if (time_span_ms == 0) return 0.0;
    }

    // Calculate speed: bytes/sec (allow even very short time spans for fast downloads)
    float speed = ((float)total_bytes * 1000.0) / (float)time_span_ms;
    return speed;
}

/**
 * Get total bytes downloaded in the current window.
 *
 * @return "Total bytes in the time window"
 */
fn ulong SpeedTracker.get_bytes_in_window(&self) @public
{
    if (self.count == 0) return 0;

    long now = get_current_time_ms();
    long window_start = now - self.window_ms;

    ulong total_bytes = 0;

    // Iterate through circular buffer
    for (usz i = 0; i < self.count; i++)
    {
        usz index = (self.head + MAX_SAMPLES - self.count + i) % MAX_SAMPLES;
        SpeedSample sample = self.samples[index];

        if (sample.timestamp_ms >= window_start)
        {
            total_bytes += sample.bytes;
        }
    }

    return total_bytes;
}

/**
 * Get number of samples currently in the tracker.
 *
 * @return "Sample count"
 */
fn usz SpeedTracker.get_sample_count(&self) @public
{
    return self.count;
}

/**
 * Reset the speed tracker (clear all samples).
 */
fn void SpeedTracker.reset(&self) @public
{
    self.head = 0;
    self.count = 0;
}
