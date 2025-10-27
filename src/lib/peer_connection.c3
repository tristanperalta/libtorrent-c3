module libtorrent::peer_connection;

import async::tcp;
import async::event_loop;
import libtorrent::peer_wire;
import libtorrent::bitfield;
import libtorrent::pex;
import libtorrent::common;
import std::io;
import std::time;
import libtorrent::logger;

<*
 Peer Connection State Machine
 ==============================
 Manages a single peer connection using the peer wire protocol.

 Usage:
   PeerConnection* peer = connect(loop, "127.0.0.1", 6881, info_hash, peer_id, &on_message);
   defer close(peer);

   // In callbacks:
   peer.send_interested();
   peer.send_request(piece_index, begin, length);
*>

// Faults
faultdef PEER_HANDSHAKE_FAILED;
faultdef PEER_MESSAGE_SEND_FAILED;
faultdef PEER_INVALID_STATE;

<*
 Connection state for a peer.
*>
enum PeerState : const char
{
    CONNECTING = 0,   // TCP connection in progress
    HANDSHAKING = 1,  // Waiting for handshake response
    READY = 2,        // Can exchange messages
    CLOSED = 3        // Connection terminated
}

// Callback for when a message is received from peer.
// Parameters: peer (connection), msg (received message), user_data (context)
alias MessageCallback = fn void(PeerConnection* peer, peer_wire::Message* msg, void* user_data);

// Callback for when connection state changes.
// Parameters: peer (connection), state (new state), user_data (context)
alias StateCallback = fn void(PeerConnection* peer, PeerState state, void* user_data);

// Callback for when PEX message is received.
// Parameters: peer (connection), pex_message (decoded PEX message), user_data (context)
alias PexCallback = fn void(PeerConnection* peer, pex::PexMessage* pex_msg, void* user_data);

// Peer connection structure.
// Manages the connection to a single peer.
struct PeerConnection
{
    async::tcp::TcpConnection* tcp;
    event_loop::EventLoop* loop;
    PeerState state;

    // Torrent info
    common::InfoHash info_hash;
    common::PeerId our_peer_id;
    common::PeerId remote_peer_id;

    // Peer state flags (BEP 3)
    bool am_choking;         // We are choking the peer
    bool am_interested;      // We are interested in the peer
    bool peer_choking;       // Peer is choking us
    bool peer_interested;    // Peer is interested in us

    // Extension protocol support (BEP 10)
    bool supports_extensions;     // Peer supports extension protocol
    bool sent_ext_handshake;      // We've sent extension handshake
    bool received_ext_handshake;  // We've received extension handshake

    // PEX (Peer Exchange) support (BEP 11)
    bool supports_pex;       // Peer supports ut_pex
    char peer_pex_msg_id;    // Peer's message ID for ut_pex (0 = disabled)
    char our_pex_msg_id;     // Our message ID for ut_pex (fixed at 1)

    // PEX state tracking
    pex::PexPeer[] added_peers;     // Peers to send in next PEX message
    pex::PexPeer[] dropped_peers;   // Dropped peers to send in next PEX message
    long last_pex_sent_sec;         // Timestamp of last PEX message sent in seconds (rate limiting)
    bool pex_initialized;           // Whether last_pex_sent_sec has been initialized

    // Message buffering
    DString recv_buffer;     // Accumulates TCP chunks

    // Callbacks
    MessageCallback msg_cb;
    StateCallback state_cb;
    PexCallback pex_cb;
    void* user_data;
}

<*
 Connect to a peer and initiate handshake.

 @param loop : "Event loop"
 @param host : "Peer IP address"
 @param port : "Peer port"
 @param info_hash : "Torrent info hash"
 @param our_peer_id : "Our peer ID"
 @param msg_cb : "Callback for received messages"
 @param state_cb : "Callback for state changes (can be null)"
 @param pex_cb : "Callback for PEX messages (can be null)"
 @param user_data : "User context for callbacks"
 @return "Peer connection or fault"
