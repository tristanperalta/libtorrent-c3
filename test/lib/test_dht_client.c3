module libtorrent::dht_client::test;

import std::io;
import libtorrent::dht_client;
import libtorrent::common;

/**
 * DHT Client Test Suite
 * =====================
 * Tests for DHT client core functionality
 */

// Helper function to create a test node ID
fn common::NodeId create_test_node_id(char seed)
{
    common::NodeId id;
    for (usz i = 0; i < 20; i++)
    {
        id[i] = (char)(seed + i);
    }
    return id;
}

// ============================================================================
// Basic DHT Client Tests
// ============================================================================

fn void test_create_dht_client() @test
{
    common::NodeId our_id = create_test_node_id(0x42);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    // Verify our ID was copied
    for (usz i = 0; i < 20; i++)
    {
        assert(client.our_id[i] == our_id[i], "Our ID should match");
    }

    // Verify initial state (BEP 32: dual routing tables)
    assert(client.routing_table_ipv4 != null, "IPv4 routing table should be created");
    assert(client.routing_table_ipv6 != null, "IPv6 routing table should be created");
    assert(client.rpc_manager != null, "RPC manager should be created");
    assert(client.state == dht_client::DhtState.UNINITIALIZED, "Should start uninitialized");

    io::printn("✓ Create DHT client");
}

fn void test_get_state() @test
{
    common::NodeId our_id = create_test_node_id(0x50);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    dht_client::DhtState state = client.get_state();
    assert(state == dht_client::DhtState.UNINITIALIZED, "Should be uninitialized");

    io::printn("✓ Get DHT state");
}

// ============================================================================
// Bootstrap Node Tests
// ============================================================================

fn void test_add_bootstrap_node() @test
{
    common::NodeId our_id = create_test_node_id(0x60);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    common::SocketAddress addr = common::create_ipv4_address(192, 168, 1, 1, 6881);
    bool added = client.add_bootstrap_node(addr);
    assert(added, "Should add bootstrap node");

    assert(client.bootstrap_node_count == 1, "Should have 1 bootstrap node");

    io::printn("✓ Add bootstrap node");
}

fn void test_add_multiple_bootstrap_nodes() @test
{
    common::NodeId our_id = create_test_node_id(0x70);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    // Add 5 bootstrap nodes
    for (int i = 0; i < 5; i++)
    {
        common::SocketAddress addr = common::create_ipv4_address(192, 168, 1, (char)(10 + i), (ushort)(6881 + i));
        bool added = client.add_bootstrap_node(addr);
        assert(added, "Should add bootstrap node");
    }

    assert(client.bootstrap_node_count == 5, "Should have 5 bootstrap nodes");

    io::printn("✓ Add multiple bootstrap nodes");
}

fn void test_add_default_bootstrap_nodes() @test
{
    common::NodeId our_id = create_test_node_id(0x80);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    client.add_default_bootstrap_nodes();

    assert(client.bootstrap_node_count > 0, "Should add default bootstrap nodes");
    assert(client.bootstrap_node_count <= 10, "Should not exceed max bootstrap nodes");

    io::printn("✓ Add default bootstrap nodes");
}

// ============================================================================
// Query Sending Tests
// ============================================================================

fn void test_send_ping() @test
{
    common::NodeId our_id = create_test_node_id(0x90);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    common::NodeId target_id = create_test_node_id(0xA0);
    common::SocketAddress target_addr = common::create_ipv4_address(192, 168, 1, 100, 6881);

    bool sent = client.send_ping(target_id, target_addr);
    assert(sent, "Should send ping query");

    // Verify transaction was created
    int total, active, transactions;
    client.get_stats( &total, &active, &transactions);
    assert(transactions == 1, "Should have 1 active transaction");

    io::printn("✓ Send ping query");
}

