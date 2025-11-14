module libtorrent_test::test_composite_peer_discovery;

import libtorrent::ports::peer_discovery;
import libtorrent::adapters::composite_peer_discovery;
import libtorrent_test::mocks::mock_peer_discovery;
import libtorrent::common;
import libtorrent::logger;
import std::io;

// ============================================================================
// Test Helpers
// ============================================================================

struct TestContext
{
    bool peer_callback_called;
    usz total_peers_received;
    bool complete_callback_called;
    bool last_success;
}

fn void on_test_peers(common::SocketAddress[] peers, String source, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.peer_callback_called = true;
    ctx.total_peers_received += peers.len;
}

fn void on_test_complete(bool success, String error, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.complete_callback_called = true;
    ctx.last_success = success;
}

// ============================================================================
// Composite Creation Tests
// ============================================================================

fn void test_create_empty_composite() @test
{
    defer logger::free_logger();

    composite_peer_discovery::CompositePeerDiscovery* composite =
        composite_peer_discovery::create();
    defer composite.free();

    assert(composite != null, "Should create composite");
    assert(composite.get_source_count() == 0, "Should have no sources initially");
    assert(!composite.is_active(), "Should not be active initially");
}

// ============================================================================
// Source Management Tests
// ============================================================================

fn void test_add_single_source() @test
{
    defer logger::free_logger();

    composite_peer_discovery::CompositePeerDiscovery* composite =
        composite_peer_discovery::create();
    defer composite.free();

    // Create mock source
    mock_peer_discovery::MockPeerDiscovery* mock = mock_peer_discovery::create();

    mock.set_name("test-mock");

    // Add as interface
    peer_discovery::PeerDiscovery source = (peer_discovery::PeerDiscovery)mock;
    composite.add_source(source);

    assert(composite.get_source_count() == 1, "Should have 1 source");
}

fn void test_add_multiple_sources() @test
{
    defer logger::free_logger();

    composite_peer_discovery::CompositePeerDiscovery* composite =
        composite_peer_discovery::create();
    defer composite.free();

    // Create multiple mock sources
    mock_peer_discovery::MockPeerDiscovery* mock1 = mock_peer_discovery::create();
    mock1.set_name("mock1");
    mock_peer_discovery::MockPeerDiscovery* mock2 = mock_peer_discovery::create();
    mock2.set_name("mock2");
    mock_peer_discovery::MockPeerDiscovery* mock3 = mock_peer_discovery::create();
    mock3.set_name("mock3");

    // Add all sources
    composite.add_source((peer_discovery::PeerDiscovery)mock1);
    composite.add_source((peer_discovery::PeerDiscovery)mock2);
    composite.add_source((peer_discovery::PeerDiscovery)mock3);

    assert(composite.get_source_count() == 3, "Should have 3 sources");
}

// ============================================================================
// Discovery Start Tests
// ============================================================================

fn void test_start_discovery_no_sources() @test
{
    defer logger::free_logger();

    composite_peer_discovery::CompositePeerDiscovery* composite =
        composite_peer_discovery::create();
    defer composite.free();

    TestContext ctx;
    ctx.peer_callback_called = false;
    ctx.complete_callback_called = false;

    common::InfoHash info_hash;
    for (int i = 0; i < 20; i++) info_hash[i] = (char)i;

    peer_discovery::DiscoveryOptions options = peer_discovery::default_options();

    composite.start_discovery(
        &info_hash,
        &options,
        &on_test_peers,
        &on_test_complete,
        &ctx
    );

    // Should call complete callback with failure when no sources
    assert(ctx.complete_callback_called, "Complete callback should be called");
    assert(!ctx.last_success, "Should fail with no sources");
}

fn void test_start_discovery_with_sources() @test
{
    defer logger::free_logger();

    composite_peer_discovery::CompositePeerDiscovery* composite =
        composite_peer_discovery::create();
    defer composite.free();

    // Create and configure mock source
    mock_peer_discovery::MockPeerDiscovery* mock = mock_peer_discovery::create();
    mock.set_name("test-mock");
    mock.set_should_succeed(true);

    common::SocketAddress[2] test_peers;
    test_peers[0] = common::create_ipv4_address(192, 168, 1, 100, 6881);
    test_peers[1] = common::create_ipv4_address(192, 168, 1, 101, 6882);
    mock.set_peers_to_return(test_peers[..]);

    // Add source to composite
    composite.add_source((peer_discovery::PeerDiscovery)mock);

    TestContext ctx;
    ctx.peer_callback_called = false;
    ctx.total_peers_received = 0;
    ctx.complete_callback_called = false;

    common::InfoHash info_hash;
    for (int i = 0; i < 20; i++) info_hash[i] = (char)i;

    peer_discovery::DiscoveryOptions options = peer_discovery::default_options();

    composite.start_discovery(
        &info_hash,
        &options,
        &on_test_peers,
        &on_test_complete,
        &ctx
    );

    // Composite should now be active
    assert(composite.is_active(), "Composite should be active after start");

    // Mock should have been called
    assert(mock.start_discovery_called, "Mock start_discovery should be called");
}

