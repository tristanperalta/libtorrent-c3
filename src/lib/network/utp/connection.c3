module libtorrent::utp::connection;

import libtorrent::utp::common;
import libtorrent::utp::packet;
import libtorrent::utp::socket;
import libtorrent::network::utp::delay_hist;
import libtorrent::common;
import std::time;
import std::collections::list;
import std::io;
import std::math;

faultdef SEND_NOT_CONNECTED;
faultdef SEND_BUFFER_FULL;

<*
 μTP Connection State Machine
 =============================

 Implements the connection lifecycle and state transitions for μTP (BEP 29).
 Basic state machine skeleton with essential fields and transitions.

 Connection States (BEP 29):
 - NONE: Uninitialized/closed
 - SYN_SENT: Outgoing connection, waiting for SYN-ACK
 - CONNECTED: Connection established, data transfer active
 - FIN_SENT: Graceful close initiated, waiting for final ACK
 - ERROR_WAIT: Error state, waiting before cleanup
 - DELETING: Marked for deletion
*>

// ============================================================================
// Send Buffer
// ============================================================================

/**
 * Sent packet awaiting acknowledgment.
 * Stored in send buffer until ACKed or retransmit limit reached.
 */
struct SentPacket
{
    ushort seq_nr;              // Sequence number
    char[] data;                // Full packet data (header + payload) - owned
    long send_time;             // Timestamp when sent (microseconds)
    char num_transmissions;     // Retry counter (max 5 in later phase)
}

/**
 * Send buffer - tracks unacknowledged packets.
 *
 * Simple in-order tracking
 * - Packets stored in send order
 * - ACK removes packets ≤ ack_nr
 * - Backpressure when buffer full
 * - No out-of-order ACK complexity yet
 */
struct SendBuffer
{
    List{SentPacket*} packets;  // Sent packets awaiting ACK
    ushort oldest_seq;          // First unACKed sequence number
    usz max_buffered;           // Backpressure limit (default: 256 packets)
}

// ============================================================================
// Receive Buffer
// ============================================================================

/**
 * Receive buffer - stores received data chunks in order.
 *
 * In-order delivery
 * - Stores data chunks in arrival order
 * - read() returns first chunk (or partial chunk) - "Option B"
 * - Tracks partial chunk reads with offset
 * - No out-of-order buffering yet
 */
struct ReceiveBuffer
{
    List{char[]} chunks;         // Data chunks in order (each chunk is owned)
    ushort expected_seq;         // Next expected sequence number
    usz total_buffered;          // Total bytes buffered
    usz max_buffered;            // Backpressure limit (default: 1MB)
    usz current_chunk_offset;    // Offset into first chunk for partial reads
}

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
 * Added send buffer for packet tracking and retransmission.
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

    // LEDBAT Delay measurement (Phase 2: BEP 29 delay-based congestion control)
    delay_hist::DelayHist our_hist;      // Our measured one-way delays
    delay_hist::DelayHist their_hist;    // Their reported delays (from timestamp_difference)

    // LEDBAT Congestion Control (Phase 2)
    bool slow_start;                 // True if in slow start phase
    uint ssthresh;                   // Slow start threshold
    ulong last_maxed_out_window;    // Last time we hit window limit (milliseconds)
    uint min_rtt;                    // Minimum observed RTT (microseconds)

    // Flags
    bool is_outgoing;    // true = we initiated, false = they initiated

    // Send buffer for reliable delivery
    SendBuffer send_buf;

    // Receive buffer for in-order data delivery
    ReceiveBuffer recv_buf;

    // FIN handling
    bool fin_sent;       // true if we've sent a FIN packet
    ushort fin_seq_nr;   // Sequence number of our FIN packet
    bool remote_fin_received;  // true if remote sent FIN

    // Error handling
    ErrorReason error_reason;  // Why connection failed (if in error state)

    // Timeout tracking
    uint current_timeout_ms;   // Current timeout value (doubles on retransmit)

    uint mss;                  // Maximum segment size (1400 bytes default)
    uint cwnd;                 // Congestion window (bytes)
    uint bytes_in_flight;      // Bytes sent but not yet ACKed
    ushort last_cwnd_ack;      // Last ACK processed for cwnd update
}

/**
 * Reasons for connection errors.
 */
enum ErrorReason : char
{
    NONE,              // No error
    RESET_RECEIVED,    // Remote sent RESET packet
    TIMEOUT,           // Connection timed out
    PROTOCOL_ERROR,    // Protocol violation
    UNKNOWN            // Unknown/generic error
}

