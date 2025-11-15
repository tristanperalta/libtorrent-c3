module libtorrent::adapters::tracker_peer_discovery;

import libtorrent::ports::peer_discovery;
import libtorrent::tracker;
import libtorrent::tracker_manager;
import libtorrent::metainfo;
import libtorrent::common;
import std::core::log;
import async::event_loop;
import async::timer;
import std::time;
import std::io;

<*
 * TrackerPeerDiscovery Adapter
 * =============================
 * Wraps existing tracker implementation (HTTP/UDP) for PeerDiscovery interface.
 *
 * Features:
 * - HTTP and UDP tracker support (BEP 3, 15)
 * - Multi-tracker failover (BEP 12)
 * - Exponential backoff retry
 * - Periodic announces with configurable interval
 * - Statistics tracking
 *
 * Architecture:
 * - Adapter (hexagonal architecture)
 * - Wraps existing tracker and tracker_manager modules
 * - Implements PeerDiscovery port interface
 *>

// Internal state for announce context
struct AnnounceContext
{
    TrackerPeerDiscovery* discovery;
    String event;  // "started", "stopped", "completed", ""
}

// TrackerPeerDiscovery adapter struct
struct TrackerPeerDiscovery (peer_discovery::PeerDiscovery)
{
    // Dependencies
    event_loop::EventLoop* loop;
    metainfo::TorrentFile* torrent;
    tracker_manager::TrackerManager* tracker_mgr;

    // Configuration
    peer_discovery::DiscoveryOptions options;
    ushort local_port;

    // State
    bool active;
    common::InfoHash current_info_hash;

    // Callbacks
    peer_discovery::PeerDiscoveredCallback peer_callback;
    peer_discovery::DiscoveryCompleteCallback complete_callback;
    void* user_data;

    // Statistics
    peer_discovery::DiscoveryStats stats;
    long last_announce_start_time;

    // Retry state
    timer::Timer* retry_timer;
    int retry_count;
    uint current_backoff_ms;

    // Periodic announce timer
    timer::Timer* announce_timer;
    bool initial_announce_done;
}

// ============================================================================
// Factory
// ============================================================================

<*
 * Create a TrackerPeerDiscovery adapter.
 *
 * @param loop : "Event loop for async operations"
 * @param torrent : "Torrent file (contains tracker URLs)"
 * @param tracker_mgr : "Tracker manager for multi-tracker support (can be null)"
 * @return "TrackerPeerDiscovery adapter instance"
 *>
fn TrackerPeerDiscovery* create(
    event_loop::EventLoop* loop,
    metainfo::TorrentFile* torrent,
    tracker_manager::TrackerManager* tracker_mgr
) @public
{
    TrackerPeerDiscovery* adapter = mem::new(TrackerPeerDiscovery);

    adapter.loop = loop;
    adapter.torrent = torrent;
    adapter.tracker_mgr = tracker_mgr;

    adapter.options = peer_discovery::default_options();
    adapter.local_port = 6881;

    adapter.active = false;
    adapter.peer_callback = null;
    adapter.complete_callback = null;
    adapter.user_data = null;

    // Initialize stats
    adapter.stats.total_peers_discovered = 0;
    adapter.stats.total_discovery_attempts = 0;
    adapter.stats.successful_attempts = 0;
    adapter.stats.failed_attempts = 0;
    adapter.stats.last_discovery_time = 0;
    adapter.stats.average_response_time_ms = 0.0;
    adapter.stats.active_peers = 0;

    adapter.last_announce_start_time = 0;
    adapter.retry_timer = null;
    adapter.retry_count = 0;
    adapter.current_backoff_ms = 0;
    adapter.announce_timer = null;
    adapter.initial_announce_done = false;

    log::info( "[TrackerDiscovery] Created adapter for torrent");

    return adapter;
}

// ============================================================================
// Callbacks
// ============================================================================

// Periodic announce timer callback
fn void on_periodic_announce(timer::Timer* timer, void* user_data)
{
    TrackerPeerDiscovery* self = (TrackerPeerDiscovery*)user_data;

    if (!self.active) return;

    log::debug(
                 "[TrackerDiscovery] Periodic announce triggered");

    // Reset tracker manager to beginning for new cycle
    if (self.tracker_mgr)
    {
        self.tracker_mgr.reset();
    }

    self.do_announce("");  // Empty event for periodic announces
}

// Retry timer callback
fn void on_retry_timer(timer::Timer* timer, void* user_data)
{
    TrackerPeerDiscovery* self = (TrackerPeerDiscovery*)user_data;

    if (!self.active) return;

    log::debug(
                 "[TrackerDiscovery] Retry timer fired (retry %d/%d)",
                 self.retry_count + 1, self.options.max_retries);

    // Clear retry timer
    if (self.retry_timer)
    {
        self.retry_timer.close();
        self.retry_timer = null;
    }

    // Try next tracker or retry current
    if (self.tracker_mgr && self.tracker_mgr.mark_failure())
    {
        // More trackers available in this tier or next tier
        self.retry_count = 0;  // Reset retry count for new tracker
        self.do_announce(self.initial_announce_done ? "" : "started");
    }
    else
    {
        // All trackers exhausted or no tracker manager
        self.stats.failed_attempts++;

        if (self.complete_callback)
        {
            self.complete_callback(false, "All trackers failed", self.user_data);
        }
    }
}

