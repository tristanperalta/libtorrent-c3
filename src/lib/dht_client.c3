module libtorrent::dht_client;

import std::io;
import std::time;
import std::collections::list;
import std::core::mem::allocator;
import libtorrent::common;
import libtorrent::dht_routing_table;
import libtorrent::dht_rpc_manager;
import libtorrent::dht_get_peers;
import libtorrent::krpc;
import libtorrent::bencode;
import libtorrent::event_bus;
import libtorrent::event_types;
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
    bencode::BencodeValue* current_response_root;  // Temporarily store response during callback
    allocator::DynamicArenaAllocator arena;        // Arena for RPC contexts and temp allocations
    event_bus::EventBus* event_bus;                // Event bus for publishing DHT events (can be null)
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
 * @param event_bus Event bus for publishing DHT events (can be null)
 * @return Initialized DHT client (allocated on heap), or null on failure
 */
fn DhtClient* create_dht_client(common::NodeId our_id, event_loop::EventLoop* loop, ushort port,
                                event_bus::EventBus* event_bus) @public
{
    DhtClient* client = mem::new(DhtClient);

    // Copy our ID
    for (int i = 0; i < 20; i++)
    {
        client.our_id[i] = our_id[i];
    }

    client.state = DhtState.UNINITIALIZED;
    client.last_refresh_time = 0;
    client.bootstrap_node_count = 0;
    client.loop = loop;
    client.current_response_root = null;
    client.event_bus = event_bus;

    // Initialize arena allocator for routing table, RPC manager, and RPC contexts
    // 4KB pages grow as needed (typical: ~200KB for routing table + RPC manager)
    client.arena.init(mem, 4096);

    // Create routing table and RPC manager (allocated from arena)
    client.routing_table = dht_routing_table::create_routing_table(our_id, &client.arena);
    client.rpc_manager = dht_rpc_manager::create_rpc_manager(&client.arena);

    // Create UDP socket (only if event loop is provided)
    if (loop != null)
    {
        udp::UdpSocket*? socket_opt = udp::create(loop);
        if (catch err = socket_opt)
        {
            io::eprintfn("[DHT] Failed to create UDP socket");
            client.free();
            return null;
        }

        client.socket = socket_opt;

        // Bind to DHT port
        DString addr_str;
        addr_str.appendf("0.0.0.0");
        client.socket.bind(addr_str.str_view(), (int)port);

        // Start receiving UDP datagrams
        client.socket.recv_start(&on_udp_alloc, &on_udp_recv, client);

        io::printfn("[DHT] UDP socket bound to port %d", port);

        // Publish DHT started event
        if (client.event_bus)
        {
            event_types::DhtEvent evt = event_types::create_dht_event(0, 0, "DHT started");
            client.event_bus.publish(event_types::EVENT_DHT_STARTED, &evt, event_types::DhtEvent.sizeof);
        }
    }
    else
    {
        client.socket = null;
    }

    return client;
}

// Note: RPC callback contexts are now allocated from arena, no manual free needed

/**
 * Free a DHT client
 */
fn void DhtClient.free(&self) @public
{
    // Close UDP socket
    if (self.socket)
    {
        self.socket.close();
    }

    // Cancel all pending transactions (userdata freed by arena)
    if (self.rpc_manager)
    {
        self.rpc_manager.cancel_all_transactions(null);
    }

    // NOTE: Do NOT call routing_table.free() or rpc_manager.free() here!
    // They are allocated from the arena and will be freed with arena.free().
    // Calling free() on arena-allocated memory would cause double-free.

    self.arena.free();

    // Free DhtClient struct itself (allocated from heap in create_dht_client())
    free(self);
}

// ============================================================================
// Bootstrap Node Management
// ============================================================================

/**
 * Add a bootstrap node
 *
 * @param ip Bootstrap node IP address
 * @param port Bootstrap node port
 * @return true if node was added
 */
