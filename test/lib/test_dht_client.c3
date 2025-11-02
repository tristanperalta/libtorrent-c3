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

// Helper function to create a test IP address
fn common::Ipv4Addr create_test_ip(char a, char b, char c, char d)
{
    common::Ipv4Addr ip;
    ip[0] = a;
    ip[1] = b;
    ip[2] = c;
    ip[3] = d;
    return ip;
}

// ============================================================================
// Basic DHT Client Tests
// ============================================================================

fn void test_create_dht_client() @test
{
    common::NodeId our_id = create_test_node_id(0x42);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0);
    defer client.free();

    // Verify our ID was copied
    for (usz i = 0; i < 20; i++)
    {
        assert(client.our_id[i] == our_id[i], "Our ID should match");
    }

    // Verify initial state
    assert(client.routing_table != null, "Routing table should be created");
    assert(client.rpc_manager != null, "RPC manager should be created");
    assert(client.state == dht_client::DhtState.UNINITIALIZED, "Should start uninitialized");

    io::printn("✓ Create DHT client");
}

fn void test_get_state() @test
{
    common::NodeId our_id = create_test_node_id(0x50);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0);
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
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0);
    defer client.free();

    common::Ipv4Addr ip = create_test_ip(192, 168, 1, 1);
    bool added = client.add_bootstrap_node( ip, 6881);
    assert(added, "Should add bootstrap node");

    assert(client.bootstrap_node_count == 1, "Should have 1 bootstrap node");

    io::printn("✓ Add bootstrap node");
}

fn void test_add_multiple_bootstrap_nodes() @test
{
    common::NodeId our_id = create_test_node_id(0x70);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0);
    defer client.free();

    // Add 5 bootstrap nodes
    for (int i = 0; i < 5; i++)
    {
        common::Ipv4Addr ip = create_test_ip(192, 168, 1, (char)(10 + i));
        bool added = client.add_bootstrap_node( ip, (ushort)(6881 + i));
        assert(added, "Should add bootstrap node");
    }

    assert(client.bootstrap_node_count == 5, "Should have 5 bootstrap nodes");

    io::printn("✓ Add multiple bootstrap nodes");
}

fn void test_add_default_bootstrap_nodes() @test
{
    common::NodeId our_id = create_test_node_id(0x80);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0);
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
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0);
    defer client.free();

    common::NodeId target_id = create_test_node_id(0xA0);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);

    bool sent = client.send_ping( target_id, target_ip, 6881);
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
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0);
    defer client.free();

    common::NodeId target_id = create_test_node_id(0xC0);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);
    common::NodeId search_id = create_test_node_id(0xD0);

    bool sent = client.send_find_node( target_id, target_ip, 6881, search_id);
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
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0);
    defer client.free();

    // Try to bootstrap without adding nodes
    bool bootstrapped = client.bootstrap();
    assert(!bootstrapped, "Should fail to bootstrap without nodes");

    io::printn("✓ Bootstrap: no nodes");
}

fn void test_bootstrap_with_nodes() @test
{
    common::NodeId our_id = create_test_node_id(0xF0);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0);
    defer client.free();

    // Add bootstrap nodes
    common::Ipv4Addr ip = create_test_ip(192, 168, 1, 1);
    client.add_bootstrap_node( ip, 6881);

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
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0);
    defer client.free();

    // Should not be bootstrapped initially
    bool is_boot = client.is_bootstrapped();
    assert(!is_boot, "Should not be bootstrapped initially");

    io::printn("✓ Check if bootstrapped");
}

// ============================================================================
// Statistics Tests
// ============================================================================

fn void test_get_stats() @test
{
    common::NodeId our_id = create_test_node_id(0x22);
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0);
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
    dht_client::DhtClient* client = dht_client::create_dht_client(our_id, null, 0);
    defer client.free();

    // Set state to running
    client.state = dht_client::DhtState.RUNNING;

    // Call tick (should not crash)
    client.tick();

    io::printn("✓ DHT tick");
}