*>
fn PeerConnection*? connect(event_loop::EventLoop* loop, String host, ushort port,
                              common::InfoHash info_hash, common::PeerId our_peer_id,
                              MessageCallback msg_cb, StateCallback state_cb,
                              PexCallback pex_cb, void* user_data) @public
{
    PeerConnection* peer = mem::new(PeerConnection);
    peer.loop = loop;
    peer.state = PeerState.CONNECTING;

    // Copy info hash and peer IDs
    for (usz i = 0; i < 20; i++)
    {
        peer.info_hash[i] = info_hash[i];
        peer.our_peer_id[i] = our_peer_id[i];
    }

    // Initialize state (BEP 3: start choking and not interested)
    peer.am_choking = true;
    peer.am_interested = false;
    peer.peer_choking = true;
    peer.peer_interested = false;

    // Initialize extension protocol state (BEP 10)
    peer.supports_extensions = false;
    peer.sent_ext_handshake = false;
    peer.received_ext_handshake = false;

    // Initialize PEX state (BEP 11)
    peer.supports_pex = false;
    peer.peer_pex_msg_id = 0;
    peer.our_pex_msg_id = 1;  // Fixed message ID for ut_pex
    peer.added_peers = {};
    peer.dropped_peers = {};
    peer.pex_initialized = false;

    // Initialize callbacks
    peer.msg_cb = msg_cb;
    peer.state_cb = state_cb;
    peer.pex_cb = pex_cb;
    peer.user_data = user_data;

    // Connect to peer
    async::tcp::TcpConnection*? tcp_opt = async::tcp::connect(loop, host, port, &on_tcp_connect, peer);
    if (catch excuse = tcp_opt)
    {
        free(peer);
        return excuse?;
    }

    peer.tcp = tcp_opt;
    return peer;
}

<*
 Close a peer connection and free resources.

 @param peer : "Peer to close"
*>
fn void close(PeerConnection* peer) @public
{
    if (!peer) return;

    if (peer.state != PeerState.CLOSED)
    {
        peer.state = PeerState.CLOSED;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.user_data);
    }

    if (peer.tcp)
    {
        peer.tcp.close();
        peer.tcp = null;
    }

    if (peer.recv_buffer.len() > 0)
    {
        peer.recv_buffer.free();
    }

    // Free PEX arrays
    if (peer.added_peers.len > 0) free(peer.added_peers);
    if (peer.dropped_peers.len > 0) free(peer.dropped_peers);

    free(peer);
}

<*
 Gracefully close a peer connection by sending protocol messages before disconnect.

 Sends NOT_INTERESTED and final PEX messages before closing the TCP connection,
 allowing the peer to properly handle our disconnection.

 @param peer : "Peer to gracefully close"
*>
fn void graceful_close(PeerConnection* peer) @public
{
    if (!peer) return;
    if (peer.state == PeerState.CLOSED) return;

    // Log graceful disconnect
    logger::log(logger::LogLevel.INFO, "[Shutdown] Gracefully disconnecting from peer");

    // Step 1: Send NOT_INTERESTED if we were interested
    // This tells the peer we're intentionally leaving, not crashing
    if (peer.am_interested)
    {
        (void)peer.send_not_interested();  // Ignore errors - we're closing anyway
    }

    // Step 2: Send final PEX message if we have queued peer updates
    // This shares our peer list one last time before leaving the swarm
    if (peer.supports_pex && (peer.added_peers.len > 0 || peer.dropped_peers.len > 0))
    {
        (void)send_pex_message(peer);  // Ignore errors - best effort delivery
    }

    // Step 3: Close the connection (TCP will flush buffers before sending FIN)
    close(peer);
}

// ============================================================================
// Internal Callbacks
// ============================================================================

<*
 Called when TCP connection completes.
