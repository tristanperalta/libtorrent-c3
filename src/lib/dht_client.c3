module libtorrent::dht_client;

import std::io;
import std::time;
import std::collections::list;
import libtorrent::common;
import libtorrent::dht_routing_table;
import libtorrent::dht_rpc_manager;
import libtorrent::krpc;
import libtorrent::bencode;
import async::udp;
import async::event_loop;
import uv;

/**
 * DHT Client Implementation
 * =========================
 * Main DHT client that coordinates routing table, RPC manager, and DHT operations.
 * Implements BEP 5 (Kademlia DHT) for peer discovery.
 *
 * Key responsibilities:
 * - Bootstrap DHT node by connecting to bootstrap nodes
 * - Send/receive DHT queries (ping, find_node, get_peers, announce_peer)
 * - Maintain routing table with periodic refreshes
 * - Coordinate between routing table and RPC manager
 */

// ============================================================================
// Constants
// ============================================================================

const int DHT_PORT = 6881;                    // Default DHT port
const int BOOTSTRAP_TIMEOUT_MS = 10000;        // 10 second bootstrap timeout
const int BUCKET_REFRESH_INTERVAL_SEC = 900;  // 15 minutes
const int MAX_BOOTSTRAP_NODES = 10;            // Maximum bootstrap nodes to try

// ============================================================================
// Fault Definitions
// ============================================================================

faultdef DHT_NOT_BOOTSTRAPPED;
faultdef DHT_BOOTSTRAP_FAILED;
faultdef DHT_INVALID_NODE_ID;

// ============================================================================
// Data Structures
// ============================================================================

/**
 * Bootstrap node entry
 */
struct BootstrapNode
{
    common::Ipv4Addr ip;
    ushort port;
}

/**
 * DHT client state
 */
enum DhtState : char
{
    UNINITIALIZED,    // Not yet initialized
    BOOTSTRAPPING,    // Connecting to bootstrap nodes
    RUNNING,          // Normal operation
    STOPPED           // Stopped/shutdown
}

/**
 * DHT Client
 * Main DHT client coordinating all DHT operations
 */
struct DhtClient
{
    common::NodeId our_id;                         // Our 20-byte node ID
    dht_routing_table::RoutingTable* routing_table; // Routing table
    dht_rpc_manager::RpcManager* rpc_manager;      // RPC transaction manager
    DhtState state;                                // Current state
    long last_refresh_time;                        // Last bucket refresh timestamp
    BootstrapNode[MAX_BOOTSTRAP_NODES] bootstrap_nodes;
    int bootstrap_node_count;
    udp::UdpSocket* socket;                        // UDP socket for DHT communication
    event_loop::EventLoop* loop;                   // Event loop
}

// ============================================================================
// DHT Client Lifecycle
// ============================================================================

/**
 * Create a new DHT client
 *
 * @param our_id Our node ID (20 random bytes)
 * @param loop Event loop for async I/O
 * @param port DHT port to bind to
 * @return Initialized DHT client (allocated on heap), or null on failure
 */
fn DhtClient* create_dht_client(common::NodeId our_id, event_loop::EventLoop* loop, ushort port) @public
{
    DhtClient* client = mem::new(DhtClient);

    // Copy our ID
    for (int i = 0; i < 20; i++)
    {
        client.our_id[i] = our_id[i];
    }

    // Create routing table and RPC manager
    client.routing_table = dht_routing_table::create_routing_table(our_id);
    client.rpc_manager = dht_rpc_manager::create_rpc_manager();

    client.state = DhtState.UNINITIALIZED;
    client.last_refresh_time = 0;
    client.bootstrap_node_count = 0;
    client.loop = loop;

    // Create UDP socket (only if event loop is provided)
    if (loop != null)
    {
        udp::UdpSocket*? socket_opt = udp::create(loop);
        if (catch err = socket_opt)
        {
            io::eprintfn("[DHT] Failed to create UDP socket");
            free_dht_client(client);
            return null;
        }

        client.socket = socket_opt;

        // Bind to DHT port
        DString addr_str;
        addr_str.appendf("0.0.0.0");
        udp::bind(client.socket, addr_str.str_view(), (int)port);

        // Start receiving UDP datagrams
        udp::recv_start(client.socket, &on_udp_alloc, &on_udp_recv, client);

        io::printfn("[DHT] UDP socket bound to port %d", port);
    }
    else
    {
        client.socket = null;
    }

    return client;
}

