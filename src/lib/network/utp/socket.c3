module libtorrent::utp::socket;

import libtorrent::utp::common;
import libtorrent::utp::packet;
import libtorrent::utp::connection;
import libtorrent::utp::timeout;
import libtorrent::common;
import async::udp;
import async::event_loop;
import uv;
import std::io;
import std::time;
import std::collections::map;

// Module alias to distinguish between libtorrent::common and libtorrent::utp::common
alias lib_common = module libtorrent::common;

<*
 μTP Socket Manager
 ==================

 Manages UDP socket and dispatches packets to μTP connections.
 Phase 1: Basic socket wrapper with connection dispatch.

 Architecture:
 - Single UDP socket binds to a port
 - Multiple μTP connections multiplex over this socket
 - Incoming packets are dispatched by connection ID
 - Outgoing packets are sent through the socket
*>

// ============================================================================
// Faults
// ============================================================================

faultdef UTP_SOCKET_CREATE_FAILED;
faultdef UTP_SOCKET_BIND_FAILED;

// ============================================================================
// Callback Types
// ============================================================================

/**
 * Callback invoked when a new incoming connection is received.
 * The application should create a UtpConnection and register it.
 */
alias NewConnectionCallback = fn void(UtpSocket* socket, lib_common::SocketAddress remote_addr, packet::UtpHeader* syn_header, void* user_data);

/**
 * Callback invoked when a packet is received for an existing connection.
 */
alias PacketReceivedCallback = fn void(UtpSocket* socket, connection::UtpConnection* conn, packet::UtpHeader* header, char[] payload, void* user_data);

// ============================================================================
// Socket Structure
// ============================================================================

/**
 * μTP socket - manages UDP socket and connection dispatch.
 *
 * Phase 1: Basic functionality:
 * - Bind to port and listen
 * - Dispatch packets to connections by connection ID
 * - Send packets through UDP socket
 */
struct UtpSocket
{
    udp::UdpSocket* udp_socket;
    event_loop::EventLoop* loop;

    // Connection tracking (connection_id -> UtpConnection*)
    map::HashMap{ushort, connection::UtpConnection*} connections;

    // Callbacks
    NewConnectionCallback new_conn_cb;
    PacketReceivedCallback packet_recv_cb;
    void* user_data;

    // State
    bool is_closed;

    // Week 4: Timeout management
    timeout::TimeoutManager* timeout_mgr;
}

// ============================================================================
// Creation and Lifecycle
// ============================================================================

/**
 * Create a μTP socket.
 *
 * @param loop : Event loop
 * @return New μTP socket (caller must close and free)
 */
fn UtpSocket*? create(event_loop::EventLoop* loop) @public
{
    // Create UDP socket
    udp::UdpSocket*? udp_result = udp::create(loop);
    if (catch err = udp_result)
    {
        return UTP_SOCKET_CREATE_FAILED?;
    }

    UtpSocket* socket = mem::new(UtpSocket);
    socket.udp_socket = udp_result;
    socket.loop = loop;
    socket.connections.init(mem);
    socket.new_conn_cb = null;
    socket.packet_recv_cb = null;
    socket.user_data = null;
    socket.is_closed = false;

    // Week 4: Create timeout manager
    timeout::TimeoutManager*? mgr_result = timeout::create(loop);
    if (catch err = mgr_result)
    {
        io::eprintn("Warning: Failed to create timeout manager");
        socket.timeout_mgr = null;
    }
    else
    {
        socket.timeout_mgr = mgr_result;
    }

    return socket;
}

/**
 * Bind μTP socket to a local port and start listening.
 *
 * @param ip : IP address to bind to (e.g., "0.0.0.0" for any)
 * @param port : Port number
 */
fn void UtpSocket.bind(&self, String ip, ushort port) @public
{
    self.udp_socket.bind(ip, (int)port);

    // Start receiving packets
    self.udp_socket.recv_start(null, &on_packet_received, (void*)self);

    // Week 4: Start timeout checking
    if (self.timeout_mgr)
    {
        self.timeout_mgr.start(self);
    }
}

/**
 * Register a μTP connection with the socket.
 *
 * After creating a connection (outgoing or incoming), register it
 * so the socket can dispatch packets to it.
 *
 * @param conn : Connection to register
 */
fn void UtpSocket.register_connection(&self, connection::UtpConnection* conn) @public
{
    self.connections.set(conn.recv_id, conn);
}

/**
 * Unregister a μTP connection from the socket.
 *
 * Call this when a connection is closed.
 *
 * @param conn : Connection to unregister
 */
fn void UtpSocket.unregister_connection(&self, connection::UtpConnection* conn) @public
{
    self.connections.remove(conn.recv_id);
}

/**
 * Set callbacks for new connections and packet reception.
 *
 * @param new_conn_cb : Callback for new incoming connections (can be null)
 * @param packet_recv_cb : Callback for packets on existing connections (can be null)
 * @param user_data : User data passed to callbacks
 */
