module libtorrent::peer_connection;

import async::tcp;
import async::event_loop;
import libtorrent::peer_wire;
import libtorrent::bitfield;
import libtorrent::pex;
import libtorrent::metadata_exchange;
import libtorrent::bencode;
import libtorrent::common;
import std::io;
import std::time;
import std::collections::list;
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
faultdef PEER_NO_FAST_EXTENSION;

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

<*
 Reason why a peer connection was closed.
 Used for diagnostics and determining whether to retry connection.
*>
enum DisconnectReason : const char
{
    UNKNOWN = 0,
    TCP_CONNECT_FAILED = 1,      // Initial TCP connection failed
    READ_START_FAILED = 2,       // Failed to start reading from socket
    HANDSHAKE_SEND_FAILED = 3,   // Failed to send handshake
    HANDSHAKE_WRITE_FAILED = 4,  // Failed to write handshake (callback)
    REMOTE_CLOSED = 5,           // Socket closed by remote peer (EOF)
    INVALID_HANDSHAKE = 6,       // Received invalid handshake format
    WRONG_INFO_HASH = 7,         // Info hash mismatch in handshake
    INVALID_MESSAGE = 8,         // Invalid protocol message received
    USER_CLOSED = 9              // Explicitly closed by user
}

// Callback for when a message is received from peer.
// Parameters: peer (connection), msg (received message), user_data (context)
alias MessageCallback = fn void(PeerConnection* peer, peer_wire::Message* msg, void* user_data);

// Callback for when connection state changes.
// Parameters: peer (connection), state (new state), reason (disconnect reason, only valid when state==CLOSED), user_data (context)
alias StateCallback = fn void(PeerConnection* peer, PeerState state, DisconnectReason reason, void* user_data);

// Callback for when PEX message is received.
// Parameters: peer (connection), pex_message (decoded PEX message), user_data (context)
alias PexCallback = fn void(PeerConnection* peer, pex::PexMessage* pex_msg, void* user_data);

// Unified metadata message structure for callbacks (BEP 9)
struct MetadataMessage
{
    metadata_exchange::MetadataMessageType msg_type;
    uint piece;
    uint total_size;  // Only valid for DATA messages
    char[] data;      // Only valid for DATA messages
}

// Callback for when metadata message is received (BEP 9).
// Parameters: peer (connection), metadata_message (decoded metadata message), user_data (context)
alias MetadataCallback = fn void(PeerConnection* peer, MetadataMessage* metadata_msg, void* user_data);

// Peer connection structure.
// Manages the connection to a single peer.
struct PeerConnection
{
    async::tcp::TcpConnection* tcp;
    event_loop::EventLoop* loop;
    PeerState state;
    DisconnectReason last_disconnect_reason;  // Reason for disconnect (valid when state==CLOSED)
    bool is_closed;  // Safety flag: true when connection is being closed/freed (prevents use-after-free in callbacks)

    // Torrent info
    common::InfoHash info_hash;
    common::PeerId our_peer_id;
    common::PeerId remote_peer_id;
    bool is_private;             // BEP 27: Private torrent flag (DHT/PEX disabled)

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

    // Metadata Exchange (BEP 9) - for magnet link support
    bool supports_metadata;      // Peer supports ut_metadata
    char peer_metadata_msg_id;   // Peer's message ID for ut_metadata (0 = disabled)
    char our_metadata_msg_id;    // Our message ID for ut_metadata (fixed at 2)
    uint peer_metadata_size;     // Size of metadata the peer has (0 = unknown/not sharing)

    // Fast Extension (BEP 6) - for improved bootstrapping
    bool supports_fast;                  // Peer supports Fast Extension
    List{uint} allowed_fast_set;         // Pieces peer allows us to download when choked
    List{uint} peer_allowed_fast;        // Pieces we allow peer to download when choked
    List{uint} suggested_pieces;         // Pieces peer has suggested we download

    // Message buffering
    DString recv_buffer;     // Accumulates TCP chunks