// ============================================================================
// Connection ID Management
// ============================================================================

/**
 * Allocate a new outgoing connection ID (odd numbers).
 *
 * Uses a simple counter-based allocation. In production, this should be
 * randomized and check for collisions.
 *
 * @param seed : Random seed for ID generation
 * @return Odd connection ID for outgoing connection
 */
fn ushort allocate_outgoing_id(ushort seed) @public
{
    // Ensure odd by setting low bit
    return seed | 1;
}

/**
 * Get the corresponding receive ID for a send ID.
 *
 * BEP 29: recv_id = send_id + 1 for outgoing, send_id - 1 for incoming
 *
 * @param send_id : Send connection ID
 * @param is_outgoing : true if outgoing connection
 * @return Corresponding receive ID
 */
fn ushort get_recv_id_for_send_id(ushort send_id, bool is_outgoing) @public
{
    return is_outgoing ? (ushort)(send_id + 1) : (ushort)(send_id - 1);
}

/**
 * Validate connection ID (check odd/even correctness).
 *
 * @param conn_id : Connection ID to validate
 * @param should_be_odd : true if ID should be odd
 * @return true if ID is valid
 */
fn bool validate_connection_id(ushort conn_id, bool should_be_odd) @public
{
    bool is_odd = (conn_id & 1) == 1;
    return is_odd == should_be_odd;
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

    // Default window size
    conn.local_window = 1024 * 1024;
    conn.remote_window = 1024 * 1024;  // Assume max until we learn actual

    // Initialize timestamps (convert seconds to microseconds)
    long now = (long)time::now().to_seconds() * 1_000_000;
    conn.last_send_time = now;
    conn.last_recv_time = now;

    // Initialize LEDBAT delay tracking
    ulong now_ms = (ulong)time::now().to_seconds() * 1000;
    conn.our_hist.clear(now_ms);
    conn.their_hist.clear(now_ms);

    // Initialize LEDBAT congestion control
    conn.slow_start = true;
    conn.ssthresh = 0xFFFFFFFF;  // No threshold initially (unlimited slow start)
    conn.last_maxed_out_window = now_ms;  // Initialize to current time
    conn.min_rtt = 0xFFFFFFFF;   // Initialize to max (will be updated with real measurements)

    // Initialize send buffer
    conn.send_buf.init();

    // Initialize receive buffer
    conn.recv_buf.init();

    // Initialize FIN tracking
    conn.fin_sent = false;
    conn.fin_seq_nr = 0;
    conn.remote_fin_received = false;

    // Initialize error tracking
    conn.error_reason = ErrorReason.NONE;

    // Initialize timeout
    conn.current_timeout_ms = 1000;  // 1 second initial timeout

    conn.mss = 1400;  // Conservative MSS (1500 MTU - 20 IP - 8 UDP - 20 μTP - ~52 bytes margin)
    conn.cwnd = 2 * conn.mss;  // Initial window: 2 segments (conservative start)
    conn.bytes_in_flight = 0;
    conn.last_cwnd_ack = 0;

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

    // Initialize LEDBAT delay tracking
    ulong now_ms = (ulong)time::now().to_seconds() * 1000;
    conn.our_hist.clear(now_ms);
    conn.their_hist.clear(now_ms);

    // Initialize LEDBAT congestion control
    conn.slow_start = true;
    conn.ssthresh = 0xFFFFFFFF;  // No threshold initially (unlimited slow start)
    conn.last_maxed_out_window = now_ms;  // Initialize to current time
    conn.min_rtt = 0xFFFFFFFF;   // Initialize to max (will be updated with real measurements)

    // Initialize send buffer
    conn.send_buf.init();

    // Initialize receive buffer
    conn.recv_buf.init();

    // Initialize FIN tracking
    conn.fin_sent = false;
    conn.fin_seq_nr = 0;
    conn.remote_fin_received = false;

    // Initialize error tracking
    conn.error_reason = ErrorReason.NONE;

    // Initialize timeout
    conn.current_timeout_ms = 1000;  // 1 second initial timeout

    conn.mss = 1400;  // Conservative MSS (1500 MTU - 20 IP - 8 UDP - 20 μTP - ~52 bytes margin)
    conn.cwnd = 2 * conn.mss;  // Initial window: 2 segments (conservative start)
    conn.bytes_in_flight = 0;
    conn.last_cwnd_ack = 0;

    return conn;
}

// ============================================================================
// Send Buffer Implementation
// ============================================================================

