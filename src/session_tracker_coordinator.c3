module torrent_client::session_tracker_coordinator;

import std::io;
import async::event_loop;
import async::timer;
import libtorrent::tracker;
import libtorrent::tracker_manager;
import libtorrent::metainfo;
import torrent_client::download_session;

/**
 * Session Tracker Coordinator
 * ============================
 * Manages tracker announces with retry logic and multi-tracker failover.
 *
 * Extracted from download_session.c3 to improve modularity.
 * Implements BEP 12 multi-tracker support with exponential backoff.
 */

/**
 * Callback type for successful tracker announces.
 * Called when peers are received from tracker.
 */
alias OnPeersReceivedCallback = fn void(tracker::TrackerResponse* response, void* user_data);

/**
 * Callback type for tracker failures.
 * Called when announce fails after all retries exhausted.
 */
alias OnTrackerFailedCallback = fn void(String error_msg, void* user_data);

/**
 * Tracker coordinator state.
 */
struct TrackerCoordinator
{
    event_loop::EventLoop* loop;
    metainfo::TorrentFile* torrent;
    tracker_manager::TrackerManager* tracker_mgr;

    // Retry state
    async::timer::Timer* retry_timer;
    int announce_retry_count;
    int announce_backoff_ms;
    bool initial_announce_done;
    String current_tracker_url;

    // Periodic announce timer
    async::timer::Timer* announce_timer;

    // Callbacks
    OnPeersReceivedCallback on_peers_received;
    OnTrackerFailedCallback on_tracker_failed;
    void* user_data;
}

/**
 * Create a new tracker coordinator.
 *
 * @param loop : "Event loop"
 * @param torrent : "Torrent file"
 * @param tracker_mgr : "Tracker manager (can be null)"
 * @param current_tracker_url : "Current tracker URL"
 * @return "New tracker coordinator"
 */
fn TrackerCoordinator* create(event_loop::EventLoop* loop,
                               metainfo::TorrentFile* torrent,
                               tracker_manager::TrackerManager* tracker_mgr,
                               String current_tracker_url) @public
{
    TrackerCoordinator* coord = mem::new(TrackerCoordinator);
    coord.loop = loop;
    coord.torrent = torrent;
    coord.tracker_mgr = tracker_mgr;
    coord.retry_timer = null;
    coord.announce_timer = null;
    coord.announce_retry_count = 0;
    coord.announce_backoff_ms = 0;
    coord.initial_announce_done = false;
    coord.current_tracker_url = current_tracker_url;
    coord.on_peers_received = null;
    coord.on_tracker_failed = null;
    coord.user_data = null;

    return coord;
}

/**
 * Set the callback for successful peer reception.
 */
fn void TrackerCoordinator.set_peers_received_callback(&self,
                                                         OnPeersReceivedCallback callback,
                                                         void* user_data) @public
{
    self.on_peers_received = callback;
    self.user_data = user_data;
}

/**
 * Set the callback for tracker failures.
 */
fn void TrackerCoordinator.set_failed_callback(&self,
                                                OnTrackerFailedCallback callback,
                                                void* user_data) @public
{
    self.on_tracker_failed = callback;
    self.user_data = user_data;
}

/**
 * Start initial tracker announce with retry support.
 *
 * @param event : "Event string (empty, started, stopped, completed)"
 */
fn void TrackerCoordinator.start_announce(&self, String event) @public
{
    // Determine which tracker URL to use
    if (self.tracker_mgr && self.tracker_mgr.has_trackers())
    {
        // BEP 12: Use tracker manager for multi-tracker support
        String tracker_url = self.tracker_mgr.get_next_tracker();
        if (tracker_url.len > 0)
        {
            self.current_tracker_url = tracker_url;
            tracker::announce_to_url(self.loop, self.torrent, tracker_url, 6881, event,
                                      &on_announce_complete_with_retry_internal, self);
        }
        else
        {
            io::eprintfn("[COORD] No valid trackers available");
        }
    }
    else
    {
        // Fallback: Use primary announce URL from torrent
        tracker::announce(self.loop, self.torrent, 6881, event,
                          &on_announce_complete_with_retry_internal, self);
    }
}

/**
 * Start periodic announces with the given interval.
 *
 * @param interval_seconds : "Announce interval in seconds"
 */
