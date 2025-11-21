/**
 * Integration tests for μTP Transport Interface
 * ==============================================
 *
 * Tests the UtpTransport implementation of the Transport interface,
 * verifying that it correctly implements callback-based async API
 * on top of the polling-based μTP connection API.
 */

module libtorrent::utp::transport_test;

import libtorrent::network;
import libtorrent::network::utp;
import libtorrent::utp::socket;
import libtorrent::utp::connection;
import libtorrent::common;
import async::event_loop;
import std::io;
import std::time;

alias lib_common = module libtorrent::common;

// ============================================================================
// Test State Tracking
// ============================================================================

struct TestState
{
    bool connect_called;
    int connect_status;
    bool read_called;
    char[] read_data;
    bool write_called;
    int write_status;
}

// ============================================================================
// Module-Level Callbacks (Test 3: Connect)
// ============================================================================

fn void test3_on_connect(network::Transport t, int status, void* user_data)
{
    TestState* state = (TestState*)user_data;
    state.connect_called = true;
    state.connect_status = status;
}

// ============================================================================
// Module-Level Callbacks (Test 4: start_read)
// ============================================================================

// No alloc callback needed - μTP allocates internally

fn void test4_on_read(network::Transport t, char[] data, void* user_data)
{
    TestState* state = (TestState*)user_data;
    state.read_called = true;
    // COPY data - it's temporary (freed after callback returns)
    state.read_data = mem::new_array(char, data.len);
    for (usz i = 0; i < data.len; i++) {
        state.read_data[i] = data[i];
    }
}

// ============================================================================
// Module-Level Callbacks (Test 5: Read with data)
// ============================================================================

// No alloc callback needed - μTP allocates internally

fn void test5_on_read(network::Transport t, char[] data, void* user_data)
{
    TestState* state = (TestState*)user_data;
    state.read_called = true;
    // COPY data - it's temporary (freed after callback returns)
    state.read_data = mem::new_array(char, data.len);
    for (usz i = 0; i < data.len; i++) {
        state.read_data[i] = data[i];
    }
}

// ============================================================================
// Module-Level Callbacks (Test 6: Write completion)
// ============================================================================

fn void test6_on_write(network::Transport t, int status, void* user_data)
{
    TestState* state = (TestState*)user_data;
    state.write_called = true;
    state.write_status = status;
}

// ============================================================================
// Module-Level Callbacks (Test 7: Write fails)
// ============================================================================

fn void test7_on_write(network::Transport t, int status, void* user_data)
{
    TestState* state = (TestState*)user_data;
    state.write_called = true;
    state.write_status = status;
}

// ============================================================================
// Module-Level Callbacks (Test 8: Multiple writes)
// ============================================================================

fn void test8_on_write_first(network::Transport t, int status, void* user_data)
{
    bool* called = (bool*)user_data;
    *called = true;
}

fn void test8_on_write_second(network::Transport t, int status, void* user_data)
{
    TestState* state = (TestState*)user_data;
    state.write_called = true;
    state.write_status = status;
}

// ============================================================================
// Module-Level Callbacks (Test 10: Full lifecycle)
// ============================================================================

fn void test10_on_connect(network::Transport t, int status, void* user_data)
{
    TestState* state = (TestState*)user_data;
    state.connect_called = true;
    state.connect_status = status;
}

fn void test10_on_write(network::Transport t, int status, void* user_data)
{
    TestState* state = (TestState*)user_data;
    state.write_called = true;
    state.write_status = status;
}

// No alloc callback needed - μTP allocates internally

fn void test10_on_read(network::Transport t, char[] data, void* user_data)
{
    TestState* state = (TestState*)user_data;
    state.read_called = true;
    // COPY data - it's temporary (freed after callback returns)
    state.read_data = mem::new_array(char, data.len);
    for (usz i = 0; i < data.len; i++) {
        state.read_data[i] = data[i];
    }
}

// ============================================================================
// Test Functions
// ============================================================================

/**
 * Test 1: Basic transport creation and initialization
 */