/**
 * Compare sequence numbers with wraparound handling.
 *
 * Uses signed arithmetic to handle 16-bit wraparound correctly.
 * Example: seq 65535 vs 0 should treat 0 as "greater"
 *
 * @param a : First sequence number
 * @param b : Second sequence number
 * @return < 0 if a < b, 0 if a == b, > 0 if a > b
 */
fn int compare_seq_nr(ushort a, ushort b) @private
{
    // Cast to signed short for correct wraparound behavior
    short diff = (short)(a - b);
    return (int)diff;
}

/**
 * Initialize send buffer.
 *
 * @param max_buffered : Maximum packets to buffer (default: 256)
 */
fn void SendBuffer.init(&self, usz max_buffered = 256) @private
{
    self.packets.init(mem);
    self.oldest_seq = 0;
    self.max_buffered = max_buffered;
}

/**
 * Check if we can send more packets (backpressure check).
 *
 * @return true if buffer has room for more packets
 */
fn bool SendBuffer.can_send(&self) @public
{
    return self.packets.len() < self.max_buffered;
}

/**
 * Add sent packet to buffer.
 * Packet data is copied (caller retains ownership of original).
 *
 * @param seq_nr : Sequence number of packet
 * @param packet_data : Full packet bytes (header + payload)
 */
fn void SendBuffer.add_packet(&self, ushort seq_nr, char[] packet_data) @public
{
    // Create packet structure
    SentPacket* pkt = mem::new(SentPacket);
    pkt.seq_nr = seq_nr;
    pkt.num_transmissions = 1;
    pkt.send_time = (long)time::now().to_seconds() * 1_000_000;

    // Copy packet data (we own this copy)
    pkt.data = mem::new_array(char, packet_data.len);
    for (usz i = 0; i < packet_data.len; i++)
    {
        pkt.data[i] = packet_data[i];
    }

    // Add to buffer
    self.packets.push(pkt);

    // Update oldest_seq if this is the first packet
    if (self.packets.len() == 1)
    {
        self.oldest_seq = seq_nr;
    }
}

/**
 * Process ACK - remove all packets with seq_nr ≤ ack_nr.
 * Handles sequence number wraparound correctly.
 *
 * @param ack_nr : Acknowledgment number from peer
 */
fn void SendBuffer.ack_packet(&self, ushort ack_nr) @public
{
    // Remove packets in order until we hit one not ACKed
    while (self.packets.len() > 0)
    {
        SentPacket* pkt = self.packets[0];

        // Check if this packet is ACKed (seq_nr <= ack_nr with wraparound)
        if (compare_seq_nr(pkt.seq_nr, ack_nr) <= 0)
        {
            // This packet is acknowledged - remove it
            free(pkt.data);
            free(pkt);
            self.packets.remove_at(0);

            // Update oldest_seq if buffer not empty
            if (self.packets.len() > 0)
            {
                self.oldest_seq = self.packets[0].seq_nr;
            }
        }
        else
        {
            // This packet (and all following) not yet ACKed
            break;
        }
    }
}

/**
 * Get packet by sequence number (for retransmission).
 *
 * @param seq_nr : Sequence number to find
 * @return Packet if found, fault otherwise
 */
fn SentPacket*? SendBuffer.get_packet(&self, ushort seq_nr) @public
{
    foreach (pkt : self.packets)
    {
        if (pkt.seq_nr == seq_nr)
        {
            return pkt;
        }
    }
    // Packet not found - return fault
    return common::UTP_PACKET_NOT_FOUND?;
}

/**
 * Get number of packets in flight (unacknowledged).
 *
 * @return Number of packets awaiting ACK
 */
fn usz SendBuffer.packets_in_flight(&self) @public
{
    return self.packets.len();
}

/**
 * Check if send buffer is empty
 *
 * @return true if no packets are waiting for ACK
 */
fn bool SendBuffer.is_empty(&self) @public
{
    return self.packets.len() == 0;
}

/**
 * Free send buffer and all buffered packets.
 */
fn void SendBuffer.free(&self) @private
{
    // Free each packet's data and struct
    foreach (pkt : self.packets)
    {
        free(pkt.data);
        free(pkt);
    }

    // Free the list
    self.packets.free();
}

// ============================================================================
// Receive Buffer Implementation
// ============================================================================

/**
 * Initialize receive buffer.
 *
 * @param max_buffered : Maximum bytes to buffer (default: 1MB)
 */