fn void UtpSocket.set_callbacks(&self, NewConnectionCallback new_conn_cb,
                                PacketReceivedCallback packet_recv_cb,
                                void* user_data) @public
{
    self.new_conn_cb = new_conn_cb;
    self.packet_recv_cb = packet_recv_cb;
    self.user_data = user_data;
}

// ============================================================================
// Sending Packets
// ============================================================================

/**
 * Send a μTP packet to a remote address.
 *
 * @param remote_addr : Destination address
 * @param header : Packet header to send
 * @param payload : Optional payload data
 */
fn void UtpSocket.send_packet(&self, lib_common::SocketAddress remote_addr,
                              packet::UtpHeader* header, char[] payload = {}) @public
{
    // Encode packet
    char[] packet_data = packet::encode_packet(header, payload);
    defer free(packet_data);  // Free after send completes

    // Format just the IP address (not IP:port)
    DString ip_builder;
    ip_builder.appendf("%s", remote_addr.addr);
    String ip_str = ip_builder.copy_str(mem);
    defer free(ip_str);

    // Send via UDP (callback is optional for fire-and-forget)
    self.udp_socket.send(ip_str, (int)remote_addr.port, packet_data, null, null);
}

/**
 * Send a SYN packet to initiate a connection (Week 2).
 *
 * @param conn : Connection to send SYN for
 */
fn void UtpSocket.send_syn(&self, connection::UtpConnection* conn) @public
{
    // Build SYN packet header
    packet::UtpHeader header;
    header.packet_type = common::ST_SYN;
    header.version = 1;
    header.extension = 0;
    header.connection_id = conn.send_id;
    header.timestamp_microseconds = (uint)((long)time::now().to_seconds() * 1_000_000);
    header.timestamp_difference_microseconds = 0;  // No delay measurement yet
    header.wnd_size = conn.local_window;
    header.seq_nr = conn.seq_nr;
    header.ack_nr = 0;  // No ACK in SYN

    // Send packet
    self.send_packet(conn.remote_addr, &header, {});

    // Update connection state
    conn.last_send_time = (long)time::now().to_seconds() * 1_000_000;
}

/**
 * Send a SYN-ACK packet in response to a SYN (Week 2).
 *
 * @param conn : Connection to send SYN-ACK for
 */
fn void UtpSocket.send_syn_ack(&self, connection::UtpConnection* conn) @public
{
    // Build SYN-ACK packet header (ST_STATE with ack_nr set)
    packet::UtpHeader header;
    header.packet_type = common::ST_STATE;
    header.version = 1;
    header.extension = 0;
    header.connection_id = conn.send_id;
    header.timestamp_microseconds = (uint)((long)time::now().to_seconds() * 1_000_000);
    header.timestamp_difference_microseconds = conn.their_delay;
    header.wnd_size = conn.local_window;
    header.seq_nr = conn.seq_nr;
    header.ack_nr = conn.ack_nr;  // ACK their SYN

    // Send packet
    self.send_packet(conn.remote_addr, &header, {});

    // Update connection state
    conn.last_send_time = (long)time::now().to_seconds() * 1_000_000;
}

/**
 * Send a FIN packet to gracefully close a connection (Week 3).
 *
 * @param conn : Connection to send FIN for
 */
fn void UtpSocket.send_fin(&self, connection::UtpConnection* conn) @public
{
    // Build FIN packet header
    packet::UtpHeader header;
    header.packet_type = common::ST_FIN;
    header.version = 1;
    header.extension = 0;
    header.connection_id = conn.send_id;
    header.timestamp_microseconds = (uint)((long)time::now().to_seconds() * 1_000_000);
    header.timestamp_difference_microseconds = conn.their_delay;
    header.wnd_size = conn.local_window;
    header.seq_nr = conn.seq_nr;
    header.ack_nr = conn.ack_nr;

    // Send packet (no payload)
    self.send_packet(conn.remote_addr, &header, {});

    // Update connection state
    conn.last_send_time = (long)time::now().to_seconds() * 1_000_000;
}

/**
 * Send a RESET packet to forcefully close a connection (Week 3).
 *
 * Used for unknown connection IDs, protocol errors, or forceful close.
 *
 * @param remote_addr : Destination address
 * @param conn_id : Connection ID to reset
 * @param seq_nr : Sequence number (usually 0 for unknown connections)
 * @param ack_nr : Acknowledgment number (from received packet)
 */