*>
fn void on_tcp_connect(async::tcp::TcpConnection* conn, int status, void* user_data)
{
    PeerConnection* peer = (PeerConnection*)user_data;

    if (status != 0)
    {
        // Connection failed - libuv already cleaned up the handle
        // Don't call close() as the connection never succeeded
        peer.tcp = null;
        peer.state = PeerState.CLOSED;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.user_data);
        return;
    }

    // Connected - send handshake
    peer.state = PeerState.HANDSHAKING;
    if (peer.state_cb) peer.state_cb(peer, PeerState.HANDSHAKING, peer.user_data);

    char[] handshake = peer_wire::encode_handshake(peer.info_hash, peer.our_peer_id);
    defer free(handshake);

    // Start reading to receive handshake response
    if (catch excuse = conn.start_read(&alloc_buffer, &on_tcp_read, peer))
    {
        logger::log(logger::LogLevel.ERROR, "Failed to start reading from peer");
        if (peer.tcp)
        {
            peer.tcp.close();
            peer.tcp = null;
        }
        peer.state = PeerState.CLOSED;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.user_data);
        return;
    }

    // Send handshake
    if (catch excuse = conn.write(handshake, &on_handshake_sent, peer))
    {
        logger::log(logger::LogLevel.ERROR, "Failed to send handshake to peer");
        if (peer.tcp)
        {
            peer.tcp.close();
            peer.tcp = null;
        }
        peer.state = PeerState.CLOSED;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.user_data);
        return;
    }
}

<*
 Called when handshake has been sent.
*>
fn void on_handshake_sent(async::tcp::TcpConnection* conn, int status, void* user_data)
{
    if (status != 0)
    {
        PeerConnection* peer = (PeerConnection*)user_data;
        logger::logf(logger::LogLevel.ERROR, "Failed to send handshake: status=%d", status);
        if (peer.tcp)
        {
            peer.tcp.close();
            peer.tcp = null;
        }
        peer.state = PeerState.CLOSED;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.user_data);
    }
    // Otherwise just wait for handshake response in on_tcp_read
}

<*
 Allocate buffer for incoming TCP data.
*>
fn char[] alloc_buffer(async::tcp::TcpConnection* conn, usz suggested_size, void* user_data)
{
    return mem::new_array(char, suggested_size);
}

<*
 Called when TCP data is received.
*>
fn void on_tcp_read(async::tcp::TcpConnection* conn, char[] data, void* user_data)
{
    PeerConnection* peer = (PeerConnection*)user_data;

    if (data.len == 0)
    {
        // EOF - connection closed
        if (peer.tcp)
        {
            peer.tcp.close();
            peer.tcp = null;
        }
        peer.state = PeerState.CLOSED;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.user_data);
        return;
    }

    // Append to receive buffer
    peer.recv_buffer.append(data);

    // Process messages from buffer
    if (peer.state == PeerState.HANDSHAKING)
    {
        process_handshake(peer);
    }
    else if (peer.state == PeerState.READY)
    {
        process_messages(peer);
    }
}

<*
 Process handshake from receive buffer.
*>
fn void process_handshake(PeerConnection* peer)
{
    String buffer = peer.recv_buffer.str_view();

    // Need at least 68 bytes for handshake
    if (buffer.len < 68) return;

    // Decode handshake
    peer_wire::HandshakeMsg? handshake_opt = peer_wire::decode_handshake((char[])buffer);
    if (catch excuse = handshake_opt)
    {
        logger::log(logger::LogLevel.ERROR, "Invalid handshake from peer");
        peer.state = PeerState.CLOSED;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.user_data);
        return;
    }

    peer_wire::HandshakeMsg handshake = handshake_opt;

    // Verify info hash matches
    bool hash_matches = true;
    for (usz i = 0; i < 20; i++)
    {
        if (handshake.info_hash[i] != peer.info_hash[i])
        {
            hash_matches = false;
            break;
        }
    }

    if (!hash_matches)
    {
        logger::log(logger::LogLevel.ERROR, "Peer sent wrong info hash");
        peer.state = PeerState.CLOSED;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.user_data);
        return;
    }

    // Save remote peer ID
    for (usz i = 0; i < 20; i++)
    {
        peer.remote_peer_id[i] = handshake.peer_id[i];
    }

    // Check if peer supports extension protocol (BEP 10)
    peer.supports_extensions = peer_wire::handshake_supports_extensions(&handshake);

    // Remove handshake from buffer
    peer.recv_buffer.delete(0, 68);

    // Handshake complete - ready for messages
    peer.state = PeerState.READY;
    if (peer.state_cb) peer.state_cb(peer, PeerState.READY, peer.user_data);

    // Send extension handshake if supported
    if (peer.supports_extensions && !peer.sent_ext_handshake)
    {
        send_extension_handshake(peer);
    }
    else if (!peer.supports_extensions)
    {
        logger::log(logger::LogLevel.INFO, "Peer does not support extension protocol - PEX unavailable");
    }

    // Process any messages that came with the handshake
    if (peer.recv_buffer.len() > 0)
    {
        process_messages(peer);
    }
}

