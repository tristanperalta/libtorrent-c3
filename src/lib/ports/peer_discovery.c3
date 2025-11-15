module libtorrent::ports::peer_discovery;

import std::time;
import libtorrent::common;

<*
 * PeerDiscovery Port Interface
 * =============================
 * Hexagonal architecture port for peer discovery abstraction.
 *
 * This interface unifies all peer discovery mechanisms:
 * - Trackers (HTTP/UDP) - BEP 3, 15
 * - DHT (Distributed Hash Table) - BEP 5
 * - LSD (Local Service Discovery) - BEP 14
 * - PEX (Peer Exchange) - BEP 11
 * - Metadata Exchange - BEP 9
 *
 * Architecture:
 * - Core domain depends on this interface (Port)
 * - Concrete implementations are Adapters (outside the core)
 * - CompositePeerDiscovery aggregates multiple sources
 *
 * Benefits:
 * - Testability: Mock discovery for unit tests
 * - Modularity: Add/remove discovery mechanisms without changing core
 * - Configuration: Unified options for all mechanisms
 * - Statistics: Track performance across all sources
 *>

// ============================================================================
// Callback Types
// ============================================================================

// Called when peers are discovered from any source.
// Params: peers (discovered addresses), discovery_source (tracker/dht/lsd/pex), user_data
alias PeerDiscoveredCallback = fn void(
    common::SocketAddress[] peers,
    String discovery_source,
    void* user_data
);

// Called when a discovery attempt completes (success or failure).
// Params: success (true/false), error_message (description), user_data
alias DiscoveryCompleteCallback = fn void(
    bool success,
    String error_message,
    void* user_data
);

// ============================================================================
// Configuration
// ============================================================================

<*
 * Comprehensive configuration options for all peer discovery mechanisms.
 *
 * Structure:
 * - Common options (peer limits, timing, retry, network)
 * - Privacy options (private torrents)
 * - Mechanism-specific overrides (DHT, LSD, PEX)
 * - Logging options
 *
 * Use default_options() for BEP-compliant defaults.
 *>
struct DiscoveryOptions
{
    // ========================================================================
    // Peer Limits
    // ========================================================================

    <* Number of peers to request per discovery attempt (BEP 3: numwant) *>
    int max_peers_wanted;           // Default: 50

    <* Maximum total peers to maintain across all sources *>
    int max_total_peers;            // Default: 200

    // ========================================================================
    // Timing Configuration
    // ========================================================================

    <* Interval between discovery attempts (BEP 3: interval) *>
    uint discovery_interval_ms;     // Default: 1800000 (30 minutes)

    <* Minimum interval between attempts (rate limiting) *>
    uint min_discovery_interval_ms; // Default: 60000 (1 minute)

    <* Timeout for single discovery request *>
    uint discovery_timeout_ms;      // Default: 10000 (10 seconds)

    // ========================================================================
    // Retry Configuration
    // ========================================================================

    <* Maximum number of retries on failure *>
    int max_retries;                // Default: 3

    <* Exponential backoff multiplier for retry delays *>
    float retry_backoff_multiplier; // Default: 2.0

    <* Base delay for first retry (ms) *>
    uint retry_base_delay_ms;       // Default: 1000

    // ========================================================================
    // Network Configuration
    // ========================================================================

    <* Local BitTorrent listening port *>
    ushort local_port;              // Default: 6881

    <* Enable IPv4 peer discovery *>
    bool enable_ipv4;               // Default: true

    <* Enable IPv6 peer discovery *>
    bool enable_ipv6;               // Default: true

    <* Filter private IP addresses (RFC 1918) *>
    bool filter_private_ips;        // Default: true

    <* Prevent connecting to self *>
    bool filter_self_connection;    // Default: true

    // ========================================================================
    // Privacy Configuration
    // ========================================================================

    <* Respect private torrent flag (BEP 27: disable DHT/LSD/PEX) *>
    bool respect_private_flag;      // Default: true

    <* Randomize peer_id for each announce *>
    bool randomize_peer_id;         // Default: false

