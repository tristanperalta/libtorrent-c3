module libtorrent::shared_resources;

import async::event_loop;
import async::timer;
import libtorrent::dht_client;
import libtorrent::lsd;
import libtorrent::ports::peer_discovery;
import std::io;

/**
 * SharedResources - Resources shared across torrent sessions
 * ===========================================================
 *
 * Contains resources that can be shared across multiple torrent sessions:
 * - Event loop (single thread model)
 * - DHT client (one DHT node serves all torrents)
 * - Peer discovery (DHT/LSD broadcast once)
 * - LSD manager (Local Service Discovery)
 *
 * Uses reference counting for automatic cleanup when last session releases.
 */

/**
 * Resources shared across one or more torrent sessions.
 * Uses reference counting for automatic memory management.
 */
struct SharedResources
{
    // Core shared resources
    event_loop::EventLoop* loop;                // Event loop (owned)
    dht_client::DhtClient* dht;                  // DHT client (owned)
    peer_discovery::PeerDiscovery* peer_discovery;  // Composite peer discovery (owned)
    lsd::LsdManager* lsd_mgr;                    // LSD manager (owned)

    // Shared timers
    async::timer::Timer* dht_tick_timer;         // DHT RPC timeout processing (DHT-wide)
    async::timer::Timer* lsd_timer;              // LSD announce timer (all torrents)

    // DHT/LSD flags
    bool dht_enabled;
    bool lsd_enabled;

    // Network configuration
    ushort listen_port;                          // Shared listening port (default: 6881)

    // Reference counting
    uint ref_count;                              // Number of sessions using this

    // Statistics
    uint active_sessions;
    ulong total_download_rate;
    ulong total_upload_rate;
}

/**
 * Create shared resources with an event loop.
 *
 * @param loop : "Event loop to use (NOT owned - caller must manage)"
 * @return "New SharedResources instance"
 */
fn SharedResources* create(event_loop::EventLoop* loop) @public
{
    SharedResources* shared = mem::new(SharedResources);

    shared.loop = loop;
    shared.dht = null;
    shared.peer_discovery = null;
    shared.lsd_mgr = null;
    shared.dht_tick_timer = null;
    shared.lsd_timer = null;
    shared.dht_enabled = false;
    shared.lsd_enabled = false;
    shared.listen_port = 6881;  // Default BitTorrent port
    shared.ref_count = 0;
    shared.active_sessions = 0;
    shared.total_download_rate = 0;
    shared.total_upload_rate = 0;

    return shared;
}

/**
 * Add a reference (session is using these resources).
 * Increments the reference count.
 */
fn void SharedResources.add_ref(&self) @public
{
    self.ref_count++;
    self.active_sessions++;
}

/**
 * Release a reference (session is done with resources).
 * Decrements reference count and auto-frees when it reaches zero.
 *
 * This is the normal cleanup path - when the last session releases,
 * SharedResources automatically cleans itself up.
 */
fn void SharedResources.release(&self) @public
{
    if (self.ref_count == 0)
    {
        io::eprintfn("Warning: SharedResources.release() called with ref_count=0");
        return;
    }

    self.ref_count--;
    if (self.active_sessions > 0)
    {
        self.active_sessions--;
    }

    if (self.ref_count == 0)
    {
        // Last reference released - auto-cleanup
        self.free();
    }
}

/**
 * Force free all resources (ignores ref count).
 *
 * Use this for error cleanup or when you know no sessions are using it.
 * For normal cleanup, use release() instead.
 */
fn void SharedResources.free(&self) @public
{
    // Close shared timers
    if (self.dht_tick_timer)
    {
        self.dht_tick_timer.close();
        self.dht_tick_timer = null;
    }

    if (self.lsd_timer)
    {
        self.lsd_timer.close();
        self.lsd_timer = null;
    }

    // Clean up DHT
    if (self.dht)
    {
        self.dht.free();
        self.dht = null;
    }

    // Clean up LSD
    if (self.lsd_mgr)
    {
        self.lsd_mgr.free();
        self.lsd_mgr = null;
    }

    // Clean up peer discovery
    if (self.peer_discovery)
    {
        free(self.peer_discovery);
        self.peer_discovery = null;
    }

    // Note: Event loop is NOT owned by SharedResources
    // Caller must manage event loop lifetime

    free(self);
}

/**
 * Get the event loop.
 */
fn event_loop::EventLoop* SharedResources.get_loop(&self) @public
{
    return self.loop;
}

/**
 * Check if DHT is enabled.
 */
fn bool SharedResources.is_dht_enabled(&self) @public
{
    return self.dht_enabled && self.dht != null;
}

/**
 * Check if LSD is enabled.
 */
fn bool SharedResources.is_lsd_enabled(&self) @public
{
    return self.lsd_enabled && self.lsd_mgr != null;
}