fn void UtpSocket.send_reset(&self, lib_common::SocketAddress remote_addr,
                             ushort conn_id, ushort seq_nr, ushort ack_nr) @public
{
    // Build RESET packet header
    packet::UtpHeader header;
    header.packet_type = common::ST_RESET;
    header.version = 1;
    header.extension = 0;
    header.connection_id = conn_id;
    header.timestamp_microseconds = (uint)((long)time::now().to_seconds() * 1_000_000);
    header.timestamp_difference_microseconds = 0;
    header.wnd_size = 0;  // Not applicable for RESET
    header.seq_nr = seq_nr;
    header.ack_nr = ack_nr;

    // Send packet (no payload)
    self.send_packet(remote_addr, &header, {});
}

// ============================================================================
// Packet Reception (Internal)
// ============================================================================

/**
 * Internal callback for UDP packet reception.
 * Dispatches packets to connections based on connection ID.
 */
fn void on_packet_received(udp::UdpSocket* udp_socket, char[] data,
                           uv::Sockaddr* addr, void* user_data)
{
    UtpSocket* socket = (UtpSocket*)user_data;

    // Ignore empty packets
    if (data.len == 0) return;

    // Decode packet header
    packet::UtpHeader? header_result = packet::decode_packet(data);
    if (catch err = header_result)
    {
        // Invalid packet, ignore
        return;
    }
    packet::UtpHeader header = header_result;

    // Extract payload
    char[] payload = packet::get_payload(data);

    // Convert uv::Sockaddr to SocketAddress
    lib_common::SocketAddress remote_addr = sockaddr_to_socket_address(addr);

    // Get connection ID from header
    ushort conn_id = header.connection_id;

    // Check if this is for an existing connection
    connection::UtpConnection**? conn_ptr_result = socket.connections.get_ref(conn_id);

    if (catch err = conn_ptr_result)
    {
        // Connection not found
        // Check if this is a new SYN
        if (header.packet_type == common::ST_SYN)
        {
            // New incoming connection
            if (socket.new_conn_cb)
            {
                socket.new_conn_cb(socket, remote_addr, &header, socket.user_data);
            }
        }
        else
        {
            // Week 3: Packet for unknown connection - send RESET
            // Don't send RESET for RESET packets (avoid loops)
            if (header.packet_type != common::ST_RESET)
            {
                socket.send_reset(remote_addr, conn_id, 0, header.seq_nr);
            }
        }
    }
    else
    {
        // Existing connection - dispatch packet
        connection::UtpConnection** conn_ptr = conn_ptr_result;
        connection::UtpConnection* conn = *conn_ptr;

        // Let connection process the packet
        conn.process_packet(&header);

        // Notify application
        if (socket.packet_recv_cb)
        {
            socket.packet_recv_cb(socket, conn, &header, payload, socket.user_data);
        }
    }
}

/**
 * Convert uv::Sockaddr to SocketAddress.
 *
 * Phase 1: Simple IPv4-only conversion.
 * TODO: Add IPv6 support in later phases.
 */
fn lib_common::SocketAddress sockaddr_to_socket_address(uv::Sockaddr* addr) @private
{
    lib_common::SocketAddress result;

    // Phase 1: Assume IPv4 only
    uv::Sockaddr_in* addr4 = (uv::Sockaddr_in*)addr;
    result.addr.is_ipv6 = false;

    // Extract IP bytes (sin_addr is a struct containing uint s_addr in network byte order)
    uint ip_be = addr4.sin_addr;  // This is the uint directly
    result.addr.ipv4.a = (char)(ip_be & 0xFF);
    result.addr.ipv4.b = (char)((ip_be >> 8) & 0xFF);
    result.addr.ipv4.c = (char)((ip_be >> 16) & 0xFF);
    result.addr.ipv4.d = (char)((ip_be >> 24) & 0xFF);

    // Extract port (big-endian -> little-endian)
    ushort port_be = addr4.sin_port;
    result.port = ((port_be & 0xFF) << 8) | ((port_be >> 8) & 0xFF);

    return result;
}

// ============================================================================
// Cleanup
// ============================================================================

/**
 * Close the μTP socket and free all resources.
 *
 * This closes the UDP socket and frees all connections.
 * Note: This is async - connections and socket will be freed when close completes.
 */
fn void UtpSocket.close(&self) @public
{
    if (self.is_closed) return;

    self.is_closed = true;

    // Week 4: Stop timeout manager (async close)
    if (self.timeout_mgr)
    {
        self.timeout_mgr.stop();
    }

    // Close UDP socket (async)
    self.udp_socket.close();

    // Free connections (Phase 1: simple cleanup)
    // TODO: In later phases, gracefully close connections first
    self.connections.@each(; ushort conn_id, connection::UtpConnection* conn)
    {
        conn.free();
    };

    self.connections.free();
}

/**
 * Free the μTP socket struct.
 * Note: Call close() first, then run event loop to drain callbacks,
 * then call this to free the struct.
 */
fn void UtpSocket.free(&self) @public
{
    // Week 4: Free timeout manager
    if (self.timeout_mgr)
    {
        self.timeout_mgr.free();
    }

    free(self);
}
