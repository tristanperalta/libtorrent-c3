module libtorrent::utp::connection;

import libtorrent::utp::common;
import libtorrent::utp::packet;
import libtorrent::common;
import std::time;

<*
 μTP Connection State Machine
 =============================

 Implements the connection lifecycle and state transitions for μTP (BEP 29).
 Phase 1: Basic state machine skeleton with essential fields and transitions.

 Connection States (BEP 29):
 - NONE: Uninitialized/closed
 - SYN_SENT: Outgoing connection, waiting for SYN-ACK
 - CONNECTED: Connection established, data transfer active
 - FIN_SENT: Graceful close initiated, waiting for final ACK
 - ERROR_WAIT: Error state, waiting before cleanup
 - DELETING: Marked for deletion
*>

// ============================================================================
// Connection State
// ============================================================================

/**
 * μTP connection states (BEP 29).
 */
enum ConnectionState : char
{
    NONE,        // Uninitialized/closed
    SYN_SENT,    // Outgoing connection, waiting for SYN-ACK
    CONNECTED,   // Connection established
    FIN_SENT,    // Graceful close initiated
    ERROR_WAIT,  // Error state, waiting before cleanup
    DELETING     // Marked for deletion
}

// ============================================================================
// Connection Structure
// ============================================================================

/**
 * μTP connection instance.
 *
 * Tracks connection state, sequence numbers, remote address, and timing info.
 * Phase 1: Essential fields only. Buffers are managed separately.
 */
struct UtpConnection
{
    // State
    ConnectionState state;

    // Connection identifiers (BEP 29)
    ushort send_id;      // Connection ID we send (odd for outgoing, even for incoming)
    ushort recv_id;      // Connection ID we receive (even for outgoing, odd for incoming)

    // Sequence numbers (16-bit, wraps at 65536)
    ushort seq_nr;       // Next sequence number to send
    ushort ack_nr;       // Last in-order sequence number received

    // Remote endpoint
    common::SocketAddress remote_addr;

    // Window management
    uint local_window;   // Our advertised receive window (bytes)
    uint remote_window;  // Remote's advertised receive window (bytes)

    // Timing (microseconds since epoch)
    long last_recv_time;  // Last time we received any packet
    long last_send_time;  // Last time we sent any packet

    // Delay measurement (BEP 29: one-way delay estimation)
    uint our_delay;      // Our measured one-way delay (microseconds)
    uint their_delay;    // Their reported delay (from timestamp_difference)

    // Flags
    bool is_outgoing;    // true = we initiated, false = they initiated
}

// ============================================================================
// Connection Creation
// ============================================================================

/**
 * Create an outgoing μTP connection.
 *
 * Initializes connection in SYN_SENT state with odd connection ID.
 *
 * @param remote_addr : Remote endpoint address
 * @param conn_id_seed : Seed for connection ID generation (should be random)
 * @return New connection in SYN_SENT state
 */
fn UtpConnection* create_outgoing(common::SocketAddress remote_addr, ushort conn_id_seed) @public
{
    UtpConnection* conn = mem::new(UtpConnection);

    conn.state = ConnectionState.SYN_SENT;
    conn.is_outgoing = true;

    // Outgoing connections use odd send_id (BEP 29)
    conn.recv_id = conn_id_seed | 1;  // Ensure odd
    conn.send_id = conn.recv_id + 1;  // Even (peer's recv_id)

    // Initial sequence number (random starting point for security)
    conn.seq_nr = (ushort)(conn_id_seed ^ 0x5A5A);
    conn.ack_nr = 0;

    conn.remote_addr = remote_addr;

    // Default window size (Phase 1: static 1MB)
    conn.local_window = 1024 * 1024;
    conn.remote_window = 1024 * 1024;  // Assume max until we learn actual

    // Initialize timestamps (convert seconds to microseconds)
    long now = (long)time::now().to_seconds() * 1_000_000;
    conn.last_send_time = now;
    conn.last_recv_time = now;

    conn.our_delay = 0;
    conn.their_delay = 0;

    return conn;
}

/**
 * Create an incoming μTP connection from a SYN packet.
 *
 * Initializes connection in CONNECTED state (we'll send SYN-ACK).
 *
 * @param remote_addr : Remote endpoint address
 * @param syn_header : SYN packet header received
 * @return New connection ready to send SYN-ACK
 */