    // Callbacks
    MessageCallback msg_cb;
    StateCallback state_cb;
    PexCallback pex_cb;
    MetadataCallback metadata_cb;
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
 @param metadata_cb : "Callback for metadata messages (can be null, BEP 9)"
 @param user_data : "User context for callbacks"
 @param is_private : "BEP 27: Private torrent flag (disables PEX)"
 @return "Peer connection or fault"
*>
fn PeerConnection*? connect(event_loop::EventLoop* loop, String host, ushort port,
                              common::InfoHash info_hash, common::PeerId our_peer_id,
                              MessageCallback msg_cb, StateCallback state_cb,
                              PexCallback pex_cb, MetadataCallback metadata_cb,
                              void* user_data, bool is_private) @public
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
    peer.is_private = is_private;

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

    // Initialize metadata exchange state (BEP 9)
    peer.supports_metadata = false;
    peer.peer_metadata_msg_id = 0;
    peer.our_metadata_msg_id = 2;  // Fixed message ID for ut_metadata
    peer.peer_metadata_size = 0;

    // Initialize Fast Extension state (BEP 6)
    peer.supports_fast = false;
    peer.allowed_fast_set.init(mem);
    peer.peer_allowed_fast.init(mem);
    peer.suggested_pieces.init(mem);

    // Initialize callbacks
    peer.msg_cb = msg_cb;
    peer.state_cb = state_cb;
    peer.pex_cb = pex_cb;
    peer.metadata_cb = metadata_cb;
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
*>
fn void PeerConnection.close(&self) @public
{
    // Mark as closed FIRST to prevent use-after-free in pending callbacks
    self.is_closed = true;

    if (self.state != PeerState.CLOSED)
    {
        self.state = PeerState.CLOSED;
        self.last_disconnect_reason = DisconnectReason.USER_CLOSED;
        if (self.state_cb) self.state_cb(self, PeerState.CLOSED, self.last_disconnect_reason, self.user_data);
    }

    if (self.tcp)
    {
        self.tcp.close();
        self.tcp = null;
    }

    if (self.recv_buffer.len() > 0)
    {
        self.recv_buffer.free();
    }

    // Free PEX arrays
    if (self.added_peers.len > 0) free(self.added_peers);
    if (self.dropped_peers.len > 0) free(self.dropped_peers);

    // Free Fast Extension lists
    self.allowed_fast_set.free();
    self.peer_allowed_fast.free();
    self.suggested_pieces.free();

    // NOTE: Do NOT free(self) here!
    // During shutdown, there may be pending async callbacks that still reference this connection.
    // The PeerConnection will be freed by peer_pool.free() after the event loop has drained.
    // This prevents use-after-free crashes during shutdown.
}

<*
 Gracefully close a peer connection by sending protocol messages before disconnect.

 Sends NOT_INTERESTED and final PEX messages before closing the TCP connection,
 allowing the peer to properly handle our disconnection.
*>
fn void PeerConnection.graceful_close(&self) @public
{
    if (self.state == PeerState.CLOSED) return;

    // Log graceful disconnect
    logger::log(logger::LogLevel.INFO, "[Shutdown] Gracefully disconnecting from peer");

    // Step 1: Send NOT_INTERESTED if we were interested
    // This tells the peer we're intentionally leaving, not crashing
    if (self.am_interested)
    {
        (void)self.send_not_interested();  // Ignore errors - we're closing anyway
    }

    // Step 2: Send final PEX message if we have queued peer updates
    // This shares our peer list one last time before leaving the swarm
    if (self.supports_pex && (self.added_peers.len > 0 || self.dropped_peers.len > 0))
    {
        (void)self.send_pex_message();  // Ignore errors - best effort delivery
    }

    // Step 3: Close the connection (TCP will flush buffers before sending FIN)
    self.close();
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

    // Safety check: ignore callback if connection is being freed (prevents use-after-free)
    if (peer.is_closed)
    {
        return;
    }

    // Ignore callback if connection was already closed (shutdown race condition)
    if (peer.state == PeerState.CLOSED)
    {
        return;
    }

    if (status != 0)
    {
        // Connection failed - libuv already cleaned up the handle
        // Don't call close() as the connection never succeeded
        peer.tcp = null;
        peer.state = PeerState.CLOSED;
        peer.last_disconnect_reason = DisconnectReason.TCP_CONNECT_FAILED;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.last_disconnect_reason, peer.user_data);
        return;
    }