fn void ReceiveBuffer.init(&self, usz max_buffered = 1024 * 1024) @private
{
    self.chunks.init(mem);
    self.expected_seq = 0;
    self.total_buffered = 0;
    self.max_buffered = max_buffered;
    self.current_chunk_offset = 0;
}

/**
 * Add received data packet to buffer.
 *
 * Only accepts in-order packets (seq == expected_seq).
 * Data is copied (caller retains ownership of original).
 *
 * @param seq_nr : Sequence number of packet
 * @param data : Packet payload data
 * @return true if packet was accepted and buffered
 */
fn bool ReceiveBuffer.add_packet(&self, ushort seq_nr, char[] data) @public
{
    // Only accept in-order packets
    if (seq_nr != self.expected_seq)
    {
        return false;  // Out of order - drop for now
    }

    // Check backpressure
    if (self.total_buffered + data.len > self.max_buffered)
    {
        return false;  // Buffer full
    }

    // Copy data (we own this copy)
    char[] chunk = mem::new_array(char, data.len);
    for (usz i = 0; i < data.len; i++)
    {
        chunk[i] = data[i];
    }

    // Add to chunks
    self.chunks.push(chunk);
    self.total_buffered += data.len;

    // Advance expected sequence number (with wraparound)
    self.expected_seq = (ushort)(self.expected_seq + 1);

    return true;
}

/**
 * Read data from buffer (Option B: Return first chunk or partial).
 *
 * Returns the first chunk up to max_bytes. If the first chunk is larger than
 * max_bytes, returns a partial chunk and tracks offset for next read.
 * After returning a complete chunk, it's removed from the buffer.
 *
 * @param max_bytes : Maximum bytes to read
 * @return Data chunk (may be less than max_bytes), or empty if no data
 */
fn char[] ReceiveBuffer.read(&self, usz max_bytes) @public
{
    if (self.chunks.len() == 0)
    {
        // No data available
        return {};
    }

    char[] first_chunk = self.chunks[0];
    usz available = first_chunk.len - self.current_chunk_offset;
    usz to_read = (available < max_bytes) ? available : max_bytes;

    // Allocate result buffer
    char[] result = mem::new_array(char, to_read);

    // Copy from current offset
    for (usz i = 0; i < to_read; i++)
    {
        result[i] = first_chunk[self.current_chunk_offset + i];
    }

    // Update offset and state
    self.current_chunk_offset += to_read;
    self.total_buffered -= to_read;

    // If we've consumed the entire chunk, remove it
    if (self.current_chunk_offset >= first_chunk.len)
    {
        free(first_chunk);
        self.chunks.remove_at(0);
        self.current_chunk_offset = 0;
    }

    return result;
}

/**
 * Check if buffer has data available.
 *
 * @return true if data can be read
 */
fn bool ReceiveBuffer.has_data(&self) @public
{
    return self.chunks.len() > 0;
}

/**
 * Get total bytes available in buffer.
 *
 * @return Number of bytes that can be read
 */
fn usz ReceiveBuffer.bytes_available(&self) @public
{
    return self.total_buffered;
}

/**
 * Free receive buffer and all buffered chunks.
 */
fn void ReceiveBuffer.free(&self) @private
{
    // Free each chunk
    foreach (chunk : self.chunks)
    {
        free(chunk);
    }

    // Free the list
    self.chunks.free();
}

// ============================================================================
// Connection Lifecycle
// ============================================================================

/**
 * Initiate graceful close of connection.
 *
 * Marks connection for closure. Caller should send FIN packet.
 * Connection will transition to DELETING once:
 * - Send buffer is drained (all packets ACKed)
 * - Our FIN is ACKed
 * - Remote FIN is received (if applicable)
 *
 * @return true if close was initiated, false if already closing
 */
fn bool UtpConnection.initiate_close(&self) @public
{
    // Only allow close from CONNECTED state
    if (self.state != ConnectionState.CONNECTED)
    {
        return false;  // Already closing or not connected
    }

    // Mark that we're sending FIN
    self.fin_sent = true;
    self.fin_seq_nr = self.seq_nr;

    // Transition to FIN_SENT state
    self.transition_to_fin_sent();

    return true;
}

/**
 * Check if connection can be deleted.
 *
 * Connection is ready for deletion when:
 * - We're in FIN_SENT or ERROR_WAIT/DELETING state
 * - Send buffer is empty (all data ACKed)
 * - FIN is ACKed (if we sent one)
 * - Remote sent FIN (for graceful close)
 *
 * @return true if connection can be safely deleted
 */
