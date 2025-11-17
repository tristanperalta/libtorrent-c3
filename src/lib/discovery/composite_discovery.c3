module libtorrent::discovery::composite;

import libtorrent::discovery;
import libtorrent::common;
import std::core::log;
import std::collections::list;
import std::time;
import std::io;

<*
 * CompositePeerDiscovery Adapter
 * ===============================
 * Aggregates multiple peer discovery sources into a unified interface.
 *
 * Features:
 * - Combines multiple discovery mechanisms (Tracker, DHT, LSD, PEX)
 * - Forwards callbacks from all sources to single callback
 * - Aggregates statistics across all sources
 * - Manages lifecycle of all child discovery instances
 *
 * Architecture:
 * - Composite pattern (hexagonal architecture)
 * - Contains multiple PeerDiscovery adapters
 * - Implements PeerDiscovery port interface
 *
 * Usage:
 *   CompositePeerDiscovery* composite = create();
 *   composite.add_source(tracker_discovery);
 *   composite.add_source(dht_discovery);
 *   composite.start_discovery(...);
 *>

// CompositePeerDiscovery aggregator struct
struct CompositePeerDiscovery (discovery::PeerDiscovery)
{
    // Child discovery sources
    List{discovery::PeerDiscovery} sources;

    // Configuration
    discovery::DiscoveryOptions options;

    // State
    bool active;
    common::InfoHash current_info_hash;

    // Callbacks
    discovery::PeerDiscoveredCallback peer_callback;
    discovery::DiscoveryCompleteCallback complete_callback;
    void* user_data;

    // Aggregated statistics
    discovery::DiscoveryStats aggregated_stats;

    // Callback contexts (one per source, allocated during start_discovery)
    List{CallbackContext*} callback_contexts;
}

// ============================================================================
// Factory
// ============================================================================

<*
 * Create a CompositePeerDiscovery aggregator.
 *
 * @return "CompositePeerDiscovery aggregator instance"
 *>
fn CompositePeerDiscovery* create() @public
{
    CompositePeerDiscovery* composite = mem::new(CompositePeerDiscovery);

    composite.sources.init(mem);
    composite.callback_contexts.init(mem);

    composite.options = discovery::default_options();

    composite.active = false;
    composite.peer_callback = null;
    composite.complete_callback = null;
    composite.user_data = null;

    // Initialize aggregated stats
    composite.aggregated_stats.total_peers_discovered = 0;
    composite.aggregated_stats.total_discovery_attempts = 0;
    composite.aggregated_stats.successful_attempts = 0;
    composite.aggregated_stats.failed_attempts = 0;
    composite.aggregated_stats.last_discovery_time = 0;
    composite.aggregated_stats.average_response_time_ms = 0.0;
    composite.aggregated_stats.active_peers = 0;

    log::info( "[CompositeDiscovery] Created aggregator");

    return composite;
}

// ============================================================================
// Source Management
// ============================================================================

<*
 * Add a discovery source to the composite.
 *
 * @param source : "PeerDiscovery adapter to add"
 *>
fn void CompositePeerDiscovery.add_source(&self, discovery::PeerDiscovery source) @public
{
    self.sources.push(source);

    // Note: Can't call source.get_name() here due to C3 interface limitation
    // Interface methods work in loops but not in simple variable contexts
    log::info(
                 "[CompositeDiscovery] Added source (total: %d)",
                 self.sources.len());
}

<*
 * Get the number of discovery sources.
 *
 * @return "Number of sources"
 *>
fn usz CompositePeerDiscovery.get_source_count(&self) @public
{
    return self.sources.len();
}

// ============================================================================
// Internal Callback Forwarding
// ============================================================================

// Context for forwarding callbacks from child sources
struct CallbackContext
{
    CompositePeerDiscovery* composite;
    String source_name;  // Name of the child source
}

// Helper to free all callback contexts
fn void CompositePeerDiscovery.free_callback_contexts(&self) @private
{
    for (usz i = 0; i < self.callback_contexts.len(); i++)
    {
        CallbackContext* ctx = self.callback_contexts.get(i);
        free(ctx);
    }
    self.callback_contexts.clear();
}

// Forward peer discovered callback
fn void on_source_peers_discovered(common::SocketAddress[] peers,
                                     String discovery_source,
                                     void* user_data)
{
    CallbackContext* ctx = (CallbackContext*)user_data;
    CompositePeerDiscovery* self = ctx.composite;

    if (!self.active) return;

    log::debug(
                 "[CompositeDiscovery] Forwarding %d peers from %s",
                 peers.len, discovery_source);

    // Forward to user callback
    if (self.peer_callback)
    {
        self.peer_callback(peers, discovery_source, self.user_data);
    }
}

// Forward discovery complete callback
fn void on_source_discovery_complete(bool success,
                                       String error_message,
                                       void* user_data)
{
    CallbackContext* ctx = (CallbackContext*)user_data;
    CompositePeerDiscovery* self = ctx.composite;

    if (!self.active) return;

    if (!success)
    {
        log::debug(
                     "[CompositeDiscovery] Source %s failed: %s",
                     ctx.source_name, error_message);
    }

    // Composite doesn't fail unless all sources fail
    // Individual source failures are logged but not propagated
}