    // ========================================================================
    // Tracker-Specific Options
    // ========================================================================

    <* User-Agent header for HTTP tracker requests *>
    String user_agent;              // Default: "libtorrent-c3/0.1.0"

    <* Tracker key for identification (BEP 7) *>
    String tracker_key;             // Default: "" (auto-generated)

    // ========================================================================
    // DHT-Specific Options
    // ========================================================================

    <* Bootstrap nodes for DHT (host:port pairs) *>
    common::SocketAddress[] dht_bootstrap_nodes; // Default: empty (use standard)

    <* DHT k-value (bucket size, BEP 5) *>
    int dht_k_value;                // Default: 8

    <* DHT alpha (concurrent lookups, BEP 5) *>
    int dht_alpha;                  // Default: 3

    <* DHT announce interval (seconds) *>
    uint dht_announce_interval_sec; // Default: 1800 (30 minutes)

    // ========================================================================
    // LSD-Specific Options
    // ========================================================================

    <* LSD multicast TTL (1 = local network only) *>
    int lsd_multicast_ttl;          // Default: 1

    <* LSD announce interval (ms) *>
    uint lsd_announce_interval_ms;  // Default: 300000 (5 minutes)

    // ========================================================================
    // PEX-Specific Options
    // ========================================================================

    <* Maximum peers to include in PEX message *>
    int pex_max_peers_per_message;  // Default: 50

    <* Include peer flags in PEX (BEP 11) *>
    bool pex_include_flags;         // Default: true

    <* PEX exchange interval (ms) *>
    uint pex_exchange_interval_ms;  // Default: 60000 (1 minute)

    // ========================================================================
    // Logging Options
    // ========================================================================

    <* Enable debug logging for discovery *>
    bool enable_debug_logging;      // Default: false
}

<*
 * Factory function for default discovery options.
 * Provides BEP-compliant defaults for all discovery mechanisms.
 *
 * @return "DiscoveryOptions with sensible defaults"
 *>
fn DiscoveryOptions default_options() @public
{
    DiscoveryOptions opts;

    // Peer limits
    opts.max_peers_wanted = 50;
    opts.max_total_peers = 200;

    // Timing
    opts.discovery_interval_ms = 1800000;      // 30 minutes
    opts.min_discovery_interval_ms = 60000;    // 1 minute
    opts.discovery_timeout_ms = 10000;         // 10 seconds

    // Retry
    opts.max_retries = 3;
    opts.retry_backoff_multiplier = 2.0;
    opts.retry_base_delay_ms = 1000;

    // Network
    opts.local_port = 6881;
    opts.enable_ipv4 = true;
    opts.enable_ipv6 = true;
    opts.filter_private_ips = true;
    opts.filter_self_connection = true;

    // Privacy
    opts.respect_private_flag = true;
    opts.randomize_peer_id = false;

    // Tracker
    opts.user_agent = "libtorrent-c3/0.1.0";
    opts.tracker_key = "";

    // DHT
    opts.dht_bootstrap_nodes = {};
    opts.dht_k_value = 8;
    opts.dht_alpha = 3;
    opts.dht_announce_interval_sec = 1800;

    // LSD
    opts.lsd_multicast_ttl = 1;
    opts.lsd_announce_interval_ms = 300000;    // 5 minutes

    // PEX
    opts.pex_max_peers_per_message = 50;
    opts.pex_include_flags = true;
    opts.pex_exchange_interval_ms = 60000;     // 1 minute

    // Logging
    opts.enable_debug_logging = false;

    return opts;
}

// ============================================================================
// Statistics
// ============================================================================

<*
 * Statistics for peer discovery performance tracking.
 *
 * Used for monitoring, debugging, and optimization.
 * CompositePeerDiscovery aggregates stats from all sources.
 *>
struct DiscoveryStats
{
    <* Total peers discovered across all attempts *>
    usz total_peers_discovered;

    <* Total number of discovery attempts *>
    usz total_discovery_attempts;

    <* Number of successful discovery attempts *>
    usz successful_attempts;

    <* Number of failed discovery attempts *>
    usz failed_attempts;

