module libtorrent::dht_traversal::test;

import std::io;
import libtorrent::dht_traversal;
import libtorrent::dht_routing_table;
import libtorrent::common;

/**
 * DHT Traversal Test Suite
 * ========================
 * Tests for Kademlia iterative node lookup
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

// Helper to create routing table entry
fn dht_routing_table::NodeEntry create_node_entry(char seed)
{
    dht_routing_table::NodeEntry entry;
    for (usz i = 0; i < 20; i++) entry.id[i] = (char)(seed + i);
    for (usz i = 0; i < 4; i++) entry.ip[i] = (char)(192 + i);
    entry.port = 6881;
    entry.last_queried = 0;
    entry.rtt_ms = 100;
    entry.timeout_count = 0;
    entry.verified = false;
    return entry;
}

// ============================================================================
// Basic Traversal Tests
// ============================================================================

fn void test_create_traversal() @test
{
    common::NodeId target = create_test_node_id(0x42);
    dht_traversal::Traversal* t = dht_traversal::create_traversal(target);
    defer t.free();

    // Verify target was copied
    for (usz i = 0; i < 20; i++)
    {
        assert(t.target[i] == target[i], "Target should match");
    }

    // Verify initial state
    assert(t.node_count == 0, "Should start with no nodes");
    assert(t.queries_sent == 0, "Should have no queries sent");
    assert(t.responses_received == 0, "Should have no responses");
    assert(!t.is_done, "Should not be done initially");

    io::printn("✓ Create traversal");
}

// ============================================================================
// Node Management Tests
// ============================================================================

fn void test_add_initial_nodes() @test
{
    common::NodeId target = create_test_node_id(0x50);
    dht_traversal::Traversal* t = dht_traversal::create_traversal(target);
    defer t.free();

    // Create initial nodes
    dht_routing_table::NodeEntry[] nodes = mem::new_array(dht_routing_table::NodeEntry, 3);
    defer free(nodes);

    for (int i = 0; i < 3; i++)
    {
        nodes[i] = create_node_entry((char)(0x10 + i * 10));
    }

    // Add initial nodes
    int added = t.add_initial_nodes(nodes);
    assert(added == 3, "Should add 3 nodes");
    assert(t.node_count == 3, "Should have 3 nodes");

    io::printn("✓ Add initial nodes");
}

fn void test_add_node() @test
{
    common::NodeId target = create_test_node_id(0x60);
    dht_traversal::Traversal* t = dht_traversal::create_traversal(target);
    defer t.free();

    common::NodeId node_id = create_test_node_id(0x70);
    common::Ipv4Addr ip = create_test_ip(192, 168, 1, 100);

    bool added = t.add_node(node_id, ip, 6881);
    assert(added, "Should add node");
    assert(t.node_count == 1, "Should have 1 node");

    io::printn("✓ Add node");
}

fn void test_add_duplicate_node() @test
{
    common::NodeId target = create_test_node_id(0x80);
    dht_traversal::Traversal* t = dht_traversal::create_traversal(target);
    defer t.free();

    common::NodeId node_id = create_test_node_id(0x90);
    common::Ipv4Addr ip = create_test_ip(192, 168, 1, 100);

    // Add node first time
    bool added1 = t.add_node(node_id, ip, 6881);
    assert(added1, "Should add node first time");

    // Try to add same node again
    bool added2 = t.add_node(node_id, ip, 6881);
    assert(!added2, "Should not add duplicate");
    assert(t.node_count == 1, "Should still have only 1 node");

    io::printn("✓ Add duplicate node");
}

// ============================================================================
// Query Selection Tests
// ============================================================================

fn void test_get_next_queries_empty() @test
{
    common::NodeId target = create_test_node_id(0xA0);
    dht_traversal::Traversal* t = dht_traversal::create_traversal(target);
    defer t.free();

    int[] next = t.get_next_queries( 3);
    defer free(next);

    assert(next.len == 0, "Should return no queries for empty traversal");

    io::printn("✓ Get next queries: empty");
}

fn void test_get_next_queries() @test
{
    common::NodeId target = create_test_node_id(0xB0);
    dht_traversal::Traversal* t = dht_traversal::create_traversal(target);
    defer t.free();

    // Add 5 nodes
    for (int i = 0; i < 5; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x10 + i * 10));
        common::Ipv4Addr ip = create_test_ip(192, 168, 1, (char)(100 + i));
        t.add_node( node_id, ip, (ushort)(6881 + i));
    }

    // Get next 3 queries
    int[] next = t.get_next_queries( 3);
    defer free(next);

    assert(next.len == 3, "Should return 3 queries");

    io::printn("✓ Get next queries");
}

// ============================================================================
// Node State Tests
// ============================================================================

fn void test_mark_querying() @test
{
    common::NodeId target = create_test_node_id(0xC0);
    dht_traversal::Traversal* t = dht_traversal::create_traversal(target);
    defer t.free();

    common::NodeId node_id = create_test_node_id(0xD0);
    common::Ipv4Addr ip = create_test_ip(192, 168, 1, 100);
    t.add_node(node_id, ip, 6881);

    // Mark as querying
    t.mark_querying( node_id);

    assert(t.queries_sent == 1, "Should increment queries sent");
    assert(t.nodes[0].state == dht_traversal::NodeState.QUERYING, "Node should be querying");

    io::printn("✓ Mark node as querying");
}

fn void test_mark_responded() @test
{
    common::NodeId target = create_test_node_id(0xE0);
    dht_traversal::Traversal* t = dht_traversal::create_traversal(target);
    defer t.free();

    common::NodeId node_id = create_test_node_id(0xF0);
    common::Ipv4Addr ip = create_test_ip(192, 168, 1, 100);
    t.add_node(node_id, ip, 6881);

    // Mark as responded
    t.mark_responded( node_id);

    assert(t.responses_received == 1, "Should increment responses received");
    assert(t.nodes[0].state == dht_traversal::NodeState.RESPONDED, "Node should be responded");

    io::printn("✓ Mark node as responded");
}

fn void test_mark_failed() @test
{
    common::NodeId target = create_test_node_id(0x11);
    dht_traversal::Traversal* t = dht_traversal::create_traversal(target);
    defer t.free();

    common::NodeId node_id = create_test_node_id(0x22);
    common::Ipv4Addr ip = create_test_ip(192, 168, 1, 100);
    t.add_node(node_id, ip, 6881);

    // Mark as failed
    t.mark_failed( node_id);

    assert(t.nodes[0].state == dht_traversal::NodeState.FAILED, "Node should be failed");

    io::printn("✓ Mark node as failed");
}

// ============================================================================
// Traversal Completion Tests
// ============================================================================

fn void test_is_done_empty() @test
{
    common::NodeId target = create_test_node_id(0x33);
    dht_traversal::Traversal* t = dht_traversal::create_traversal(target);
    defer t.free();

    // Empty traversal should be done
    bool done = dht_traversal::is_done(t);
    assert(done, "Empty traversal should be done");

    io::printn("✓ Is done: empty traversal");
}

fn void test_is_done_with_unqueried() @test
{
    common::NodeId target = create_test_node_id(0x44);
    dht_traversal::Traversal* t = dht_traversal::create_traversal(target);
    defer t.free();

    // Add unqueried nodes
    for (int i = 0; i < 3; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x10 + i * 10));
        common::Ipv4Addr ip = create_test_ip(192, 168, 1, (char)(100 + i));
        t.add_node(node_id, ip, 6881);
    }

    // Should not be done with unqueried nodes
    bool done = dht_traversal::is_done(t);
    assert(!done, "Should not be done with unqueried nodes");

    io::printn("✓ Is done: with unqueried nodes");
}

// ============================================================================
// Result Retrieval Tests
// ============================================================================

fn void test_get_closest_nodes() @test
{
    common::NodeId target = create_test_node_id(0x55);
    dht_traversal::Traversal* t = dht_traversal::create_traversal(target);
    defer t.free();

    // Add and mark nodes as responded
    for (int i = 0; i < 5; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x10 + i * 10));
        common::Ipv4Addr ip = create_test_ip(192, 168, 1, (char)(100 + i));
        t.add_node(node_id, ip, 6881);
        t.mark_responded( node_id);
    }

    // Get closest nodes
    dht_traversal::TraversalNode[] closest = t.get_closest_nodes();
    defer free(closest);

    assert(closest.len == 5, "Should return 5 closest nodes");

    io::printn("✓ Get closest nodes");
}

// ============================================================================
// Statistics Tests
// ============================================================================

fn void test_get_stats() @test
{
    common::NodeId target = create_test_node_id(0x66);
    dht_traversal::Traversal* t = dht_traversal::create_traversal(target);
    defer t.free();

    int total, queries, responses;
    t.get_stats( &total, &queries, &responses);

    assert(total == 0, "Should have 0 total nodes");
    assert(queries == 0, "Should have 0 queries sent");
    assert(responses == 0, "Should have 0 responses");

    // Add nodes and mark as querying
    for (int i = 0; i < 3; i++)
    {
        common::NodeId node_id = create_test_node_id((char)(0x10 + i * 10));
        common::Ipv4Addr ip = create_test_ip(192, 168, 1, (char)(100 + i));
        t.add_node(node_id, ip, 6881);
        t.mark_querying( node_id);
    }

    t.get_stats( &total, &queries, &responses);
    assert(total == 3, "Should have 3 total nodes");
    assert(queries == 3, "Should have 3 queries sent");

    io::printn("✓ Get traversal statistics");
}