/**
 * Helper function to free callback context userdata
 */
fn void free_callback_context(void* userdata)
{
    if (userdata) free(userdata);
}

/**
 * Free a DHT client
 *
 * @param client DHT client to free
 */
fn void free_dht_client(DhtClient* client) @public
{
    if (!client) return;

    // Close UDP socket
    if (client.socket)
    {
        udp::close(client.socket);
    }

    // Cancel all pending transactions and free their callback contexts
    if (client.rpc_manager)
    {
        dht_rpc_manager::cancel_all_transactions(client.rpc_manager, &free_callback_context);
        dht_rpc_manager::free_rpc_manager(client.rpc_manager);
    }

    if (client.routing_table)
    {
        dht_routing_table::free_routing_table(client.routing_table);
    }

    free(client);
}

// ============================================================================
// Bootstrap Node Management
// ============================================================================

/**
 * Add a bootstrap node
 *
 * @param client DHT client
 * @param ip Bootstrap node IP address
 * @param port Bootstrap node port
 * @return true if node was added
 */
fn bool add_bootstrap_node(DhtClient* client, common::Ipv4Addr ip, ushort port) @public
{
    if (client.bootstrap_node_count >= MAX_BOOTSTRAP_NODES)
    {
        return false;
    }

    BootstrapNode* node = &client.bootstrap_nodes[client.bootstrap_node_count];
    for (int i = 0; i < 4; i++) node.ip[i] = ip[i];
    node.port = port;
    client.bootstrap_node_count++;

    return true;
}

/**
 * Add well-known bootstrap nodes
 * Uses public DHT bootstrap nodes from BitTorrent clients
 *
 * @param client DHT client
 */
fn void add_default_bootstrap_nodes(DhtClient* client) @public
{
    // router.bittorrent.com (87.98.162.88:6881)
    add_bootstrap_node(client, { 87, 98, 162, 88 }, 6881);

    // dht.transmissionbt.com (87.98.162.88:6881 - same IP as above)
    // router.utorrent.com (82.221.103.244:6881)
    add_bootstrap_node(client, { 82, 221, 103, 244 }, 6881);

    // dht.libtorrent.org (87.98.162.88:6881 - same IP)
    // router.silotis.us (130.239.18.159:6881)
    add_bootstrap_node(client, { 130, 239, 18, 159 }, 6881);
}

// ============================================================================
// RPC Query Sending
// ============================================================================

/**
 * Helper: Convert IP address to string
 */
