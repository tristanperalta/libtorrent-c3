module libtorrent::utp::timeout;

import libtorrent::utp::connection;
import libtorrent::utp::socket;
import libtorrent::utp::packet;
import async::timer;
import async::event_loop;
import std::time;
import std::io;
import std::collections::list;

<*
 μTP Timeout Manager
 ===================

 Handles timeout detection and retransmission for reliable packet delivery.

 Implementation:
 - Fixed 1-second timeout (no RTT estimation)
 - Exponential backoff on retransmission
 - Max 5 retries per packet
 - Connection failure after max retries exceeded

 Architecture:
 - Single global timer checks all connections every 250ms
 - Iterates through connections and their send buffers
 - Retransmits timed-out packets or fails connection

 Future:
 - Dynamic RTT-based timeout calculation
 - Minimum/maximum timeout bounds
 - Fast retransmit (duplicate ACK detection)
*>

// ============================================================================
// Constants
// ============================================================================

const uint INITIAL_TIMEOUT_MS = 1000;          // 1 second initial timeout
const uint TIMEOUT_CHECK_INTERVAL_MS = 250;    // Check 4x per second
const char MAX_RETRANSMISSIONS = 5;            // Give up after 5 retries

// ============================================================================
// Timeout Manager Structure
// ============================================================================

/**
 * Timeout manager - handles timeout detection and retransmission.
 *
 * Uses a single timer to periodically check all connections for timed-out packets.
 */
struct TimeoutManager
{
    uint timeout_ms;                    // Fixed 1000ms in Phase 1
    event_loop::EventLoop* loop;        // Event loop for timer
    timer::Timer* check_timer;          // Periodic timeout checker
    socket::UtpSocket* socket;          // Socket containing connections to check
}

// ============================================================================
// Creation and Lifecycle
// ============================================================================

/**
 * Create a timeout manager.
 *
 * @param loop : Event loop for timer integration
 * @return New timeout manager (caller must free)
 */
fn TimeoutManager*? create(event_loop::EventLoop* loop) @public
{
    TimeoutManager* mgr = mem::new(TimeoutManager);
    mgr.timeout_ms = INITIAL_TIMEOUT_MS;
    mgr.loop = loop;
    mgr.check_timer = null;
    mgr.socket = null;

    return mgr;
}

/**
 * Start timeout checking for a socket.
 *
 * Creates a periodic timer that checks all connections in the socket.
 *
 * @param socket : Socket containing connections to monitor
 */
fn void TimeoutManager.start(&self, socket::UtpSocket* socket) @public
{
    self.socket = socket;

    // Create timer if not already created
    if (!self.check_timer)
    {
        timer::Timer*? timer_result = timer::create(self.loop);
        if (catch err = timer_result)
        {
            io::eprintn("Failed to create timeout timer");
            return;
        }
        self.check_timer = timer_result;
    }

    // Start periodic timeout checking
    self.check_timer.start(
        TIMEOUT_CHECK_INTERVAL_MS,   // Initial delay
        TIMEOUT_CHECK_INTERVAL_MS,   // Repeat interval
        &on_timeout_check,
        (void*)self
    );
}

/**
 * Stop timeout checking (async close).
 *
 * IMPORTANT: Follow async close pattern from SHUTDOWN_LEAKS.md
 * - Call close() to queue async close
 * - Run event loop to drain callbacks
 * - Then call free() to release memory
 */
fn void TimeoutManager.stop(&self) @public
{
    if (self.check_timer)
    {
        self.check_timer.close();  // Async close (not free()!)
        self.check_timer = null;
    }
}

/**
 * Free timeout manager resources.
 *
 * Note: Call stop() first, drain event loop, then call this.
 */
fn void TimeoutManager.free(&self) @public
{
    free(self);
}

// ============================================================================
// Timeout Detection
// ============================================================================

/**
 * Check if a packet has timed out.
 *
 * @param pkt : Packet to check
 * @param timeout_ms : Timeout value in milliseconds
 * @return true if packet has timed out
 */
fn bool is_packet_timeout(connection::SentPacket* pkt, uint timeout_ms) @public
{
    long now = (long)time::now().to_seconds() * 1_000_000;
    long elapsed_usec = now - pkt.send_time;
    long timeout_usec = (long)timeout_ms * 1000;

    return elapsed_usec > timeout_usec;
}

