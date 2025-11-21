module libtorrent_test::test_peer_discovery;

import libtorrent::discovery;
import libtorrent::discovery::composite;
import libtorrent_test::mocks::mock_peer_discovery;
import libtorrent::common;
import std::io;

// ============================================================================
// Test Helpers
// ============================================================================

// Context for callback testing
struct CallbackContext
{
    bool peer_callback_called;
    uint peer_callback_count;
    usz total_peers_received;
    String last_discovery_source;

    bool complete_callback_called;
    uint complete_callback_count;
    bool last_success;
    String last_error_message;
}

fn void on_test_peers_discovered(common::SocketAddress[] peers,
                                   String discovery_source,
                                   void* user_data)
{
    CallbackContext* ctx = (CallbackContext*)user_data;
    ctx.peer_callback_called = true;
    ctx.peer_callback_count++;
    ctx.total_peers_received += peers.len;
    ctx.last_discovery_source = discovery_source;
}

fn void on_test_discovery_complete(bool success,
                                     String error_message,
                                     void* user_data)
{
    CallbackContext* ctx = (CallbackContext*)user_data;
    ctx.complete_callback_called = true;
    ctx.complete_callback_count++;
    ctx.last_success = success;
    ctx.last_error_message = error_message;
}

fn CallbackContext* create_callback_context()
{
    CallbackContext* ctx = mem::new(CallbackContext);
    ctx.peer_callback_called = false;
    ctx.peer_callback_count = 0;
    ctx.total_peers_received = 0;
    ctx.last_discovery_source = "";
    ctx.complete_callback_called = false;
    ctx.complete_callback_count = 0;
    ctx.last_success = false;
    ctx.last_error_message = "";
    return ctx;
}

// ============================================================================
// Mock PeerDiscovery Tests
// ============================================================================

fn void test_mock_peer_discovery_creation() @test
{
    mock_peer_discovery::MockPeerDiscovery* mock = mock_peer_discovery::create();
    defer free(mock);

    assert(!mock.start_discovery_called);
    assert(mock.start_discovery_call_count == 0);
    assert(!mock.active);
    assert(mock.name_to_return == "mock");
}

fn void test_mock_peer_discovery_start_success() @test
{
    mock_peer_discovery::MockPeerDiscovery* mock = mock_peer_discovery::create();
    defer free(mock);

    // Configure mock
    common::SocketAddress[2] test_peers;
    test_peers[0] = common::create_ipv4_address(192, 168, 1, 100, 6881);
    test_peers[1] = common::create_ipv4_address(192, 168, 1, 101, 6882);
    mock.set_peers_to_return(test_peers[..]);
    mock.set_should_succeed(true);

    // Setup callback context
    CallbackContext* ctx = create_callback_context();
    defer free(ctx);

    // Start discovery - call directly on mock, not through interface
    common::InfoHash info_hash;
    for (int i = 0; i < 20; i++) info_hash[i] = (char)i;

    discovery::DiscoveryOptions options = discovery::default_options();

    mock.start_discovery(
        &info_hash,
        &options,
        &on_test_peers_discovered,
        &on_test_discovery_complete,
        ctx
    );

    // Verify calls
    assert(mock.start_discovery_called, "start_discovery should be called");
    assert(mock.start_discovery_call_count == 1);
    assert(mock.active, "Mock should be active");

    // Verify callbacks were invoked
    assert(ctx.peer_callback_called, "Peer callback should be called");
    assert(ctx.total_peers_received == 2, "Should receive 2 peers");
    assert(ctx.complete_callback_called, "Complete callback should be called");
    assert(ctx.last_success, "Discovery should succeed");

    // Verify stats
    discovery::DiscoveryStats stats = mock.get_stats();
    assert(stats.total_discovery_attempts == 1);
    assert(stats.successful_attempts == 1);
    assert(stats.total_peers_discovered == 2);
}