<*
 Process messages from receive buffer.
*>
fn void process_messages(PeerConnection* peer)
{
    while (true)
    {
        String buffer = peer.recv_buffer.str_view();

        // Need at least 4 bytes for length prefix
        if (buffer.len < 4) break;

        // Check if we have a complete message
        usz? total_size_opt = peer_wire::message_total_size((char[])buffer);
        if (catch excuse = total_size_opt) break;

        usz total_size = total_size_opt;
        if (buffer.len < total_size) break;  // Don't have complete message yet

        // Decode message
        peer_wire::Message? msg_opt = peer_wire::decode_message((char[])buffer);
        if (catch excuse = msg_opt)
        {
            logger::log(logger::LogLevel.ERROR, "Invalid message from peer");
            peer.state = PeerState.CLOSED;
            if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.user_data);
            return;
        }

        peer_wire::Message msg = msg_opt;

        // Remove message from buffer
        peer.recv_buffer.delete(0, total_size);

        // Handle state-changing messages
        handle_state_message(peer, &msg);

        // Call user callback
        if (peer.msg_cb)
        {
            peer.msg_cb(peer, &msg, peer.user_data);
        }

        // Free message payload
        if (msg.payload.len > 0)
        {
            free(msg.payload);
        }
    }
}

<*
 Handle messages that change peer state.
*>
fn void handle_state_message(PeerConnection* peer, peer_wire::Message* msg)
{
    switch (msg.type)
    {
        case peer_wire::MessageType.CHOKE:
            peer.peer_choking = true;
        case peer_wire::MessageType.UNCHOKE:
            peer.peer_choking = false;
        case peer_wire::MessageType.INTERESTED:
            peer.peer_interested = true;
        case peer_wire::MessageType.NOT_INTERESTED:
            peer.peer_interested = false;
        case peer_wire::MessageType.EXTENDED:
            // Handle extension protocol messages (BEP 10)
            handle_extension_message(peer, msg.payload);
        default:
            // Other messages don't change state
    }
}

// ============================================================================
// Message Sending
// ============================================================================

<*
 Send a message to the peer.

 @param peer : "Peer connection"
 @param data : "Message bytes to send"
 @return "Fault if send fails"
*>
fn fault? send_message(PeerConnection* peer, char[] data) @inline
{
    if (peer.state != PeerState.READY)
    {
        return PEER_INVALID_STATE?;
    }

    if (catch excuse = peer.tcp.write(data, &on_message_sent, peer))
    {
        return PEER_MESSAGE_SEND_FAILED?;
    }

    return {};
}

<*
 Called when a message has been sent.
*>
fn void on_message_sent(async::tcp::TcpConnection* conn, int status, void* user_data)
{
    if (status != 0)
    {
        PeerConnection* peer = (PeerConnection*)user_data;
        logger::logf(logger::LogLevel.ERROR, "Failed to send message to peer: status=%d", status);
        // Don't close connection on send failure, just log it
    }
}

<*
 Send CHOKE message to peer.
*>
fn fault? PeerConnection.send_choke(&self) @public
{
    char[] msg = peer_wire::encode_simple_message(peer_wire::MessageType.CHOKE);
    defer free(msg);
    fault? result = send_message(self, msg);
    if (catch excuse = result) return excuse?;
    self.am_choking = true;
    return {};
}

<*
 Send UNCHOKE message to peer.
