module libtorrent::adapters::dht_peer_discovery;

import libtorrent::ports::peer_discovery;
import libtorrent::dht_client;
import libtorrent::dht_get_peers;
import libtorrent::dht_routing_table;
import libtorrent::common;
import libtorrent::logger;
import async::event_loop;
import async::timer;
import std::time;
import std::io;
import std::collections::list;

<*
 * DhtPeerDiscovery Adapter
 * =========================
 * Wraps existing DHT client for PeerDiscovery interface.
 *
 * Features:
 * - Kademlia DHT get_peers operation (BEP 5)
 * - Iterative traversal to find closest nodes
 * - Dual IPv4/IPv6 routing tables (BEP 32)
 * - Periodic peer discovery with configurable interval
 * - Statistics tracking
 *
 * Architecture:
 * - Adapter (hexagonal architecture)
 * - Wraps existing dht_client and dht_get_peers modules
 * - Implements PeerDiscovery port interface
 *
 * Note:
 * - DHT must be bootstrapped before discovery works
 * - Private torrents should not use DHT (BEP 27)
 *>

// DhtPeerDiscovery adapter struct
struct DhtPeerDiscovery (peer_discovery::PeerDiscovery)
{
    // Dependencies
    dht_client::DhtClient* dht_client;
    event_loop::EventLoop* loop;

    // Configuration
    peer_discovery::DiscoveryOptions options;

    // State
    bool active;
    common::InfoHash current_info_hash;
    dht_get_peers::GetPeersSearch* search;

    // Callbacks
    peer_discovery::PeerDiscoveredCallback peer_callback;
    peer_discovery::DiscoveryCompleteCallback complete_callback;
    void* user_data;

    // Statistics
    peer_discovery::DiscoveryStats stats;
    long last_discovery_start_time;

    // Timers
    timer::Timer* discovery_timer;      // Periodic discovery timer
    timer::Timer* check_timer;          // Check for new peers timer
}

// ============================================================================
// Factory
// ============================================================================

<*
 * Create a DhtPeerDiscovery adapter.
 *
 * @param dht_client : "DHT client instance"
 * @param loop : "Event loop for async operations"
 * @return "DhtPeerDiscovery adapter instance"
 *>
fn DhtPeerDiscovery* create(
    dht_client::DhtClient* dht_client,
    event_loop::EventLoop* loop
) @public
{
    DhtPeerDiscovery* adapter = mem::new(DhtPeerDiscovery);

    adapter.dht_client = dht_client;
    adapter.loop = loop;

    adapter.options = peer_discovery::default_options();

    adapter.active = false;
    adapter.search = null;
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

    adapter.last_discovery_start_time = 0;
    adapter.discovery_timer = null;
    adapter.check_timer = null;

    logger::logf(logger::LogLevel.INFO, "[DhtDiscovery] Created adapter");

    return adapter;
}

// ============================================================================
// Callbacks
// ============================================================================

// Check for discovered peers
fn void on_check_peers(timer::Timer* timer, void* user_data)
{
    DhtPeerDiscovery* self = (DhtPeerDiscovery*)user_data;

    if (!self.active || !self.search) return;

    // Calculate response time
    long now = (long)(time::now().to_seconds() * 1000);
    long elapsed_ms = now - self.last_discovery_start_time;

    // Check if search found any peers
    if (self.search.found_peers)
    {
        // Get discovered peers
        common::SocketAddress[] peers = self.search.get_peers();
        defer free(peers);

        if (peers.len > 0)
        {
            logger::logf(logger::LogLevel.INFO,
                         "[DhtDiscovery] Found %d peers from DHT (elapsed: %d ms)",
                         peers.len, elapsed_ms);

            // Update stats
            self.stats.successful_attempts++;
            self.stats.total_peers_discovered += peers.len;
            self.stats.last_discovery_time = now / 1000;

            // Update rolling average response time
            if (self.stats.successful_attempts > 1)
            {
                double alpha = 0.2;
                self.stats.average_response_time_ms =
                    (float)((alpha * (double)elapsed_ms) +
                    ((1.0 - alpha) * (double)self.stats.average_response_time_ms));
            }
            else
            {
                self.stats.average_response_time_ms = (float)elapsed_ms;
            }

            // Notify callback with discovered peers
            if (self.peer_callback)
            {
                self.peer_callback(peers, "dht", self.user_data);
            }

            // Notify completion
            if (self.complete_callback)
            {
                self.complete_callback(true, "", self.user_data);
            }
        }
    }
    else if (self.search.is_done())
    {
        // Search completed but no peers found
        logger::logf(logger::LogLevel.DEBUG,
                     "[DhtDiscovery] DHT search completed with no peers (elapsed: %d ms)",
                     elapsed_ms);

        self.stats.failed_attempts++;

        if (self.complete_callback)
        {
            self.complete_callback(false, "No peers found", self.user_data);
        }
    }
    else
    {
        // Search still ongoing
        logger::logf(logger::LogLevel.DEBUG,
                     "[DhtDiscovery] DHT search ongoing... (elapsed: %d ms)",
                     elapsed_ms);
    }

    // Clean up check timer
    if (self.check_timer)
    {
        self.check_timer.close();
        self.check_timer = null;
    }
}