fn void test_mock_peer_discovery_start_failure() @test
{
    mock_peer_discovery::MockPeerDiscovery* mock = mock_peer_discovery::create();
    defer free(mock);

    // Configure mock to fail
    mock.set_should_succeed(false);
    mock.set_error_message("Test error");

    // Setup callback context
    CallbackContext* ctx = create_callback_context();
    defer free(ctx);

    // Start discovery
    common::InfoHash info_hash;
    discovery::DiscoveryOptions options = discovery::default_options();

    mock.start_discovery(
        &info_hash,
        &options,
        &on_test_peers_discovered,
        &on_test_discovery_complete,
        ctx
    );

    // Verify failure
    assert(ctx.complete_callback_called, "Complete callback should be called");
    assert(!ctx.last_success, "Discovery should fail");
    assert(ctx.last_error_message == "Test error");

    // Verify no peers received
    assert(!ctx.peer_callback_called, "Peer callback should not be called on failure");

    // Verify stats
    discovery::DiscoveryStats stats = mock.get_stats();
    assert(stats.failed_attempts == 1);
    assert(stats.total_peers_discovered == 0);
}

fn void test_mock_peer_discovery_stop() @test
{
    mock_peer_discovery::MockPeerDiscovery* mock = mock_peer_discovery::create();
    defer free(mock);

    // Start then stop
    common::InfoHash info_hash;
    discovery::DiscoveryOptions options = discovery::default_options();

    mock.start_discovery(&info_hash, &options, null, null, null);

    assert(mock.active, "Should be active after start");

    mock.stop_discovery();

    assert(mock.stop_discovery_called, "stop_discovery should be called");
    assert(!mock.active, "Should not be active after stop");
}

fn void test_mock_peer_discovery_manual_callbacks() @test
{
    mock_peer_discovery::MockPeerDiscovery* mock = mock_peer_discovery::create();
    defer free(mock);

    // Setup callback context
    CallbackContext* ctx = create_callback_context();
    defer free(ctx);

    // Start discovery (with empty peers)
    common::InfoHash info_hash;
    discovery::DiscoveryOptions options = discovery::default_options();

    mock.start_discovery(
        &info_hash,
        &options,
        &on_test_peers_discovered,
        &on_test_discovery_complete,
        ctx
    );

    // Reset context
    ctx.peer_callback_called = false;
    ctx.complete_callback_called = false;

    // Manually trigger callbacks
    common::SocketAddress[1] manual_peers;
    manual_peers[0] = common::create_ipv4_address(10, 0, 0, 1, 8080);

    mock.trigger_peer_callback(manual_peers[..], "test");
    assert(ctx.peer_callback_called, "Manual peer callback should work");
    assert(ctx.total_peers_received == 1);
    assert(ctx.last_discovery_source == "test");

    mock.trigger_complete_callback(true, "");
    assert(ctx.complete_callback_called, "Manual complete callback should work");
}

fn void test_mock_get_name() @test
{
    mock_peer_discovery::MockPeerDiscovery* mock = mock_peer_discovery::create();
    defer free(mock);

    mock.set_name("custom_mock");
    String name = mock.get_name();
    assert(name == "custom_mock", "Should return custom name");
}

// ============================================================================
// Composite PeerDiscovery Tests
// ============================================================================
// NOTE: Composite is tested through integration in download_session.c3
// C3's interface system makes it difficult to test with mocks in unit tests

// ============================================================================
// Default Options Tests
// ============================================================================

fn void test_default_discovery_options() @test
{
    discovery::DiscoveryOptions options = discovery::default_options();

    assert(options.discovery_interval_ms > 0, "Interval should be positive");
    assert(options.min_discovery_interval_ms > 0, "Min interval should be positive");
    assert(options.discovery_timeout_ms > 0, "Timeout should be positive");
    assert(options.max_peers_wanted > 0, "Max peers wanted should be positive");
    assert(options.max_total_peers > 0, "Max total peers should be positive");

    // Verify min <= regular interval
    assert(options.min_discovery_interval_ms <= options.discovery_interval_ms,
           "Min interval should be <= regular interval");

    // Verify defaults match BEP specifications
    assert(options.max_peers_wanted == 50, "Default should be 50 per BEP 3");
    assert(options.discovery_interval_ms == 1800000, "Default should be 30 minutes");
}

fn void test_discovery_options_fields() @test
{
    discovery::DiscoveryOptions options = discovery::default_options();

    // Test that all expected fields exist and have reasonable defaults
    assert(options.local_port == 6881, "Default port should be 6881");
    assert(options.enable_ipv4, "IPv4 should be enabled by default");
    assert(options.enable_ipv6, "IPv6 should be enabled by default");
    assert(options.respect_private_flag, "Should respect private flag by default");
    assert(options.dht_k_value == 8, "DHT k-value should be 8 per BEP 5");
    assert(options.dht_alpha == 3, "DHT alpha should be 3 per BEP 5");
}