*>
fn fault? PeerConnection.send_unchoke(&self) @public
{
    char[] msg = peer_wire::encode_simple_message(peer_wire::MessageType.UNCHOKE);
    defer free(msg);
    fault? result = send_message(self, msg);
    if (catch excuse = result) return excuse?;
    self.am_choking = false;
    return {};
}

<*
 Send INTERESTED message to peer.
*>
fn fault? PeerConnection.send_interested(&self) @public
{
    char[] msg = peer_wire::encode_simple_message(peer_wire::MessageType.INTERESTED);
    defer free(msg);
    fault? result = send_message(self, msg);
    if (catch excuse = result) return excuse?;
    self.am_interested = true;
    return {};
}

<*
 Send NOT_INTERESTED message to peer.
*>
fn fault? PeerConnection.send_not_interested(&self) @public
{
    char[] msg = peer_wire::encode_simple_message(peer_wire::MessageType.NOT_INTERESTED);
    defer free(msg);
    fault? result = send_message(self, msg);
    if (catch excuse = result) return excuse?;
    self.am_interested = false;
    return {};
}

<*
 Send HAVE message to peer.

 @param piece_index : "Index of piece we have"
*>
fn fault? PeerConnection.send_have(&self, uint piece_index) @public
{
    char[] msg = peer_wire::encode_have(piece_index);
    defer free(msg);
    return send_message(self, msg);
}

<*
 Send BITFIELD message to peer.

 @param bf : "Our bitfield of available pieces"
*>
fn fault? PeerConnection.send_bitfield(&self, bitfield::Bitfield* bf) @public
{
    char[] bytes = bf.to_bytes();
    char[] msg = peer_wire::encode_bitfield(bytes);
    defer free(msg);
    return send_message(self, msg);
}

<*
 Send REQUEST message to peer.

 @param index : "Piece index"
 @param begin : "Byte offset within piece"
 @param length : "Block length to request"
*>
fn fault? PeerConnection.send_request(&self, uint index, uint begin, uint length) @public
{
    char[] msg = peer_wire::encode_request(index, begin, length);
    defer free(msg);
    return send_message(self, msg);
}

<*
 Send PIECE message to peer.

 @param index : "Piece index"
 @param begin : "Byte offset within piece"
 @param block : "Block data"
*>
fn fault? PeerConnection.send_piece(&self, uint index, uint begin, char[] block) @public
{
    char[] msg = peer_wire::encode_piece(index, begin, block);
    defer free(msg);
    return send_message(self, msg);
}

<*
 Send CANCEL message to peer.

 @param index : "Piece index"
 @param begin : "Byte offset within piece"
 @param length : "Block length to cancel"
*>
fn fault? PeerConnection.send_cancel(&self, uint index, uint begin, uint length) @public
{
    char[] msg = peer_wire::encode_cancel(index, begin, length);
    defer free(msg);
    return send_message(self, msg);
}

<*
 Send keep-alive message to peer.
*>
fn fault? PeerConnection.send_keepalive(&self) @public
{
    char[] msg = peer_wire::encode_keepalive();
    defer free(msg);
    return send_message(self, msg);
}

// ============================================================================
// Extension Protocol (BEP 10)
// ============================================================================

<*
 Send extension handshake to peer (BEP 10).

 Called automatically after BitTorrent handshake if peer supports extensions.
*>
fn void send_extension_handshake(PeerConnection* peer) @private
{
    peer_wire::ExtensionHandshake ext_hs;
    ext_hs.ut_pex_id = peer.our_pex_msg_id;  // Advertise ut_pex support
    ext_hs.port = 6881;  // Our listen port (TODO: make configurable)
    ext_hs.client_name = "libtorrent-c3 0.1.0";
    ext_hs.reqq = 250;  // Max outstanding requests

    char[] msg = peer_wire::encode_extension_handshake(&ext_hs);
    defer free(msg);

    if (catch excuse = send_message(peer, msg))
    {
        logger::log(logger::LogLevel.ERROR, "Failed to send extension handshake");
        return;
    }

    peer.sent_ext_handshake = true;
    // Debug output disabled for logging mode
    // io::printfn("[EXT] Sent extension handshake (ut_pex: %d)", peer.our_pex_msg_id);
}