fn void TrackerCoordinator.start_periodic_announces(&self, int interval_seconds) @public
{
    if (self.announce_timer)
    {
        // Timer already running
        return;
    }

    ulong interval_ms = (ulong)(interval_seconds * 1000);
    io::printfn("  Setting up periodic announce every %d seconds", interval_seconds);

    async::timer::Timer*? timer_opt = async::timer::create(self.loop);
    if (catch err = timer_opt)
    {
        io::eprintfn("  Warning: Failed to create announce timer");
        return;
    }

    self.announce_timer = timer_opt;
    self.announce_timer.start(interval_ms, interval_ms,
                              &on_periodic_announce_internal, self);
}

/**
 * Stop all timers and clean up.
 */
fn void TrackerCoordinator.stop(&self) @public
{
    if (self.retry_timer)
    {
        self.retry_timer.stop();
        self.retry_timer.close();
        self.retry_timer = null;
    }

    if (self.announce_timer)
    {
        self.announce_timer.stop();
        self.announce_timer.close();
        self.announce_timer = null;
    }
}

/**
 * Free the coordinator and all resources.
 */
fn void TrackerCoordinator.free(&self) @public
{
    self.stop();
    free(self);
}

/**
 * Get current tracker URL.
 */
fn String TrackerCoordinator.get_current_tracker(&self) @public
{
    return self.current_tracker_url;
}

/**
 * Check if initial announce has completed successfully.
 */
fn bool TrackerCoordinator.is_initial_announce_done(&self) @public
{
    return self.initial_announce_done;
}

// ============================================================================
// Internal Callbacks
// ============================================================================

/**
 * Internal retry timer callback.
 */
fn void on_retry_timer_internal(async::timer::Timer* timer, void* user_data)
{
    TrackerCoordinator* coord = (TrackerCoordinator*)user_data;

    io::printfn("  Retrying tracker announce (attempt %d)...", coord.announce_retry_count + 1);

    // Close retry timer
    timer.close();
    coord.retry_timer = null;

    // Retry announce
    tracker::announce(coord.loop, coord.torrent, 6881,
                      coord.initial_announce_done ? "" : "started",
                      &on_announce_complete_with_retry_internal, coord);
}

/**
 * Internal periodic announce callback.
 */
fn void on_periodic_announce_internal(async::timer::Timer* timer, void* user_data)
{
    TrackerCoordinator* coord = (TrackerCoordinator*)user_data;

    io::printfn("Periodic tracker re-announce...");

    // BEP 12: Use the active tracker (the one that succeeded)
    if (coord.tracker_mgr && coord.tracker_mgr.has_trackers())
    {
        String active_tracker = coord.tracker_mgr.get_active_tracker();
        if (active_tracker.len > 0)
        {
            // Re-announce to successful tracker
            tracker::announce_to_url(coord.loop, coord.torrent, active_tracker, 6881, "",
                                      &on_periodic_announce_complete_internal, coord);
        }
        else
        {
            // No active tracker yet - use current tracker
            tracker::announce_to_url(coord.loop, coord.torrent, coord.current_tracker_url, 6881, "",
                                      &on_periodic_announce_complete_internal, coord);
        }
    }
    else
    {
        // Fallback: Use primary tracker
        tracker::announce(coord.loop, coord.torrent, 6881, "",
                          &on_periodic_announce_complete_internal, coord);
    }
}

/**
 * Internal callback for periodic announces (simpler, no retry logic).
 */
fn void on_periodic_announce_complete_internal(tracker::TrackerResponse* response,
                                                int status,
                                                void* user_data)
{
    TrackerCoordinator* coord = (TrackerCoordinator*)user_data;

    if (status != 0 || !response || response.failure_reason.len > 0)
    {
        // Periodic announce failed - just log it, don't retry
        if (status != 0)
        {
            io::eprintfn("  Periodic announce failed (will retry next interval)");
        }
        else if (response && response.failure_reason.len > 0)
        {
            io::eprintfn("  Tracker error on periodic announce: %s", response.failure_reason);
        }
        return;
    }

    // Success - notify callback if we have peers
    if (response.peers.len > 0 && coord.on_peers_received)
    {
        coord.on_peers_received(response, coord.user_data);
    }
}

/**
 * Internal callback for announces with retry support.
 * Implements exponential backoff and BEP 12 multi-tracker failover.
 */