// Periodic discovery timer callback
fn void on_periodic_discovery(timer::Timer* timer, void* user_data)
{
    DhtPeerDiscovery* self = (DhtPeerDiscovery*)user_data;

    if (!self.active) return;

    logger::logf(logger::LogLevel.DEBUG,
                 "[DhtDiscovery] Periodic discovery triggered");

    self.do_search();
}

// ============================================================================
// Internal Search Logic
// ============================================================================

<*
 * Perform a DHT get_peers search.
 *>
fn void DhtPeerDiscovery.do_search(&self) @private
{
    if (!self.dht_client)
    {
        logger::logf(logger::LogLevel.WARN,
                     "[DhtDiscovery] DHT client not available");
        if (self.complete_callback)
        {
            self.complete_callback(false, "DHT client not available", self.user_data);
        }
        return;
    }

    // Check if DHT is bootstrapped
    if (!self.dht_client.is_bootstrapped())
    {
        logger::logf(logger::LogLevel.WARN,
                     "[DhtDiscovery] DHT not bootstrapped yet");
        if (self.complete_callback)
        {
            self.complete_callback(false, "DHT not bootstrapped", self.user_data);
        }
        return;
    }

    self.stats.total_discovery_attempts++;
    self.last_discovery_start_time = (long)(time::now().to_seconds() * 1000);

    logger::logf(logger::LogLevel.DEBUG,
                 "[DhtDiscovery] Starting DHT get_peers search (attempt %d)",
                 self.stats.total_discovery_attempts);

    // Create new search if needed
    if (!self.search)
    {
        self.search = dht_get_peers::create_search(self.current_info_hash);
    }

    // Get closest nodes from both IPv4 and IPv6 routing tables (BEP 32)
    int k_value = self.options.dht_k_value;  // Typically 8

    // Query IPv4 routing table
    dht_routing_table::NodeEntry[] ipv4_nodes =
        self.dht_client.routing_table_ipv4.find_closest_nodes(
            self.current_info_hash, k_value);
    defer free(ipv4_nodes);

    // Query IPv6 routing table
    dht_routing_table::NodeEntry[] ipv6_nodes =
        self.dht_client.routing_table_ipv6.find_closest_nodes(
            self.current_info_hash, k_value);
    defer free(ipv6_nodes);

    // Merge results into a List
    List{dht_routing_table::NodeEntry} nodes;
    nodes.init(mem);
    defer nodes.free();

    // Add IPv4 nodes to list
    foreach (node : ipv4_nodes)
    {
        nodes.push(node);
    }

    // Add IPv6 nodes to list
    foreach (node : ipv6_nodes)
    {
        nodes.push(node);
    }

    if (nodes.len() == 0)
    {
        logger::logf(logger::LogLevel.WARN,
                     "[DhtDiscovery] No nodes in routing tables yet");
        self.stats.failed_attempts++;

        if (self.complete_callback)
        {
            self.complete_callback(false, "No DHT nodes in routing table", self.user_data);
        }
        return;
    }

    logger::logf(logger::LogLevel.DEBUG,
                 "[DhtDiscovery] Querying %d DHT nodes (%d IPv4, %d IPv6)",
                 nodes.len(), ipv4_nodes.len, ipv6_nodes.len);

    // Send get_peers query to each node
    int queries_sent = 0;
    for (usz i = 0; i < nodes.len(); i++)
    {
        dht_routing_table::NodeEntry node = nodes.get(i);
        self.dht_client.send_get_peers(
            node.id,
            node.addr,
            self.current_info_hash,
            self.search
        );
        queries_sent++;
    }

    if (queries_sent == 0)
    {
        logger::logf(logger::LogLevel.WARN,
                     "[DhtDiscovery] No DHT nodes available for query");
        self.stats.failed_attempts++;

        if (self.complete_callback)
        {
            self.complete_callback(false, "No DHT nodes available", self.user_data);
        }
        return;
    }

    logger::logf(logger::LogLevel.DEBUG,
                 "[DhtDiscovery] Sent %d get_peers queries", queries_sent);

    // Schedule check timer to collect results
    uint check_interval_ms = self.options.discovery_timeout_ms;

    timer::Timer*? timer_opt = timer::create(self.loop);
    if (catch err = timer_opt)
    {
        logger::logf(logger::LogLevel.WARN,
                     "[DhtDiscovery] Failed to create check timer");
        return;
    }

    self.check_timer = timer_opt;
    self.check_timer.start(check_interval_ms, 0, &on_check_peers, self);
}