<*
 Handle extension handshake from peer (BEP 10).
*>
fn void handle_extension_handshake(PeerConnection* peer, char[] payload) @private
{
    peer_wire::ExtensionHandshake? ext_hs_opt = peer_wire::decode_extension_handshake(payload);
    if (catch excuse = ext_hs_opt)
    {
        logger::log(logger::LogLevel.ERROR, "Failed to decode extension handshake");
        return;
    }

    peer_wire::ExtensionHandshake ext_hs = ext_hs_opt;
    defer if (ext_hs.client_name.len > 0) free(ext_hs.client_name);

    peer.received_ext_handshake = true;

    // Check if peer supports ut_pex
    if (ext_hs.ut_pex_id > 0)
    {
        peer.supports_pex = true;
        peer.peer_pex_msg_id = ext_hs.ut_pex_id;
        // Debug output disabled for logging mode
        // io::printfn("[EXT] Peer supports PEX (msg_id: %d)", peer.peer_pex_msg_id);
    }

    // Debug output disabled for logging mode
    // if (ext_hs.client_name.len > 0)
    // {
    //     io::printfn("[EXT] Peer client: %s", ext_hs.client_name);
    // }
}

<*
 Handle extension protocol messages (BEP 10).
*>
fn void handle_extension_message(PeerConnection* peer, char[] payload) @private
{
    peer_wire::ExtensionMessage? ext_msg_opt = peer_wire::decode_extension_message(payload);
    if (catch excuse = ext_msg_opt)
    {
        logger::log(logger::LogLevel.ERROR, "Failed to decode extension message");
        return;
    }

    peer_wire::ExtensionMessage ext_msg = ext_msg_opt;
    defer if (ext_msg.payload.len > 0) free(ext_msg.payload);

    if (ext_msg.ext_msg_id == peer_wire::EXTENSION_HANDSHAKE_ID)
    {
        // Extension handshake
        handle_extension_handshake(peer, ext_msg.payload);
    }
    else if (ext_msg.ext_msg_id == peer.our_pex_msg_id)
    {
        // PEX message
        handle_pex_message(peer, ext_msg.payload);
    }
    else
    {
        logger::logf(logger::LogLevel.WARN, "Unknown extension message ID: %d", ext_msg.ext_msg_id);
    }
}

<*
 Handle PEX message from peer (BEP 11).
*>
fn void handle_pex_message(PeerConnection* peer, char[] payload) @private
{
    pex::PexMessage? pex_msg_opt = pex::decode_pex_message(payload);
    if (catch excuse = pex_msg_opt)
    {
        logger::log(logger::LogLevel.ERROR, "Failed to decode PEX message");
        return;
    }

    pex::PexMessage pex_msg = pex_msg_opt;
    defer pex::free_pex_message(&pex_msg);

    // Log PEX activity
    if (pex_msg.added.len > 0 || pex_msg.dropped.len > 0)
    {
        logger::logf(logger::LogLevel.INFO, "[PEX] Received %d added, %d dropped peers",
                     pex_msg.added.len, pex_msg.dropped.len);
    }

    // Notify user callback (e.g., peer_pool) to add these peers
    if (peer.pex_cb)
    {
        peer.pex_cb(peer, &pex_msg, peer.user_data);
    }
}

<*
 Send PEX message to peer with current added/dropped peers.

 BEP 11 rate limiting: Maximum 1 PEX message per minute per peer.

 @param peer : "Peer to send PEX message to"
 @return "void or fault"