fn bool DhtClient.add_bootstrap_node(&self, common::Ipv4Addr ip, ushort port) @public
{
    if (self.bootstrap_node_count >= MAX_BOOTSTRAP_NODES)
    {
        return false;
    }

    BootstrapNode* node = &self.bootstrap_nodes[self.bootstrap_node_count];
    for (int i = 0; i < 4; i++) node.ip[i] = ip[i];
    node.port = port;
    self.bootstrap_node_count++;

    return true;
}

/**
 * Add well-known bootstrap nodes
 * Uses public DHT bootstrap nodes from BitTorrent clients
 */
fn void DhtClient.add_default_bootstrap_nodes(&self) @public
{
    // router.bittorrent.com (87.98.162.88:6881)
    self.add_bootstrap_node({ 87, 98, 162, 88 }, 6881);

    // dht.transmissionbt.com (87.98.162.88:6881 - same IP as above)
    // router.utorrent.com (82.221.103.244:6881)
    self.add_bootstrap_node({ 82, 221, 103, 244 }, 6881);

    // dht.libtorrent.org (87.98.162.88:6881 - same IP)
    // router.silotis.us (130.239.18.159:6881)
    self.add_bootstrap_node({ 130, 239, 18, 159 }, 6881);
}

// ============================================================================
// RPC Query Sending
// ============================================================================

/**
 * Helper: Convert IP address to string (uses temp allocator)
 */