fn void on_announce_complete_with_retry_internal(tracker::TrackerResponse* response,
                                                   int status,
                                                   void* user_data)
{
    TrackerCoordinator* coord = (TrackerCoordinator*)user_data;

    io::printfn("[COORD] Announce callback: status=%d, response=%p", status, response);

    if (status != 0 || !response || response.failure_reason.len > 0)
    {
        // Failed - try next tracker or use exponential backoff
        if (status != 0)
        {
            io::eprintfn("  Tracker announce failed (status=%d)", status);
        }
        else if (response && response.failure_reason.len > 0)
        {
            io::eprintfn("  Tracker error: %s", response.failure_reason);
        }

        // BEP 31: Check retry_in field for permanent failure ("never")
        if (response && response.retry_in_minutes == -1)
        {
            io::eprintfn("  Tracker returned 'retry in: never' - permanently failed");

            // BEP 12: Try next tracker immediately
            if (coord.tracker_mgr && coord.tracker_mgr.has_trackers())
            {
                coord.tracker_mgr.mark_failure();
                String next_tracker = coord.tracker_mgr.get_next_tracker();

                if (next_tracker.len > 0)
                {
                    io::printfn("  Trying next tracker...");
                    coord.current_tracker_url = next_tracker;

                    tracker::announce_to_url(coord.loop, coord.torrent, next_tracker, 6881,
                                              coord.initial_announce_done ? "" : "started",
                                              &on_announce_complete_with_retry_internal, coord);
                    return;
                }
            }

            // No more trackers available
            io::eprintfn("  All trackers exhausted - giving up");
            if (coord.on_tracker_failed)
            {
                coord.on_tracker_failed("All trackers permanently failed", coord.user_data);
            }
            return;
        }

        // BEP 12: Try next tracker if available
        if (coord.tracker_mgr && coord.tracker_mgr.has_trackers())
        {
            // Mark current tracker as failed and get next one
            coord.tracker_mgr.mark_failure();
            String next_tracker = coord.tracker_mgr.get_next_tracker();

            if (next_tracker.len > 0)
            {
                // Try next tracker immediately (no backoff for different tracker)
                io::printfn("  Trying next tracker in tier...");
                coord.current_tracker_url = next_tracker;

                tracker::announce_to_url(coord.loop, coord.torrent, next_tracker, 6881,
                                          coord.initial_announce_done ? "" : "started",
                                          &on_announce_complete_with_retry_internal, coord);
                return;
            }
            else
            {
                // All trackers exhausted - use exponential backoff and try again
                io::printfn("  All trackers failed - will retry from beginning");
            }
        }

        // Calculate retry delay
        coord.announce_retry_count++;
        int backoff_ms;

        // BEP 31: Honor retry_in if specified by tracker
        if (response && response.retry_in_minutes > 0)
        {
            backoff_ms = response.retry_in_minutes * 60 * 1000;  // Convert minutes to milliseconds
            io::printfn("  Tracker requested retry in %d minutes", response.retry_in_minutes);
        }
        else
        {
            // Use exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s (cap at 30s)
            backoff_ms = 1000 * (1 << (coord.announce_retry_count - 1));
            if (backoff_ms > 30000) backoff_ms = 30000;
        }

        coord.announce_backoff_ms = backoff_ms;

        io::printfn("  Retrying in %d seconds...", backoff_ms / 1000);

        // Create retry timer (one-shot)
        async::timer::Timer*? timer_opt = async::timer::create(coord.loop);
        if (catch err = timer_opt)
        {
            io::eprintfn("  Failed to create retry timer - giving up");
            if (coord.on_tracker_failed)
            {
                coord.on_tracker_failed("Failed to create retry timer", coord.user_data);
            }
            return;
        }

        coord.retry_timer = timer_opt;
        coord.retry_timer.start((ulong)backoff_ms, 0,
                                &on_retry_timer_internal, coord);
        return;
    }

    // Success - mark tracker as successful (BEP 12: move to front of tier)
    if (coord.tracker_mgr && coord.tracker_mgr.has_trackers())
    {
        coord.tracker_mgr.mark_success(coord.current_tracker_url);
        io::printfn("  Tracker announce successful: %s", coord.current_tracker_url);
    }
    else
    {
        io::printfn("  Tracker announce successful");
    }

    coord.announce_retry_count = 0;
    coord.initial_announce_done = true;

    // Notify callback with peers
    if (coord.on_peers_received)
    {
        coord.on_peers_received(response, coord.user_data);
    }

    // NOTE: Do NOT free response.peers here!
    // The tracker cleanup functions (udp_tracker/http_tracker) free it after this callback returns.
    // Freeing it here would cause a double-free.

    // Start periodic announces if not already running
    // BEP 31: Enforce min_interval - use the larger of interval and min_interval
    if (!coord.announce_timer && response.interval > 0)
    {
        int announce_interval = (int)response.interval;
        if (response.min_interval > 0 && response.min_interval > response.interval)
        {
            announce_interval = (int)response.min_interval;
        }
        coord.start_periodic_announces(announce_interval);
    }
}