    // Connected - send handshake
    peer.state = PeerState.HANDSHAKING;
    if (peer.state_cb) peer.state_cb(peer, PeerState.HANDSHAKING, DisconnectReason.UNKNOWN, peer.user_data);

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
        peer.last_disconnect_reason = DisconnectReason.READ_START_FAILED;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.last_disconnect_reason, peer.user_data);
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
        peer.last_disconnect_reason = DisconnectReason.HANDSHAKE_SEND_FAILED;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.last_disconnect_reason, peer.user_data);
        return;
    }
}

<*
 Called when handshake has been sent.
*>
fn void on_handshake_sent(async::tcp::TcpConnection* conn, int status, void* user_data)
{
    PeerConnection* peer = (PeerConnection*)user_data;

    // Safety check: ignore callback if connection is being freed
    if (peer.is_closed)
    {
        return;
    }

    if (status != 0)
    {
        logger::logf(logger::LogLevel.ERROR, "Failed to send handshake: status=%d", status);
        if (peer.tcp)
        {
            peer.tcp.close();
            peer.tcp = null;
        }
        peer.state = PeerState.CLOSED;
        peer.last_disconnect_reason = DisconnectReason.HANDSHAKE_WRITE_FAILED;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.last_disconnect_reason, peer.user_data);
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

    // Safety check: ignore callback if connection is being freed
    if (peer.is_closed)
    {
        return;
    }

    if (data.len == 0)
    {
        // EOF - connection closed
        if (peer.tcp)
        {
            peer.tcp.close();
            peer.tcp = null;
        }
        peer.state = PeerState.CLOSED;
        peer.last_disconnect_reason = DisconnectReason.REMOTE_CLOSED;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.last_disconnect_reason, peer.user_data);
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
    if (buffer.len < 68)
    {
        return;
    }

    // Decode handshake
    peer_wire::HandshakeMsg? handshake_opt = peer_wire::decode_handshake((char[])buffer);
    if (catch excuse = handshake_opt)
    {
        logger::log(logger::LogLevel.ERROR, "Invalid handshake from peer");
        peer.state = PeerState.CLOSED;
        peer.last_disconnect_reason = DisconnectReason.INVALID_HANDSHAKE;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.last_disconnect_reason, peer.user_data);
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
        peer.last_disconnect_reason = DisconnectReason.WRONG_INFO_HASH;
        if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.last_disconnect_reason, peer.user_data);
        return;
    }

    // Save remote peer ID
    for (usz i = 0; i < 20; i++)
    {
        peer.remote_peer_id[i] = handshake.peer_id[i];
    }

    // Check if peer supports extension protocol (BEP 10)
    peer.supports_extensions = peer_wire::handshake_supports_extensions(&handshake);

    // Check if peer supports Fast Extension (BEP 6)
    peer.supports_fast = peer_wire::handshake_supports_fast(&handshake);

    // Remove handshake from buffer
    peer.recv_buffer.delete(0, 68);

    // Handshake complete - ready for messages
    peer.state = PeerState.READY;
    if (peer.state_cb) peer.state_cb(peer, PeerState.READY, DisconnectReason.UNKNOWN, peer.user_data);

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
            peer.last_disconnect_reason = DisconnectReason.INVALID_MESSAGE;
            if (peer.state_cb) peer.state_cb(peer, PeerState.CLOSED, peer.last_disconnect_reason, peer.user_data);
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

// ============================================================================
// BEP 6: Fast Extension Helper Functions
// ============================================================================

<*
 Add a piece to the allowed_fast set (if not already present).
