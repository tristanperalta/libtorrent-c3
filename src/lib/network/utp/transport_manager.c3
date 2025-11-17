/**
 * μTP Transport Manager
 * =====================
 *
 * Centralized manager for all μTP transports using timer-based polling.
 * Follows libtorrent's proven pattern: single 100ms tick timer processes
 * all active connections for timeout checking, data polling, and ACK tracking.
 *
 * Architecture:
 * - One manager per EventLoop (singleton pattern)
 * - Single tick timer at 100ms intervals (production default from libtorrent)
 * - HashMap of all active transports by connection ID
 * - Each tick: check timeouts, poll for data, track write completion
 */

module libtorrent::network::utp;

import async::timer;
import async::event_loop;
import std::collections::map;
import std::io;
import libtorrent::common;
import libtorrent::utp::connection;

const ulong TICK_INTERVAL_MS = 100;  // 100ms - matches libtorrent default
const ulong CONNECT_TIMEOUT_MS = 3000;  // 3 second connection timeout

/**
 * Composite key for tracking μTP transports.
 *
 * BEP 29: Connection IDs are only unique per remote endpoint,
 * so we must key by (remote_addr, conn_id) like libutp does.
 */
struct TransportKey
{
    common::SocketAddress remote_addr;
    ushort conn_id;
}

/**
 * Hash function for TransportKey (required by C3 HashMap).
 *
 * Combines conn_id with remote address hash using SocketAddress.hash().
 */
fn uint TransportKey.hash(&self)
{
    // Use the existing SocketAddress.hash() method from common.c3
    uint addr_hash = self.remote_addr.hash();

    // Combine with conn_id using XOR (following libutp pattern)
    return addr_hash ^ ((uint)self.conn_id << 16);
}

/**
 * Equality operator for TransportKey (required by C3 HashMap).
 *
 * Two keys are equal if both remote_addr and conn_id match.
 */
fn bool TransportKey.equals(&self, TransportKey other) @operator(==)
{
    // Use SocketAddress equality (it already has @operator(==) implemented)
    return self.remote_addr == other.remote_addr
        && self.conn_id == other.conn_id;
}

/**
 * Centralized manager for μTP transports.
 *
 * Manages lifecycle and periodic processing of all active transports.
 */
struct UtpTransportManager
{
    event_loop::EventLoop* loop;
    timer::Timer* tick_timer;
    HashMap{TransportKey, UtpTransport*} transports;  // By (remote_addr, conn_id)
    bool running;
    ulong tick_count;  // For debugging/stats
}

/**
 * Create a new transport manager.
 */
fn UtpTransportManager* create_manager(event_loop::EventLoop* loop) @public
{
    UtpTransportManager* mgr = mem::new(UtpTransportManager);
    mgr.loop = loop;
    mgr.tick_timer = null;
    mgr.transports.init(mem);
    mgr.running = false;
    mgr.tick_count = 0;
    return mgr;
}

/**
 * Start the manager's tick timer.
 *
 * Begins 100ms periodic processing of all registered transports.
 */
fn void start(UtpTransportManager* mgr) @public
{
    if (mgr.running) return;

    // Create tick timer
    mgr.tick_timer = timer::create(mgr.loop)!!;

    // Start repeating timer at 100ms intervals
    mgr.tick_timer.start(
        TICK_INTERVAL_MS,      // Initial delay
        TICK_INTERVAL_MS,      // Repeat interval
        &on_tick_callback,
        (void*)mgr
    );

    mgr.running = true;
    io::printfn("[UtpTransportManager] Started tick timer at %dms intervals", TICK_INTERVAL_MS);
}

/**
 * Stop the manager's tick timer.
 *
 * NOTE: After calling stop(), you should call loop.run_once() to drain
 * the close callback and fully clean up the timer resources.
 */
fn void stop(UtpTransportManager* mgr) @public
{
    if (!mgr.running) return;

    if (mgr.tick_timer)
    {
        mgr.tick_timer.stop();
        mgr.tick_timer.close();  // Registers close callback
        mgr.tick_timer = null;

        // Drain event loop to process close callback
        // This ensures timer resources are fully cleaned up
        mgr.loop.run_once();
    }

    mgr.running = false;
    io::printfn("[UtpTransportManager] Stopped (processed %d ticks)", mgr.tick_count);
}

/**
 * Register a transport with the manager.
 *
 * The transport will be processed on each tick.
 */
fn void register_transport(UtpTransportManager* mgr, UtpTransport* transport) @public
{
    // Create composite key (BEP 29: conn_id + remote_addr)
    TransportKey key = {
        .remote_addr = transport.conn.remote_addr,
        .conn_id = transport.conn.send_id
    };
    mgr.transports.set(key, transport);
    // Only log when first transport is registered or on milestones
    if (mgr.transports.count == 1 || mgr.transports.count % 10 == 0)
    {
        io::printfn("[UtpTransportManager] Registered %d transport(s)", mgr.transports.count);
    }
}

