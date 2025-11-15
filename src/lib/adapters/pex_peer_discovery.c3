module libtorrent::adapters::pex_peer_discovery;

import libtorrent::ports::peer_discovery;
import libtorrent::peer_pool;
import libtorrent::common;
import std::core::log;

<*
 * PexPeerDiscovery Adapter
 * =========================
 * Wraps PEX (Peer Exchange) for PeerDiscovery interface.
 *
 * Features:
 * - Peer-to-peer peer list exchange (BEP 11)
 * - Learns about new peers from connected peers
 * - Automatic via extension protocol
 * - No explicit discovery needed
 *
 * Architecture:
 * - Adapter (hexagonal architecture)
 * - Wraps existing peer_pool PEX functionality
 * - Implements PeerDiscovery port interface
 *
 * Note:
 * - PEX is passive - peers are discovered automatically during connections
 * - Private torrents should not use PEX (BEP 27)
 * - This adapter mainly tracks statistics
 *>

// PexPeerDiscovery adapter struct
struct PexPeerDiscovery (peer_discovery::PeerDiscovery)
{
    // Dependencies
    peer_pool::PeerPool* peer_pool;

    // Configuration
    peer_discovery::DiscoveryOptions options;

    // State
    bool active;
    common::InfoHash current_info_hash;

    // Callbacks
    peer_discovery::PeerDiscoveredCallback peer_callback;
    peer_discovery::DiscoveryCompleteCallback complete_callback;
    void* user_data;

    // Statistics
    peer_discovery::DiscoveryStats stats;
    usz last_peer_count;  // Track peer count to detect new discoveries
}

// ============================================================================
// Factory
// ============================================================================

<*
 * Create a PexPeerDiscovery adapter.
 *
 * @param peer_pool : "Peer pool instance"
 * @return "PexPeerDiscovery adapter instance"
 *>
fn PexPeerDiscovery* create(
    peer_pool::PeerPool* peer_pool
) @public
{
    PexPeerDiscovery* adapter = mem::new(PexPeerDiscovery);

    adapter.peer_pool = peer_pool;

    adapter.options = peer_discovery::default_options();

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

    adapter.last_peer_count = 0;

    log::info( "[PexDiscovery] Created adapter");

    return adapter;
}

// ============================================================================
// PeerDiscovery Interface Implementation
// ============================================================================

fn void PexPeerDiscovery.start_discovery(
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
                     "[PexDiscovery] Discovery already active");
        return;
    }

    if (!self.peer_pool)
    {
        log::warn(
                     "[PexDiscovery] Peer pool not available");
        if (complete_callback)
        {
            complete_callback(false, "Peer pool not available", user_data);
        }
        return;
    }

    log::info(
                 "[PexDiscovery] Starting discovery (passive mode)");

    self.active = true;
    self.options = *options;
    self.current_info_hash = *info_hash;
    self.peer_callback = peer_callback;
    self.complete_callback = complete_callback;
    self.user_data = user_data;

    // PEX is passive - peers are exchanged automatically via extension protocol
    // The peer_pool handles PEX messages internally
    // We just track when new peers are discovered

    // Get initial peer count
    self.last_peer_count = self.peer_pool.peers.len();

    // Notify completion immediately (PEX is passive)
    if (self.complete_callback)
    {
        self.complete_callback(true, "", self.user_data);
    }
}

fn void PexPeerDiscovery.stop_discovery(&self) @dynamic
{
    if (!self.active) return;

    log::info(
                 "[PexDiscovery] Stopping discovery");

    self.active = false;

    // PEX continues automatically in peer_pool
    // Nothing to explicitly stop
}

fn peer_discovery::DiscoveryStats PexPeerDiscovery.get_stats(&self) @dynamic
{
    if (self.active && self.peer_pool)
    {
        // Check if peer count increased (indicating PEX discovery)
        usz current_peer_count = self.peer_pool.peers.len();
        if (current_peer_count > self.last_peer_count)
        {
            usz new_peers = current_peer_count - self.last_peer_count;
            self.stats.total_peers_discovered += new_peers;
            self.stats.successful_attempts++;
            self.last_peer_count = current_peer_count;

            log::debug(
                         "[PexDiscovery] Detected %d new peers via PEX",
                         new_peers);
        }

        self.stats.active_peers = current_peer_count;
    }

    return self.stats;
}

fn bool PexPeerDiscovery.is_active(&self) @dynamic
{
    return self.active;
}

fn String PexPeerDiscovery.get_name(&self) @dynamic
{
    return "pex";
}

fn void PexPeerDiscovery.free(&self) @dynamic
{
    self.stop_discovery();
    free(self);
}