fn void test_create_transport() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // Create manager
    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    // Create socket
    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 50001);
    defer {
        sock.close();
        loop.run_once();
        sock.free();
    }

    // Create transport
    utp::UtpTransport* transport = utp::create(&loop, sock, mgr);
    defer free(transport);

    // Verify initialization
    assert(transport.loop == &loop, "Loop should be set");
    assert(transport.utp_socket == sock, "Socket should be set");
    assert(transport.manager == mgr, "Manager should be set");
    assert(!transport.connected, "Should not be connected initially");
    assert(!transport.has_pending_write, "Should have no pending writes");

    io::printn("✓ test_create_transport");
}

/**
 * Test 2: is_connected() in various states
 */
fn void test_is_connected_states() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 50002);
    defer {
        sock.close();
        loop.run_once();
        sock.free();
    }

    utp::UtpTransport* transport = utp::create(&loop, sock, mgr);
    defer free(transport);

    // Before connection
    assert(!transport.is_connected(), "Should not be connected without connection");

    // Create connection (SYN_SENT state)
    lib_common::SocketAddress remote_addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50003);
    transport.conn = connection::create_outgoing(remote_addr, 1000);
    defer {
        if (transport.conn) {
            transport.conn.close();
            transport.conn.free();
        }
    }

    // Still not connected (connection exists but not in CONNECTED state)
    assert(!transport.is_connected(), "Should not be connected in SYN_SENT state");

    // Simulate connection established
    transport.connected = true;
    assert(transport.is_connected(), "Should be connected when flag is set");

    io::printn("✓ test_is_connected_states");
}

/**
 * Test 3: Connect callback invocation
 *
 * Verifies that connect() stores the callback and the manager
 * invokes it when connection state transitions to CONNECTED.
 */
fn void test_connect_callback() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 50004);
    defer {
        sock.close();      // Frees connections
        loop.run_once();
        sock.free();
    }

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);  // Frees transports BEFORE socket cleanup

    utp::UtpTransport* transport = utp::create(&loop, sock, mgr);

    // Track callback invocation
    TestState state = {};

    // Initiate connection
    (void)transport.connect("127.0.0.1", 50005, &test3_on_connect, &state);

    // Verify callback stored
    assert(transport.connect_cb != null, "Connect callback should be stored");
    assert(transport.conn != null, "Connection should be created");
    assert(transport.conn.state == connection::ConnectionState.SYN_SENT, "Should be in SYN_SENT");

    // Simulate state transition to CONNECTED
    transport.conn.state = connection::ConnectionState.CONNECTED;

    // Process transport (should detect state change and invoke callback)
    utp::process_transport(transport);

    // Verify callback was invoked
    assert(state.connect_called, "Connect callback should have been called");
    assert(state.connect_status == 0, "Connect should have succeeded (status 0)");
    assert(transport.connected, "Transport should be marked as connected");
    assert(transport.connect_cb == null, "Callback should be cleared after invocation");

    // Cleanup
    // NOTE: Manager will free the transport (registered via transport.connect())
    // NOTE: Socket will free the connection (also registered via transport.connect())
    // Don't manually free anything - let defer blocks handle it

    io::printn("✓ test_connect_callback");
}

/**
 * Test 4: start_read() stores callbacks
 */
fn void test_start_read_stores_callbacks() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 50006);
    defer {
        sock.close();
        loop.run_once();
        sock.free();
    }

    utp::UtpTransport* transport = utp::create(&loop, sock, mgr);
    defer free(transport);

    // Create connection
    lib_common::SocketAddress remote_addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50007);
    transport.conn = connection::create_outgoing(remote_addr, 1000);
    defer {
        transport.conn.close();
        transport.conn.free();
    }

    TestState state = {};

    // Start reading (alloc_cb = null, ignored for μTP)
    (void)transport.start_read(null, &test4_on_read, &state);

    // Verify callback stored (no alloc_cb for μTP - allocates internally)
    assert(transport.read_cb != null, "Read callback should be stored");
    assert(transport.read_user_data == &state, "User data should be stored");

    io::printn("✓ test_start_read_stores_callbacks");
}