/**
 * Unregister a transport from the manager.
 *
 * The transport will no longer be processed.
 */
fn void unregister_transport(UtpTransportManager* mgr, UtpTransport* transport) @public
{
    // Create composite key (BEP 29: conn_id + remote_addr)
    TransportKey key = {
        .remote_addr = transport.conn.remote_addr,
        .conn_id = transport.conn.send_id
    };
    mgr.transports.remove(key);
    io::printfn("[UtpTransportManager] Unregistered transport conn_id=%d (remaining: %d)",
                key.conn_id, mgr.transports.count);
}

/**
 * Main tick callback - processes all active transports.
 *
 * Called every 100ms to:
 * 1. Check connection timeouts and retransmit lost packets
 * 2. Poll for received data and invoke read callbacks
 * 3. Track write completion via ACK monitoring
 * 4. Detect connection state changes
 */
fn void on_tick_callback(timer::Timer* timer, void* user_data)
{
    UtpTransportManager* mgr = (UtpTransportManager*)user_data;
    mgr.tick_count++;

    // Process each transport
    mgr.transports.@each(; TransportKey key, UtpTransport* transport)
    {
        // Process this transport (polling, timeout checking, etc.)
        process_transport(transport);
    };

    // Debug logging every 100 ticks (10 seconds)
    if (mgr.tick_count % 100 == 0 && mgr.transports.count > 0)
    {
        io::printfn("[UtpTransportManager] Active: %d transports", mgr.transports.count);
    }
}

/**
 * Process a single transport during tick.
 *
 * Handles:
 * - Data polling (check if data available, invoke read callbacks)
 * - Connection state changes (check for CONNECTED, invoke connect callbacks)
 * - Timeout checking (detect stalled connections)
 * - Write completion tracking (monitor ACKs, invoke write callbacks)
 */
fn void process_transport(UtpTransport* transport)
{
    if (!transport.conn) return;

    // Phase 3: Check connection state for async connect
    if (!transport.connected && transport.conn.state == connection::ConnectionState.CONNECTED)
    {
        transport.connected = true;
        if (transport.connect_cb)
        {
            transport.connect_cb((Transport)transport, 0, transport.connect_user_data);
            transport.connect_cb = null;  // Only invoke once
        }
    }

    // Poll for received data (pull-based, μTP doesn't push)
    if (transport.read_cb && transport.conn.has_data())
    {
        // Use fixed suggested size (match TCP behavior)
        const usz SUGGESTED_SIZE = 65536;  // 64KB

        // Allocate buffer via callback
        char[] buffer = transport.alloc_cb((Transport)transport, SUGGESTED_SIZE, transport.read_user_data);

        // Read available data (up to buffer size)
        char[] data = transport.conn.recv_data(buffer.len);

        // Invoke read callback with actual data
        if (data.len > 0)
        {
            transport.read_cb((Transport)transport, data, transport.read_user_data);
        }
    }

    // Phase 4: Track write completion via ACK monitoring
    if (transport.has_pending_write && transport.conn.bytes_in_flight == 0)
    {
        // All sent data has been ACKed
        transport.has_pending_write = false;

        if (transport.write_cb)
        {
            transport.write_cb((Transport)transport, 0, transport.write_user_data);
            transport.write_cb = null;  // Only invoke once per write
        }
    }

    // TODO: Check timeouts (future phase)
    // if (connection_timed_out()) {
    //     transport.close();
    // }
}

/**
 * Free the manager and all resources.
 *
 * Properly cleans up all active transports and their connections before
 * freeing the manager itself.
 */
fn void free_manager(UtpTransportManager* mgr) @public
{
    if (mgr.running)
    {
        stop(mgr);
    }

    // Collect all transports first (avoid modifying HashMap during iteration)
    usz count = mgr.transports.count;
    UtpTransport*[] transports_to_free = mem::new_array(UtpTransport*, count);
    defer free(transports_to_free);

    usz index = 0;
    mgr.transports.@each(; TransportKey key, UtpTransport* transport)
    {
        transports_to_free[index] = transport;
        index++;
    };

    // Null out manager pointers so transports won't try to unregister during cleanup
    foreach (transport : transports_to_free)
    {
        if (transport)
        {
            transport.manager = null;
        }
    }

    // Free the HashMap
    mgr.transports.free();

    // Now close and free all transports
    foreach (transport : transports_to_free)
    {
        if (transport)
        {
            // Close connection
            if (transport.conn)
            {
                transport.conn.close();
                transport.conn.free();
                transport.conn = null;
            }

            // Free transport struct
            free(transport);
        }
    }

    // Free the manager struct
    free(mgr);
}
