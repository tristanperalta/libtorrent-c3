module libtorrent_test::mocks::mock_peer_discovery;

import libtorrent::ports::peer_discovery;
import libtorrent::common;

<*
 * MockPeerDiscovery
 * =================
 * Test double for PeerDiscovery interface.
 *
 * Features:
 * - Records all method calls for verification
 * - Allows configuring canned responses
 * - Simulates discovery success/failure
 * - Tracks callback invocations
 *
 * Usage:
 *   MockPeerDiscovery* mock = create();
 *   mock.set_peers_to_return(test_peers);
 *   mock.set_should_succeed(true);
 *
 *   // Use as PeerDiscovery interface
 *   peer_discovery::PeerDiscovery* discovery = (peer_discovery::PeerDiscovery*)mock;
 *   discovery.start_discovery(...);
 *
 *   // Verify behavior
 *   assert(mock.start_discovery_called);
 *   assert(mock.start_discovery_call_count == 1);
 *>

// MockPeerDiscovery struct
struct MockPeerDiscovery (peer_discovery::PeerDiscovery)
{
    // Configuration
    common::SocketAddress[] peers_to_return;
    bool should_succeed;
    String error_message_to_return;
    String name_to_return;

    // Call tracking
    bool start_discovery_called;
    uint start_discovery_call_count;
    bool stop_discovery_called;
    uint stop_discovery_call_count;
    bool get_stats_called;
    uint get_stats_call_count;
    bool is_active_called;
    uint is_active_call_count;
    bool get_name_called;
    uint get_name_call_count;

    // Last call parameters
    common::InfoHash last_info_hash;
    peer_discovery::DiscoveryOptions last_options;

    // Callbacks stored
    peer_discovery::PeerDiscoveredCallback peer_callback;
    peer_discovery::DiscoveryCompleteCallback complete_callback;
    void* user_data;

    // State
    bool active;
    peer_discovery::DiscoveryStats stats;
}

// ============================================================================
// Factory
// ============================================================================

<*
 * Create a MockPeerDiscovery instance.
 *
 * @return "MockPeerDiscovery instance"
 *>
fn MockPeerDiscovery* create() @public
{
    MockPeerDiscovery* mock = mem::new(MockPeerDiscovery);

    // Default configuration
    mock.peers_to_return = {};
    mock.should_succeed = true;
    mock.error_message_to_return = "";
    mock.name_to_return = "mock";

    // Initialize call tracking
    mock.start_discovery_called = false;
    mock.start_discovery_call_count = 0;
    mock.stop_discovery_called = false;
    mock.stop_discovery_call_count = 0;
    mock.get_stats_called = false;
    mock.get_stats_call_count = 0;
    mock.is_active_called = false;
    mock.is_active_call_count = 0;
    mock.get_name_called = false;
    mock.get_name_call_count = 0;

    mock.peer_callback = null;
    mock.complete_callback = null;
    mock.user_data = null;

    mock.active = false;

    // Initialize stats
    mock.stats.total_peers_discovered = 0;
    mock.stats.total_discovery_attempts = 0;
    mock.stats.successful_attempts = 0;
    mock.stats.failed_attempts = 0;
    mock.stats.last_discovery_time = 0;
    mock.stats.average_response_time_ms = 0.0;
    mock.stats.active_peers = 0;

    return mock;
}

<*
 * Create a MockPeerDiscovery as a PeerDiscovery interface pointer.
 * Use this when you need to pass the mock to code expecting interface pointers.
 *
 * @return "PeerDiscovery interface pointer to mock"
 *>
fn peer_discovery::PeerDiscovery* create_as_interface() @public
{
    MockPeerDiscovery* mock = create();
    return (peer_discovery::PeerDiscovery*)mock;
}

// ============================================================================
// Configuration Methods
// ============================================================================

<*
 * Set the peers that will be returned by discovery.
 *
 * @param peers : "Array of peers to return"
 *>
fn void MockPeerDiscovery.set_peers_to_return(&self, common::SocketAddress[] peers) @public
{
    self.peers_to_return = peers;
}

<*
 * Set whether discovery should succeed or fail.
 *
 * @param should_succeed : "True for success, false for failure"
 *>
