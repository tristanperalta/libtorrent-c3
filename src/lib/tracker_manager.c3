module libtorrent::tracker_manager;

import std::time;
import std::math::random;
import std::io;

<*
 * Multi-Tracker Manager (BEP 12)
 * ===============================
 * Implements tier-based tracker failover with within-tier shuffling
 * and successful tracker promotion.
 *
 * BEP 12 Specification:
 * - Process tiers sequentially (all trackers in tier N must fail before tier N+1)
 * - Shuffle trackers within each tier at initialization
 * - Try trackers sequentially within tier until one succeeds
 * - Move successful tracker to front of its tier for future announces
 *>

// TrackerManager maintains the state for multi-tracker announces.
struct TrackerManager {
    String[][] tiers;            // Shuffled copy of announce_list tiers
    uint current_tier;           // Current tier index (0-based)
    uint current_index;          // Current tracker index within tier
    String active_tracker;       // The tracker that last succeeded (empty if none)
    bool has_active_tracker;     // Whether we have a successful tracker
}

<*
 * Shuffle an array of strings in place using Fisher-Yates algorithm.
 *
 * @param trackers : "Array of tracker URLs to shuffle"
 *>
fn void shuffle_trackers(String[] trackers)
{
    if (trackers.len <= 1) return;

    random::DefaultRandom rng;
    random::seed(&rng, (uint)time::now().to_seconds());

    // Fisher-Yates shuffle
    for (usz i = trackers.len - 1; i > 0; i--)
    {
        usz j = (usz)random::next_in_range(&rng, 0, (int)i);

        // Swap trackers[i] and trackers[j]
        String temp = trackers[i];
        trackers[i] = trackers[j];
        trackers[j] = temp;
    }
}

<*
 * Initialize tracker manager from announce_list.
 * Creates a shuffled copy of the tiers and initializes state.
 *
 * @param announce_list : "Multi-tracker tier list from torrent file"
 * @return "Initialized TrackerManager"
 *>
fn TrackerManager initialize(String[][] announce_list) @public
{
    TrackerManager manager;
    manager.current_tier = 0;
    manager.current_index = 0;
    manager.active_tracker = "";
    manager.has_active_tracker = false;

    if (announce_list.len == 0)
    {
        // No announce list - return empty manager
        manager.tiers = {};
        return manager;
    }

    // Create a deep copy of announce_list
    manager.tiers = mem::new_array(String[], announce_list.len);

    foreach (tier_idx, tier : announce_list)
    {
        if (tier.len == 0) continue;

        // Copy tier
        manager.tiers[tier_idx] = mem::new_array(String, tier.len);
        foreach (tracker_idx, tracker_url : tier)
        {
            manager.tiers[tier_idx][tracker_idx] = tracker_url.copy(mem);
        }

        // Shuffle trackers within this tier (BEP 12 requirement)
        shuffle_trackers(manager.tiers[tier_idx]);
    }

    return manager;
}

<*
 * Get the next tracker URL to try.
 * Returns the tracker at current position (tier, index).
 *
 * @return "Tracker URL to try, or empty string if no more trackers"
 *>
fn String TrackerManager.get_next_tracker(&self) @public
{
    // If we have an active tracker, return it first
    if (self.has_active_tracker && self.active_tracker.len > 0)
    {
        return self.active_tracker;
    }

    // No tiers available
    if (self.tiers.len == 0)
    {
        return "";
    }

    // Check if current tier is valid
    if (self.current_tier >= self.tiers.len)
    {
        return "";  // No more tiers
    }

    // Get current tier
    String[] tier = self.tiers[self.current_tier];

    // Check if current index is valid
    if (self.current_index >= tier.len)
    {
        return "";  // No more trackers in this tier
    }

    return tier[self.current_index];
}

<*
 * Mark the current tracker as successful.
 * Moves it to the front of its tier (BEP 12 requirement).
 *
 * @param tracker_url : "The tracker URL that succeeded"
 *>
fn void TrackerManager.mark_success(&self, String tracker_url) @public
{
    // Store as active tracker
    if (self.active_tracker.len > 0)
    {
        free(self.active_tracker);
    }
    self.active_tracker = tracker_url.copy(mem);
    self.has_active_tracker = true;

    // Move tracker to front of its tier
    if (self.current_tier >= self.tiers.len) return;
    String[] tier = self.tiers[self.current_tier];
    if (self.current_index >= tier.len) return;

    // Only move if not already at front
    if (self.current_index > 0)
    {
        String successful_tracker = tier[self.current_index];

        // Shift all trackers before it one position to the right
        for (usz i = self.current_index; i > 0; i--)
        {
            tier[i] = tier[i - 1];
        }

        // Place successful tracker at front
        tier[0] = successful_tracker;
    }

    // Reset to beginning of tier for next announce
    self.current_index = 0;
}

<*
 * Mark the current tracker as failed and advance to next.
 * Moves to next tracker in tier, or next tier if all in current tier failed.
 *
 * @return "true if there are more trackers to try, false if all exhausted"
 *>