// ============================================================================
// PeerDiscovery Interface Implementation
// ============================================================================

fn void CompositePeerDiscovery.start_discovery(
    &self,
    common::InfoHash* info_hash,
    discovery::DiscoveryOptions* options,
    discovery::PeerDiscoveredCallback peer_callback,
    discovery::DiscoveryCompleteCallback complete_callback,
    void* user_data
) @dynamic
{
    io::printfn("[CompositeDiscovery] start_discovery called (active=%s, sources=%d)",
                self.active ? "true" : "false", self.sources.len());

    if (self.active)
    {
        io::printfn("[CompositeDiscovery] WARNING: Discovery already active");
        return;
    }

    if (self.sources.len() == 0)
    {
        io::printfn("[CompositeDiscovery] WARNING: No discovery sources configured");
        if (complete_callback)
        {
            complete_callback(false, "No discovery sources", user_data);
        }
        return;
    }

    io::printfn("[CompositeDiscovery] Starting discovery across %d sources", self.sources.len());

    self.active = true;
    self.options = *options;
    self.current_info_hash = *info_hash;
    self.peer_callback = peer_callback;
    self.complete_callback = complete_callback;
    self.user_data = user_data;

    // Clear previous callback contexts if any
    self.free_callback_contexts();

    // Start all child sources
    int started = 0;
    for (usz i = 0; i < self.sources.len(); i++)
    {
        discovery::PeerDiscovery source = self.sources.get(i);

        // Create callback context for this source
        CallbackContext* ctx = mem::new(CallbackContext);
        ctx.composite = self;
        // Note: Can't call source.get_name() - C3 interface method dispatch fails
        ctx.source_name = "unknown";

        // Track the context for cleanup
        self.callback_contexts.push(ctx);

        // Start discovery on this source
        source.start_discovery(
            info_hash,
            options,
            &on_source_peers_discovered,
            &on_source_discovery_complete,
            ctx
        );

        started++;
    }

    io::printfn("[CompositeDiscovery] Started %d discovery sources", started);

    // Notify completion (composite starts all sources immediately)
    if (self.complete_callback)
    {
        self.complete_callback(true, "", self.user_data);
    }
}

fn void CompositePeerDiscovery.stop_discovery(&self) @dynamic
{
    if (!self.active) return;

    log::info(
                 "[CompositeDiscovery] Stopping discovery across %d sources",
                 self.sources.len());

    self.active = false;

    // Stop all child sources
    for (usz i = 0; i < self.sources.len(); i++)
    {
        discovery::PeerDiscovery source = self.sources.get(i);
        source.stop_discovery();
    }

    // Free callback contexts
    self.free_callback_contexts();
}

fn discovery::DiscoveryStats CompositePeerDiscovery.get_stats(&self) @dynamic
{
    // Aggregate stats from all sources
    self.aggregated_stats.total_peers_discovered = 0;
    self.aggregated_stats.total_discovery_attempts = 0;
    self.aggregated_stats.successful_attempts = 0;
    self.aggregated_stats.failed_attempts = 0;
    self.aggregated_stats.last_discovery_time = 0;
    self.aggregated_stats.average_response_time_ms = 0.0;
    self.aggregated_stats.active_peers = 0;

    int source_count = 0;
    double total_avg_response_time = 0.0;

    for (usz i = 0; i < self.sources.len(); i++)
    {
        discovery::PeerDiscovery source = self.sources.get(i);
        discovery::DiscoveryStats stats = source.get_stats();

        self.aggregated_stats.total_peers_discovered += stats.total_peers_discovered;
        self.aggregated_stats.total_discovery_attempts += stats.total_discovery_attempts;
        self.aggregated_stats.successful_attempts += stats.successful_attempts;
        self.aggregated_stats.failed_attempts += stats.failed_attempts;

        // Track latest discovery time
        if (stats.last_discovery_time > self.aggregated_stats.last_discovery_time)
        {
            self.aggregated_stats.last_discovery_time = stats.last_discovery_time;
        }

        // Accumulate average response times
        if (stats.average_response_time_ms > 0.0)
        {
            total_avg_response_time += (double)stats.average_response_time_ms;
            source_count++;
        }

        self.aggregated_stats.active_peers += stats.active_peers;
    }

    // Calculate overall average response time
    if (source_count > 0)
    {
        self.aggregated_stats.average_response_time_ms =
            (float)(total_avg_response_time / (double)source_count);
    }

    return self.aggregated_stats;
}

fn bool CompositePeerDiscovery.is_active(&self) @dynamic
{
    return self.active;
}

fn String CompositePeerDiscovery.get_name(&self) @dynamic
{
    return "composite";
}

fn void CompositePeerDiscovery.free(&self) @dynamic
{
    self.stop_discovery();

    // Free all child sources
    for (usz i = 0; i < self.sources.len(); i++)
    {
        discovery::PeerDiscovery source = self.sources.get(i);
        source.free();
    }

    self.sources.free();
    self.callback_contexts.free();
    free(self);
}