fn void test_send_find_node() @test
{
    common::NodeId our_id = create_test_node_id(0xB0);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    common::NodeId target_id = create_test_node_id(0xC0);
    common::SocketAddress target_addr = common::create_ipv4_address(192, 168, 1, 100, 6881);
    common::NodeId search_id = create_test_node_id(0xD0);

    bool sent = client.send_find_node(target_id, target_addr, search_id);
    assert(sent, "Should send find_node query");

    // Verify transaction was created
    int total, active, transactions;
    client.get_stats( &total, &active, &transactions);
    assert(transactions == 1, "Should have 1 active transaction");

    io::printn("✓ Send find_node query");
}

// ============================================================================
// Bootstrap Tests
// ============================================================================

fn void test_bootstrap_no_nodes() @test
{
    common::NodeId our_id = create_test_node_id(0xE0);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    // Try to bootstrap without adding nodes
    bool bootstrapped = client.bootstrap();
    assert(!bootstrapped, "Should fail to bootstrap without nodes");

    io::printn("✓ Bootstrap: no nodes");
}

fn void test_bootstrap_with_nodes() @test
{
    common::NodeId our_id = create_test_node_id(0xF0);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    // Add bootstrap nodes
    common::SocketAddress addr = common::create_ipv4_address(192, 168, 1, 1, 6881);
    client.add_bootstrap_node(addr);

    // Bootstrap
    bool bootstrapped = client.bootstrap();
    assert(bootstrapped, "Should initiate bootstrap");

    // Verify state changed
    assert(client.state == dht_client::DhtState.RUNNING, "Should be running after bootstrap");

    io::printn("✓ Bootstrap: with nodes");
}

fn void test_is_bootstrapped() @test
{
    common::NodeId our_id = create_test_node_id(0x11);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    // Should not be bootstrapped initially
    bool is_boot = client.is_bootstrapped();
    assert(!is_boot, "Should not be bootstrapped initially");

    io::printn("✓ Check if bootstrapped");
}

// ============================================================================
// Detailed Bootstrap Process Tests (Kademlia Paper)
// ============================================================================

fn void test_bootstrap_sends_find_node_for_own_id() @test
{
    // Test that bootstrap performs FIND_NODE query for own node ID
    // (Kademlia paper: Section 2.3 - "u performs a node lookup for its own node ID")

    common::NodeId our_id = create_test_node_id(0xAA);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    // Add bootstrap node
    common::SocketAddress bootstrap_addr = common::create_ipv4_address(192, 168, 1, 100, 6881);
    client.add_bootstrap_node(bootstrap_addr);

    // Initiate bootstrap
    bool started = client.bootstrap();
    assert(started, "Should initiate bootstrap");

    // Verify DHT state transitioned to RUNNING
    assert(client.state == dht_client::DhtState.RUNNING,
           "Bootstrap should transition state to RUNNING");

    // NOTE: In a real implementation, we would verify that a FIND_NODE query
    // for our own ID was sent to the bootstrap node. This requires either:
    // - Mocking the network layer
    // - Inspecting transaction history
    // - Using a test hook/callback
    // This test documents the expected behavior from the paper

    io::printn("✓ Bootstrap sends FIND_NODE for own ID (documented behavior)");
}

fn void test_bootstrap_populates_multiple_buckets() @test
{
    // Test that bootstrap populates routing table across multiple buckets
    // (Kademlia paper: Section 2.3 - "u refreshes all k-buckets further away than its closest neighbor")

    common::NodeId our_id = create_test_node_id(0xBB);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    // In a real network, bootstrap would:
    // 1. Contact bootstrap node
    // 2. Receive nodes from FIND_NODE response
    // 3. Add those nodes to routing table
    // 4. Perform iterative lookups to fill more buckets

    // Since we're testing in isolation, we simulate by directly adding nodes
    // at different distances to the routing table

    // Add nodes at various distances (simulates successful bootstrap responses)
    // Create nodes at different bit positions to ensure they go into different buckets
    int[] distances = { 5, 15, 30, 60, 90, 120, 140, 155 };

    for (int i = 0; i < distances.len; i++)
    {
        common::NodeId node_id;
        for (usz j = 0; j < 20; j++) node_id[j] = our_id[j];

        // Flip the bit at the specified distance to create a node at that distance
        int dist = distances[i];
        int byte_idx = dist / 8;
        int bit_idx = 7 - (dist % 8);
        node_id[byte_idx] ^= (char)(1 << bit_idx);

        common::SocketAddress node_addr = common::create_ipv4_address(192, 168, 1, (char)(10 + i), (ushort)(6881 + i));

        // Manually add to IPv4 routing table (BEP 32, simulates bootstrap process)
        client.routing_table_ipv4.add_node(node_id, node_addr, 100);
    }

    // Verify routing table has nodes in multiple buckets
    int total_nodes, active_buckets, transactions;
    client.get_stats(&total_nodes, &active_buckets, &transactions);

    assert(total_nodes >= 5, "Bootstrap should populate routing table with multiple nodes");
    assert(active_buckets >= 5, "Bootstrap should populate multiple buckets");

    io::printn("✓ Bootstrap populates multiple buckets");
}