*>
fn void? send_pex_message(PeerConnection* peer) @public
{
    if (!peer.supports_pex || peer.peer_pex_msg_id == 0)
    {
        return;  // Peer doesn't support PEX
    }

    // Rate limiting: enforce 1 message per minute (BEP 11)
    if (peer.pex_initialized)
    {
        long now_sec = (long)time::now().to_seconds();
        long elapsed_sec = now_sec - peer.last_pex_sent_sec;

        if (elapsed_sec < 60)
        {
            // Too soon since last PEX message
            return;
        }
    }

    // Check if we have any peers to send
    if (peer.added_peers.len == 0 && peer.dropped_peers.len == 0)
    {
        return;  // Nothing to send
    }

    // Build PEX message
    pex::PexMessage pex_msg;
    pex_msg.added = peer.added_peers;
    pex_msg.dropped = peer.dropped_peers;

    char[] pex_payload = pex::encode_pex_message(&pex_msg);
    defer free(pex_payload);

    // Encode as extension message
    char[] ext_msg = peer_wire::encode_extension_message(peer.peer_pex_msg_id, pex_payload);
    defer free(ext_msg);

    // Send message
    if (catch err = send_message(peer, ext_msg))
    {
        logger::log(logger::LogLevel.ERROR, "Failed to send PEX message");
        return err?;
    }

    // Log PEX activity
    logger::logf(logger::LogLevel.INFO, "[PEX] Sent %d added, %d dropped peers",
                 peer.added_peers.len, peer.dropped_peers.len);

    // Update rate limit timestamp
    peer.last_pex_sent_sec = (long)time::now().to_seconds();
    peer.pex_initialized = true;

    // Clear the peer lists
    if (peer.added_peers.len > 0)
    {
        free(peer.added_peers);
        peer.added_peers = {};
    }
    if (peer.dropped_peers.len > 0)
    {
        free(peer.dropped_peers);
        peer.dropped_peers = {};
    }
}

<*
 Add a peer to the PEX added list for this connection.

 The peer will be sent in the next PEX message (subject to rate limiting).
 BEP 11: Maximum 50 peers per PEX message.

 @param peer : "Peer connection"
 @param ip : "IPv4 address of peer to add"
 @param port : "Port of peer to add"
 @param flags : "PEX flags for this peer"
*>
fn void add_pex_peer(PeerConnection* peer, common::Ipv4Addr ip, ushort port, char flags) @public
{
    // BEP 11: Limit to 50 peers per message
    if (peer.added_peers.len >= 50)
    {
        return;
    }

    // Allocate new array with space for one more peer
    pex::PexPeer[] new_peers = mem::new_array(pex::PexPeer, peer.added_peers.len + 1);

    // Copy existing peers
    for (usz i = 0; i < peer.added_peers.len; i++)
    {
        new_peers[i] = peer.added_peers[i];
    }

    // Add new peer
    new_peers[peer.added_peers.len].ip = ip;
    new_peers[peer.added_peers.len].port = port;
    new_peers[peer.added_peers.len].flags = flags;

    // Replace old array
    if (peer.added_peers.len > 0) free(peer.added_peers);
    peer.added_peers = new_peers;
}

<*
 Add a peer to the PEX dropped list for this connection.

 The peer will be sent in the next PEX message (subject to rate limiting).
 BEP 11: Maximum 50 peers per PEX message.

 @param peer : "Peer connection"
 @param ip : "IPv4 address of peer that dropped"
 @param port : "Port of peer that dropped"
*>
fn void drop_pex_peer(PeerConnection* peer, common::Ipv4Addr ip, ushort port) @public
{
    // BEP 11: Limit to 50 peers per message
    if (peer.dropped_peers.len >= 50)
    {
        return;
    }

    // Allocate new array with space for one more peer
    pex::PexPeer[] new_peers = mem::new_array(pex::PexPeer, peer.dropped_peers.len + 1);

    // Copy existing peers
    for (usz i = 0; i < peer.dropped_peers.len; i++)
    {
        new_peers[i] = peer.dropped_peers[i];
    }

    // Add dropped peer (flags don't matter for dropped peers)
    new_peers[peer.dropped_peers.len].ip = ip;
    new_peers[peer.dropped_peers.len].port = port;
    new_peers[peer.dropped_peers.len].flags = 0;

    // Replace old array
    if (peer.dropped_peers.len > 0) free(peer.dropped_peers);
    peer.dropped_peers = new_peers;
}
