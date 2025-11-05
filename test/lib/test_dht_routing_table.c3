module libtorrent::dht_routing_table::test;

import std::io;
import libtorrent::dht_routing_table;
import libtorrent::common;

/**
 * DHT Routing Table Test Suite
 * =============================
 * Tests for DHT routing table operations
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
// Basic Routing Table Tests
// ============================================================================

fn void test_create_routing_table() @test
{
    common::NodeId our_id = create_test_node_id(0x10);
    dht_routing_table::RoutingTable* table = dht_routing_table::create_routing_table(our_id, mem);
    defer table.free();

    // Verify our ID was copied correctly
    for (usz i = 0; i < 20; i++)
    {
        assert(table.our_id[i] == our_id[i], "Our ID should match");
    }

    // Verify table is empty
    int total, active;
    table.get_stats( &total, &active);
    assert(total == 0, "New table should have no nodes");
    assert(active == 0, "New table should have no active buckets");

    io::printn("✓ Create routing table");
}

fn void test_distance_exp_identical() @test
{
    common::NodeId id = create_test_node_id(0x20);

    int dist = dht_routing_table::distance_exp(id, id);
    assert(dist == 160, "Distance to self should be 160");

    io::printn("✓ Distance calculation: identical IDs");
}

fn void test_distance_exp_different() @test
{
    common::NodeId id1;
    common::NodeId id2;

    // All zeros
    for (usz i = 0; i < 20; i++)
    {
        id1[i] = 0;
        id2[i] = 0;
    }

    // id2 differs in last bit
    id2[19] = 0x01;

    int dist = dht_routing_table::distance_exp(id1, id2);
    assert(dist == 159, "Should differ in bit 159 (last bit)");

    io::printn("✓ Distance calculation: last bit different");
}

fn void test_distance_exp_first_bit() @test
{
    common::NodeId id1;
    common::NodeId id2;

    for (usz i = 0; i < 20; i++)
    {
        id1[i] = 0;
        id2[i] = 0;
    }

    // id2 differs in first bit
    id2[0] = 0x80;

    int dist = dht_routing_table::distance_exp(id1, id2);
    assert(dist == 0, "Should differ in bit 0 (first bit)");

    io::printn("✓ Distance calculation: first bit different");
}

// ============================================================================
// Node Addition Tests
// ============================================================================

fn void test_add_single_node() @test
{
    common::NodeId our_id = create_test_node_id(0x00);
    dht_routing_table::RoutingTable* table = dht_routing_table::create_routing_table(our_id, mem);
    defer table.free();

    common::NodeId node_id = create_test_node_id(0x10);
    common::Ipv4Addr ip = create_test_ip(192, 168, 1, 100);

    bool added = table.add_node( node_id, ip, 6881, 100);
    assert(added, "Should add first node successfully");

    int total, active;
    table.get_stats( &total, &active);
    assert(total == 1, "Table should have 1 node");
    assert(active == 1, "Table should have 1 active bucket");

    io::printn("✓ Add single node");
}

fn void test_add_multiple_nodes() @test
{
    common::NodeId our_id = create_test_node_id(0x00);
    dht_routing_table::RoutingTable* table = dht_routing_table::create_routing_table(our_id, mem);
    defer table.free();

    // Add 5 different nodes
    for (int i = 0; i < 5; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x10 + i * 10));
        common::Ipv4Addr ip = create_test_ip(192, 168, 1, (char)(100 + i));
        bool added = table.add_node( node_id, ip, (ushort)(6881 + i), 100);
        assert(added, "Should add node successfully");
    }

    int total, active;
    table.get_stats( &total, &active);
    assert(total == 5, "Table should have 5 nodes");

    io::printn("✓ Add multiple nodes");
}

fn void test_add_duplicate_node() @test
{
    common::NodeId our_id = create_test_node_id(0x00);
    dht_routing_table::RoutingTable* table = dht_routing_table::create_routing_table(our_id, mem);
    defer table.free();

    common::NodeId node_id = create_test_node_id(0x10);
    common::Ipv4Addr ip1 = create_test_ip(192, 168, 1, 100);
    common::Ipv4Addr ip2 = create_test_ip(192, 168, 1, 200);

    // Add node first time
    bool added1 = table.add_node( node_id, ip1, 6881, 100);
    assert(added1, "Should add node first time");

    // Add same node ID with different IP (update)
    bool added2 = table.add_node( node_id, ip2, 6882, 150);
    assert(added2, "Should update existing node");

    int total, active;
    table.get_stats( &total, &active);
    assert(total == 1, "Should still have only 1 node (updated)");

    io::printn("✓ Add duplicate node (update)");
}

fn void test_add_our_own_id() @test
{
    common::NodeId our_id = create_test_node_id(0x10);
    dht_routing_table::RoutingTable* table = dht_routing_table::create_routing_table(our_id, mem);
    defer table.free();

    common::Ipv4Addr ip = create_test_ip(127, 0, 0, 1);

    // Try to add our own ID
    bool added = table.add_node( our_id, ip, 6881, 100);
    assert(!added, "Should not add our own ID");

    int total, active;
    table.get_stats( &total, &active);
    assert(total == 0, "Table should remain empty");

    io::printn("✓ Reject our own ID");
}

fn void test_bucket_full() @test
{
    common::NodeId our_id;
    for (usz i = 0; i < 20; i++) our_id[i] = 0;

    dht_routing_table::RoutingTable* table = dht_routing_table::create_routing_table(our_id, mem);
    defer table.free();

    // Add 8 nodes to same bucket (all have first byte = 0xFF, so they go in same bucket)
    for (int i = 0; i < 8; i++)
    {
        common::NodeId node_id;
        for (usz j = 0; j < 20; j++) node_id[j] = 0xFF;
        node_id[19] = (char)i;  // Make each unique

        common::Ipv4Addr ip = create_test_ip(192, 168, 1, (char)(100 + i));
        bool added = table.add_node( node_id, ip, (ushort)(6881 + i), 100);
        assert(added, "Should add node to bucket");
    }

    int total, active;
    table.get_stats( &total, &active);
    assert(total == 8, "Bucket should be full with 8 nodes");

    // Try to add 9th node (bucket full, no failed nodes to replace)
    common::NodeId node9;
    for (usz j = 0; j < 20; j++) node9[j] = 0xFF;
    node9[19] = 0x99;

    common::Ipv4Addr ip9 = create_test_ip(192, 168, 1, 200);
    bool added9 = table.add_node( node9, ip9, 6889, 100);
    assert(!added9, "Should not add 9th node (bucket full)");

    table.get_stats( &total, &active);
    assert(total == 8, "Should still have only 8 nodes");

    io::printn("✓ Bucket full handling");
}

// ============================================================================
// Node Failure Tests
// ============================================================================

fn void test_node_failed() @test
{
    common::NodeId our_id = create_test_node_id(0x00);
    dht_routing_table::RoutingTable* table = dht_routing_table::create_routing_table(our_id, mem);
    defer table.free();

    common::NodeId node_id = create_test_node_id(0x10);
    common::Ipv4Addr ip = create_test_ip(192, 168, 1, 100);

    table.add_node( node_id, ip, 6881, 100);

    // Mark node as failed
    table.node_failed( node_id);

    // Node should still be in table (not removed until timeout count threshold)
    int total, active;
    table.get_stats( &total, &active);
    assert(total == 1, "Failed node should still be in table");

    io::printn("✓ Node failure tracking");
}

fn void test_replace_failed_node() @test
{
    common::NodeId our_id;
    for (usz i = 0; i < 20; i++) our_id[i] = 0;

    dht_routing_table::RoutingTable* table = dht_routing_table::create_routing_table(our_id, mem);
    defer table.free();

    // Add 8 nodes to same bucket
    for (int i = 0; i < 8; i++)
    {
        common::NodeId node_id;
        for (usz j = 0; j < 20; j++) node_id[j] = 0xFF;
        node_id[19] = (char)i;

        common::Ipv4Addr ip = create_test_ip(192, 168, 1, (char)(100 + i));
        table.add_node( node_id, ip, (ushort)(6881 + i), 100);
    }

    // Mark first node as failed 3 times (threshold)
    common::NodeId failed_node;
    for (usz j = 0; j < 20; j++) failed_node[j] = 0xFF;
    failed_node[19] = 0;

    for (int i = 0; i < 3; i++)
    {
        table.node_failed( failed_node);
    }

    // Try to add new node - should replace failed node
    common::NodeId new_node;
    for (usz j = 0; j < 20; j++) new_node[j] = 0xFF;
    new_node[19] = 0xAA;

    common::Ipv4Addr new_ip = create_test_ip(192, 168, 1, 250);
    bool added = table.add_node( new_node, new_ip, 6899, 100);
    assert(added, "Should replace failed node");

    int total, active;
    table.get_stats( &total, &active);
    assert(total == 8, "Should still have 8 nodes");

    io::printn("✓ Replace failed node");
}

// ============================================================================
// Find Closest Nodes Tests
// ============================================================================

fn void test_find_closest_nodes_empty() @test
{
    common::NodeId our_id = create_test_node_id(0x00);
    dht_routing_table::RoutingTable* table = dht_routing_table::create_routing_table(our_id, mem);
    defer table.free();

    common::NodeId target = create_test_node_id(0x50);
    dht_routing_table::NodeEntry[] closest = table.find_closest_nodes( target, 8);
    defer free(closest);

    assert(closest.len == 0, "Empty table should return no nodes");

    io::printn("✓ Find closest nodes: empty table");
}

fn void test_find_closest_nodes_single() @test
{
    common::NodeId our_id = create_test_node_id(0x00);
    dht_routing_table::RoutingTable* table = dht_routing_table::create_routing_table(our_id, mem);
    defer table.free();

    common::NodeId node_id = create_test_node_id(0x10);
    common::Ipv4Addr ip = create_test_ip(192, 168, 1, 100);
    table.add_node( node_id, ip, 6881, 100);

    common::NodeId target = create_test_node_id(0x50);
    dht_routing_table::NodeEntry[] closest = table.find_closest_nodes( target, 8);
    defer free(closest);

    assert(closest.len == 1, "Should return 1 node");

    io::printn("✓ Find closest nodes: single node");
}

fn void test_find_closest_nodes_multiple() @test
{
    common::NodeId our_id = create_test_node_id(0x00);
    dht_routing_table::RoutingTable* table = dht_routing_table::create_routing_table(our_id, mem);
    defer table.free();

    // Add 10 nodes
    for (int i = 0; i < 10; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x10 + i * 10));
        common::Ipv4Addr ip = create_test_ip(192, 168, 1, (char)(100 + i));
        table.add_node( node_id, ip, (ushort)(6881 + i), 100);
    }

    common::NodeId target = create_test_node_id(0x50);
    dht_routing_table::NodeEntry[] closest = table.find_closest_nodes( target, 8);
    defer free(closest);

    assert(closest.len == 8, "Should return 8 closest nodes");

    io::printn("✓ Find closest nodes: multiple nodes");
}

fn void test_find_closest_nodes_fewer_than_requested() @test
{
    common::NodeId our_id = create_test_node_id(0x00);
    dht_routing_table::RoutingTable* table = dht_routing_table::create_routing_table(our_id, mem);
    defer table.free();

    // Add only 3 nodes
    for (int i = 0; i < 3; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x10 + i * 10));
        common::Ipv4Addr ip = create_test_ip(192, 168, 1, (char)(100 + i));
        table.add_node( node_id, ip, (ushort)(6881 + i), 100);
    }

    common::NodeId target = create_test_node_id(0x50);
    dht_routing_table::NodeEntry[] closest = table.find_closest_nodes( target, 8);
    defer free(closest);

    assert(closest.len == 3, "Should return only 3 nodes (all available)");

    io::printn("✓ Find closest nodes: fewer than requested");
}