// Tracker announce completion callback
fn void on_announce_complete_internal(tracker::TrackerResponse* response,
                                        int error, void* user_data)
{
    AnnounceContext* ctx = (AnnounceContext*)user_data;
    TrackerPeerDiscovery* self = ctx.discovery;
    defer free(ctx);

    if (!self.active) return;

    // Calculate response time
    long now = (long)(time::now().to_seconds() * 1000);
    long elapsed_ms = now - self.last_announce_start_time;

    // Update rolling average response time
    if (self.stats.successful_attempts > 0)
    {
        double alpha = 0.2;  // Smoothing factor for exponential moving average
        self.stats.average_response_time_ms =
            (float)((alpha * (double)elapsed_ms) +
            ((1.0 - alpha) * (double)self.stats.average_response_time_ms));
    }
    else
    {
        self.stats.average_response_time_ms = (float)elapsed_ms;
    }

    if (error != 0 || (response && response.failure_reason.len > 0))
    {
        // Announce failed
        String error_msg = (response && response.failure_reason.len > 0) ?
                            response.failure_reason : "Unknown tracker error";

        log::warn(
                     "[TrackerDiscovery] Announce failed: %s (attempt %d)",
                     error_msg, self.retry_count + 1);

        // Try retry with exponential backoff
        self.retry_count++;

        if (self.retry_count < self.options.max_retries)
        {
            // Calculate backoff delay
            self.current_backoff_ms = self.options.retry_base_delay_ms *
                                       (uint)self.options.retry_backoff_multiplier;

            if (self.current_backoff_ms < self.options.min_discovery_interval_ms)
            {
                self.current_backoff_ms = self.options.min_discovery_interval_ms;
            }

            log::debug(
                         "[TrackerDiscovery] Scheduling retry in %d ms",
                         self.current_backoff_ms);

            // Schedule retry
            timer::Timer*? timer_opt = timer::create(self.loop);
            if (catch err = timer_opt)
            {
                log::error(
                             "[TrackerDiscovery] Failed to create retry timer");
                self.stats.failed_attempts++;
                if (self.complete_callback)
                {
                    self.complete_callback(false, error_msg, self.user_data);
                }
                return;
            }

            self.retry_timer = timer_opt;
            self.retry_timer.start(self.current_backoff_ms, 0,
                                    &on_retry_timer, self);
        }
        else
        {
            // Max retries exceeded - try next tracker
            if (self.tracker_mgr && self.tracker_mgr.mark_failure())
            {
                // More trackers available
                self.retry_count = 0;
                self.do_announce(ctx.event);
            }
            else
            {
                // All trackers exhausted
                self.stats.failed_attempts++;

                if (self.complete_callback)
                {
                    self.complete_callback(false, "All trackers failed after retries",
                                            self.user_data);
                }
            }
        }

        return;
    }

    // Announce succeeded
    if (!response)
    {
        log::error(
                     "[TrackerDiscovery] Internal error: null response with no error code");
        self.stats.failed_attempts++;
        if (self.complete_callback)
        {
            self.complete_callback(false, "Internal error", self.user_data);
        }
        return;
    }

    log::info(
                 "[TrackerDiscovery] Announce succeeded: %d peers received (interval=%d s)",
                 response.peers.len, response.interval);

    // Update stats
    self.stats.successful_attempts++;
    self.stats.total_peers_discovered += response.peers.len;
    self.stats.last_discovery_time = now / 1000;  // Convert to seconds

    // Reset retry state
    self.retry_count = 0;
    self.current_backoff_ms = 0;

    // Mark tracker as successful (BEP 12: move to front of tier)
    if (self.tracker_mgr)
    {
        String tracker_url = self.tracker_mgr.get_next_tracker();
        if (tracker_url.len > 0)
        {
            self.tracker_mgr.mark_success(tracker_url);
        }
    }

    // Notify callback with discovered peers
    if (self.peer_callback && response.peers.len > 0)
    {
        self.peer_callback(response.peers, "tracker", self.user_data);
    }

    // Notify completion
    if (self.complete_callback)
    {
        self.complete_callback(true, "", self.user_data);
    }

    // Mark initial announce as done
    if (!self.initial_announce_done)
    {
        self.initial_announce_done = true;
    }

    // Set up periodic announces if not already running
    if (!self.announce_timer)
    {
        uint interval_ms = (response.interval > 0) ?
                            (uint)(response.interval * 1000) :
                            self.options.discovery_interval_ms;

        // Respect min interval
        if (interval_ms < self.options.min_discovery_interval_ms)
        {
            interval_ms = self.options.min_discovery_interval_ms;
        }

        log::debug(
                     "[TrackerDiscovery] Setting up periodic announces every %d ms",
                     interval_ms);

        timer::Timer*? timer_opt = timer::create(self.loop);
        if (catch err = timer_opt)
        {
            log::warn(
                         "[TrackerDiscovery] Failed to create periodic timer");
            return;
        }

        self.announce_timer = timer_opt;
        self.announce_timer.start(interval_ms, interval_ms,
                                   &on_periodic_announce, self);
    }
}