fn bool UtpConnection.can_delete(&self) @public
{
    // Must be in closing/error state
    if (self.state != ConnectionState.FIN_SENT &&
        self.state != ConnectionState.ERROR_WAIT &&
        self.state != ConnectionState.DELETING)
    {
        return false;
    }

    // Send buffer must be empty
    if (!self.send_buf.is_empty())
    {
        return false;
    }

    // If we sent FIN, it must be ACKed
    // For now, we assume FIN is ACKed if send buffer is empty
    // (proper FIN ACK tracking would check specific seq_nr)

    // For graceful close, remote must have sent FIN
    if (self.state == ConnectionState.FIN_SENT && !self.remote_fin_received)
    {
        return false;  // Wait for remote FIN
    }

    return true;
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
 *
 * Enhanced with error reason tracking.
 * Idempotent: Won't overwrite error reason if already in error state.
 *
 * @param reason : Why the connection failed
 */
fn void UtpConnection.transition_to_error(&self, ErrorReason reason = ErrorReason.UNKNOWN) @public
{
    // Idempotent: Don't overwrite error if already in error/deleting state
    if (self.state == ConnectionState.ERROR_WAIT || self.state == ConnectionState.DELETING)
    {
        return;
    }

    self.state = ConnectionState.ERROR_WAIT;
    self.error_reason = reason;
}

/**
 * Transition connection to DELETING state (ready for cleanup).
 */
fn void UtpConnection.transition_to_deleting(&self) @public
{
    self.state = ConnectionState.DELETING;
}

// ============================================================================
// Packet Processing
// ============================================================================

/**
 * Process received packet and update connection state.
 *
 * Basic processing - updates ack_nr, window, and timestamps.
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

    // Update their delay history (LEDBAT Phase 2)
    ulong now_ms = (ulong)time::now().to_seconds() * 1000;
    long now_us = (long)time::now().to_seconds() * 1_000_000;

    // Clock drift compensation - store prev_delay_base before update
    uint prev_their_delay_base = self.their_hist.delay_base;
    self.their_hist.add_sample(header.timestamp_difference_microseconds, now_ms);

    // Detect clock drift and compensate
    if (self.their_hist.initialized && prev_their_delay_base > self.their_hist.delay_base)
    {
        // Their clock drifted slower - their delay_base decreased
        uint drift = prev_their_delay_base - self.their_hist.delay_base;
        // Only compensate for small drifts (< 10ms) to prevent abuse
        if (drift <= 10000 && self.our_hist.initialized)
        {
            self.our_hist.shift(drift);
        }
    }

    // Calculate one-way delay and update our_hist
    // Process ACKs before removing packets from send buffer
    usz bytes_acked = 0;
    foreach (pkt : self.send_buf.packets)
    {
        if (compare_seq_nr(pkt.seq_nr, header.ack_nr) <= 0)
        {
            bytes_acked += pkt.data.len;

            // Calculate actual one-way delay for this packet
            // actual_delay = receive_time - send_time - their_delay
            long rtt = now_us - pkt.send_time;
            uint actual_delay = 0;
            if (rtt > (long)header.timestamp_difference_microseconds)
            {
                actual_delay = (uint)(rtt - (long)header.timestamp_difference_microseconds);
            }

            // Update our delay history
            self.our_hist.add_sample(actual_delay, now_ms);

            // Update minimum RTT
            if (rtt > 0 && (uint)rtt < self.min_rtt)
            {
                self.min_rtt = (uint)rtt;
            }
        }
    }

    // Remove acknowledged packets from send buffer
    self.send_buf.ack_packet(header.ack_nr);

    // Update bytes_in_flight (subtract ACKed bytes)
    if (bytes_acked <= self.bytes_in_flight)
    {
        self.bytes_in_flight -= (uint)bytes_acked;
    }
    else
    {
        self.bytes_in_flight = 0;  // Safety: prevent underflow
    }

    // LEDBAT congestion control - use real delay measurement
    if (bytes_acked > 0)
    {
        // Use our measured one-way delay (queuing delay)
        uint our_delay = self.our_hist.get_value();
        self.apply_ledbat((uint)bytes_acked, our_delay);
    }

    // Process based on packet type
    switch (header.packet_type)
    {
        case common::ST_STATE:
            // Pure ACK packet (could be SYN-ACK)
            // Detect SYN-ACK and complete handshake
            if (self.state == ConnectionState.SYN_SENT)
            {
                // This is a SYN-ACK response
                // Update ack_nr from their seq_nr
                self.ack_nr = header.seq_nr;
                // Transition to CONNECTED
                self.transition_to_connected();
                return true;
            }
            // Regular ACK packet
            // Just update ack tracking (no buffer management yet)
            return true;

        case common::ST_DATA:
            // Data packet
            // Accept in-order only
            if (header.seq_nr == (ushort)(self.ack_nr + 1))
            {
                self.ack_nr = header.seq_nr;
                return true;
            }
            return false;  // Out of order, drop for now

        case common::ST_FIN:
            // Graceful close - remote sent FIN
            if (self.state == ConnectionState.CONNECTED || self.state == ConnectionState.FIN_SENT)
            {
                // ACK the FIN
                self.ack_nr = header.seq_nr;

                // Mark that remote sent FIN
                self.remote_fin_received = true;

                // If we haven't sent FIN yet, send our own
                if (self.state == ConnectionState.CONNECTED)
                {
                    // Mark that we'll send FIN in response
                    self.fin_sent = true;
                    self.fin_seq_nr = self.seq_nr;

                    self.transition_to_fin_sent();
                }

                // If both sides sent FIN and buffers are empty, can delete
                if (self.can_delete())
                {
                    self.transition_to_deleting();
                }

                return true;
            }
            return false;

        case common::ST_RESET:
            // Force close with error reason
            self.transition_to_error(ErrorReason.RESET_RECEIVED);

            // Automatic cleanup: If buffers are empty, transition to DELETING
            if (self.can_delete())
            {
                self.transition_to_deleting();
            }

            return true;

        case common::ST_SYN:
            // Duplicate SYN
            return false;
    }

    return false;
}

/**
 * Check if connection has timed out.
 *
 * Simple 30-second timeout.
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
// Application Data Transfer
// ============================================================================

/**
 * Send application data over μTP connection.
 *
 * Splits data into MSS-sized packets automatically.
 *
 * @param data : Application data to send
 * @param socket : Socket to send packets through
 * @return Fault if connection not ready or buffers full
 */
fn void? UtpConnection.send_data(&self, char[] data, socket::UtpSocket* socket) @public
{
    // Check connection state
    if (self.state != ConnectionState.CONNECTED)
    {
        return SEND_NOT_CONNECTED?;
    }

    // Check how much we can send
    uint max_send = self.max_bytes_to_send();
    if (max_send == 0)
    {
        return SEND_BUFFER_FULL?;  // Backpressure
    }

    // Split into MSS-sized packets, respecting window limits
    usz offset = 0;
    usz total_payload_sent = 0;  // Track cumulative payload against remote_window
    const uint HEADER_SIZE = 20;  // μTP header is 20 bytes

    while (offset < data.len)
    {
        // Calculate chunk size (limited by MSS, remaining data, and remaining remote window)
        usz remaining_data = data.len - offset;
        usz remaining_rwnd = (self.remote_window > total_payload_sent)
            ? (self.remote_window - total_payload_sent)
            : 0;

        usz chunk_size = min((usz)self.mss, remaining_data);
        chunk_size = min(chunk_size, remaining_rwnd);  // Don't exceed receiver's remaining buffer

        if (chunk_size == 0)
        {
            // No more window space
            break;
        }

        // Check if we can send this packet (header + payload)
        uint packet_size = HEADER_SIZE + (uint)chunk_size;
        if (!self.can_send_packet(packet_size, (uint)chunk_size))
        {
            // Can't send more - hit window limit
            break;
        }

        // Create chunk slice
        char[] chunk = data[offset:chunk_size];

        // Create ST_DATA packet header
        packet::UtpHeader header;
        header.packet_type = common::ST_DATA;
        header.version = 1;
        header.extension = 0;
        header.connection_id = self.send_id;
        header.timestamp_microseconds = (uint)((long)time::now().to_seconds() * 1_000_000);
        header.timestamp_difference_microseconds = self.their_hist.get_value();
        header.wnd_size = self.local_window;
        header.seq_nr = self.seq_nr;
        header.ack_nr = self.ack_nr;

        // Encode packet with payload
        char[] packet_data = packet::encode_packet(&header, chunk);
        uint encoded_size = (uint)packet_data.len;

        // Add to send buffer BEFORE sending (makes a copy for retransmission)
        self.send_buf.add_packet(self.seq_nr, packet_data);

        // Free the original (send buffer has its own copy)
        free(packet_data);

        // Send via socket
        socket.send_packet(self.remote_addr, &header, chunk);

        // Update state
        self.seq_nr++;
        self.bytes_in_flight += encoded_size;
        self.last_send_time = (long)time::now().to_seconds() * 1_000_000;

        offset += chunk_size;
        total_payload_sent += chunk_size;
    }
}

/**
 * Receive application data from the connection.
 *
 * Simple wrapper around receive buffer.
 *
 * @param max_bytes : Maximum bytes to read
 * @return Data received (empty if no data available)
 */
fn char[] UtpConnection.recv_data(&self, usz max_bytes) @public
{
    return self.recv_buf.read(max_bytes);
}

/**
 * Check if received data is available to read.
 *
 * @return true if data is available
 */
fn bool UtpConnection.has_data(&self) @public
{
    return self.recv_buf.has_data();
}

/**
 * Get number of bytes available to read.
 *
 * @return Bytes available in receive buffer
 */
fn usz UtpConnection.bytes_available(&self) @public
{
    return self.recv_buf.bytes_available();
}

/**
 * Calculate maximum bytes we can send right now.
 *
 * Enforces: min(cwnd - bytes_in_flight, remote_window)
 *
 * Note: This returns bytes available for ENTIRE packets (header + payload),
 * not just payload. Callers should account for 20-byte header per packet.
 *
 * @return Maximum bytes that can be sent without violating flow/congestion control
 */
fn uint UtpConnection.max_bytes_to_send(&self) @public
{
    // Can't send more than congestion window allows
    uint cwnd_available = (self.cwnd > self.bytes_in_flight)
        ? (self.cwnd - self.bytes_in_flight)
        : 0;

    // Can't send more than receiver's window allows
    uint rwnd_available = self.remote_window;

    // Take minimum
    return min(cwnd_available, rwnd_available);
}

/**
 * Check if we can send a packet of given size without exceeding windows.
 *
 * @param packet_size : Total packet size (header + payload)
 * @param payload_size : Payload size only
 * @return true if packet can be sent
 */
fn bool UtpConnection.can_send_packet(&self, uint packet_size, uint payload_size) @public
{
    // Check cwnd (compares total packet size)
    if (self.bytes_in_flight + packet_size > self.cwnd)
    {
        return false;
    }

    // Check remote window (compares payload size only - receiver's buffer space)
    if (payload_size > self.remote_window)
    {
        return false;
    }

    return true;
}

// ============================================================================
// LEDBAT Delay-Based Congestion Control
// ============================================================================

/**
 * Check if congestion window is currently saturated.
 *
 * The window is considered saturated if we're using it (bytes in flight
 * plus pending sends approach or exceed the current window size).
 *
 * @return true if window is saturated, false if idle
 */
fn bool UtpConnection.is_cwnd_saturated(&self) @private
{
    // Conservative check: consider saturated if we're using most of the window
    // This prevents cwnd growth when the application isn't sending data
    uint threshold = self.cwnd - self.mss;  // Leave room for 1 packet
    return self.bytes_in_flight >= threshold;
}

/**
 * Apply LEDBAT congestion control algorithm.
 *
 * LEDBAT (Low Extra Delay Background Transport) - BEP 29 Phase 2:
 * - Delay-based congestion control (proactive, not reactive)
 * - Target delay: 100ms (configurable 25-100ms range)
 * - Increases cwnd when delay < target (network has capacity)
 * - Decreases cwnd when delay > target (network congested)
 * - Uses floating-point arithmetic (libutp style, simpler than fixed-point)
 *
 * Based on libutp implementation:
 * /home/tristan/sources/libutp/utp_internal.cpp lines 1622-1738
 *
 * @param bytes_acked : Number of bytes acknowledged
 * @param our_delay : Current one-way delay (microseconds)
 */
fn void UtpConnection.apply_ledbat(&self, usz bytes_acked, uint our_delay) @public
{
    if (bytes_acked == 0) return;

    // Clamp delay to RTT (one-way delay cannot exceed round-trip time)
    if (our_delay > self.min_rtt) {
        our_delay = self.min_rtt;
    }

    // Target delay: 100ms = 100000 microseconds
    const double TARGET_DELAY = 100000.0;
    double target = TARGET_DELAY;

    // How far are we from target? (positive = below target, negative = above)
    double off_target = target - (double)our_delay;

    // LEDBAT formula (libutp style - floating point):
    //   scaled_gain = GAIN_FACTOR * window_factor * delay_factor
    //
    // window_factor: fraction of window this ACK represents
    // delay_factor: how far from target (normalized)
    uint max_window = self.cwnd;
    usz min_bytes = bytes_acked < (usz)max_window ? bytes_acked : (usz)max_window;
    usz max_bytes = bytes_acked > (usz)max_window ? bytes_acked : (usz)max_window;

    double window_factor = (double)min_bytes / (double)max_bytes;
    double delay_factor = off_target / target;

    // Gain factor: 3000 (MAX_CWND_INCREASE_BYTES_PER_RTT from libutp)
    const double GAIN_FACTOR = 3000.0;
    double scaled_gain = GAIN_FACTOR * window_factor * delay_factor;

    // Don't grow window if not saturated (idle connection)
    // Check if we haven't maxed out window in last second
    ulong current_ms = (ulong)time::now().to_seconds() * 1000;
    if (scaled_gain > 0.0 && current_ms - self.last_maxed_out_window > 1000)
    {
        // If more than 1 second since we hit window limit, we're rate-limited
        // (not window-limited), so don't grow window
        if (!self.is_cwnd_saturated()) {
            scaled_gain = 0.0;
        }
    }

    // Calculate new cwnd based on LEDBAT
    uint min_cwnd = self.mss;
    uint ledbat_cwnd = (uint)math::max((double)max_window + scaled_gain, (double)min_cwnd);

    // Slow start vs congestion avoidance
    if (self.slow_start)
    {
        // Slow start: exponential growth (add window_factor * MSS)
        uint ss_cwnd = max_window + (uint)(window_factor * (double)self.mss);

        // Exit slow start if:
        // 1. We exceed ssthresh, OR
        // 2. Delay exceeds 90% of target (conservative early exit)
        if (ss_cwnd > self.ssthresh || our_delay > (uint)(target * 0.9))
        {
            self.slow_start = false;
            self.ssthresh = max_window;  // Set threshold to current window
            self.cwnd = ledbat_cwnd;     // Use LEDBAT cwnd
        }
        else
        {
            // Stay in slow start - use max of slow start and LEDBAT
            self.cwnd = math::max(ss_cwnd, ledbat_cwnd);
        }
    }
    else
    {
        // Congestion avoidance: use LEDBAT cwnd
        self.cwnd = ledbat_cwnd;
    }

    // Clamp to reasonable bounds
    const uint MAX_CWND = 1024 * 1024;  // 1MB maximum
    self.cwnd = (uint)math::clamp(self.cwnd, min_cwnd, MAX_CWND);
}

// Removed deprecated on_packet_acked() wrapper function
// All callers now use apply_ledbat() directly with real delay measurements

/**
 * Handle packet timeout - decrease cwnd.
 *
 * Phase 1: AIMD multiplicative decrease (backward compatibility)
 * Phase 2: TODO - Integrate LEDBAT timeout recovery
 */
fn void UtpConnection.on_timeout(&self) @public
{
    // Multiplicative decrease: cut window in half (AIMD behavior)
    self.cwnd /= 2;

    // Never go below 1 MSS
    if (self.cwnd < self.mss)
    {
        self.cwnd = self.mss;
    }

    // TODO: When fully integrating LEDBAT delay measurement,
    // replace with LEDBAT timeout recovery:
    //   self.ssthresh = self.cwnd / 2;
    //   self.cwnd = self.mss;
    //   self.slow_start = true;
}

// ============================================================================
// Cleanup
// ============================================================================

/**
 * Close connection gracefully.
 *
 * Transitions to appropriate cleanup state based on current state.
 * Safe to call multiple times (idempotent).
 */
fn void UtpConnection.close(&self) @public
{
    // Already closing or closed - idempotent
    if (self.state == ConnectionState.DELETING ||
        self.state == ConnectionState.NONE ||
        self.state == ConnectionState.FIN_SENT)
    {
        return;
    }

    // If in error state, transition to deleting
    if (self.state == ConnectionState.ERROR_WAIT)
    {
        self.transition_to_deleting();
        return;
    }

    // If connected, initiate graceful close
    if (self.state == ConnectionState.CONNECTED)
    {
        self.initiate_close();
        return;
    }

    // For other states (SYN_SENT), just mark for deletion
    self.transition_to_deleting();
}

/**
 * Free connection resources.
 *
 * Enhanced to handle all states safely.
 * Call close() first for graceful cleanup, then free() to release memory.
 */
fn void UtpConnection.free(&self) @public
{
    self.send_buf.free();

    self.recv_buf.free();

    free(self);
}