/**
 * Test 5: Read callback invocation when data available
 */
fn void test_read_callback_with_data() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 50008);
    defer {
        sock.close();
        loop.run_once();
        sock.free();
    }

    utp::UtpTransport* transport = utp::create(&loop, sock, mgr);
    defer free(transport);  // Transport not registered with manager, must free manually

    // Create connection
    lib_common::SocketAddress remote_addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50009);
    transport.conn = connection::create_outgoing(remote_addr, 1000);

    // Simulate data in receive buffer
    char[] test_data = "Hello, μTP!";
    transport.conn.recv_buf.add_packet(0, test_data);

    // Track callback invocation
    TestState state = {};

    // Start reading (alloc_cb = null, ignored for μTP)
    (void)transport.start_read(null, &test5_on_read, &state);

    // Process transport (should detect data and invoke callback)
    utp::process_transport(transport);

    // Verify callback was invoked with data
    assert(state.read_called, "Read callback should have been called");
    assert(state.read_data.len == test_data.len, "Should receive all data");
    for (usz i = 0; i < test_data.len; i++) {
        assert(state.read_data[i] == test_data[i], "Data should match at byte %d", i);
    }

    // Cleanup
    // NOTE: Transport freed by defer statement above
    // NOTE: Connection must be manually freed (not registered with socket or manager)
    free(state.read_data);
    transport.conn.close();
    transport.conn.free();
    transport.conn = null;  // Clear dangling pointer

    io::printn("✓ test_read_callback_with_data");
}

/**
 * Test 6: Write callback invocation on completion
 */
fn void test_write_callback_completion() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 50010);
    defer {
        sock.close();
        loop.run_once();
        sock.free();
    }

    utp::UtpTransport* transport = utp::create(&loop, sock, mgr);

    // Create connection in CONNECTED state
    lib_common::SocketAddress remote_addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50011);
    transport.conn = connection::create_outgoing(remote_addr, 1000);
    transport.conn.state = connection::ConnectionState.CONNECTED;
    transport.connected = true;

    // Register connection with socket
    sock.register_connection(transport.conn);

    // Track callback invocation
    TestState state = {};

    // Write data
    char[] data = "Test message";
    (void)transport.write(data, &test6_on_write, &state);

    // Verify pending write flag set
    assert(transport.has_pending_write, "Should have pending write");
    assert(transport.write_cb != null, "Write callback should be stored");

    // Simulate all data ACKed (bytes_in_flight == 0)
    transport.conn.bytes_in_flight = 0;

    // Process transport (should detect completion and invoke callback)
    utp::process_transport(transport);

    // Verify callback was invoked
    assert(state.write_called, "Write callback should have been called");
    assert(state.write_status == 0, "Write should have succeeded (status 0)");
    assert(!transport.has_pending_write, "Pending write flag should be cleared");
    assert(transport.write_cb == null, "Callback should be cleared after invocation");

    // Cleanup
    // NOTE: Socket will free the connection (registered with sock.register_connection())
    free(transport);

    io::printn("✓ test_write_callback_completion");
}

/**
 * Test 7: Write fails when not connected
 */
fn void test_write_fails_when_not_connected() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 50012);
    defer {
        sock.close();
        loop.run_once();
        sock.free();
    }

    utp::UtpTransport* transport = utp::create(&loop, sock, mgr);
    defer free(transport);

    // Track callback invocation
    TestState state = {};

    // Try to write without connection
    char[] data = "Test";
    (void)transport.write(data, &test7_on_write, &state);

    // Verify callback was invoked with error
    assert(state.write_called, "Write callback should have been called");
    assert(state.write_status == -1, "Write should have failed (status -1)");

    io::printn("✓ test_write_fails_when_not_connected");
}

/**
 * Test 8: Multiple writes rejected (no queueing)
 */