fn String ip_to_string(common::Ipv4Addr ip) => @pool()
{
    DString buf;
    buf.appendf("%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
    return buf.copy_str(mem);
}

/**
 * Callback context for RPC responses
 */
struct RpcCallbackContext
{
    DhtClient* client;
    krpc::QueryType query_type;
}

/**
 * UDP send callback
 */
fn void on_udp_send(udp::UdpSocket* socket, int status, void* user_data)
{
    if (status < 0)
    {
        io::eprintfn("[DHT] UDP send failed");
    }
}

/**
 * Generic RPC response callback
 * Handles responses and updates routing table
 *
 * @param response Response message (null on timeout)
 * @param userdata RpcCallbackContext pointer
 */
fn void rpc_response_callback(krpc::KrpcMessage* response, void* userdata)
{
    RpcCallbackContext* ctx = (RpcCallbackContext*)userdata;

    if (!response)
    {
        // Timeout - could mark node as failed
        return;
    }

    // Extract node ID from response and add to routing table
    // (In a full implementation, we'd parse the response and extract node info)

    free(ctx);
}

/**
 * Send a ping query to a node
 *
 * @param client DHT client
 * @param target_id Target node ID
 * @param target_ip Target IP address
 * @param target_port Target port
 * @return true if query was sent
 */
fn bool send_ping(DhtClient* client, common::NodeId target_id,
                  common::Ipv4Addr target_ip, ushort target_port) @public
{
    // Create callback context
    RpcCallbackContext* ctx = mem::new(RpcCallbackContext);
    ctx.client = client;
    ctx.query_type = krpc::QueryType.PING;

    // Create transaction
    char[2]? tid_opt = dht_rpc_manager::create_transaction(
        client.rpc_manager,
        krpc::QueryType.PING,
        target_id,
        target_ip,
        target_port,
        &rpc_response_callback,
        ctx
    );

    if (catch excuse = tid_opt)
    {
        free(ctx);
        return false;
    }

    // Skip network I/O if no socket (test mode)
    if (!client.socket) return true;

    char[2] tid = tid_opt;

    // Encode the KRPC ping query
    String tid_str = (String)((char*)&tid)[:2];
    String message = krpc::encode_ping_query(tid_str, client.our_id);
    defer free(message);

    // Send via UDP
    String target_ip_str = ip_to_string(target_ip);
    defer free(target_ip_str);

    io::printfn("[DHT] Sending ping to %s:%d", target_ip_str, target_port);
    udp::send(client.socket, target_ip_str, (int)target_port,
              (char[])message, &on_udp_send, null);

    return true;
}

/**
 * Send a find_node query to a node
 *
 * @param client DHT client
 * @param target_id Target node ID to query
 * @param target_ip Target IP address
 * @param target_port Target port
 * @param search_id Node ID to search for
 * @return true if query was sent
 */
fn bool send_find_node(DhtClient* client, common::NodeId target_id,
                       common::Ipv4Addr target_ip, ushort target_port,
                       common::NodeId search_id) @public
{
    // Create callback context
    RpcCallbackContext* ctx = mem::new(RpcCallbackContext);
    ctx.client = client;
    ctx.query_type = krpc::QueryType.FIND_NODE;

    // Create transaction
    char[2]? tid_opt = dht_rpc_manager::create_transaction(
        client.rpc_manager,
        krpc::QueryType.FIND_NODE,
        target_id,
        target_ip,
        target_port,
        &rpc_response_callback,
        ctx
    );

    if (catch excuse = tid_opt)
    {
        free(ctx);
        return false;
    }

    // Skip network I/O if no socket (test mode)
    if (!client.socket) return true;

    char[2] tid = tid_opt;

    // Encode the KRPC find_node query
    String tid_str = (String)((char*)&tid)[:2];
    String message = krpc::encode_find_node_query(tid_str, client.our_id, search_id);
    defer free(message);

    // Send via UDP
    String target_ip_str = ip_to_string(target_ip);
    defer free(target_ip_str);

    io::printfn("[DHT] Sending find_node to %s:%d", target_ip_str, target_port);
    udp::send(client.socket, target_ip_str, (int)target_port,
              (char[])message, &on_udp_send, null);

    return true;
}

// ============================================================================
// Message Receiving
// ============================================================================

/**
 * UDP receive callback - handles incoming DHT messages
 */
fn void on_udp_recv(udp::UdpSocket* socket, char[] data, uv::Sockaddr* addr, void* user_data)
{
    DhtClient* client = (DhtClient*)user_data;

    if (data.len == 0) return;  // No data or error

    String message = (String)data;

    // Decode bencode
    bencode::BencodeValue*? root_opt = bencode::decode(message);
    if (catch err = root_opt)
    {
        io::eprintfn("[DHT] Failed to decode bencode message");
        return;
    }

    bencode::BencodeValue* root = root_opt;
    defer bencode::free_bencode_value(root);

    // Try to decode message type
    krpc::MessageType? type_opt = krpc::decode_message_type(root);
    if (catch err = type_opt)
    {
        io::eprintfn("[DHT] Failed to decode message type");
        return;
    }

    krpc::MessageType msg_type = type_opt;

    switch (msg_type)
    {
        case krpc::MessageType.RESPONSE:
            // Handle response (find matching transaction)
            io::printfn("[DHT] Received DHT response");
            // In full implementation: decode response and call transaction callback
        case krpc::MessageType.QUERY:
            // Handle incoming query
            io::printfn("[DHT] Received DHT query");
            // In full implementation: decode query and send response
        case krpc::MessageType.ERROR:
            // Handle error
            io::printfn("[DHT] Received DHT error");
    }
}

/**
 * Allocate buffer for UDP receive
 */
fn char[] on_udp_alloc(udp::UdpSocket* socket, usz suggested_size, void* user_data)
{
    return mem::new_array(char, suggested_size);
}

// ============================================================================
// Bootstrap Process
// ============================================================================

/**
 * Bootstrap the DHT client
 * Connects to bootstrap nodes and populates routing table
 *
 * @param client DHT client
 * @return true if bootstrap was initiated successfully
 */
fn bool bootstrap(DhtClient* client) @public
{
    if (client.bootstrap_node_count == 0)
    {
        return false;
    }

    client.state = DhtState.BOOTSTRAPPING;

    // Send find_node queries to all bootstrap nodes
    // Query for our own ID to get nodes close to us
    for (int i = 0; i < client.bootstrap_node_count; i++)
    {
        BootstrapNode* node = &client.bootstrap_nodes[i];

        // Create a dummy node ID for bootstrap node (we don't know it yet)
        common::NodeId dummy_id;
        for (int j = 0; j < 20; j++) dummy_id[j] = 0;

        // Send find_node query for our own ID
        send_find_node(client, dummy_id, node.ip, node.port, client.our_id);
    }

    client.state = DhtState.RUNNING;
    return true;
}

/**
 * Check if DHT client is bootstrapped
 * A client is considered bootstrapped if it has at least a few nodes in routing table
 *
 * @param client DHT client
 * @return true if bootstrapped
 */
fn bool is_bootstrapped(DhtClient* client) @public
{
    if (client.state != DhtState.RUNNING) return false;

    int total_nodes, active_buckets;
    dht_routing_table::get_stats(client.routing_table, &total_nodes, &active_buckets);

    // Consider bootstrapped if we have at least 10 nodes
    return total_nodes >= 10;
}

// ============================================================================
// Periodic Maintenance
// ============================================================================

/**
 * Perform periodic DHT maintenance
 * Should be called regularly (e.g., every second)
 *
 * @param client DHT client
 */
fn void tick(DhtClient* client) @public
{
    if (client.state != DhtState.RUNNING) return;

    // Process RPC timeouts
    dht_rpc_manager::process_timeouts(client.rpc_manager);

    // Check if bucket refresh is needed
    long now = (long)time::now().to_seconds();
    long elapsed = now - client.last_refresh_time;

    if (elapsed >= BUCKET_REFRESH_INTERVAL_SEC)
    {
        // Refresh routing table by querying random IDs in each bucket
        // (Full implementation would do this)
        client.last_refresh_time = now;
    }
}

// ============================================================================
// Statistics and Debugging
// ============================================================================

/**
 * Get DHT statistics
 *
 * @param client DHT client
 * @param total_nodes Output: total nodes in routing table
 * @param active_buckets Output: active buckets in routing table
 * @param active_transactions Output: active RPC transactions
 */
fn void get_stats(DhtClient* client, int* total_nodes, int* active_buckets,
                  int* active_transactions) @public
{
    dht_routing_table::get_stats(client.routing_table, total_nodes, active_buckets);

    int pending;
    dht_rpc_manager::get_stats(client.rpc_manager, active_transactions, &pending);
}

/**
 * Get DHT client state
 *
 * @param client DHT client
 * @return Current DHT state
 */
fn DhtState get_state(DhtClient* client) @public
{
    return client.state;
}