fn String ip_to_string(common::Ipv4Addr ip)
{
    DString buf;
    buf.appendf("%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
    return buf.copy_str(mem);  // Use persistent memory for async operations
}

/**
 * Callback context for RPC responses
 */
struct RpcCallbackContext
{
    DhtClient* client;
    krpc::QueryType query_type;
    String raw_message;  // Store raw message for full decode in callback
    void* search_context;  // Pointer to GetPeersSearch for get_peers queries (null for other queries)
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
 * Uses temp allocator for temporary strings
 *
 * @param response Response message (null on timeout)
 * @param userdata RpcCallbackContext pointer
 */
fn void rpc_response_callback(krpc::KrpcMessage* response, void* userdata) => @pool()
{
    RpcCallbackContext* ctx = (RpcCallbackContext*)userdata;
    DhtClient* client = ctx.client;

    if (!response)
    {
        // Timeout (ctx freed by arena, no manual free needed)
        io::printfn("[DHT] Query timed out");

        // Publish query timeout event
        if (client.event_bus)
        {
            int total_nodes, active_buckets;
            client.routing_table.get_stats(&total_nodes, &active_buckets);
            event_types::DhtEvent evt = event_types::create_dht_event(0, total_nodes, "DHT query timed out");
            client.event_bus.publish(event_types::EVENT_DHT_QUERY_COMPLETE, &evt, event_types::DhtEvent.sizeof);
        }
        return;
    }

    // Access the bencode root stored temporarily in the client
    if (!client.current_response_root)
    {
        return;
    }

    bencode::BencodeValue* root = client.current_response_root;

    // Extract the response dictionary ("r" key)
    bencode::BencodeValue* r_dict = root.dict_get("r");
    if (r_dict == null || r_dict.type != bencode::BencodeType.DICT)
    {
        io::eprintfn("[DHT] Invalid response format");
        return;
    }

    // Extract responding node's ID
    bencode::BencodeValue* id_val = r_dict.dict_get("id");
    if (id_val != null && id_val.type == bencode::BencodeType.STRING)
    {
        if (id_val.string.len >= 20)
        {
            common::NodeId node_id;
            for (int i = 0; i < 20; i++) node_id[i] = id_val.string[i];

            io::printfn("[DHT] Response from node %.8s...", (char*)&node_id[0]);
        }
    }

    // Handle based on query type
    switch (ctx.query_type)
    {
        case krpc::QueryType.PING:
            io::printfn("[DHT] Ping response received");

        case krpc::QueryType.FIND_NODE:
            // Parse nodes from response
            bencode::BencodeValue* nodes_val = r_dict.dict_get("nodes");
            if (nodes_val != null && nodes_val.type == bencode::BencodeType.STRING)
            {
                char[] nodes_data = nodes_val.string;
                int node_count = (int)(nodes_data.len / 26);  // Each node is 26 bytes

                io::printfn("[DHT] Received %d nodes from find_node", node_count);

                // Parse and add each node to routing table
                for (int i = 0; i < node_count; i++)
                {
                    usz offset = (usz)i * 26;
                    if (offset + 26 > nodes_data.len) break;

                    // Extract node ID (20 bytes)
                    common::NodeId node_id;
                    for (int j = 0; j < 20; j++)
                    {
                        node_id[j] = nodes_data[offset + j];
                    }

                    // Extract IP (4 bytes)
                    common::Ipv4Addr ip;
                    ip[0] = nodes_data[offset + 20];
                    ip[1] = nodes_data[offset + 21];
                    ip[2] = nodes_data[offset + 22];
                    ip[3] = nodes_data[offset + 23];

                    // Extract port (2 bytes, big-endian)
                    ushort port = ((ushort)nodes_data[offset + 24] << 8) |
                                   (ushort)nodes_data[offset + 25];

                    // Add node to routing table (with estimated RTT of 100ms)
                    bool added = client.routing_table.add_node(node_id, ip, port, 100);

                    if (added && i < 3)
                    {
                        String ip_str = ip_to_string(ip);
                        defer free(ip_str);
                        io::printfn("[DHT]   Added node %s:%d", ip_str, port);
                    }
                }
            }

        case krpc::QueryType.GET_PEERS:
            // Get search context from callback
            dht_get_peers::GetPeersSearch* search = (dht_get_peers::GetPeersSearch*)ctx.search_context;

            // Get_peers can return either peers (values) or nodes
            bencode::BencodeValue* values_val = r_dict.dict_get("values");
            bencode::BencodeValue* nodes_val = r_dict.dict_get("nodes");

            if (values_val != null && values_val.type == bencode::BencodeType.LIST)
            {
                // Response contains peers - add them to search
                int peer_count = (int)values_val.list.len();
                io::printfn("[DHT] Received %d peers from get_peers", peer_count);

                int added = 0;
                for (int i = 0; i < peer_count; i++)
                {
                    bencode::BencodeValue* peer_val = values_val.list.get(i);
                    if (peer_val && peer_val.type == bencode::BencodeType.STRING &&
                        peer_val.string.len >= 6)
                    {
                        // Parse compact peer format using helper
                        char[] compact_data = peer_val.string[0:6];
                        if (catch err = common::socket_address_from_compact_ipv4(compact_data))
                        {
                            // Invalid peer data, skip
                            continue;
                        }

                        common::SocketAddress addr = common::socket_address_from_compact_ipv4(compact_data)!!;

                        // Add peer to search if we have search context
                        if (search && search.add_peer(addr))
                        {
                            added++;
                            if (added <= 3)  // Log first 3
                            {
                                io::printfn("[DHT]   Peer: %s", addr);
                            }
                        }
                    }
                }

                if (search && added > 0)
                {
                    search.found_peers = true;

                    // Publish DHT peers found event
                    if (ctx.client.event_bus)
                    {
                        int total_nodes, active_buckets;
                        ctx.client.routing_table.get_stats(&total_nodes, &active_buckets);
                        event_types::DhtEvent evt = event_types::create_dht_event(added, total_nodes, "DHT peers found");
                        ctx.client.event_bus.publish(event_types::EVENT_DHT_PEERS_FOUND, &evt, event_types::DhtEvent.sizeof);
                    }
                }
            }
            else if (nodes_val != null && nodes_val.type == bencode::BencodeType.STRING)
            {
                // Response contains nodes (no peers found yet)
                char[] nodes_data = nodes_val.string;
                int node_count = (int)(nodes_data.len / 26);
                io::printfn("[DHT] Received %d nodes from get_peers (no peers yet)", node_count);

                // Add these nodes to routing table for future queries
                for (int i = 0; i < node_count; i++)
                {
                    usz offset = (usz)i * 26;
                    if (offset + 26 > nodes_data.len) break;

                    common::NodeId node_id;
                    for (int j = 0; j < 20; j++) node_id[j] = nodes_data[offset + j];

                    common::Ipv4Addr ip;
                    ip[0] = nodes_data[offset + 20];
                    ip[1] = nodes_data[offset + 21];
                    ip[2] = nodes_data[offset + 22];
                    ip[3] = nodes_data[offset + 23];

                    ushort port = ((ushort)nodes_data[offset + 24] << 8) |
                                   (ushort)nodes_data[offset + 25];

                    client.routing_table.add_node(node_id, ip, port, 100);
                }
            }

            // Extract token for future announce_peer
            bencode::BencodeValue* token_val = r_dict.dict_get("token");
            if (token_val != null && token_val.type == bencode::BencodeType.STRING)
            {
                io::printfn("[DHT] Received announce token (%d bytes)", token_val.string.len);
            }

        case krpc::QueryType.ANNOUNCE_PEER:
            io::printfn("[DHT] Announce_peer response");
    }

    // Publish successful query complete event
    if (client.event_bus)
    {
        int total_nodes, active_buckets;
        client.routing_table.get_stats(&total_nodes, &active_buckets);
        event_types::DhtEvent evt = event_types::create_dht_event(0, total_nodes, "DHT query completed");
        client.event_bus.publish(event_types::EVENT_DHT_QUERY_COMPLETE, &evt, event_types::DhtEvent.sizeof);
    }

    // Note: ctx freed by arena, no manual free needed
}

/**
 * Send a ping query to a node
 *
 * @param target_id Target node ID
 * @param target_ip Target IP address
 * @param target_port Target port
 * @return true if query was sent
 */
fn bool DhtClient.send_ping(&self, common::NodeId target_id,
                            common::Ipv4Addr target_ip, ushort target_port) @public => @pool()
{
    // Create callback context from arena
    RpcCallbackContext* ctx = allocator::new(&self.arena, RpcCallbackContext);
    if (!ctx)
    {
        io::eprintfn("[DHT] Failed to allocate RPC context");
        return false;
    }

    ctx.client = self;
    ctx.query_type = krpc::QueryType.PING;
    ctx.search_context = null;

    // Create transaction
    char[2]? tid_opt = self.rpc_manager.create_transaction(
        krpc::QueryType.PING,
        target_id,
        target_ip,
        target_port,
        &rpc_response_callback,
        ctx
    );

    if (catch excuse = tid_opt)
    {
        // Arena will clean this up, no manual free needed
        return false;
    }

    // Skip network I/O if no socket (test mode)
    if (!self.socket) return true;

    char[2] tid = tid_opt;

    // Encode the KRPC ping query
    String tid_str = (String)((char*)&tid)[:2];
    String message = krpc::encode_ping_query(tid_str, self.our_id);
    defer free(message);

    // Send via UDP
    String target_ip_str = ip_to_string(target_ip);
    defer free(target_ip_str);

    io::printfn("[DHT] Sending ping to %s:%d", target_ip_str, target_port);
    self.socket.send(target_ip_str, (int)target_port,
              (char[])message, &on_udp_send, null);

    return true;
}

/**
 * Send a find_node query to a node
 *
 * @param target_id Target node ID to query
 * @param target_ip Target IP address
 * @param target_port Target port
 * @param search_id Node ID to search for
 * @return true if query was sent
 */
fn bool DhtClient.send_find_node(&self, common::NodeId target_id,
                                 common::Ipv4Addr target_ip, ushort target_port,
                                 common::NodeId search_id) @public => @pool()
{
    // Create callback context from arena
    RpcCallbackContext* ctx = allocator::new(&self.arena, RpcCallbackContext);
    if (!ctx)
    {
        io::eprintfn("[DHT] Failed to allocate RPC context");
        return false;
    }

    ctx.client = self;
    ctx.query_type = krpc::QueryType.FIND_NODE;
    ctx.search_context = null;

    // Create transaction
    char[2]? tid_opt = self.rpc_manager.create_transaction(
        krpc::QueryType.FIND_NODE,
        target_id,
        target_ip,
        target_port,
        &rpc_response_callback,
        ctx
    );

    if (catch excuse = tid_opt)
    {
        // Arena will clean this up, no manual free needed
        return false;
    }

    // Skip network I/O if no socket (test mode)
    if (!self.socket) return true;

    char[2] tid = tid_opt;

    // Encode the KRPC find_node query
    String tid_str = (String)((char*)&tid)[:2];
    String message = krpc::encode_find_node_query(tid_str, self.our_id, search_id);
    defer free(message);

    // Send via UDP
    String target_ip_str = ip_to_string(target_ip);
    defer free(target_ip_str);

    io::printfn("[DHT] Sending find_node to %s:%d", target_ip_str, target_port);
    self.socket.send(target_ip_str, (int)target_port,
              (char[])message, &on_udp_send, null);

    return true;
}

/**
 * Send a get_peers query to a node
 *
 * @param target_id Target node ID to query
 * @param target_ip Target IP address
 * @param target_port Target port
 * @param info_hash Torrent info hash to search for
 * @param search_context Pointer to GetPeersSearch (for tracking responses)
 * @return true if query was sent
 */
fn bool DhtClient.send_get_peers(&self, common::NodeId target_id,
                                 common::Ipv4Addr target_ip, ushort target_port,
                                 common::InfoHash info_hash, void* search_context) @public => @pool()
{
    // Create callback context from arena
    RpcCallbackContext* ctx = allocator::new(&self.arena, RpcCallbackContext);
    if (!ctx)
    {
        io::eprintfn("[DHT] Failed to allocate RPC context");
        return false;
    }

    ctx.client = self;
    ctx.query_type = krpc::QueryType.GET_PEERS;
    ctx.search_context = search_context;

    // Create transaction
    char[2]? tid_opt = self.rpc_manager.create_transaction(
        krpc::QueryType.GET_PEERS,
        target_id,
        target_ip,
        target_port,
        &rpc_response_callback,
        ctx
    );

    if (catch excuse = tid_opt)
    {
        // Arena will clean this up, no manual free needed
        return false;
    }

    // Skip network I/O if no socket (test mode)
    if (!self.socket) return true;

    char[2] tid = tid_opt;

    // Encode the KRPC get_peers query
    String tid_str = (String)((char*)&tid)[:2];
    String message = krpc::encode_get_peers_query(tid_str, self.our_id, info_hash);
    defer free(message);

    // Send via UDP
    String target_ip_str = ip_to_string(target_ip);
    defer free(target_ip_str);

    io::printfn("[DHT] Sending get_peers to %s:%d", target_ip_str, target_port);
    self.socket.send(target_ip_str, (int)target_port,
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
    defer root.free();

    // Extract transaction ID
    bencode::BencodeValue* t_val = root.dict_get("t");
    if (t_val == null || t_val.type != bencode::BencodeType.STRING)
    {
        io::eprintfn("[DHT] Message missing transaction ID");
        return;
    }
    String transaction_id = (String)t_val.string;

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
            // Handle response - find matching transaction
            io::printfn("[DHT] Received response");

            // Store bencode root temporarily so callback can access it
            client.current_response_root = root;

            // Create a minimal KrpcMessage to pass to RPC manager
            krpc::KrpcMessage resp_msg;
            resp_msg.type = krpc::MessageType.RESPONSE;
            resp_msg.transaction_id = transaction_id;
            resp_msg.version = "";

            // Handle the response (this will call the transaction callback)
            client.rpc_manager.handle_response(&resp_msg);

            // Clear temporary storage
            client.current_response_root = null;

        case krpc::MessageType.QUERY:
            // Handle incoming query
            io::printfn("[DHT] Received query (not yet implemented)");
            // TODO: decode query and send response

        case krpc::MessageType.ERROR:
            // Handle error
            io::printfn("[DHT] Received error response");
            // TODO: handle error and cancel transaction
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
 * @return true if bootstrap was initiated successfully
 */
fn bool DhtClient.bootstrap(&self) @public
{
    if (self.bootstrap_node_count == 0)
    {
        return false;
    }

    self.state = DhtState.BOOTSTRAPPING;

    // Send find_node queries to all bootstrap nodes
    // Query for our own ID to get nodes close to us
    for (int i = 0; i < self.bootstrap_node_count; i++)
    {
        BootstrapNode* node = &self.bootstrap_nodes[i];

        // Create a dummy node ID for bootstrap node (we don't know it yet)
        common::NodeId dummy_id;
        for (int j = 0; j < 20; j++) dummy_id[j] = 0;

        // Send find_node query for our own ID
        self.send_find_node(dummy_id, node.ip, node.port, self.our_id);
    }

    self.state = DhtState.RUNNING;
    return true;
}

/**
 * Check if DHT client is bootstrapped
 * A client is considered bootstrapped if it has at least a few nodes in routing table
 *
 * @return true if bootstrapped
 */
fn bool DhtClient.is_bootstrapped(&self) @public
{
    if (self.state != DhtState.RUNNING) return false;

    int total_nodes, active_buckets;
    self.routing_table.get_stats(&total_nodes, &active_buckets);

    // Consider bootstrapped if we have at least 10 nodes
    bool bootstrapped = total_nodes >= 10;

    // Publish bootstrapped event (first time only, when crossing threshold)
    // Note: In production, you'd want to track if this event was already published
    // to avoid publishing it repeatedly. For now, we publish it each time.
    if (bootstrapped && self.event_bus)
    {
        event_types::DhtEvent evt = event_types::create_dht_event(0, total_nodes, "DHT bootstrapped");
        self.event_bus.publish(event_types::EVENT_DHT_BOOTSTRAPPED, &evt, event_types::DhtEvent.sizeof);
    }

    return bootstrapped;
}

// ============================================================================
// Periodic Maintenance
// ============================================================================

/**
 * Perform periodic DHT maintenance
 * Should be called regularly (e.g., every second)
 */
fn void DhtClient.tick(&self) @public
{
    if (self.state != DhtState.RUNNING) return;

    // Process RPC timeouts
    self.rpc_manager.process_timeouts();

    // Check if bucket refresh is needed
    long now = (long)time::now().to_seconds();
    long elapsed = now - self.last_refresh_time;

    if (elapsed >= BUCKET_REFRESH_INTERVAL_SEC)
    {
        // Refresh routing table by querying random IDs in each bucket
        // (Full implementation would do this)
        self.last_refresh_time = now;
    }
}

// ============================================================================
// Statistics and Debugging
// ============================================================================

/**
 * Get DHT statistics
 *
 * @param total_nodes Output: total nodes in routing table
 * @param active_buckets Output: active buckets in routing table
 * @param active_transactions Output: active RPC transactions
 */
fn void DhtClient.get_stats(&self, int* total_nodes, int* active_buckets,
                            int* active_transactions) @public
{
    self.routing_table.get_stats(total_nodes, active_buckets);

    int pending;
    self.rpc_manager.get_stats(active_transactions, &pending);
}

/**
 * Get DHT client state
 *
 * @return Current DHT state
 */
fn DhtState DhtClient.get_state(&self) @public
{
    return self.state;
}