    <* Unix timestamp of last discovery attempt *>
    long last_discovery_time;

    <* Average response time in milliseconds *>
    float average_response_time_ms;

    <* Number of peers currently being used *>
    usz active_peers;
}

// ============================================================================
// PeerDiscovery Interface
// ============================================================================

<*
 * PeerDiscovery interface - unifies all peer discovery mechanisms.
 *
 * Implementations:
 * - TrackerPeerDiscovery (HTTP/UDP trackers)
 * - DhtPeerDiscovery (DHT get_peers)
 * - LsdPeerDiscovery (LAN multicast)
 * - PexPeerDiscovery (Peer exchange)
 * - CompositePeerDiscovery (aggregates all sources)
 *
 * Usage:
 *   PeerDiscovery* discovery = create_composite_discovery();
 *
 *   // Simple API - uses defaults via convenience function
 *   start_with_defaults(
 *       discovery,
 *       &info_hash,
 *       &on_peers_discovered,
 *       &on_complete,
 *       user_data
 *   );
 *
 *   // Full control API - custom options
 *   DiscoveryOptions opts = default_options();
 *   opts.max_peers_wanted = 100;
 *   discovery.start_discovery(
 *       &info_hash,
 *       &opts,
 *       &on_peers_discovered,
 *       &on_complete,
 *       user_data
 *   );
 *>
interface PeerDiscovery
{
    <*
     * Start peer discovery with custom options.
     *
     * All adapters MUST implement this method.
     * This is the primary method that provides full configuration control.
     *
     * @param info_hash : "Torrent info hash to discover peers for"
     * @param options : "Configuration options"
     * @param peer_callback : "Called when peers are discovered"
     * @param complete_callback : "Called when discovery completes"
     * @param user_data : "User data passed to callbacks"
     *>
    fn void start_discovery(
        common::InfoHash* info_hash,
        DiscoveryOptions* options,
        PeerDiscoveredCallback peer_callback,
        DiscoveryCompleteCallback complete_callback,
        void* user_data
    );

    <*
     * Stop ongoing peer discovery.
     *
     * Cancels pending requests, stops timers, cleans up resources.
     * Safe to call multiple times.
     *>
    fn void stop_discovery();

    <*
     * Get current discovery statistics.
     *
     * @return "Statistics struct with current values"
     *>
    fn DiscoveryStats get_stats();

    <*
     * Check if discovery is currently active.
     *
     * @return "true if discovery is running, false otherwise"
     *>
    fn bool is_active();

    <*
     * Get the name of this discovery mechanism.
     *
     * @return "Name like 'tracker', 'dht', 'lsd', 'pex', 'composite'"
     *>
    fn String get_name();

    <*
     * Free resources associated with this discovery instance.
     *
     * Must call stop_discovery() first if still active.
     * After calling free(), the instance is invalid.
     *>
    fn void free();
}

// ============================================================================
// Convenience Wrapper
// ============================================================================

<*
 * Start peer discovery with default options (convenience function).
 *
 * This is a standalone wrapper that calls discovery.start_discovery() with
 * default_options(). It's provided for convenience - users don't need to
 * manually create and pass default options.
 *
 * @param discovery : "PeerDiscovery instance"
 * @param info_hash : "Torrent info hash to discover peers for"
 * @param peer_callback : "Called when peers are discovered"
 * @param complete_callback : "Called when discovery completes"
 * @param user_data : "User data passed to callbacks"
 *
 * Example:
 *   PeerDiscovery* discovery = create_tracker_discovery(...);
 *   start_with_defaults(discovery, &info_hash, &on_peers, &on_complete, ctx);
 *>
fn void start_with_defaults(
    PeerDiscovery* discovery,
    common::InfoHash* info_hash,
    PeerDiscoveredCallback peer_callback,
    DiscoveryCompleteCallback complete_callback,
    void* user_data
) @public
{
    DiscoveryOptions opts = default_options();
    discovery.start_discovery(
        info_hash,
        &opts,
        peer_callback,
        complete_callback,
        user_data
    );
}
