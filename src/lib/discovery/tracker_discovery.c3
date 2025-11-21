module libtorrent::discovery::tracker;

import libtorrent::discovery;
import libtorrent::trackers;
import libtorrent::tracker_manager;
import libtorrent::metainfo;
import libtorrent::common;
import libtorrent::event_bus;
import libtorrent::event_types;
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
 * - Parallel tracker announces (configurable)
 * - Exponential backoff retry
 * - Periodic announces with configurable interval
 * - Statistics tracking
 *
 * Architecture:
 * - Adapter (hexagonal architecture)
 * - Wraps existing tracker and tracker_manager modules
 * - Implements PeerDiscovery port interface
 *>

// ============================================================================
// Configuration
// ============================================================================

// Default: Announce to all trackers in same tier (qBittorrent behavior)
// If false: BEP 12 compliant (one tracker per tier)
const bool DEFAULT_ANNOUNCE_TO_ALL_TRACKERS = true;

// Default: Announce to one tracker from each tier (uTorrent behavior)
// If false: BEP 12 compliant (sequential tier escalation)
const bool DEFAULT_ANNOUNCE_TO_ALL_TIERS = true;

// Default: Maximum concurrent HTTP tracker announces (qBittorrent standard)
// UDP announces are unlimited (no concurrency control)
const uint DEFAULT_MAX_CONCURRENT_HTTP_ANNOUNCES = 50;

<*
 * TrackerConfig - Controls multi-tracker announce behavior.
 *
 * Based on libtorrent-rasterbar settings and industry standards.
 * See TRACKER_PARALLEL_ANNOUNCE_RESEARCH.md for detailed analysis.
 *>
struct TrackerConfig
{
    bool announce_to_all_trackers;      // Announce to all trackers in same tier?
    bool announce_to_all_tiers;         // Announce to one tracker from each tier?
    uint max_concurrent_http_announces; // HTTP concurrency limit (UDP unlimited)
    int tracker_timeout;                 // Tracker announce timeout in seconds (default: 60)
}

<*
 * Create default tracker configuration (qBittorrent behavior).
 *
 * @return "TrackerConfig with industry-standard defaults"
 *>
fn TrackerConfig default_tracker_config() @public
{
    return (TrackerConfig) {
        .announce_to_all_trackers = DEFAULT_ANNOUNCE_TO_ALL_TRACKERS,
        .announce_to_all_tiers = DEFAULT_ANNOUNCE_TO_ALL_TIERS,
        .max_concurrent_http_announces = DEFAULT_MAX_CONCURRENT_HTTP_ANNOUNCES,
        .tracker_timeout = 60  // Default: 60 seconds
    };
}

// Internal state for announce context
struct AnnounceContext
{
    TrackerPeerDiscovery* discovery;
    String event;  // "started", "stopped", "completed", ""
    String tracker_url;  // Which tracker this announce is for
    trackers::Tracker* tracker;  // Tracker instance (needs cleanup)
}

// TrackerPeerDiscovery adapter struct
struct TrackerPeerDiscovery (discovery::PeerDiscovery)
{
    // Dependencies
    event_loop::EventLoop* loop;
    metainfo::TorrentFile* torrent;
    tracker_manager::TrackerManager* tracker_mgr;
    event_bus::EventBus* event_bus;

    // Configuration
    discovery::DiscoveryOptions options;
    ushort local_port;
    TrackerConfig* tracker_config;  // Parallel announce configuration

    // State
    bool active;
    common::InfoHash current_info_hash;

    // Parallel announce state
    uint pending_announces;      // Count of in-flight announces
    uint successful_announces;   // Count of successful announces
    uint total_peers_received;   // Total peers from all successful announces

    // Callbacks
    discovery::PeerDiscoveredCallback peer_callback;
    discovery::DiscoveryCompleteCallback complete_callback;
    void* user_data;