// ============================================================================
// PeerDiscovery Interface Implementation
// ============================================================================

fn void DhtPeerDiscovery.start_discovery(
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
        logger::logf(logger::LogLevel.WARN,
                     "[DhtDiscovery] Discovery already active");
        return;
    }

    logger::logf(logger::LogLevel.INFO,
                 "[DhtDiscovery] Starting discovery");

    self.active = true;
    self.options = *options;
    self.current_info_hash = *info_hash;
    self.peer_callback = peer_callback;
    self.complete_callback = complete_callback;
    self.user_data = user_data;

    // Initial search
    self.do_search();

    // Set up periodic discovery if not already running
    if (!self.discovery_timer)
    {
        uint interval_ms = options.discovery_interval_ms;

        // Respect min interval
        if (interval_ms < options.min_discovery_interval_ms)
        {
            interval_ms = options.min_discovery_interval_ms;
        }

        logger::logf(logger::LogLevel.DEBUG,
                     "[DhtDiscovery] Setting up periodic discovery every %d ms",
                     interval_ms);

        timer::Timer*? timer_opt = timer::create(self.loop);
        if (catch err = timer_opt)
        {
            logger::logf(logger::LogLevel.WARN,
                         "[DhtDiscovery] Failed to create periodic timer");
            return;
        }

        self.discovery_timer = timer_opt;
        self.discovery_timer.start(interval_ms, interval_ms,
                                    &on_periodic_discovery, self);
    }
}

fn void DhtPeerDiscovery.stop_discovery(&self) @dynamic
{
    if (!self.active) return;

    logger::logf(logger::LogLevel.INFO,
                 "[DhtDiscovery] Stopping discovery");

    self.active = false;

    // Stop timers
    if (self.check_timer)
    {
        self.check_timer.stop();
        self.check_timer.close();
        self.check_timer = null;
    }

    if (self.discovery_timer)
    {
        self.discovery_timer.stop();
        self.discovery_timer.close();
        self.discovery_timer = null;
    }

    // Clean up search
    if (self.search)
    {
        self.search.free();
        self.search = null;
    }
}

fn peer_discovery::DiscoveryStats DhtPeerDiscovery.get_stats(&self) @dynamic
{
    return self.stats;
}

fn bool DhtPeerDiscovery.is_active(&self) @dynamic
{
    return self.active;
}

fn String DhtPeerDiscovery.get_name(&self) @dynamic
{
    return "dht";
}

fn void DhtPeerDiscovery.free(&self) @dynamic
{
    self.stop_discovery();
    free(self);
}
