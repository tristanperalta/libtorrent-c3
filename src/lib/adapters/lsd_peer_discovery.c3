module libtorrent::adapters::lsd_peer_discovery;

import libtorrent::ports::peer_discovery;
import libtorrent::lsd;
import libtorrent::common;
import libtorrent::logger;
import async::event_loop;
import std::time;

<*
 * LsdPeerDiscovery Adapter
 * =========================
 * Wraps existing LSD (Local Service Discovery) for PeerDiscovery interface.
 *
 * Features:
 * - UDP multicast on local network (BEP 14)
 * - Multicast group: 239.192.152.143:6771
 * - Automatic peer discovery on LAN
 * - Periodic announces every 5 minutes
 * - Cookie-based filtering of own announcements
 *
 * Architecture:
 * - Adapter (hexagonal architecture)
 * - Wraps existing lsd module
 * - Implements PeerDiscovery port interface
 *
 * Note:
 * - Only works on local network
 * - Private torrents should not use LSD (BEP 27)
 *>

// LsdPeerDiscovery adapter struct
struct LsdPeerDiscovery (peer_discovery::PeerDiscovery)
{
    // Dependencies
    lsd::LsdManager* lsd_manager;
    event_loop::EventLoop* loop;

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
}

// ============================================================================
// Factory
// ============================================================================

<*
 * Create an LsdPeerDiscovery adapter.
 *
 * @param lsd_manager : "LSD manager instance"
 * @param loop : "Event loop for async operations"
 * @return "LsdPeerDiscovery adapter instance"
 *>
fn LsdPeerDiscovery* create(
    lsd::LsdManager* lsd_manager,
    event_loop::EventLoop* loop
) @public
{
    LsdPeerDiscovery* adapter = mem::new(LsdPeerDiscovery);

    adapter.lsd_manager = lsd_manager;
    adapter.loop = loop;

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

    logger::logf(logger::LogLevel.INFO, "[LsdDiscovery] Created adapter");

    return adapter;
}

// ============================================================================
// Internal LSD Callbacks
// ============================================================================

// Callback for when LSD discovers peers
fn void on_lsd_peers_discovered(common::InfoHash* infohash,
                                  common::SocketAddress[] peers,
                                  void* user_data)
{
    LsdPeerDiscovery* self = (LsdPeerDiscovery*)user_data;

    if (!self.active) return;

    // Verify this is for our torrent
    bool match = true;
    for (int i = 0; i < 20; i++)
    {
        if ((*infohash)[i] != self.current_info_hash[i])
        {
            match = false;
            break;
        }
    }

    if (!match) return;

    logger::logf(logger::LogLevel.INFO,
                 "[LsdDiscovery] Discovered %d peers via LSD", peers.len);

    // Update stats
    self.stats.successful_attempts++;
    self.stats.total_peers_discovered += peers.len;
    self.stats.last_discovery_time = (long)time::now().to_seconds();

    // Notify callback
    if (self.peer_callback)
    {
        self.peer_callback(peers, "lsd", self.user_data);
    }
}

// ============================================================================
// PeerDiscovery Interface Implementation
// ============================================================================

fn void LsdPeerDiscovery.start_discovery(
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
                     "[LsdDiscovery] Discovery already active");
        return;
    }

    if (!self.lsd_manager)
    {
        logger::logf(logger::LogLevel.WARN,
                     "[LsdDiscovery] LSD manager not available");
        if (complete_callback)
        {
            complete_callback(false, "LSD manager not available", user_data);
        }
        return;
    }

    logger::logf(logger::LogLevel.INFO,
                 "[LsdDiscovery] Starting discovery");

    self.active = true;
    self.options = *options;
    self.local_port = options.local_port;
    self.current_info_hash = *info_hash;
    self.peer_callback = peer_callback;
    self.complete_callback = complete_callback;
    self.user_data = user_data;

    // Set up LSD peer callback
    self.lsd_manager.peer_callback = &on_lsd_peers_discovered;
    self.lsd_manager.peer_callback_data = self;

    // Start LSD if not already active
    self.lsd_manager.start(self.loop);

    // Begin announcing
    self.stats.total_discovery_attempts++;
    self.lsd_manager.announce(&self.current_info_hash, self.local_port);

    // Notify completion immediately (LSD is fire-and-forget)
    if (self.complete_callback)
    {
        self.complete_callback(true, "", self.user_data);
    }
}

fn void LsdPeerDiscovery.stop_discovery(&self) @dynamic
{
    if (!self.active) return;

    logger::logf(logger::LogLevel.INFO,
                 "[LsdDiscovery] Stopping discovery");

    self.active = false;

    // LSD manager continues running for other torrents
    // Just stop announcing this specific torrent
    // (LSD manager handles announce lifecycle internally)
}

fn peer_discovery::DiscoveryStats LsdPeerDiscovery.get_stats(&self) @dynamic
{
    return self.stats;
}

fn bool LsdPeerDiscovery.is_active(&self) @dynamic
{
    return self.active;
}

fn String LsdPeerDiscovery.get_name(&self) @dynamic
{
    return "lsd";
}

fn void LsdPeerDiscovery.free(&self) @dynamic
{
    self.stop_discovery();
    free(self);
}