fn UtpConnection* create_incoming(common::SocketAddress remote_addr, packet::UtpHeader* syn_header) @public
{
    UtpConnection* conn = mem::new(UtpConnection);

    conn.state = ConnectionState.CONNECTED;  // Move to connected after SYN-ACK sent
    conn.is_outgoing = false;

    // Incoming connections: their send_id becomes our recv_id
    conn.recv_id = syn_header.connection_id;
    conn.send_id = conn.recv_id + 1;  // Our send_id is recv_id + 1

    // Sequence numbers
    conn.seq_nr = 1;  // Start at 1 for incoming
    conn.ack_nr = syn_header.seq_nr;  // ACK their SYN

    conn.remote_addr = remote_addr;

    // Use their advertised window
    conn.local_window = 1024 * 1024;
    conn.remote_window = syn_header.wnd_size;

    // Initialize timestamps (convert seconds to microseconds)
    long now = (long)time::now().to_seconds() * 1_000_000;
    conn.last_send_time = now;
    conn.last_recv_time = now;

    conn.our_delay = 0;
    conn.their_delay = 0;

    return conn;
}

// ============================================================================
// State Transitions
// ============================================================================

/**
 * Transition connection to CONNECTED state (after SYN-ACK received).
 */
fn void UtpConnection.transition_to_connected(&self) @public
{
    assert(self.state == ConnectionState.SYN_SENT, "Can only transition to CONNECTED from SYN_SENT");
    self.state = ConnectionState.CONNECTED;
}

/**
 * Transition connection to FIN_SENT state (graceful close initiated).
 */
fn void UtpConnection.transition_to_fin_sent(&self) @public
{
    assert(self.state == ConnectionState.CONNECTED, "Can only send FIN from CONNECTED state");
    self.state = ConnectionState.FIN_SENT;
}

/**
 * Transition connection to ERROR_WAIT state (error occurred).
 */
fn void UtpConnection.transition_to_error(&self) @public
{
    self.state = ConnectionState.ERROR_WAIT;
}

/**
 * Transition connection to DELETING state (ready for cleanup).
 */
fn void UtpConnection.transition_to_deleting(&self) @public
{
    self.state = ConnectionState.DELETING;
}

// ============================================================================
// Packet Processing (Phase 1: Basic)
// ============================================================================

/**
 * Process received packet and update connection state.
 *
 * Phase 1: Basic processing - updates ack_nr, window, and timestamps.
 * Does NOT handle retransmission or out-of-order packets yet.
 *
 * @param header : Received packet header
 * @return true if packet was valid and processed
 */
fn bool UtpConnection.process_packet(&self, packet::UtpHeader* header) @public
{
    // Update last receive time (convert seconds to microseconds)
    self.last_recv_time = (long)time::now().to_seconds() * 1_000_000;

    // Validate connection ID
    if (header.connection_id != self.recv_id)
    {
        return false;  // Wrong connection
    }

    // Update remote window
    self.remote_window = header.wnd_size;

    // Update their delay (one-way delay measurement)
    self.their_delay = header.timestamp_difference_microseconds;

    // Process based on packet type
    switch (header.packet_type)
    {
        case common::ST_STATE:
            // Pure ACK packet
            // Phase 1: Just update ack tracking (no buffer management yet)
            return true;

        case common::ST_DATA:
            // Data packet
            // Phase 1: Accept in-order only
            if (header.seq_nr == (ushort)(self.ack_nr + 1))
            {
                self.ack_nr = header.seq_nr;
                return true;
            }
            return false;  // Out of order, drop for now

        case common::ST_FIN:
            // Graceful close
            if (self.state == ConnectionState.CONNECTED)
            {
                self.ack_nr = header.seq_nr;
                self.transition_to_fin_sent();
                return true;
            }
            return false;

        case common::ST_RESET:
            // Force close
            self.transition_to_error();
            return true;

        case common::ST_SYN:
            // Duplicate SYN (ignore in Phase 1)
            return false;
    }

    return false;
}

/**
 * Check if connection has timed out.
 *
 * Phase 1: Simple 30-second timeout.
 *
 * @return true if connection should be closed due to timeout
 */
fn bool UtpConnection.is_timed_out(&self) @public
{
    const long TIMEOUT_USEC = 30_000_000;  // 30 seconds

    long now = (long)time::now().to_seconds() * 1_000_000;
    long idle_time = now - self.last_recv_time;

    return idle_time > TIMEOUT_USEC;
}

/**
 * Get current connection state as string (for debugging).
 */
fn String UtpConnection.state_string(&self) @public
{
    switch (self.state)
    {
        case ConnectionState.NONE: return "NONE";
        case ConnectionState.SYN_SENT: return "SYN_SENT";
        case ConnectionState.CONNECTED: return "CONNECTED";
        case ConnectionState.FIN_SENT: return "FIN_SENT";
        case ConnectionState.ERROR_WAIT: return "ERROR_WAIT";
        case ConnectionState.DELETING: return "DELETING";
    }
    return "UNKNOWN";
}

// ============================================================================
// Cleanup
// ============================================================================

/**
 * Free connection resources.
 */
fn void UtpConnection.free(&self) @public
{
    free(self);
}