fn bool TrackerManager.mark_failure(&self) @public
{
    // Advance to next tracker in current tier
    self.current_index++;

    // Check if we've exhausted current tier
    if (self.current_tier >= self.tiers.len)
    {
        return false;  // No more tiers
    }

    String[] tier = self.tiers[self.current_tier];
    if (self.current_index >= tier.len)
    {
        // Current tier exhausted, move to next tier
        self.current_tier++;
        self.current_index = 0;

        // Check if we have more tiers
        if (self.current_tier >= self.tiers.len)
        {
            return false;  // All tiers exhausted
        }
    }

    return true;  // More trackers available
}

<*
 * Reset to beginning (first tracker in first tier).
 * Used when starting a new announce cycle.
 *>
fn void TrackerManager.reset(&self) @public
{
    self.current_tier = 0;
    self.current_index = 0;
    // Keep active_tracker and has_active_tracker
}

<*
 * Reset to beginning and clear active tracker.
 * Used when you want to try all trackers again from scratch.
 *>
fn void TrackerManager.reset_all(&self) @public
{
    self.current_tier = 0;
    self.current_index = 0;
    if (self.active_tracker.len > 0)
    {
        free(self.active_tracker);
        self.active_tracker = "";
    }
    self.has_active_tracker = false;
}

<*
 * Get the currently active tracker URL.
 *
 * @return "Active tracker URL, or empty string if none"
 *>
fn String TrackerManager.get_active_tracker(&self) @public
{
    if (self.has_active_tracker)
    {
        return self.active_tracker;
    }
    return "";
}

<*
 * Check if there are any trackers available.
 *
 * @return "true if manager has at least one tracker"
 *>
fn bool TrackerManager.has_trackers(&self) @public
{
    return self.tiers.len > 0;
}

<*
 * Get total number of tiers.
 *
 * @return "Number of tiers"
 *>
fn uint TrackerManager.get_tier_count(&self) @public
{
    return (uint)self.tiers.len;
}

<*
 * Get number of trackers in a specific tier.
 *
 * @param tier : "Tier index (0-based)"
 * @return "Number of trackers in tier, or 0 if invalid tier"
 *>
fn uint TrackerManager.get_tracker_count(&self, uint tier) @public
{
    if (tier >= self.tiers.len) return 0;
    return (uint)self.tiers[tier].len;
}

<*
 * Get tracker URL by tier and index.
 *
 * @param tier : "Tier index (0-based)"
 * @param index : "Tracker index within tier (0-based)"
 * @return "Tracker URL, or empty string if invalid tier/index"
 *>
fn String TrackerManager.get_tracker_url(&self, uint tier, uint index) @public
{
    if (tier >= self.tiers.len) return "";
    if (index >= self.tiers[tier].len) return "";
    return self.tiers[tier][index];
}

<*
 * Get all tracker URLs in a specific tier (for parallel announces).
 * Used when announce_to_all_trackers=true.
 *
 * @param tier : "Tier index (0-based)"
 * @return "List of tracker URLs in the tier (caller must free list, not strings)"
 *>
fn String[] TrackerManager.get_tier_trackers(&self, uint tier) @public
{
    if (tier >= self.tiers.len)
    {
        return {};  // Invalid tier
    }

    // Return reference to the tier array (no copy needed)
    return self.tiers[tier];
}

<*
 * Get one tracker from each tier (for parallel tier announces).
 * Used when announce_to_all_tiers=true, announce_to_all_trackers=false (uTorrent mode).
 * Returns the first tracker from each tier.
 *
 * @return "List of tracker URLs (one per tier, caller must free)"
 *>
fn String[] TrackerManager.get_one_per_tier(&self) @public
{
    if (self.tiers.len == 0)
    {
        return {};
    }

    // Allocate result array
    String[] result = mem::new_array(String, self.tiers.len);
    uint count = 0;

    foreach (tier : self.tiers)
    {
        if (tier.len > 0)
        {
            result[count++] = tier[0];  // First tracker from this tier
        }
    }

    // If we didn't fill the array, return a slice of what we actually filled
    if (count < self.tiers.len)
    {
        return result[0..count];
    }

    return result;
}

<*
 * Get all tracker URLs across all tiers (for maximum parallel announces).
 * Used when both announce_to_all_trackers=true AND announce_to_all_tiers=true.
 *
 * @return "List of all tracker URLs (caller must free)"
 *>
fn String[] TrackerManager.get_all_trackers(&self) @public
{
    if (self.tiers.len == 0)
    {
        return {};
    }

    // Count total trackers
    uint total_count = 0;
    foreach (tier : self.tiers)
    {
        total_count += (uint)tier.len;
    }

    if (total_count == 0)
    {
        return {};
    }

    // Allocate result array
    String[] result = mem::new_array(String, total_count);
    uint index = 0;

    // Copy all trackers from all tiers
    foreach (tier : self.tiers)
    {
        foreach (tracker_url : tier)
        {
            result[index++] = tracker_url;
        }
    }

    return result;
}

<*
 * Free tracker manager resources.
 *>
fn void TrackerManager.free(&self) @public
{
    // Free all copied tracker URLs
    foreach (tier : self.tiers)
    {
        foreach (tracker : tier)
        {
            free(tracker);
        }
        free(tier);
    }
    if (self.tiers.len > 0)
    {
        free(self.tiers);
    }

    // Free active tracker
    if (self.active_tracker.len > 0)
    {
        free(self.active_tracker);
    }
}
