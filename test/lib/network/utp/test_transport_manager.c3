/**
 * Unit tests for μTP Transport Manager
 * =====================================
 *
 * Tests the centralized manager that coordinates tick-based processing
 * of all active μTP transports.
 */

module libtorrent::utp::transport_manager_test;

import libtorrent::network::utp;
import libtorrent::utp::connection;
import libtorrent::utp::socket;
import libtorrent::common;
import async::event_loop;
import std::io;

alias lib_common = module libtorrent::common;

/**
 * Test 1: Manager creation and initialization
 *
 * Verifies that create_manager() properly initializes all fields.
 */
fn void test_create_manager() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    assert(mgr.loop == &loop, "Loop should be set");
    assert(!mgr.running, "Manager should not be running initially");
    assert(mgr.tick_count == 0, "Tick count should be zero");
    assert(mgr.transports.count == 0, "Should have no transports initially");

    io::printn("✓ test_create_manager");
}

/**
 * Test 2: Start and stop tick timer
 *
 * Verifies that start() creates the timer and stop() cleans it up.
 */
fn void test_start_stop_timer() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    // Start the manager
    utp::start(mgr);
    assert(mgr.running, "Manager should be running after start()");
    assert(mgr.tick_timer != null, "Tick timer should be created");

    // Stop the manager
    utp::stop(mgr);
    assert(!mgr.running, "Manager should not be running after stop()");

    io::printn("✓ test_start_stop_timer");
}

/**
 * Test 3: Register and unregister transport
 *
 * Verifies transport registration and tracking.
 */
fn void test_register_unregister_transport() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    // Create a socket and transport
    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 51000);
    defer {
        sock.close();
        loop.run_once();
        sock.free();
    }

    utp::UtpTransport* transport = utp::create(&loop, sock, mgr);
    defer free(transport);

    // Create a connection for the transport
    lib_common::SocketAddress remote_addr = lib_common::create_ipv4_address(127, 0, 0, 1, 51001);
    transport.conn = connection::create_outgoing(remote_addr, 1000);
    defer {
        if (transport.conn) {
            transport.conn.close();
            transport.conn.free();
        }
    }

    // Register should add to HashMap
    assert(mgr.transports.count == 0, "Should start with no transports");
    utp::register_transport(mgr, transport);
    assert(mgr.transports.count == 1, "Should have 1 transport after register");

    // Unregister should remove from HashMap
    utp::unregister_transport(mgr, transport);
    assert(mgr.transports.count == 0, "Should have 0 transports after unregister");

    io::printn("✓ test_register_unregister_transport");
}

/**
 * Test 4: Tick processing with active transport
 *
 * Verifies that transports can be registered while manager is running.
 */
fn void test_tick_processing() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    // Create transport
    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 51002);
    defer {
        sock.close();
        loop.run_once();
        sock.free();
    }

    utp::UtpTransport* transport = utp::create(&loop, sock, mgr);

    // Create connection
    lib_common::SocketAddress remote_addr = lib_common::create_ipv4_address(127, 0, 0, 1, 51003);
    transport.conn = connection::create_outgoing(remote_addr, 1000);

    // Register transport
    utp::register_transport(mgr, transport);
    assert(mgr.transports.count == 1, "Should have 1 transport registered");

    // Start manager
    utp::start(mgr);
    assert(mgr.running, "Manager should be running");

    // Stop and cleanup
    utp::stop(mgr);
    utp::unregister_transport(mgr, transport);

    transport.conn.close();
    transport.conn.free();
    free(transport);

    io::printn("✓ test_tick_processing");
}

/**
 * Test 5: Multiple transports
 *
 * Verifies manager can handle multiple transports simultaneously.
 */