/**
 * Calculate timeout for a packet based on transmission count.
 *
 * Implements exponential backoff:
 * - Transmission 0: 1000ms
 * - Transmission 1: 2000ms
 * - Transmission 2: 4000ms
 * - Transmission 3: 8000ms
 * - Transmission 4: 16000ms
 *
 * @param base_timeout : Base timeout value (1000ms in Phase 1)
 * @param num_transmissions : Number of times packet has been sent
 * @return Timeout value in milliseconds
 */
fn uint timeout_for_transmission(uint base_timeout, char num_transmissions) @public
{
    return base_timeout * (1 << num_transmissions);
}

// ============================================================================
// Timeout Checking (Timer Callback)
// ============================================================================

/**
 * Periodic timer callback - checks all connections for timeouts.
 *
 * @param timer : Timer that fired
 * @param user_data : TimeoutManager pointer
 */
fn void on_timeout_check(timer::Timer* timer, void* user_data)
{
    TimeoutManager* mgr = (TimeoutManager*)user_data;

    if (!mgr.socket) return;

    // Iterate all connections in the socket
    mgr.socket.connections.@each(; ushort conn_id, connection::UtpConnection* conn)
    {
        check_connection_timeouts(mgr, conn);
    };
}

/**
 * Check all packets in a connection for timeouts.
 *
 * @param mgr : Timeout manager
 * @param conn : Connection to check
 */
fn void check_connection_timeouts(TimeoutManager* mgr, connection::UtpConnection* conn) @private
{
    // Skip connections not in data transfer state
    if (conn.state != connection::ConnectionState.CONNECTED &&
        conn.state != connection::ConnectionState.FIN_SENT)
    {
        return;
    }

    // Build list of timed-out packets first (buffer may change during retransmit)
    List{ushort} timed_out_seqs;
    timed_out_seqs.init(mem);
    defer timed_out_seqs.free();

    foreach (pkt : conn.send_buf.packets)
    {
        uint packet_timeout = timeout_for_transmission(mgr.timeout_ms, pkt.num_transmissions);

        if (is_packet_timeout(pkt, packet_timeout))
        {
            timed_out_seqs.push(pkt.seq_nr);
        }
    }

    // Retransmit timed-out packets
    foreach (seq_nr : timed_out_seqs)
    {
        connection::SentPacket*? pkt_opt = conn.send_buf.get_packet(seq_nr);
        if (catch err = pkt_opt)
        {
            // Packet already ACKed during this iteration
            continue;
        }

        handle_packet_timeout(mgr, conn, pkt_opt);
    }
}

// ============================================================================
// Retransmission Logic
// ============================================================================

/**
 * Handle a timed-out packet - retransmit or fail connection.
 *
 * @param mgr : Timeout manager
 * @param conn : Connection containing the packet
 * @param pkt : Timed-out packet
 */
fn void handle_packet_timeout(TimeoutManager* mgr, connection::UtpConnection* conn,
                               connection::SentPacket* pkt) @public
{
    // Check if max retries exceeded
    if (pkt.num_transmissions >= MAX_RETRANSMISSIONS)
    {
        // Connection failed - too many retries
        conn.transition_to_error(connection::ErrorReason.TIMEOUT);

        // Transition to DELETING if buffers empty
        if (conn.can_delete())
        {
            conn.transition_to_deleting();
        }

        return;
    }

    // Increment retry counter
    pkt.num_transmissions++;

    // AIMD congestion control - decrease cwnd on timeout
    conn.on_timeout();

    // Update send time for next timeout check
    pkt.send_time = (long)time::now().to_seconds() * 1_000_000;

    // Decode packet header from stored data
    packet::UtpHeader? header_result = packet::decode_packet(pkt.data);
    if (catch err = header_result)
    {
        // Corrupted packet data - shouldn't happen
        io::eprintfn("Failed to decode packet for retransmission: seq=%d", pkt.seq_nr);
        return;
    }
    packet::UtpHeader header = header_result;

    // Extract payload (everything after 20-byte header)
    char[] payload = packet::get_payload(pkt.data);

    // Resend packet via socket
    mgr.socket.send_packet(conn.remote_addr, &header, payload);
}