*>
fn void add_to_allowed_fast_set(PeerConnection* peer, uint piece_index)
{
    // Check if already in set
    foreach (existing_piece : peer.allowed_fast_set)
    {
        if (existing_piece == piece_index) return;  // Already added
    }

    // Add new piece
    peer.allowed_fast_set.push(piece_index);
}

<*
 Add a piece to the suggested pieces list (if not already suggested).
*>
fn void add_suggested_piece(PeerConnection* peer, uint piece_index)
{
    // Check if already suggested
    foreach (existing_piece : peer.suggested_pieces)
    {
        if (existing_piece == piece_index) return;  // Already suggested
    }

    // Add new piece
    peer.suggested_pieces.push(piece_index);
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
            // MVP: Automatically unchoke interested peers (simple seeding)
            // TODO: Implement proper choking algorithm (BEP 3) for production
            if (peer.am_choking)
            {
                (void)peer.send_unchoke();  // Ignore errors - best effort
            }
        case peer_wire::MessageType.NOT_INTERESTED:
            peer.peer_interested = false;
            // Choke peers that are not interested (save bandwidth)
            if (!peer.am_choking)
            {
                (void)peer.send_choke();  // Ignore errors - best effort
            }
        case peer_wire::MessageType.EXTENDED:
            // Handle extension protocol messages (BEP 10)
            handle_extension_message(peer, msg.payload);
        case peer_wire::MessageType.SUGGEST_PIECE:
            // BEP 6: Add suggested piece to array
            if (peer.supports_fast)
            {
                uint piece_index = peer_wire::decode_fast_piece_index(msg.payload)!!;
                add_suggested_piece(peer, piece_index);
            }
        case peer_wire::MessageType.ALLOWED_FAST:
            // BEP 6: Add piece to allowed fast set
            if (peer.supports_fast)
            {
                uint piece_index = peer_wire::decode_fast_piece_index(msg.payload)!!;
                add_to_allowed_fast_set(peer, piece_index);
            }
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
    PeerConnection* peer = (PeerConnection*)user_data;

    // Safety check: ignore callback if connection is being freed
    if (peer.is_closed)
    {
        return;
    }

    if (status != 0)
    {
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

// ============================================================================
// BEP 6: Fast Extension Message Sending
// ============================================================================

<*
 Send HAVE_ALL message to peer (BEP 6).

 This replaces sending a full bitfield when we have all pieces.
*>
fn fault? PeerConnection.send_have_all(&self) @public
{
    if (!self.supports_fast) return PEER_NO_FAST_EXTENSION?;

    char[] msg = peer_wire::encode_have_all();
    defer free(msg);
    return send_message(self, msg);
}

<*
 Send HAVE_NONE message to peer (BEP 6).

 This replaces sending an empty bitfield when we have no pieces.
*>
fn fault? PeerConnection.send_have_none(&self) @public
{
    if (!self.supports_fast) return PEER_NO_FAST_EXTENSION?;

    char[] msg = peer_wire::encode_have_none();
    defer free(msg);
    return send_message(self, msg);
}

<*
 Send SUGGEST_PIECE message to peer (BEP 6).

 @param piece_index : "Suggested piece index"
*>
fn fault? PeerConnection.send_suggest_piece(&self, uint piece_index) @public
{
    if (!self.supports_fast) return PEER_NO_FAST_EXTENSION?;

    char[] msg = peer_wire::encode_suggest_piece(piece_index);
    defer free(msg);
    return send_message(self, msg);
}

<*
 Send REJECT_REQUEST message to peer (BEP 6).

 @param index : "Piece index"
 @param begin : "Byte offset within piece"
 @param length : "Block length"
*>
fn fault? PeerConnection.send_reject_request(&self, uint index, uint begin, uint length) @public
{
    if (!self.supports_fast) return PEER_NO_FAST_EXTENSION?;

    char[] msg = peer_wire::encode_reject_request(index, begin, length);
    defer free(msg);
    return send_message(self, msg);
}

<*
 Send ALLOWED_FAST message to peer (BEP 6).

 @param piece_index : "Piece index to allow fast download"
*>
fn fault? PeerConnection.send_allowed_fast(&self, uint piece_index) @public
{
    if (!self.supports_fast) return PEER_NO_FAST_EXTENSION?;

    char[] msg = peer_wire::encode_allowed_fast(piece_index);
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
    // BEP 27: Don't advertise ut_pex for private torrents
    ext_hs.ut_pex_id = peer.is_private ? 0 : peer.our_pex_msg_id;
    // BEP 9: Advertise ut_metadata support
    ext_hs.ut_metadata_id = peer.our_metadata_msg_id;
    ext_hs.port = 6881;  // Our listen port (TODO: make configurable)
    ext_hs.client_name = "libtorrent-c3 0.1.0";
    ext_hs.reqq = 250;  // Max outstanding requests
    ext_hs.metadata_size = 0;  // Set to actual size when we have metadata

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

    // Check if peer supports ut_metadata (BEP 9)
    if (ext_hs.ut_metadata_id > 0)
    {
        peer.supports_metadata = true;
        peer.peer_metadata_msg_id = ext_hs.ut_metadata_id;
        peer.peer_metadata_size = ext_hs.metadata_size;
        logger::logf(logger::LogLevel.INFO, "[Metadata] Peer supports metadata exchange (msg_id: %d, size: %d)",
                     peer.peer_metadata_msg_id, peer.peer_metadata_size);
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
    else if (ext_msg.ext_msg_id == peer.our_metadata_msg_id)
    {
        // Metadata exchange message (BEP 9)
        handle_metadata_message(peer, ext_msg.payload);
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
    // BEP 27: Ignore PEX messages for private torrents
    if (peer.is_private)
    {
        logger::logf(logger::LogLevel.WARN,
                    "[PEX] Ignoring PEX message from peer on private torrent (BEP 27)");
        return;
    }

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

 @return "void or fault"
*>
fn void? PeerConnection.send_pex_message(&self) @public
{
    // BEP 27: Don't send PEX for private torrents
    if (self.is_private)
    {
        return;  // Silently skip PEX for private torrents
    }

    if (!self.supports_pex || self.peer_pex_msg_id == 0)
    {
        return;  // Peer doesn't support PEX
    }

    // Rate limiting: enforce 1 message per minute (BEP 11)
    if (self.pex_initialized)
    {
        long now_sec = (long)time::now().to_seconds();
        long elapsed_sec = now_sec - self.last_pex_sent_sec;

        if (elapsed_sec < 60)
        {
            // Too soon since last PEX message
            return;
        }
    }

    // Check if we have any peers to send
    if (self.added_peers.len == 0 && self.dropped_peers.len == 0)
    {
        return;  // Nothing to send
    }

    // Build PEX message
    pex::PexMessage pex_msg;
    pex_msg.added = self.added_peers;
    pex_msg.dropped = self.dropped_peers;

    char[] pex_payload = pex::encode_pex_message(&pex_msg);
    defer free(pex_payload);

    // Encode as extension message
    char[] ext_msg = peer_wire::encode_extension_message(self.peer_pex_msg_id, pex_payload);
    defer free(ext_msg);

    // Send message
    if (catch err = send_message(self, ext_msg))
    {
        logger::log(logger::LogLevel.ERROR, "Failed to send PEX message");
        return err?;
    }

    // Log PEX activity
    logger::logf(logger::LogLevel.INFO, "[PEX] Sent %d added, %d dropped peers",
                 self.added_peers.len, self.dropped_peers.len);

    // Update rate limit timestamp
    self.last_pex_sent_sec = (long)time::now().to_seconds();
    self.pex_initialized = true;

    // Clear the peer lists
    if (self.added_peers.len > 0)
    {
        free(self.added_peers);
        self.added_peers = {};
    }
    if (self.dropped_peers.len > 0)
    {
        free(self.dropped_peers);
        self.dropped_peers = {};
    }
}

<*
 Add a peer to the PEX added list for this connection.

 The peer will be sent in the next PEX message (subject to rate limiting).
 BEP 11: Maximum 50 peers per PEX message.

 @param ip : "IPv4 address of peer to add"
 @param port : "Port of peer to add"
 @param flags : "PEX flags for this peer"
*>
fn void PeerConnection.add_pex_peer(&self, common::Ipv4Addr ip, ushort port, char flags) @public
{
    // BEP 11: Limit to 50 peers per message
    if (self.added_peers.len >= 50)
    {
        return;
    }

    // Allocate new array with space for one more peer
    pex::PexPeer[] new_peers = mem::new_array(pex::PexPeer, self.added_peers.len + 1);

    // Copy existing peers
    for (usz i = 0; i < self.added_peers.len; i++)
    {
        new_peers[i] = self.added_peers[i];
    }

    // Add new peer
    new_peers[self.added_peers.len].ip = ip;
    new_peers[self.added_peers.len].port = port;
    new_peers[self.added_peers.len].flags = flags;

    // Replace old array
    if (self.added_peers.len > 0) free(self.added_peers);
    self.added_peers = new_peers;
}

<*
 Add a peer to the PEX dropped list for this connection.

 The peer will be sent in the next PEX message (subject to rate limiting).
 BEP 11: Maximum 50 peers per PEX message.

 @param ip : "IPv4 address of peer that dropped"
 @param port : "Port of peer that dropped"
*>
fn void PeerConnection.drop_pex_peer(&self, common::Ipv4Addr ip, ushort port) @public
{
    // BEP 11: Limit to 50 peers per message
    if (self.dropped_peers.len >= 50)
    {
        return;
    }

    // Allocate new array with space for one more peer
    pex::PexPeer[] new_peers = mem::new_array(pex::PexPeer, self.dropped_peers.len + 1);

    // Copy existing peers
    for (usz i = 0; i < self.dropped_peers.len; i++)
    {
        new_peers[i] = self.dropped_peers[i];
    }

    // Add dropped peer (flags don't matter for dropped peers)
    new_peers[self.dropped_peers.len].ip = ip;
    new_peers[self.dropped_peers.len].port = port;
    new_peers[self.dropped_peers.len].flags = 0;

    // Replace old array
    if (self.dropped_peers.len > 0) free(self.dropped_peers);
    self.dropped_peers = new_peers;
}

// ============================================================================
// Metadata Exchange (BEP 9)
// ============================================================================

<*
 Handle metadata exchange message from peer (BEP 9).
*>
fn void handle_metadata_message(PeerConnection* peer, char[] payload) @private
{
    // First parse just to get the msg_type field
    bencode::BencodeValue*? root_opt = bencode::decode((String)payload);
    if (catch excuse = root_opt)
    {
        logger::log(logger::LogLevel.ERROR, "Failed to decode metadata message");
        return;
    }

    bencode::BencodeValue* root = root_opt;
    defer root.free();

    if (root.type != bencode::BencodeType.DICT)
    {
        logger::log(logger::LogLevel.ERROR, "Metadata message is not a dictionary");
        return;
    }

    bencode::BencodeValue* msg_type_val = root.dict_get("msg_type");
    if (!msg_type_val || msg_type_val.type != bencode::BencodeType.INTEGER)
    {
        logger::log(logger::LogLevel.ERROR, "Metadata message missing msg_type");
        return;
    }

    metadata_exchange::MetadataMessageType msg_type = (metadata_exchange::MetadataMessageType)msg_type_val.integer;

    MetadataMessage metadata_msg;
    metadata_msg.msg_type = msg_type;
    metadata_msg.total_size = 0;
    metadata_msg.data = {};

    // Decode based on message type
    switch (msg_type)
    {
        case metadata_exchange::MetadataMessageType.REQUEST:
            metadata_exchange::MetadataRequest? req_opt = metadata_exchange::decode_request(payload);
            if (catch excuse = req_opt)
            {
                logger::log(logger::LogLevel.ERROR, "Failed to decode metadata REQUEST");
                return;
            }
            metadata_msg.piece = req_opt.piece;
            logger::logf(logger::LogLevel.INFO, "[Metadata] Received REQUEST for piece %d", metadata_msg.piece);

        case metadata_exchange::MetadataMessageType.DATA:
            metadata_exchange::MetadataData? data_opt = metadata_exchange::decode_data(payload);
            if (catch excuse = data_opt)
            {
                logger::log(logger::LogLevel.ERROR, "Failed to decode metadata DATA");
                return;
            }
            metadata_msg.piece = data_opt.piece;
            metadata_msg.total_size = data_opt.total_size;
            metadata_msg.data = data_opt.data;  // Transfer ownership
            logger::logf(logger::LogLevel.INFO, "[Metadata] Received DATA for piece %d (%d bytes)",
                         metadata_msg.piece, metadata_msg.data.len);

        case metadata_exchange::MetadataMessageType.REJECT:
            metadata_exchange::MetadataReject? reject_opt = metadata_exchange::decode_reject(payload);
            if (catch excuse = reject_opt)
            {
                logger::log(logger::LogLevel.ERROR, "Failed to decode metadata REJECT");
                return;
            }
            metadata_msg.piece = reject_opt.piece;
            logger::logf(logger::LogLevel.INFO, "[Metadata] Received REJECT for piece %d", metadata_msg.piece);

        default:
            logger::logf(logger::LogLevel.ERROR, "Unknown metadata message type: %d", msg_type);
            return;
    }

    // Notify user callback (e.g., metadata_download manager)
    if (peer.metadata_cb)
    {
        peer.metadata_cb(peer, &metadata_msg, peer.user_data);
    }

    // Free data if allocated
    if (metadata_msg.data.len > 0)
    {
        free(metadata_msg.data);
    }
}

<*
 Send a metadata exchange message to peer (BEP 9).

 @param msg_type : "Message type (REQUEST, DATA, or REJECT)"
 @param piece : "Piece index"
 @param total_size : "Total metadata size (only for DATA messages)"
 @param data : "Metadata piece data (only for DATA messages, can be empty)"
 @return "void or fault"
*>
fn void? PeerConnection.send_metadata_message(&self, metadata_exchange::MetadataMessageType msg_type,
                                               uint piece, uint total_size, char[] data) @public
{
    if (!self.supports_metadata || self.peer_metadata_msg_id == 0)
    {
        return;  // Peer doesn't support metadata exchange
    }

    // Encode based on message type
    char[] metadata_payload;
    switch (msg_type)
    {
        case metadata_exchange::MetadataMessageType.REQUEST:
            metadata_payload = metadata_exchange::encode_request(piece);
        case metadata_exchange::MetadataMessageType.DATA:
            metadata_payload = metadata_exchange::encode_data(piece, total_size, data);
        case metadata_exchange::MetadataMessageType.REJECT:
            metadata_payload = metadata_exchange::encode_reject(piece);
        default:
            logger::logf(logger::LogLevel.ERROR, "Unknown metadata message type: %d", msg_type);
            return;
    }
    defer free(metadata_payload);

    // Encode as extension message
    char[] ext_msg = peer_wire::encode_extension_message(self.peer_metadata_msg_id, metadata_payload);
    defer free(ext_msg);

    // Send message
    if (catch err = send_message(self, ext_msg))
    {
        logger::log(logger::LogLevel.ERROR, "Failed to send metadata message");
        return err?;
    }

    // Log metadata activity
    String msg_type_str;
    switch (msg_type)
    {
        case metadata_exchange::MetadataMessageType.REQUEST:
            msg_type_str = "REQUEST";
        case metadata_exchange::MetadataMessageType.DATA:
            msg_type_str = "DATA";
        case metadata_exchange::MetadataMessageType.REJECT:
            msg_type_str = "REJECT";
        default:
            msg_type_str = "UNKNOWN";
    }
    logger::logf(logger::LogLevel.INFO, "[Metadata] Sent %s for piece %d",
                 msg_type_str, piece);
}