// ============================================================================
// Internal Announce Logic
// ============================================================================

<*
 * Perform a tracker announce.
 *>
fn void TrackerPeerDiscovery.do_announce(&self, String event) @private
{
    self.stats.total_discovery_attempts++;
    self.last_announce_start_time = (long)(time::now().to_seconds() * 1000);

    log::debug(
                 "[TrackerDiscovery] Starting announce (event=%s, attempt=%d)",
                 event.len > 0 ? event : "(none)", self.stats.total_discovery_attempts);

    // Create announce context
    AnnounceContext* ctx = mem::new(AnnounceContext);
    ctx.discovery = self;
    ctx.event = event.len > 0 ? event.copy(mem) : "";

    // Determine tracker URL to use
    if (self.tracker_mgr && self.tracker_mgr.has_trackers())
    {
        // BEP 12: Use tracker manager for multi-tracker support
        String tracker_url = self.tracker_mgr.get_next_tracker();
        if (tracker_url.len > 0)
        {
            log::debug(
                         "[TrackerDiscovery] Announcing to tracker: %s", tracker_url);
            tracker::announce_to_url(self.loop, self.torrent, tracker_url,
                                      self.options.local_port, event,
                                      &on_announce_complete_internal, ctx);
        }
        else
        {
            log::warn(
                         "[TrackerDiscovery] No valid trackers available");
            free(ctx);
            if (self.complete_callback)
            {
                self.complete_callback(false, "No trackers available", self.user_data);
            }
        }
    }
    else
    {
        // Fallback: Use primary announce URL from torrent
        if (self.torrent.announce.len > 0)
        {
            log::debug(
                         "[TrackerDiscovery] Announcing to primary tracker: %s",
                         self.torrent.announce);
            tracker::announce(self.loop, self.torrent, self.options.local_port,
                              event, &on_announce_complete_internal, ctx);
        }
        else
        {
            log::warn(
                         "[TrackerDiscovery] No trackers configured");
            free(ctx);
            if (self.complete_callback)
            {
                self.complete_callback(false, "No trackers configured", self.user_data);
            }
        }
    }
}

// ============================================================================
// PeerDiscovery Interface Implementation
// ============================================================================

fn void TrackerPeerDiscovery.start_discovery(
    &self,
    common::InfoHash* info_hash,
    peer_discovery::DiscoveryOptions* options,
    peer_discovery::PeerDiscoveredCallback peer_callback,
    peer_discovery::DiscoveryCompleteCallback complete_callback,
    void* user_data
) @dynamic
{
    if (self.active)
    {
        log::warn(
                     "[TrackerDiscovery] Discovery already active");
        return;
    }

    log::info(
                 "[TrackerDiscovery] Starting discovery");

    self.active = true;
    self.options = *options;
    self.local_port = options.local_port;
    self.current_info_hash = *info_hash;
    self.peer_callback = peer_callback;
    self.complete_callback = complete_callback;
    self.user_data = user_data;

    // Reset retry state
    self.retry_count = 0;
    self.current_backoff_ms = 0;

    // Initial announce with "started" event
    String event = self.initial_announce_done ? "" : "started";
    self.do_announce(event);
}

<*
 * Trigger a manual announce with a specific event.
 * Used for sending "completed" events on download finish.
 *
 * @param event : "Event string (empty, started, stopped, completed)"
 *>
fn void TrackerPeerDiscovery.trigger_event_announce(&self, String event) @public
{
    if (!self.active)
    {
        log::warn(
                     "[TrackerDiscovery] Cannot announce - discovery not active");
        return;
    }

    log::info(
                 "[TrackerDiscovery] Manual announce triggered (event=%s)",
                 event.len > 0 ? event : "(none)");

    self.do_announce(event);
}

fn void TrackerPeerDiscovery.stop_discovery(&self) @dynamic
{
    if (!self.active) return;

    log::info(
                 "[TrackerDiscovery] Stopping discovery");

    self.active = false;

    // Stop timers
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

    // Send "stopped" event to tracker
    if (self.initial_announce_done)
    {
        self.do_announce("stopped");
    }
}

fn peer_discovery::DiscoveryStats TrackerPeerDiscovery.get_stats(&self) @dynamic
{
    return self.stats;
}

fn bool TrackerPeerDiscovery.is_active(&self) @dynamic
{
    return self.active;
}

fn String TrackerPeerDiscovery.get_name(&self) @dynamic
{
    return "tracker";
}

fn void TrackerPeerDiscovery.free(&self) @dynamic
{
    self.stop_discovery();
    free(self);
}