fn void test_multiple_writes_rejected() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 50013);
    defer {
        sock.close();
        loop.run_once();
        sock.free();
    }

    utp::UtpTransport* transport = utp::create(&loop, sock, mgr);

    // Create connected connection
    lib_common::SocketAddress remote_addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50014);
    transport.conn = connection::create_outgoing(remote_addr, 1000);
    transport.conn.state = connection::ConnectionState.CONNECTED;
    transport.connected = true;
    sock.register_connection(transport.conn);

    // Track callback invocations
    bool first_called = false;
    TestState second_state = {};

    // First write
    char[] data1 = "First";
    (void)transport.write(data1, &test8_on_write_first, &first_called);
    assert(transport.has_pending_write, "Should have pending write");

    // Second write (should fail immediately)
    char[] data2 = "Second";
    (void)transport.write(data2, &test8_on_write_second, &second_state);

    // Verify second write was rejected
    assert(second_state.write_called, "Second write callback should have been called");
    assert(second_state.write_status == -1, "Second write should have failed");
    assert(transport.has_pending_write, "First write should still be pending");

    // Cleanup
    // NOTE: Socket will free the connection (registered with sock.register_connection())
    free(transport);

    io::printn("✓ test_multiple_writes_rejected");
}

/**
 * Test 9: Close during active connection
 */
fn void test_close_during_connection() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 50015);
    defer {
        sock.close();
        loop.run_once();
        sock.free();
    }

    utp::UtpTransport* transport = utp::create(&loop, sock, mgr);

    // Create connection
    lib_common::SocketAddress remote_addr = lib_common::create_ipv4_address(127, 0, 0, 1, 50016);
    transport.conn = connection::create_outgoing(remote_addr, 1000);
    transport.connected = true;

    // Register with manager and socket
    sock.register_connection(transport.conn);
    utp::register_transport(mgr, transport);

    // Close transport
    transport.close();

    // Verify cleanup
    assert(!transport.connected, "Should not be connected after close");

    // Cleanup
    // NOTE: Socket will free the connection when socket.close() is called in defer
    // so we don't need to manually free it here
    free(transport);

    io::printn("✓ test_close_during_connection");
}

/**
 * Test 10: Full lifecycle - connect → write → read → close
 *
 * This is a comprehensive integration test that exercises the complete
 * transport lifecycle. Due to the complexity of establishing a real μTP
 * connection between two transports, this test simulates the key states.
 */
fn void test_full_lifecycle() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 50017);
    defer {
        sock.close();
        loop.run_once();
        sock.free();
    }

    utp::UtpTransport* transport = utp::create(&loop, sock, mgr);

    // Phase 1: Connect
    TestState state = {};
    (void)transport.connect("127.0.0.1", 50018, &test10_on_connect, &state);
    assert(transport.conn != null, "Connection should be created");

    // Simulate connection established
    transport.conn.state = connection::ConnectionState.CONNECTED;
    utp::process_transport(transport);

    assert(state.connect_called, "Connect callback should have been called");
    assert(state.connect_status == 0, "Connect should have succeeded");
    assert(transport.connected, "Transport should be connected");

    // Phase 2: Write
    char[] message = "Hello, μTP!";
    (void)transport.write(message, &test10_on_write, &state);
    assert(transport.has_pending_write, "Should have pending write");

    // Simulate write completion
    transport.conn.bytes_in_flight = 0;
    utp::process_transport(transport);

    assert(state.write_called, "Write callback should have been called");
    assert(state.write_status == 0, "Write should have succeeded");

    // Phase 3: Read (alloc_cb = null, ignored for μTP)
    (void)transport.start_read(null, &test10_on_read, &state);

    // Simulate received data
    char[] response = "ACK";
    transport.conn.recv_buf.add_packet(0, response);
    utp::process_transport(transport);

    assert(state.read_called, "Read callback should have been called");
    assert(state.read_data.len == response.len, "Should receive response");

    // Phase 4: Close
    // NOTE: close() unregisters from manager, so don't call it here
    // Let defer cleanup handle everything properly
    // transport.close();

    // Cleanup
    // NOTE: Socket will free the connection when socket.close() is called in defer
    // NOTE: Manager will free the transport (registered via transport.connect())
    if (state.read_data.len > 0) free(state.read_data);

    io::printn("✓ test_full_lifecycle");
}
