module test_speed_tracker;

import std::io;
import std::time;
import libtorrent::speed_tracker;

<*
 * Unit tests for speed tracking implementation.
 *>

// Test: SpeedTracker initialization
fn void test_speed_tracker_init() @test
{
    // Create tracker with default window
    speed_tracker::SpeedTracker* tracker = speed_tracker::create();
    assert(tracker != null, "Failed to create SpeedTracker");
    defer if (tracker) tracker.free();

    assert(tracker.window_ms == 5000, "Default window should be 5000ms");
    assert(tracker.count == 0, "Initial count should be 0");
    assert(tracker.head == 0, "Initial head should be 0");
}

// Test: SpeedTracker custom window
fn void test_speed_tracker_custom_window() @test
{
    // Create tracker with custom window (10 seconds)
    speed_tracker::SpeedTracker* tracker = speed_tracker::create(10000);
    assert(tracker != null, "Failed to create SpeedTracker");
    defer if (tracker) tracker.free();

    assert(tracker.window_ms == 10000, "Custom window should be 10000ms");
}

// Test: Add bytes to tracker
fn void test_speed_tracker_add_bytes() @test
{
    speed_tracker::SpeedTracker* tracker = speed_tracker::create();
    assert(tracker != null, "Failed to create SpeedTracker");
    defer if (tracker) tracker.free();

    // Add some bytes
    tracker.add_bytes(1024, speed_tracker::DownloadSource.PEER);
    assert(tracker.get_sample_count() == 1, "Should have 1 sample");

    tracker.add_bytes(2048, speed_tracker::DownloadSource.PEER);
    assert(tracker.get_sample_count() == 2, "Should have 2 samples");

    tracker.add_bytes(512, speed_tracker::DownloadSource.WEBSEED);
    assert(tracker.get_sample_count() == 3, "Should have 3 samples");
}

// Test: Speed calculation with two samples
fn void test_speed_tracker_single_sample() @test
{
    speed_tracker::SpeedTracker* tracker = speed_tracker::create();
    assert(tracker != null, "Failed to create SpeedTracker");
    defer if (tracker) tracker.free();

    // Add two samples
    tracker.add_bytes(1024, speed_tracker::DownloadSource.PEER);
    tracker.add_bytes(1024, speed_tracker::DownloadSource.PEER);

    // With monotonic timestamp sequencing, should calculate speed between samples
    // Each sample gets a unique timestamp (base_ms * 1000 + counter)
    float speed = tracker.get_speed();
    assert(speed > 0.0, "Speed should be calculated with multiple samples");
}

// Test: Bytes in window calculation
fn void test_speed_tracker_bytes_in_window() @test
{
    speed_tracker::SpeedTracker* tracker = speed_tracker::create(10000);  // 10 second window
    assert(tracker != null, "Failed to create SpeedTracker");
    defer if (tracker) tracker.free();

    // Add samples
    tracker.add_bytes(1024, speed_tracker::DownloadSource.PEER);
    tracker.add_bytes(2048, speed_tracker::DownloadSource.PEER);
    tracker.add_bytes(512, speed_tracker::DownloadSource.WEBSEED);

    // All samples should be in window
    ulong bytes = tracker.get_bytes_in_window();
    assert(bytes == 3584, "Should have 3584 bytes total (1024+2048+512)");
}

// Test: Per-source speed calculation
fn void test_speed_tracker_per_source() @test
{
    speed_tracker::SpeedTracker* tracker = speed_tracker::create();
    assert(tracker != null, "Failed to create SpeedTracker");
    defer if (tracker) tracker.free();

    // Add samples from different sources
    tracker.add_bytes(1024, speed_tracker::DownloadSource.PEER);
    tracker.add_bytes(2048, speed_tracker::DownloadSource.WEBSEED);
    tracker.add_bytes(512, speed_tracker::DownloadSource.PEER);

    // Get total bytes in window
    ulong total = tracker.get_bytes_in_window();
    assert(total == 3584, "Total should be 3584 bytes");

    // Note: Speed calculation requires time difference, so we can't easily test
    // per-source speed values without time manipulation
}

// Test: Reset tracker
fn void test_speed_tracker_reset() @test
{
    speed_tracker::SpeedTracker* tracker = speed_tracker::create();
    assert(tracker != null, "Failed to create SpeedTracker");
    defer if (tracker) tracker.free();

    // Add samples
    tracker.add_bytes(1024, speed_tracker::DownloadSource.PEER);
    tracker.add_bytes(2048, speed_tracker::DownloadSource.PEER);
    assert(tracker.get_sample_count() == 2, "Should have 2 samples");

    // Reset
    tracker.reset();
    assert(tracker.get_sample_count() == 0, "Should have 0 samples after reset");
    assert(tracker.get_bytes_in_window() == 0, "Should have 0 bytes after reset");
}

// Test: Circular buffer wraparound
fn void test_speed_tracker_circular_buffer() @test
{
    speed_tracker::SpeedTracker* tracker = speed_tracker::create();
    assert(tracker != null, "Failed to create SpeedTracker");
    defer if (tracker) tracker.free();

    // Add more than MAX_SAMPLES (100) samples
    for (usz i = 0; i < 150; i++)
    {
        tracker.add_bytes(1024, speed_tracker::DownloadSource.PEER);
    }

    // Should saturate at MAX_SAMPLES
    assert(tracker.get_sample_count() == 100, "Should saturate at MAX_SAMPLES (100)");
}

// Test: DownloadSource enum values
fn void test_speed_tracker_source_types() @test
{
    // Verify enum values exist and are distinct
    speed_tracker::DownloadSource unknown = speed_tracker::DownloadSource.UNKNOWN;
    speed_tracker::DownloadSource peer = speed_tracker::DownloadSource.PEER;
    speed_tracker::DownloadSource webseed = speed_tracker::DownloadSource.WEBSEED;
    speed_tracker::DownloadSource dht = speed_tracker::DownloadSource.DHT;

    assert((int)unknown != (int)peer, "UNKNOWN and PEER should be distinct");
    assert((int)peer != (int)webseed, "PEER and WEBSEED should be distinct");
    assert((int)webseed != (int)dht, "WEBSEED and DHT should be distinct");
}

// Test: Zero bytes handling
fn void test_speed_tracker_zero_bytes() @test
{
    speed_tracker::SpeedTracker* tracker = speed_tracker::create();
    assert(tracker != null, "Failed to create SpeedTracker");
    defer if (tracker) tracker.free();

    // Add zero bytes (should be valid)
    tracker.add_bytes(0, speed_tracker::DownloadSource.PEER);
    assert(tracker.get_sample_count() == 1, "Should have 1 sample even with 0 bytes");

    ulong bytes = tracker.get_bytes_in_window();
    assert(bytes == 0, "Should have 0 bytes total");
}

// Test: Large byte values
fn void test_speed_tracker_large_values() @test
{
    speed_tracker::SpeedTracker* tracker = speed_tracker::create();
    assert(tracker != null, "Failed to create SpeedTracker");
    defer if (tracker) tracker.free();

    // Add large byte value (262KB piece)
    ulong large_value = 262144;
    tracker.add_bytes(large_value, speed_tracker::DownloadSource.PEER);

    ulong bytes = tracker.get_bytes_in_window();
    assert(bytes == large_value, "Should handle large byte values");
}