fn void test_multiple_transports() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    // Create socket
    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 51004);
    defer {
        sock.close();
        loop.run_once();
        sock.free();
    }

    // Create 3 transports with unique connection IDs
    const int NUM_TRANSPORTS = 3;
    utp::UtpTransport*[NUM_TRANSPORTS] transports;

    for (int i = 0; i < NUM_TRANSPORTS; i++)
    {
        transports[i] = utp::create(&loop, sock, mgr);

        lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, (ushort)(52000 + i));
        // Use different seed values to get unique connection IDs
        transports[i].conn = connection::create_outgoing(addr, (ushort)(1000 + i * 100));

        utp::register_transport(mgr, transports[i]);
    }

    assert(mgr.transports.count == NUM_TRANSPORTS, "Should have 3 transports");

    // Cleanup
    for (int i = 0; i < NUM_TRANSPORTS; i++)
    {
        utp::unregister_transport(mgr, transports[i]);
        transports[i].conn.close();
        transports[i].conn.free();
        free(transports[i]);
    }

    assert(mgr.transports.count == 0, "Should have no transports after cleanup");

    io::printn("✓ test_multiple_transports");
}

/**
 * Test 6: Manager cleanup frees all transports
 *
 * Verifies that free_manager() properly cleans up active transports.
 */
fn void test_manager_cleanup_frees_transports() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);

    // Create socket
    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 51005);
    defer {
        sock.close();
        loop.run_once();
        sock.free();
    }

    // Create and register 2 transports with unique connection IDs
    for (int i = 0; i < 2; i++)
    {
        utp::UtpTransport* transport = utp::create(&loop, sock, mgr);

        lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, (ushort)(53000 + i));
        // Use different seed values to get unique connection IDs
        transport.conn = connection::create_outgoing(addr, (ushort)(2000 + i * 100));

        utp::register_transport(mgr, transport);
    }

    assert(mgr.transports.count == 2, "Should have 2 transports");

    // Free manager - should clean up all transports
    utp::free_manager(mgr);

    // If we get here without crash, cleanup worked properly
    io::printn("✓ test_manager_cleanup_frees_transports");
}

/**
 * Test 7: Stop idempotency
 *
 * Verifies that calling stop() multiple times is safe.
 */
fn void test_stop_idempotency() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);
    defer utp::free_manager(mgr);

    // Start and stop multiple times
    utp::start(mgr);
    assert(mgr.running, "Should be running after start");

    utp::stop(mgr);
    assert(!mgr.running, "Should not be running after stop");

    // Second stop should be safe
    utp::stop(mgr);
    assert(!mgr.running, "Should still not be running");

    io::printn("✓ test_stop_idempotency");
}

/**
 * Test 8: Manager without starting
 *
 * Verifies that manager can be freed without ever starting.
 */
fn void test_manager_without_starting() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);

    // Free without starting - should not crash
    utp::free_manager(mgr);

    io::printn("✓ test_manager_without_starting");
}

/**
 * Test 9: Unregister during shutdown
 *
 * Verifies that unregister is safe even after HashMap is freed.
 */
fn void test_unregister_during_shutdown() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);

    socket::UtpSocket* sock = socket::create(&loop)!!;
    sock.bind("127.0.0.1", 51006);
    defer {
        sock.close();
        loop.run_once();
        sock.free();
    }

    // Create transport but don't free it before manager
    utp::UtpTransport* transport = utp::create(&loop, sock, mgr);
    lib_common::SocketAddress addr = lib_common::create_ipv4_address(127, 0, 0, 1, 54000);
    transport.conn = connection::create_outgoing(addr, 1000);
    utp::register_transport(mgr, transport);

    // Free manager - this should handle the transport
    utp::free_manager(mgr);

    // No crash = success
    io::printn("✓ test_unregister_during_shutdown");
}

/**
 * Test 10: Empty manager cleanup
 *
 * Verifies that freeing a manager with no transports works.
 */
fn void test_empty_manager_cleanup() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    utp::UtpTransportManager* mgr = utp::create_manager(&loop);

    assert(mgr.transports.count == 0, "Should have no transports");

    // Free empty manager
    utp::free_manager(mgr);

    io::printn("✓ test_empty_manager_cleanup");
}