fn void test_prevent_double_start() @test
{
    defer logger::free_logger();

    composite_peer_discovery::CompositePeerDiscovery* composite =
        composite_peer_discovery::create();
    defer composite.free();

    // Add a mock source
    mock_peer_discovery::MockPeerDiscovery* mock = mock_peer_discovery::create();
    mock.set_should_succeed(true);
    composite.add_source((peer_discovery::PeerDiscovery)mock);

    TestContext ctx;
    ctx.peer_callback_called = false;
    ctx.complete_callback_called = false;

    common::InfoHash info_hash;
    for (int i = 0; i < 20; i++) info_hash[i] = (char)i;

    peer_discovery::DiscoveryOptions options = peer_discovery::default_options();

    // Start discovery first time
    composite.start_discovery(&info_hash, &options, &on_test_peers, &on_test_complete, &ctx);
    assert(composite.is_active(), "Should be active after first start");
    assert(mock.start_discovery_call_count == 1, "Mock should be called once");

    // Try to start again - should be rejected
    composite.start_discovery(&info_hash, &options, &on_test_peers, &on_test_complete, &ctx);
    assert(mock.start_discovery_call_count == 1, "Mock should still only be called once");
}

// ============================================================================
// Discovery Stop Tests
// ============================================================================

fn void test_stop_discovery() @test
{
    defer logger::free_logger();

    composite_peer_discovery::CompositePeerDiscovery* composite =
        composite_peer_discovery::create();
    defer composite.free();

    // Add mock source
    mock_peer_discovery::MockPeerDiscovery* mock = mock_peer_discovery::create();
    mock.set_should_succeed(true);
    composite.add_source((peer_discovery::PeerDiscovery)mock);

    // Start discovery
    TestContext ctx;
    common::InfoHash info_hash;
    peer_discovery::DiscoveryOptions options = peer_discovery::default_options();
    composite.start_discovery(&info_hash, &options, &on_test_peers, &on_test_complete, &ctx);

    assert(composite.is_active(), "Should be active");
    assert(mock.start_discovery_called);

    // Stop discovery
    composite.stop_discovery();

    assert(!composite.is_active(), "Should not be active after stop");
    assert(mock.stop_discovery_called, "Mock stop should be called");
}

// ============================================================================
// Stats Aggregation Tests
// ============================================================================

fn void test_aggregated_stats_empty() @test
{
    defer logger::free_logger();

    composite_peer_discovery::CompositePeerDiscovery* composite =
        composite_peer_discovery::create();
    defer composite.free();

    peer_discovery::DiscoveryStats stats = composite.get_stats();

    assert(stats.total_peers_discovered == 0);
    assert(stats.total_discovery_attempts == 0);
    assert(stats.successful_attempts == 0);
    assert(stats.failed_attempts == 0);
}

fn void test_aggregated_stats_single_source() @test
{
    defer logger::free_logger();

    composite_peer_discovery::CompositePeerDiscovery* composite =
        composite_peer_discovery::create();
    defer composite.free();

    // Create mock with stats
    mock_peer_discovery::MockPeerDiscovery* mock = mock_peer_discovery::create();
    mock.set_should_succeed(true);

    common::SocketAddress[5] test_peers;
    for (int i = 0; i < 5; i++)
    {
        test_peers[i] = common::create_ipv4_address(192, 168, 1, (char)(100 + i), 6881);
    }
    mock.set_peers_to_return(test_peers[..]);

    composite.add_source((peer_discovery::PeerDiscovery)mock);

    // Start discovery to generate stats
    TestContext ctx;
    common::InfoHash info_hash;
    peer_discovery::DiscoveryOptions options = peer_discovery::default_options();
    composite.start_discovery(&info_hash, &options, &on_test_peers, &on_test_complete, &ctx);

    // Get aggregated stats
    peer_discovery::DiscoveryStats stats = composite.get_stats();

    // Should reflect mock's stats
    assert(stats.total_peers_discovered == 5, "Should have 5 peers from mock");
    assert(stats.successful_attempts == 1, "Should have 1 successful attempt");
}