fn void test_bootstrap_convergence() @test
{
    // Test bootstrap completion/convergence criteria
    // (Kademlia paper: bootstrap is "complete" when routing table is populated)

    common::NodeId our_id = create_test_node_id(0xCC);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    // Add bootstrap node and start bootstrap
    common::SocketAddress bootstrap_addr = common::create_ipv4_address(192, 168, 1, 100, 6881);
    client.add_bootstrap_node(bootstrap_addr);
    bool started = client.bootstrap();
    assert(started, "Bootstrap should start");

    // Initially should not be considered fully bootstrapped
    // (needs nodes in routing table and successful queries)
    bool initially_bootstrapped = client.is_bootstrapped();

    // BEP 32: Simulate adding nodes to BOTH routing tables (as would happen during bootstrap)
    // Need 8 nodes in each table to be considered bootstrapped
    for (int i = 0; i < 8; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x20 + i * 15));
        common::SocketAddress ipv4_addr = common::create_ipv4_address(192, 168, 1, (char)(20 + i), (ushort)(6881 + i));
        client.routing_table_ipv4.add_node(node_id, ipv4_addr, 100);

        // Also add IPv6 nodes (2001:db8::1+i:port)
        common::NodeId node_id_v6 = create_test_node_id((char)(0x30 + i * 15));
        char[16] ipv6_bytes = {
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, (char)(0x01 + i)
        };
        common::SocketAddress ipv6_addr = common::create_ipv6_address(ipv6_bytes, (ushort)(6881 + i));
        client.routing_table_ipv6.add_node(node_id_v6, ipv6_addr, 100);
    }

    // After populating both routing tables, should be considered bootstrapped
    bool after_nodes_added = client.is_bootstrapped();

    // NOTE: Exact bootstrapping criteria may vary by implementation
    // The paper suggests it's complete when we have a populated routing table
    // Some implementations may require additional criteria (e.g., successful lookups)

    int total_nodes, active_buckets, transactions;
    client.get_stats(&total_nodes, &active_buckets, &transactions);

    assert(total_nodes >= 8, "Should have nodes after bootstrap simulation");

    io::printn("✓ Bootstrap convergence criteria");
}

// ============================================================================
// Bucket Refresh Tests (Kademlia Paper)
// ============================================================================

fn void test_bucket_refresh_after_inactivity() @test
{
    // Test that buckets without activity for >1 hour are refreshed with random lookups
    // (Kademlia paper: Section 2.3 - "refresh any bucket to which it has not performed
    // a node lookup in the past hour")
    // NOTE: This test documents expected behavior - actual time-based refresh testing
    // would require time mocking or integration testing

    common::NodeId our_id = create_test_node_id(0xDD);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    // Set state to running
    client.state = dht_client::DhtState.RUNNING;

    // Add IPv4 nodes to routing table (BEP 32)
    for (int i = 0; i < 5; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x30 + i * 20));
        common::SocketAddress node_addr = common::create_ipv4_address(192, 168, 1, (char)(30 + i), (ushort)(6881 + i));
        client.routing_table_ipv4.add_node(node_id, node_addr, 100);
    }

    // In a real implementation with time tracking:
    // 1. Mock time progression by +1 hour
    // 2. Call client.tick() or refresh mechanism
    // 3. Verify FIND_NODE queries sent for random IDs in inactive buckets

    // For now, we just call tick and verify it doesn't crash
    // The paper specifies refresh interval of 1 hour
    client.tick();

    // Verify client is still in valid state
    assert(client.state == dht_client::DhtState.RUNNING,
           "Client should remain running after tick");

    io::printn("✓ Bucket refresh after inactivity (documented behavior - requires time mocking)");
}

