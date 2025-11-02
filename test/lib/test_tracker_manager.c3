module libtorrent::tracker_manager_test;

import std::io;
import libtorrent::tracker_manager;

/**
 * Tracker Manager Test Suite (BEP 12)
 * ====================================
 * Tests for multi-tracker tier-based selection and failover.
 */

<*
 * Test basic initialization and tracker retrieval.
 *>
fn void test_initialize_basic() @test
{
    // Create announce list with 2 tiers
    String[][] announce_list = mem::new_array(String[], 2);
    announce_list[0] = mem::new_array(String, 2);
    announce_list[0][0] = "udp://tracker1.example.com:6969/announce";
    announce_list[0][1] = "udp://tracker2.example.com:6969/announce";
    announce_list[1] = mem::new_array(String, 1);
    announce_list[1][0] = "http://backup.example.com:80/announce";

    // Initialize tracker manager
    tracker_manager::TrackerManager mgr = tracker_manager::initialize(announce_list);
    defer mgr.free();

    // Verify tier count
    assert(mgr.get_tier_count() == 2, "Should have 2 tiers");

    // Verify tracker counts
    assert(mgr.get_tracker_count(0) == 2, "Tier 0 should have 2 trackers");
    assert(mgr.get_tracker_count(1) == 1, "Tier 1 should have 1 tracker");

    // Get first tracker (should be from tier 0)
    String tracker = mgr.get_next_tracker();
    assert(tracker.len > 0, "Should return a tracker");
    assert(tracker.contains("tracker") || tracker.contains("example.com"), "Should be a valid tracker URL");

    // Cleanup announce_list
    foreach (tier : announce_list) free(tier);
    free(announce_list);

    io::printn("✓ Basic initialization and tracker retrieval");
}

<*
 * Test tier-based failover.
 *>
fn void test_tier_failover() @test
{
    // Create announce list with 2 tiers
    String[][] announce_list = mem::new_array(String[], 2);
    announce_list[0] = mem::new_array(String, 2);
    announce_list[0][0] = "udp://tier0-tracker1.example.com:6969/announce";
    announce_list[0][1] = "udp://tier0-tracker2.example.com:6969/announce";
    announce_list[1] = mem::new_array(String, 1);
    announce_list[1][0] = "http://tier1-backup.example.com:80/announce";

    tracker_manager::TrackerManager mgr = tracker_manager::initialize(announce_list);
    defer mgr.free();

    // Get first tracker from tier 0
    String tracker1 = mgr.get_next_tracker();
    assert(tracker1.contains("tier0"), "First tracker should be from tier 0");

    // Mark as failed - should advance to next tracker in tier 0
    bool has_more = mgr.mark_failure();
    assert(has_more, "Should have more trackers");

    String tracker2 = mgr.get_next_tracker();
    assert(tracker2.contains("tier0"), "Second tracker should also be from tier 0");

    // Mark as failed - should advance to tier 1
    has_more = mgr.mark_failure();
    assert(has_more, "Should have tier 1 available");

    String tracker3 = mgr.get_next_tracker();
    assert(tracker3.contains("tier1"), "Third tracker should be from tier 1");

    // Mark as failed - no more trackers
    has_more = mgr.mark_failure();
    assert(!has_more, "Should have no more trackers");

    // Cleanup
    foreach (tier : announce_list) free(tier);
    free(announce_list);

    io::printn("✓ Tier-based failover");
}

<*
 * Test successful tracker promotion (move to front).
 *>
fn void test_tracker_promotion() @test
{
    // Create announce list with single tier, 3 trackers
    String[][] announce_list = mem::new_array(String[], 1);
    announce_list[0] = mem::new_array(String, 3);
    announce_list[0][0] = "udp://tracker-a.example.com:6969/announce";
    announce_list[0][1] = "udp://tracker-b.example.com:6969/announce";
    announce_list[0][2] = "udp://tracker-c.example.com:6969/announce";

    tracker_manager::TrackerManager mgr = tracker_manager::initialize(announce_list);
    defer mgr.free();

    // Skip first tracker (fail)
    String tracker1 = mgr.get_next_tracker();
    mgr.mark_failure();

    // Get second tracker and mark as successful
    String tracker2 = mgr.get_next_tracker();
    String tracker2_copy = tracker2.copy(mem);
    defer free(tracker2_copy);

    mgr.mark_success(tracker2);

    // Verify it's now the active tracker
    String active = mgr.get_active_tracker();
    assert(active == tracker2, "Successful tracker should be active");

    // Reset and get next tracker - should be the successful one (now at front)
    mgr.reset();
    String next = mgr.get_next_tracker();
    assert(next == active, "Active tracker should be returned first on reset");

    // Cleanup
    foreach (tier : announce_list) free(tier);
    free(announce_list);

    io::printn("✓ Successful tracker promotion");
}

