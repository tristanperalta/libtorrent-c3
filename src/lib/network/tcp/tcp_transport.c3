/**
 * TCP Transport Adapter
 *
 * Implements the Transport interface for TCP connections.
 * Wraps async::tcp::TcpConnection from c3io library.
 */

module libtorrent::network::tcp;

import libtorrent::network;
import async::tcp;
import async::event_loop;
import std::io;

/**
 * TCP transport implementation.
 *
 * Wraps async::tcp::TcpConnection and implements Transport interface.
 */
struct TcpTransport (Transport)
{
    tcp::TcpConnection* tcp;      // Underlying TCP connection
    event_loop::EventLoop* loop;  // Event loop for async operations

    // User callbacks
    network::ConnectCallback connect_cb;
    void* connect_user_data;

    network::AllocCallback alloc_cb;
    network::ReadCallback read_cb;
    void* read_user_data;
}

// ============================================================================
// Factory Function
// ============================================================================

/**
 * Create a new TCP transport.
 *
 * @param loop Event loop for async operations
 * @return New TcpTransport instance (caller must free)
 */
fn TcpTransport* create(event_loop::EventLoop* loop) @public
{
    TcpTransport* transport = mem::new(TcpTransport);
    transport.loop = loop;
    transport.tcp = null;
    return transport;
}

// ============================================================================
// Internal Callbacks (adapt TCP callbacks to Transport callbacks)
// ============================================================================

/**
 * Internal TCP connect callback - adapts to Transport callback signature.
 */
fn void on_tcp_connect(tcp::TcpConnection* conn, int status, void* user_data)
{
    TcpTransport* transport = (TcpTransport*)user_data;
    transport.tcp = conn;

    // Invoke user callback with Transport interface fat pointer
    if (transport.connect_cb)
    {
        transport.connect_cb((Transport)transport, status, transport.connect_user_data);
    }
}

/**
 * Internal TCP alloc callback - adapts to Transport callback signature.
 */
fn char[] on_tcp_alloc(tcp::TcpConnection* conn, usz suggested_size, void* user_data)
{
    TcpTransport* transport = (TcpTransport*)user_data;

    // Invoke user callback with Transport interface fat pointer
    if (transport.alloc_cb)
    {
        return transport.alloc_cb((Transport)transport, suggested_size, transport.read_user_data);
    }

    // Fallback: allocate default buffer
    return mem::new_array(char, suggested_size);
}

/**
 * Internal TCP read callback - adapts to Transport callback signature.
 */
fn void on_tcp_read(tcp::TcpConnection* conn, char[] data, void* user_data)
{
    TcpTransport* transport = (TcpTransport*)user_data;

    // Invoke user callback with Transport interface fat pointer
    if (transport.read_cb)
    {
        transport.read_cb((Transport)transport, data, transport.read_user_data);
    }
}

// ============================================================================
// Transport Interface Implementation
// ============================================================================

fn void? TcpTransport.connect(&self, String host, ushort port, network::ConnectCallback callback, void* user_data) @dynamic
{
    // Store user callback
    self.connect_cb = callback;
    self.connect_user_data = user_data;

    // Initiate TCP connection (adapter callback will invoke user callback)
    tcp::TcpConnection*? tcp_opt = tcp::connect(self.loop, host, port, &on_tcp_connect, self);

    if (catch excuse = tcp_opt)
    {
        return excuse?;
    }

    // Connection initiated successfully (callback will be invoked async)
    self.tcp = tcp_opt;
}

fn void? TcpTransport.start_read(&self, network::AllocCallback alloc_cb, network::ReadCallback read_cb, void* user_data) @dynamic
{
    if (self.tcp == null)
    {
        io::eprintn("TcpTransport.start_read: No TCP connection");
        return;
    }

    // Store user callbacks
    self.alloc_cb = alloc_cb;
    self.read_cb = read_cb;
    self.read_user_data = user_data;

    // Start reading from TCP connection (adapter callbacks will invoke user callbacks)
    return self.tcp.start_read(&on_tcp_alloc, &on_tcp_read, self);
}

fn void? TcpTransport.write(&self, char[] data, network::WriteCallback callback, void* user_data) @dynamic
{
    if (self.tcp == null)
    {
        io::eprintn("TcpTransport.write: No TCP connection");
        return;
    }

    // For write, we need a wrapper callback to adapt the signature
    // TCP write callback: fn void(TcpConnection*, int, void*)
    // Transport write callback: fn void(Transport*, int, void*)

    // Store callback info in a heap-allocated context
    WriteContext* ctx = mem::new(WriteContext);
    ctx.transport = self;
    ctx.callback = callback;
    ctx.user_data = user_data;

    return self.tcp.write(data, &on_tcp_write, ctx);
}

fn void TcpTransport.close(&self) @dynamic
{
    if (self.tcp)
    {
        self.tcp.close();
        self.tcp = null;
    }
}

fn bool TcpTransport.is_connected(&self) @dynamic
{
    return self.tcp != null;
}

// ============================================================================
// Write Context (for adapting write callbacks)
// ============================================================================

struct WriteContext
{
    TcpTransport* transport;
    network::WriteCallback callback;
    void* user_data;
}

/**
 * Internal TCP write callback - adapts to Transport callback signature.
 */
fn void on_tcp_write(tcp::TcpConnection* conn, int status, void* user_data)
{
    WriteContext* ctx = (WriteContext*)user_data;

    // Invoke user callback with Transport interface fat pointer
    if (ctx.callback)
    {
        ctx.callback((Transport)ctx.transport, status, ctx.user_data);
    }

    // Free context
    free(ctx);
}

// ============================================================================
// Cleanup
// ============================================================================

/**
 * Free TCP transport resources.
 *
 * Note: Must call close() before free().
 */
fn void TcpTransport.free(&self) @public
{
    if (self.tcp)
    {
        io::eprintn("WARNING: TcpTransport.free() called without close()");
        self.tcp.close();
    }

    free(self);
}