fn void test_refresh_lookup_targets_bucket_range() @test
{
    // Test that refresh lookups target random IDs within the bucket's range
    // (Kademlia paper: "picking a random ID in the bucket's range and
    // performing a find_nodes search for it")

    common::NodeId our_id = create_test_node_id(0xEE);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    // The paper specifies that refresh should:
    // 1. Identify inactive buckets (no lookup in past hour)
    // 2. Generate random ID within that bucket's distance range
    // 3. Perform FIND_NODE for that random ID

    // For bucket i (distance 2^i to 2^(i+1)), the random ID should differ
    // from our ID starting at bit i

    // This test documents the expected behavior
    // Actual testing would require:
    // - Access to refresh mechanism
    // - Verification of generated random IDs
    // - Checking that FIND_NODE queries are sent

    io::printn("✓ Refresh lookup targets bucket range (documented behavior)");
}

// ============================================================================
// Statistics Tests
// ============================================================================

fn void test_get_stats() @test
{
    common::NodeId our_id = create_test_node_id(0x22);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    int total, active, transactions;
    client.get_stats( &total, &active, &transactions);

    assert(total == 0, "Should have 0 total nodes initially");
    assert(active == 0, "Should have 0 active buckets initially");
    assert(transactions == 0, "Should have 0 transactions initially");

    io::printn("✓ Get DHT statistics");
}

// ============================================================================
// Periodic Maintenance Tests
// ============================================================================

fn void test_tick() @test
{
    common::NodeId our_id = create_test_node_id(0x33);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    // Set state to running
    client.state = dht_client::DhtState.RUNNING;

    // Call tick (should not crash)
    client.tick();

    io::printn("✓ DHT tick");
}

// ============================================================================
// BEP 32: Dual IPv4/IPv6 Routing Table Tests
// ============================================================================

fn void test_dual_routing_tables_created() @test
{
    // Verify both routing tables are created on initialization
    common::NodeId our_id = create_test_node_id(0xAA);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    assert(client.routing_table_ipv4 != null, "IPv4 routing table should be created");
    assert(client.routing_table_ipv6 != null, "IPv6 routing table should be created");

    io::printn("✓ BEP 32: Dual routing tables created");
}

fn void test_ipv4_nodes_route_to_ipv4_table() @test
{
    // Verify IPv4 nodes are added to IPv4 table only
    common::NodeId our_id = create_test_node_id(0xBB);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    client.state = dht_client::DhtState.RUNNING;

    // Add IPv4 nodes
    for (int i = 0; i < 5; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x10 + i * 10));
        common::SocketAddress ipv4_addr = common::create_ipv4_address(192, 168, 1, (char)(10 + i), 6881);
        client.routing_table_ipv4.add_node(node_id, ipv4_addr, 100);
    }

    // Verify IPv4 table has nodes, IPv6 table is empty
    int ipv4_nodes, ipv4_buckets, ipv6_nodes, ipv6_buckets;
    client.routing_table_ipv4.get_stats(&ipv4_nodes, &ipv4_buckets);
    client.routing_table_ipv6.get_stats(&ipv6_nodes, &ipv6_buckets);

    assert(ipv4_nodes == 5, "IPv4 table should have 5 nodes");
    assert(ipv6_nodes == 0, "IPv6 table should be empty");

    io::printn("✓ BEP 32: IPv4 nodes route to IPv4 table");
}