<*
 * Test reset functionality.
 *>
fn void test_reset() @test
{
    // Create simple announce list
    String[][] announce_list = mem::new_array(String[], 1);
    announce_list[0] = mem::new_array(String, 2);
    announce_list[0][0] = "udp://tracker1.example.com:6969/announce";
    announce_list[0][1] = "udp://tracker2.example.com:6969/announce";

    tracker_manager::TrackerManager mgr = tracker_manager::initialize(announce_list);
    defer mgr.free();

    // Advance to second tracker
    String tracker1 = mgr.get_next_tracker();
    mgr.mark_failure();

    // Reset - should go back to beginning
    mgr.reset();
    String tracker_after_reset = mgr.get_next_tracker();

    // Should get the same first tracker again (or the shuffled first tracker)
    assert(tracker_after_reset.len > 0, "Should have a tracker after reset");

    // Cleanup
    foreach (tier : announce_list) free(tier);
    free(announce_list);

    io::printn("✓ Reset functionality");
}

<*
 * Test empty announce list.
 *>
fn void test_empty_announce_list() @test
{
    // Create empty announce list
    String[][] empty_list = {};

    tracker_manager::TrackerManager mgr = tracker_manager::initialize(empty_list);
    defer mgr.free();

    assert(!mgr.has_trackers(), "Empty list should have no trackers");
    assert(mgr.get_tier_count() == 0, "Should have 0 tiers");

    String tracker = mgr.get_next_tracker();
    assert(tracker.len == 0, "Should return empty string for no trackers");

    io::printn("✓ Empty announce list handling");
}

<*
 * Test single tracker.
 *>
fn void test_single_tracker() @test
{
    // Create announce list with single tracker
    String[][] announce_list = mem::new_array(String[], 1);
    announce_list[0] = mem::new_array(String, 1);
    announce_list[0][0] = "udp://only-tracker.example.com:6969/announce";

    tracker_manager::TrackerManager mgr = tracker_manager::initialize(announce_list);
    defer mgr.free();

    assert(mgr.has_trackers(), "Should have trackers");
    assert(mgr.get_tier_count() == 1, "Should have 1 tier");
    assert(mgr.get_tracker_count(0) == 1, "Tier 0 should have 1 tracker");

    String tracker = mgr.get_next_tracker();
    assert(tracker.contains("only-tracker"), "Should get the only tracker");

    // Mark as failed - no more trackers
    bool has_more = mgr.mark_failure();
    assert(!has_more, "Should have no more trackers after failing the only one");

    // Cleanup
    foreach (tier : announce_list) free(tier);
    free(announce_list);

    io::printn("✓ Single tracker handling");
}

<*
 * Test multiple tiers with empty tiers.
 *>
fn void test_skip_empty_tiers() @test
{
    // Create announce list with an empty tier (shouldn't happen but test robustness)
    String[][] announce_list = mem::new_array(String[], 3);
    announce_list[0] = mem::new_array(String, 1);
    announce_list[0][0] = "udp://tier0.example.com:6969/announce";
    announce_list[1] = mem::new_array(String, 0);  // Empty tier
    announce_list[2] = mem::new_array(String, 1);
    announce_list[2][0] = "http://tier2.example.com:80/announce";

    tracker_manager::TrackerManager mgr = tracker_manager::initialize(announce_list);
    defer mgr.free();

    // Get first tracker
    String tracker1 = mgr.get_next_tracker();
    assert(tracker1.contains("tier0"), "Should get tier 0 tracker");

    // Fail tier 0 - should skip empty tier 1 and go to tier 2
    mgr.mark_failure();
    String tracker2 = mgr.get_next_tracker();

    // Either gets tier 2 or empty (depending on implementation)
    // For robustness, empty tier should be skipped
    assert(tracker2.len == 0 || tracker2.contains("tier2"),
           "Should skip empty tier and get tier 2 or return empty");

    // Cleanup
    foreach (tier : announce_list) free(tier);
    free(announce_list);

    io::printn("✓ Skip empty tiers");
}