fn void MockPeerDiscovery.set_should_succeed(&self, bool should_succeed) @public
{
    self.should_succeed = should_succeed;
}

<*
 * Set the error message to return on failure.
 *
 * @param message : "Error message"
 *>
fn void MockPeerDiscovery.set_error_message(&self, String message) @public
{
    self.error_message_to_return = message;
}

<*
 * Set the name to return from get_name().
 *
 * @param name : "Discovery source name"
 *>
fn void MockPeerDiscovery.set_name(&self, String name) @public
{
    self.name_to_return = name;
}

// ============================================================================
// Verification Methods
// ============================================================================

<*
 * Reset all call tracking.
 *>
fn void MockPeerDiscovery.reset_call_tracking(&self) @public
{
    self.start_discovery_called = false;
    self.start_discovery_call_count = 0;
    self.stop_discovery_called = false;
    self.stop_discovery_call_count = 0;
    self.get_stats_called = false;
    self.get_stats_call_count = 0;
    self.is_active_called = false;
    self.is_active_call_count = 0;
    self.get_name_called = false;
    self.get_name_call_count = 0;
}

<*
 * Manually trigger the peer discovered callback.
 * Useful for testing async behavior.
 *
 * @param peers : "Peers to report as discovered"
 * @param source : "Discovery source name"
 *>
fn void MockPeerDiscovery.trigger_peer_callback(&self,
                                                  common::SocketAddress[] peers,
                                                  String source) @public
{
    if (self.peer_callback)
    {
        self.peer_callback(peers, source, self.user_data);
    }
}

<*
 * Manually trigger the discovery complete callback.
 * Useful for testing async behavior.
 *
 * @param success : "Whether discovery succeeded"
 * @param error_message : "Error message if failed"
 *>
fn void MockPeerDiscovery.trigger_complete_callback(&self,
                                                      bool success,
                                                      String error_message) @public
{
    if (self.complete_callback)
    {
        self.complete_callback(success, error_message, self.user_data);
    }
}

// ============================================================================
// PeerDiscovery Interface Implementation
// ============================================================================

fn void MockPeerDiscovery.start_discovery(
    &self,
    common::InfoHash* info_hash,
    peer_discovery::DiscoveryOptions* options,
    peer_discovery::PeerDiscoveredCallback peer_callback,
    peer_discovery::DiscoveryCompleteCallback complete_callback,
    void* user_data
) @dynamic
{
    // Track call
    self.start_discovery_called = true;
    self.start_discovery_call_count++;

    // Store parameters
    self.last_info_hash = *info_hash;
    self.last_options = *options;
    self.peer_callback = peer_callback;
    self.complete_callback = complete_callback;
    self.user_data = user_data;

    // Update state
    self.active = true;
    self.stats.total_discovery_attempts++;

    // Simulate discovery (synchronous for simplicity in tests)
    if (self.should_succeed)
    {
        // Call peer callback if we have peers
        if (self.peers_to_return.len > 0 && peer_callback)
        {
            peer_callback(self.peers_to_return, self.name_to_return, user_data);
        }

        // Update stats
        self.stats.successful_attempts++;
        self.stats.total_peers_discovered += self.peers_to_return.len;

        // Call complete callback
        if (complete_callback)
        {
            complete_callback(true, "", user_data);
        }
    }
    else
    {
        // Update stats
        self.stats.failed_attempts++;

        // Call complete callback with error
        if (complete_callback)
        {
            complete_callback(false, self.error_message_to_return, user_data);
        }
    }
}

fn void MockPeerDiscovery.stop_discovery(&self) @dynamic
{
    self.stop_discovery_called = true;
    self.stop_discovery_call_count++;
    self.active = false;
}

fn peer_discovery::DiscoveryStats MockPeerDiscovery.get_stats(&self) @dynamic
{
    self.get_stats_called = true;
    self.get_stats_call_count++;
    return self.stats;
}

fn bool MockPeerDiscovery.is_active(&self) @dynamic
{
    self.is_active_called = true;
    self.is_active_call_count++;
    return self.active;
}

fn String MockPeerDiscovery.get_name(&self) @dynamic
{
    self.get_name_called = true;
    self.get_name_call_count++;
    return self.name_to_return;
}

fn void MockPeerDiscovery.free(&self) @dynamic
{
    free(self);
}
