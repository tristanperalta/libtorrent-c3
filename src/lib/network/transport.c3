/**
 * Transport Interface - Abstraction for network protocols (TCP, μTP)
 *
 * This interface allows PeerConnection to work with different transport protocols
 * without coupling to specific implementations. Follows hexagonal architecture
 * principles where the domain logic (PeerConnection) depends on the port
 * (Transport interface), not on adapters (TcpTransport, UtpTransport).
 *
 * Implementations:
 * - TcpTransport: TCP-based transport (src/lib/network/tcp/tcp_transport.c3)
 * - UtpTransport: μTP-based transport (src/lib/network/utp/utp_transport.c3)
 */

module libtorrent::network;

import async::event_loop;

// ============================================================================
// Callback Type Definitions
// ============================================================================

/**
 * Callback invoked when connection attempt completes.
 *
 * @param transport The transport connection (NULL if failed)
 * @param status 0 on success, negative error code on failure
 * @param user_data User-provided context pointer
 */
alias ConnectCallback = fn void(Transport* transport, int status, void* user_data);

/**
 * Callback to allocate buffer for incoming data.
 *
 * @param transport The transport connection
 * @param suggested_size Suggested buffer size (may allocate different size)
 * @param user_data User-provided context pointer
 * @return Buffer to receive data into
 */
alias AllocCallback = fn char[](Transport* transport, usz suggested_size, void* user_data);

/**
 * Callback invoked when data is received.
 *
 * @param transport The transport connection
 * @param data Received data (view into buffer from AllocCallback)
 * @param user_data User-provided context pointer
 */
alias ReadCallback = fn void(Transport* transport, char[] data, void* user_data);

/**
 * Callback invoked when write operation completes.
 *
 * @param transport The transport connection
 * @param status 0 on success, negative error code on failure
 * @param user_data User-provided context pointer
 */
alias WriteCallback = fn void(Transport* transport, int status, void* user_data);

// ============================================================================
// Transport Interface
// ============================================================================

/**
 * Transport interface for network connections.
 *
 * Provides a unified API for both TCP and μTP connections, allowing
 * PeerConnection to work with either protocol transparently.
 *
 * Lifecycle:
 * 1. Create: Use factory functions (tcp_transport::create or utp_transport::create)
 * 2. Connect: Call connect() with callback
 * 3. Use: Call start_read() and write() for data transfer
 * 4. Close: Call close() when done
 * 5. Free: Caller must free the transport struct after close
 *
 * Thread Safety: Not thread-safe. All operations must be on event loop thread.
 */
interface Transport
{
    /**
     * Initiate connection to remote host.
     *
     * Asynchronous operation - callback will be invoked when complete.
     *
     * @param host Hostname or IP address
     * @param port Port number
     * @param callback Function to call when connection completes
     * @param user_data Context pointer passed to callback
     * @return Optional error if operation fails to start
     */
    fn void? connect(String host, ushort port, ConnectCallback callback, void* user_data);

    /**
     * Start reading data from connection.
     *
     * Registers callbacks for allocating buffers and receiving data.
     * Read callback will be invoked repeatedly as data arrives.
     *
     * @param alloc_cb Callback to allocate receive buffer
     * @param read_cb Callback to process received data
     * @param user_data Context pointer passed to callbacks
     * @return Optional error if operation fails to start
     */
    fn void? start_read(AllocCallback alloc_cb, ReadCallback read_cb, void* user_data);

    /**
     * Write data to connection.
     *
     * Asynchronous operation - callback will be invoked when complete.
     * Data buffer must remain valid until callback is invoked.
     *
     * @param data Data to send (must remain valid until callback)
     * @param callback Function to call when write completes
     * @param user_data Context pointer passed to callback
     * @return Optional error if operation fails to start
     */
    fn void? write(char[] data, WriteCallback callback, void* user_data);

    /**
     * Close the connection.
     *
     * After calling close(), the transport should not be used for further
     * operations. However, the transport struct itself must still be freed
     * by the caller.
     */
    fn void close();

    /**
     * Check if connection is established.
     *
     * @return true if connected, false otherwise
     */
    fn bool is_connected();
}