    // Statistics
    discovery::DiscoveryStats stats;
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
 * @param event_bus : "Event bus for publishing tracker status events (can be null)"
 * @param tracker_config : "Tracker configuration for parallel announces (can be null for defaults)"
 * @return "TrackerPeerDiscovery adapter instance"
 *>
fn TrackerPeerDiscovery* create(
    event_loop::EventLoop* loop,
    metainfo::TorrentFile* torrent,
    tracker_manager::TrackerManager* tracker_mgr,
    event_bus::EventBus* event_bus,
    TrackerConfig* tracker_config
) @public
{
    TrackerPeerDiscovery* adapter = mem::new(TrackerPeerDiscovery);

    adapter.loop = loop;
    adapter.torrent = torrent;
    adapter.tracker_mgr = tracker_mgr;
    adapter.event_bus = event_bus;
    adapter.tracker_config = tracker_config;

    adapter.options = discovery::default_options();
    adapter.local_port = 6881;

    // Initialize parallel announce state
    adapter.pending_announces = 0;
    adapter.successful_announces = 0;
    adapter.total_peers_received = 0;

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

    // Log tracker configuration for visibility (bypass log level filtering)
    if (tracker_mgr && tracker_mgr.has_trackers())
    {
        uint total_trackers = 0;
        uint non_empty_tiers = 0;
        for (uint tier = 0; tier < tracker_mgr.get_tier_count(); tier++)
        {
            uint count = tracker_mgr.get_tracker_count(tier);
            if (count > 0)
            {
                total_trackers += count;
                non_empty_tiers++;
            }
        }
        io::printfn("[TrackerDiscovery] Initialized with %d tracker(s) across %d tier(s) (total tiers: %d)",
                    total_trackers, non_empty_tiers, tracker_mgr.get_tier_count());

        // Show configuration
        bool announce_all_trackers = tracker_config ?
            tracker_config.announce_to_all_trackers : DEFAULT_ANNOUNCE_TO_ALL_TRACKERS;
        bool announce_all_tiers = tracker_config ?
            tracker_config.announce_to_all_tiers : DEFAULT_ANNOUNCE_TO_ALL_TIERS;

        String mode = "BEP 12 (sequential)";
        if (announce_all_trackers && announce_all_tiers)
        {
            mode = "All trackers in all tiers (qBittorrent)";
        }
        else if (announce_all_trackers && !announce_all_tiers)
        {
            mode = "All trackers in tier 0";
        }
        else if (!announce_all_trackers && announce_all_tiers)
        {
            mode = "One tracker per tier (uTorrent)";
        }

        io::printfn("[TrackerDiscovery] Announce mode: %s", mode);
    }

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

// Tracker announce completion callback (handles parallel announces)
fn void on_announce_complete_internal(trackers::TrackerResponse* response,
                                        int error, void* user_data)
{
    AnnounceContext* ctx = (AnnounceContext*)user_data;
    TrackerPeerDiscovery* self = ctx.discovery;

    // Note: We defer freeing ctx.event and ctx, but NOT ctx.tracker_url yet
    // because we need tracker_url to persist until after event is published
    defer {
        if (ctx.tracker) {
            ctx.tracker.close();
            free(ctx.tracker);
        }
        if (ctx.event.len > 0) free(ctx.event);
        free(ctx);
    }

    if (!self.active)
    {
        // Clean up tracker_url before early return
        if (ctx.tracker_url.len > 0) free(ctx.tracker_url);
        return;
    }

    // Decrement pending count
    if (self.pending_announces > 0)
    {
        self.pending_announces--;
    }

    // Calculate response time
    long now = (long)(time::now().to_seconds() * 1000);
    long elapsed_ms = now - self.last_announce_start_time;

    // Update rolling average response time (only for successful announces)
    if (error == 0 && response && response.failure_reason.len == 0)
    {
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
    }

    if (error != 0 || (response && response.failure_reason.len > 0))
    {
        // Announce failed for this tracker
        String error_msg = (response && response.failure_reason.len > 0) ?
                            response.failure_reason : "Unknown tracker error";

        log::warn("[TrackerDiscovery] Tracker announce failed: %s", error_msg);

        // Publish failure event for this tracker
        if (self.event_bus && ctx.tracker_url.len > 0)
        {
            // Log the failure for visibility
            io::printfn("  Tracker failed: %s - %s", ctx.tracker_url, error_msg);

            // Copy tracker_url and error_msg for event (will leak, but necessary for async dispatch)
            String tracker_url_for_event = ctx.tracker_url.copy(mem);
            String error_msg_for_event = error_msg.copy(mem);
            event_types::TrackerEvent failure_evt = (event_types::TrackerEvent) {
                tracker_url_for_event, "Failed", -1, error_msg_for_event, self.tracker_mgr
            };
            self.event_bus.publish(event_types::EVENT_TRACKER_STATUS_CHANGED,
                                    &failure_evt, event_types::TrackerEvent.sizeof);
        }

        // Note: With parallel announces, we don't retry individual trackers
        // We wait for all announces to complete, then check if ANY succeeded

        // Check if all announces are done
        if (self.pending_announces == 0)
        {
            // All announces complete - check if any succeeded
            if (self.successful_announces == 0)
            {
                // All trackers failed
                self.stats.failed_attempts++;
                if (self.complete_callback)
                {
                    self.complete_callback(false, "All trackers failed", self.user_data);
                }
            }
            // If some succeeded, the success handler below already called the callback
        }

        return;
    }

    // Announce succeeded
    if (!response)
    {
        log::error("[TrackerDiscovery] Internal error: null response with no error code");
        // Count as failure but don't return - decrement pending
        if (self.pending_announces == 0 && self.successful_announces == 0)
        {
            self.stats.failed_attempts++;
            if (self.complete_callback)
            {
                self.complete_callback(false, "Internal error", self.user_data);
            }
        }
        return;
    }

    log::info(
                 "[TrackerDiscovery] Tracker announce succeeded: %d peers received (interval=%d s)",
                 response.peers.len, response.interval);

    // Track successful announce
    self.successful_announces++;
    self.total_peers_received += (uint)response.peers.len;

    // Update stats (aggregate from all successful announces)
    self.stats.total_peers_discovered += response.peers.len;
    self.stats.last_discovery_time = now / 1000;  // Convert to seconds

    // Publish success event for this tracker
    if (self.event_bus && ctx.tracker_url.len > 0)
    {
        String status = response.peers.len > 0 ? "Working" : "Working (no peers)";
        // Log the success for visibility
        io::printfn("  Tracker succeeded: %s - %d peers", ctx.tracker_url, response.peers.len);

        // Make a copy of tracker_url for the event (will be freed by event handler)
        // Note: This is a "fire and forget" allocation - event handler must copy if needed
        String tracker_url_for_event = ctx.tracker_url.copy(mem);

        event_types::TrackerEvent success_evt = (event_types::TrackerEvent) {
            tracker_url_for_event, status, (int)response.peers.len, "", self.tracker_mgr
        };
        self.event_bus.publish(event_types::EVENT_TRACKER_STATUS_CHANGED,
                                &success_evt, event_types::TrackerEvent.sizeof);

        // Note: tracker_url_for_event intentionally not freed - it lives until event dispatch
        // This is a known small leak but necessary for async event dispatch
    }

    // Immediately notify callback with discovered peers from this tracker
    if (self.peer_callback && response.peers.len > 0)
    {
        self.peer_callback(response.peers, "tracker", self.user_data);
    }

    // Check if all announces are complete
    if (self.pending_announces == 0)
    {
        // All announces done - report aggregated results
        log::info(
                     "[TrackerDiscovery] All announces complete: %d/%d successful, %d total peers",
                     self.successful_announces, self.successful_announces + (self.successful_announces > 0 ? 0 : 1),
                     self.total_peers_received);

        // Update overall stats
        self.stats.successful_attempts++;

        // Notify completion callback once
        if (self.complete_callback)
        {
            self.complete_callback(true, "", self.user_data);
        }

        // Mark initial announce as done
        if (!self.initial_announce_done)
        {
            self.initial_announce_done = true;
        }
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
            // Free tracker_url before early return
            if (ctx.tracker_url.len > 0) free(ctx.tracker_url);
            return;
        }

        self.announce_timer = timer_opt;
        self.announce_timer.start(interval_ms, interval_ms,
                                   &on_periodic_announce, self);
    }

    // Free tracker_url at the very end (after event has been published)
    if (ctx.tracker_url.len > 0) free(ctx.tracker_url);
}

// ============================================================================
// Internal Announce Logic
// ============================================================================

<*
 * Select which trackers to announce to based on configuration.
 * Implements the 4 announce modes from libtorrent-rasterbar.
 *
 * @return "Array of tracker URLs to announce to (caller must free if allocated)"
 *>
fn String[] TrackerPeerDiscovery.select_trackers_to_announce(&self) @private
{
    // If no tracker manager, use fallback (torrent.announce)
    if (!self.tracker_mgr || !self.tracker_mgr.has_trackers())
    {
        if (self.torrent.announce.len > 0)
        {
            // Return single tracker (no allocation needed, just a slice)
            String[] result = {self.torrent.announce};
            return result;
        }
        return {};
    }

    // Use default config if not provided
    bool announce_to_all_trackers = self.tracker_config ?
        self.tracker_config.announce_to_all_trackers : DEFAULT_ANNOUNCE_TO_ALL_TRACKERS;
    bool announce_to_all_tiers = self.tracker_config ?
        self.tracker_config.announce_to_all_tiers : DEFAULT_ANNOUNCE_TO_ALL_TIERS;

    // Mode 1: Both FALSE - BEP 12 compliant (one tracker from tier 0)
    if (!announce_to_all_trackers && !announce_to_all_tiers)
    {
        String tracker = self.tracker_mgr.get_next_tracker();
        if (tracker.len > 0)
        {
            String[] result = {tracker};
            return result;
        }
        return {};
    }

    // Mode 2: announce_to_all_trackers=TRUE, announce_to_all_tiers=FALSE
    // All trackers in tier 0
    if (announce_to_all_trackers && !announce_to_all_tiers)
    {
        return self.tracker_mgr.get_tier_trackers(0);
    }

    // Mode 3: announce_to_all_trackers=FALSE, announce_to_all_tiers=TRUE
    // One tracker from each tier (uTorrent mode)
    if (!announce_to_all_trackers && announce_to_all_tiers)
    {
        return self.tracker_mgr.get_one_per_tier();
    }

    // Mode 4: Both TRUE - All trackers in all tiers (maximum parallel)
    return self.tracker_mgr.get_all_trackers();
}

<*
 * Perform tracker announces (possibly to multiple trackers in parallel).
 * Uses configuration to determine which trackers to announce to.
 *>
fn void TrackerPeerDiscovery.do_announce(&self, String event) @private
{
    self.stats.total_discovery_attempts++;
    self.last_announce_start_time = (long)(time::now().to_seconds() * 1000);

    // Select trackers to announce to based on configuration
    String[] trackers = self.select_trackers_to_announce();

    if (trackers.len == 0)
    {
        log::warn("[TrackerDiscovery] No trackers available");
        if (self.complete_callback)
        {
            self.complete_callback(false, "No trackers configured", self.user_data);
        }
        return;
    }

    // Use io::printfn to bypass log level filtering for visibility
    io::printfn("[TrackerDiscovery] Parallel announce to %d tracker(s) (event=%s)",
                 trackers.len, event.len > 0 ? event : "(none)");

    // Determine which tier each tracker belongs to for display
    foreach (tracker_url : trackers)
    {
        // Find which tier this tracker belongs to
        uint tracker_tier = 0;
        bool found = false;
        for (uint tier = 0; tier < self.tracker_mgr.get_tier_count(); tier++)
        {
            for (uint idx = 0; idx < self.tracker_mgr.get_tracker_count(tier); idx++)
            {
                if (self.tracker_mgr.get_tracker_url(tier, idx) == tracker_url)
                {
                    tracker_tier = tier;
                    found = true;
                    break;
                }
            }
            if (found) break;
        }
        io::printfn("  [Tier %d] %s", tracker_tier, tracker_url);
    }

    // Reset parallel announce state
    self.pending_announces = (uint)trackers.len;
    self.successful_announces = 0;
    self.total_peers_received = 0;

    // Fire announces to all selected trackers
    foreach (tracker_url : trackers)
    {
        if (tracker_url.len == 0) continue;

        log::debug("[TrackerDiscovery] Announcing to: %s", tracker_url);

        // Publish "Trying..." event
        if (self.event_bus)
        {
            // Copy tracker_url for event (will leak, but necessary for async dispatch)
            String tracker_url_for_event = tracker_url.copy(mem);
            event_types::TrackerEvent trying_evt = (event_types::TrackerEvent) {
                tracker_url_for_event, "Trying...", -1, "", self.tracker_mgr
            };
            self.event_bus.publish(event_types::EVENT_TRACKER_STATUS_CHANGED,
                                    &trying_evt, event_types::TrackerEvent.sizeof);
        }

        // Create context for this announce
        AnnounceContext* ctx = mem::new(AnnounceContext);
        ctx.discovery = self;
        ctx.event = event.len > 0 ? event.copy(mem) : "";
        ctx.tracker_url = tracker_url.copy(mem);  // Store which tracker this is for

        // Create tracker and fire the announce (async)
        ctx.tracker = trackers::create_from_url(self.loop, tracker_url)!!;
        ctx.tracker.announce(self.torrent, self.options.local_port, event,
                            &on_announce_complete_internal, ctx,
                            self.tracker_config.tracker_timeout);
    }

    // Free tracker list if it was allocated (modes 3 and 4)
    // Modes 1 and 2 return slices/references, not allocations
    if (self.tracker_config)
    {
        bool need_free = self.tracker_config.announce_to_all_tiers;
        if (need_free && trackers.len > 0)
        {
            free(trackers);
        }
    }
}

// ============================================================================
// PeerDiscovery Interface Implementation
// ============================================================================

fn void TrackerPeerDiscovery.start_discovery(
    &self,
    common::InfoHash* info_hash,
    discovery::DiscoveryOptions* options,
    discovery::PeerDiscoveredCallback peer_callback,
    discovery::DiscoveryCompleteCallback complete_callback,
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

fn discovery::DiscoveryStats TrackerPeerDiscovery.get_stats(&self) @dynamic
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