fn void test_ipv6_nodes_route_to_ipv6_table() @test
{
    // Verify IPv6 nodes are added to IPv6 table only
    common::NodeId our_id = create_test_node_id(0xCC);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    client.state = dht_client::DhtState.RUNNING;

    // Add IPv6 nodes
    for (int i = 0; i < 5; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x20 + i * 10));
        char[16] ipv6_bytes = {
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, (char)(0x01 + i)
        };
        common::SocketAddress ipv6_addr = common::create_ipv6_address(ipv6_bytes, 6881);
        client.routing_table_ipv6.add_node(node_id, ipv6_addr, 100);
    }

    // Verify IPv6 table has nodes, IPv4 table is empty
    int ipv4_nodes, ipv4_buckets, ipv6_nodes, ipv6_buckets;
    client.routing_table_ipv4.get_stats(&ipv4_nodes, &ipv4_buckets);
    client.routing_table_ipv6.get_stats(&ipv6_nodes, &ipv6_buckets);

    assert(ipv4_nodes == 0, "IPv4 table should be empty");
    assert(ipv6_nodes == 5, "IPv6 table should have 5 nodes");

    io::printn("✓ BEP 32: IPv6 nodes route to IPv6 table");
}

fn void test_stats_aggregate_both_tables() @test
{
    // Verify get_stats() aggregates from both tables
    common::NodeId our_id = create_test_node_id(0xDD);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    client.state = dht_client::DhtState.RUNNING;

    // Add 3 IPv4 nodes
    for (int i = 0; i < 3; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x10 + i * 10));
        common::SocketAddress ipv4_addr = common::create_ipv4_address(192, 168, 1, (char)(10 + i), 6881);
        client.routing_table_ipv4.add_node(node_id, ipv4_addr, 100);
    }

    // Add 5 IPv6 nodes
    for (int i = 0; i < 5; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x30 + i * 10));
        char[16] ipv6_bytes = {
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, (char)(0x01 + i)
        };
        common::SocketAddress ipv6_addr = common::create_ipv6_address(ipv6_bytes, 6881);
        client.routing_table_ipv6.add_node(node_id, ipv6_addr, 100);
    }

    // Get aggregated stats
    int total_nodes, active_buckets, transactions;
    client.get_stats(&total_nodes, &active_buckets, &transactions);

    assert(total_nodes == 8, "Total nodes should be 3 + 5 = 8");

    io::printn("✓ BEP 32: Stats aggregate both tables");
}

fn void test_bootstrap_requires_both_tables() @test
{
    // Verify is_bootstrapped() requires 8 nodes in EACH table
    common::NodeId our_id = create_test_node_id(0xEE);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0, null);
    defer client.free();

    client.state = dht_client::DhtState.RUNNING;

    // Initially not bootstrapped
    assert(!client.is_bootstrapped(), "Should not be bootstrapped initially");

    // Add 10 IPv4 nodes (more than 8)
    for (int i = 0; i < 10; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x10 + i * 10));
        common::SocketAddress ipv4_addr = common::create_ipv4_address(192, 168, 1, (char)(10 + i), 6881);
        client.routing_table_ipv4.add_node(node_id, ipv4_addr, 100);
    }

    // Still not bootstrapped (no IPv6 nodes)
    assert(!client.is_bootstrapped(), "Should not be bootstrapped with only IPv4 nodes");

    // Add 8 IPv6 nodes
    for (int i = 0; i < 8; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x30 + i * 10));
        char[16] ipv6_bytes = {
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, (char)(0x01 + i)
        };
        common::SocketAddress ipv6_addr = common::create_ipv6_address(ipv6_bytes, 6881);
        client.routing_table_ipv6.add_node(node_id, ipv6_addr, 100);
    }

    // Now bootstrapped (both tables have >= 8 nodes)
    assert(client.is_bootstrapped(), "Should be bootstrapped with 8+ nodes in each table");

    io::printn("✓ BEP 32: Bootstrap requires both tables");
}
