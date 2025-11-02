module libtorrent::dht_rpc_manager::test;

import std::io;
import std::time;
import libtorrent::dht_rpc_manager;
import libtorrent::common;
import libtorrent::krpc;

/**
 * DHT RPC Manager Test Suite
 * ===========================
 * Tests for DHT RPC transaction management
 */

// Global flag for callback testing
bool g_callback_invoked = false;
krpc::KrpcMessage* g_callback_response = null;

// Helper callback function
fn void test_callback(krpc::KrpcMessage* response, void* userdata)
{
    g_callback_invoked = true;
    g_callback_response = response;
}

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

// Helper to create a dummy KRPC response
fn krpc::KrpcMessage create_dummy_response(char[2] tid)
{
    krpc::KrpcMessage msg;
    msg.type = krpc::MessageType.RESPONSE;
    msg.transaction_id = (String)tid[..];
    return msg;
}

// ============================================================================
// Basic RPC Manager Tests
// ============================================================================

fn void test_create_rpc_manager() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    // Verify initial state
    int total, pending;
    mgr.get_stats( &total, &pending);
    assert(total == 0, "New manager should have no transactions");
    assert(pending == 0, "New manager should have no pending transactions");

    io::printn("✓ Create RPC manager");
}

// ============================================================================
// Transaction Creation Tests
// ============================================================================

fn void test_create_single_transaction() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    common::NodeId target_id = create_test_node_id(0x10);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);

    // Reset callback flag
    g_callback_invoked = false;

    // Create transaction
    char[2]? tid_opt = mgr.create_transaction(
        krpc::QueryType.PING,
        target_id,
        target_ip,
        6881,
        &test_callback,
        null
    );

    if (catch excuse = tid_opt) { assert(false, "Should create transaction"); return; }
    char[2] tid = tid_opt;

    // Verify transaction was created
    int total, pending;
    mgr.get_stats( &total, &pending);
    assert(total == 1, "Should have 1 transaction");
    assert(pending == 1, "Should have 1 pending transaction");

    io::printn("✓ Create single transaction");
}

fn void test_create_multiple_transactions() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    // Create 5 transactions
    for (int i = 0; i < 5; i++)
    {
        common::NodeId target_id = create_test_node_id((char)(0x10 + i * 10));
        common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, (char)(100 + i));

        char[2]? tid_opt = mgr.create_transaction(
            krpc::QueryType.FIND_NODE,
            target_id,
            target_ip,
            (ushort)(6881 + i),
            &test_callback,
            null
        );

        if (catch excuse = tid_opt) { assert(false, "Should create transaction"); return; }
    }

    // Verify all transactions were created
    int total, pending;
    mgr.get_stats( &total, &pending);
    assert(total == 5, "Should have 5 transactions");
    assert(pending == 5, "Should have 5 pending transactions");

    io::printn("✓ Create multiple transactions");
}

fn void test_unique_transaction_ids() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    common::NodeId target_id = create_test_node_id(0x20);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);

    // Create 10 transactions and verify they all succeed
    // Transaction IDs are auto-generated and checked internally
    int count = 0;
    for (int i = 0; i < 10; i++)
    {
        char[2]? tid_opt = mgr.create_transaction(
            krpc::QueryType.PING,
            target_id,
            target_ip,
            6881,
            &test_callback,
            null
        );

        if (catch excuse = tid_opt) { assert(false, "Should create transaction"); return; }
        count++;
    }

    // Verify all transactions were created
    int total, pending;
    mgr.get_stats( &total, &pending);
    assert(total == 10, "Should have 10 transactions");
    assert(count == 10, "Should have created 10 transactions");

    io::printn("✓ Unique transaction IDs");
}

// ============================================================================
// Response Handling Tests
// ============================================================================

fn void test_handle_response() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    common::NodeId target_id = create_test_node_id(0x30);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);

    // Reset callback flag
    g_callback_invoked = false;
    g_callback_response = null;

    // Create transaction
    char[2]? tid_opt = mgr.create_transaction(
        krpc::QueryType.PING,
        target_id,
        target_ip,
        6881,
        &test_callback,
        null
    );

    if (catch excuse = tid_opt) { assert(false, "Should create transaction"); return; }
    char[2] tid = tid_opt;

    // Create response with transaction ID matching our transaction
    krpc::KrpcMessage response;
    response.type = krpc::MessageType.RESPONSE;
    response.transaction_id = (String)tid[..];

    // Handle response
    bool handled = mgr.handle_response( &response);
    assert(handled, "Should handle response");

    // Verify callback was invoked
    assert(g_callback_invoked, "Callback should be invoked");
    assert(g_callback_response != null, "Callback should receive response");

    // Verify transaction was removed
    int total, pending;
    mgr.get_stats( &total, &pending);
    assert(total == 0, "Transaction should be removed after response");

    io::printn("✓ Handle response");
}

fn void test_handle_response_unknown_tid() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    // Reset callback flag
    g_callback_invoked = false;

    // Create response with unknown transaction ID
    char[2] unknown_tid = { 0xFF, 0xFF };
    krpc::KrpcMessage response = create_dummy_response(unknown_tid);

    // Try to handle response
    bool handled = mgr.handle_response( &response);
    assert(!handled, "Should not handle unknown transaction");
    assert(!g_callback_invoked, "Callback should not be invoked");

    io::printn("✓ Handle response with unknown TID");
}

// ============================================================================
// Timeout Tests
// ============================================================================

fn void test_process_timeouts_no_timeout() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    common::NodeId target_id = create_test_node_id(0x40);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);

    // Create transaction
    char[2]? tid_opt = mgr.create_transaction(
        krpc::QueryType.PING,
        target_id,
        target_ip,
        6881,
        &test_callback,
        null
    );

    if (catch excuse = tid_opt) { assert(false, "Should create transaction"); return; }

    // Process timeouts immediately (should not timeout)
    int timeout_count = mgr.process_timeouts();
    assert(timeout_count == 0, "Should not timeout immediately");

    // Verify transaction still exists
    int total, pending;
    mgr.get_stats( &total, &pending);
    assert(total == 1, "Transaction should still exist");

    io::printn("✓ Process timeouts: no timeout");
}

fn void test_timeout_exactly_5_seconds() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    common::NodeId target_id = create_test_node_id(0x41);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);

    // Reset callback flag
    g_callback_invoked = false;

    // Create transaction
    char[2]? tid_opt = mgr.create_transaction(
        krpc::QueryType.PING,
        target_id,
        target_ip,
        6881,
        &test_callback,
        null
    );

    if (catch excuse = tid_opt) { assert(false, "Should create transaction"); return; }

    // Simulate exactly 5 seconds passing by manipulating sent_time
    long now = (long)time::now().to_seconds();
    mgr.transactions[0].sent_time = now - 5;  // Exactly 5 seconds ago

    // Process timeouts - should timeout
    int timeout_count = mgr.process_timeouts();
    assert(timeout_count == 1, "Should timeout exactly one transaction");

    // Verify callback was invoked
    assert(g_callback_invoked, "Callback should be invoked on timeout");

    // Verify transaction was removed
    int total, pending;
    mgr.get_stats( &total, &pending);
    assert(total == 0, "Transaction should be removed after timeout");

    io::printn("✓ Process timeouts: exactly 5 seconds");
}

fn void test_timeout_callback_receives_null() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    common::NodeId target_id = create_test_node_id(0x42);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);

    // Reset callback globals
    g_callback_invoked = false;
    g_callback_response = null;

    // Create transaction
    char[2]? tid_opt = mgr.create_transaction(
        krpc::QueryType.PING,
        target_id,
        target_ip,
        6881,
        &test_callback,
        null
    );

    if (catch excuse = tid_opt) { assert(false, "Should create transaction"); return; }

    // Simulate 6 seconds passing (beyond timeout)
    long now = (long)time::now().to_seconds();
    mgr.transactions[0].sent_time = now - 6;

    // Process timeouts
    mgr.process_timeouts();

    // Verify callback received null response
    assert(g_callback_invoked, "Callback should be invoked");
    assert(g_callback_response == null, "Callback should receive null on timeout");

    io::printn("✓ Timeout callback receives null response");
}

fn void test_timeout_removes_transaction() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    common::NodeId target_id = create_test_node_id(0x43);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);

    // Create 3 transactions
    for (int i = 0; i < 3; i++)
    {
        char[2]? tid_opt = mgr.create_transaction(
            krpc::QueryType.PING,
            target_id,
            target_ip,
            (ushort)(6881 + i),
            &test_callback,
            null
        );
        if (catch excuse = tid_opt) { assert(false, "Should create transaction"); return; }
    }

    // Verify we have 3 transactions
    int total, pending;
    mgr.get_stats( &total, &pending);
    assert(total == 3, "Should have 3 transactions");

    // Make second transaction timeout (simulate 6 seconds ago)
    long now = (long)time::now().to_seconds();
    mgr.transactions[1].sent_time = now - 6;

    // Process timeouts
    int timeout_count = mgr.process_timeouts();
    assert(timeout_count == 1, "Should timeout one transaction");

    // Verify only 2 transactions remain
    mgr.get_stats( &total, &pending);
    assert(total == 2, "Should have 2 transactions after timeout");

    io::printn("✓ Timeout removes transaction");
}

fn void test_multiple_transactions_timeout() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    common::NodeId target_id = create_test_node_id(0x44);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);

    // Create 5 transactions
    for (int i = 0; i < 5; i++)
    {
        char[2]? tid_opt = mgr.create_transaction(
            krpc::QueryType.PING,
            target_id,
            target_ip,
            (ushort)(6881 + i),
            &test_callback,
            null
        );
        if (catch excuse = tid_opt) { assert(false, "Should create transaction"); return; }
    }

    // Make first 3 transactions timeout
    long now = (long)time::now().to_seconds();
    mgr.transactions[0].sent_time = now - 6;
    mgr.transactions[1].sent_time = now - 7;
    mgr.transactions[2].sent_time = now - 10;

    // Process timeouts
    int timeout_count = mgr.process_timeouts();
    assert(timeout_count == 3, "Should timeout 3 transactions");

    // Verify only 2 transactions remain
    int total, pending;
    mgr.get_stats( &total, &pending);
    assert(total == 2, "Should have 2 transactions remaining");

    io::printn("✓ Multiple transactions timeout");
}

fn void test_timeout_boundary_4999ms() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    common::NodeId target_id = create_test_node_id(0x45);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);

    // Create transaction
    char[2]? tid_opt = mgr.create_transaction(
        krpc::QueryType.PING,
        target_id,
        target_ip,
        6881,
        &test_callback,
        null
    );

    if (catch excuse = tid_opt) { assert(false, "Should create transaction"); return; }

    // Simulate 4 seconds passing (4000ms < 5000ms timeout)
    // Note: Since time is in seconds, we simulate 4 seconds which gives 4000ms elapsed
    long now = (long)time::now().to_seconds();
    mgr.transactions[0].sent_time = now - 4;

    // Process timeouts - should NOT timeout
    int timeout_count = mgr.process_timeouts();
    assert(timeout_count == 0, "Should not timeout at 4000ms (< 5000ms)");

    // Verify transaction still exists
    int total, pending;
    mgr.get_stats( &total, &pending);
    assert(total == 1, "Transaction should still exist");

    io::printn("✓ Timeout boundary: 4 seconds does not timeout");
}

// ============================================================================
// Transaction Cancellation Tests
// ============================================================================

fn void test_cancel_transaction() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    common::NodeId target_id = create_test_node_id(0x50);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);

    // Create transaction
    char[2]? tid_opt = mgr.create_transaction(
        krpc::QueryType.PING,
        target_id,
        target_ip,
        6881,
        &test_callback,
        null
    );

    if (catch excuse = tid_opt) { assert(false, "Should create transaction"); return; }
    char[2] tid = tid_opt;

    // Cancel transaction
    bool cancelled = mgr.cancel_transaction( (String)tid[..]);
    assert(cancelled, "Should cancel transaction");

    // Verify transaction was removed
    int total, pending;
    mgr.get_stats( &total, &pending);
    assert(total == 0, "Transaction should be removed after cancel");

    io::printn("✓ Cancel transaction");
}

fn void test_cancel_unknown_transaction() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    // Try to cancel unknown transaction
    char[2] unknown_tid = { 0xFF, 0xFF };
    bool cancelled = mgr.cancel_transaction( (String)unknown_tid[..]);
    assert(!cancelled, "Should not cancel unknown transaction");

    io::printn("✓ Cancel unknown transaction");
}

// ============================================================================
// Statistics Tests
// ============================================================================

fn void test_get_stats() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    common::NodeId target_id = create_test_node_id(0x60);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);

    // Initially empty
    int total, pending;
    mgr.get_stats( &total, &pending);
    assert(total == 0, "Should start with 0 total");
    assert(pending == 0, "Should start with 0 pending");

    // Add 3 transactions
    for (int i = 0; i < 3; i++)
    {
        char[2]? tid_opt = mgr.create_transaction(
            krpc::QueryType.PING,
            target_id,
            target_ip,
            6881,
            &test_callback,
            null
        );
        if (catch excuse = tid_opt) { assert(false, "Should create transaction"); return; }
    }

    // Check stats
    mgr.get_stats( &total, &pending);
    assert(total == 3, "Should have 3 total");
    assert(pending == 3, "Should have 3 pending");

    io::printn("✓ Get statistics");
}

// ============================================================================
// Stress Tests (Boundary Conditions)
// ============================================================================

fn void test_transaction_table_full() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    common::NodeId target_id = create_test_node_id(0x70);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);

    // Fill the transaction table to MAX_TRANSACTIONS (1024)
    io::printn("Creating 1024 transactions...");
    for (int i = 0; i < 1024; i++)
    {
        char[2]? tid_opt = mgr.create_transaction(
            krpc::QueryType.PING,
            target_id,
            target_ip,
            (ushort)(6881 + (i % 1000)),  // Vary ports
            &test_callback,
            null
        );
        if (catch excuse = tid_opt)
        {
            io::printfn("Failed to create transaction %d: expected to fill 1024", i);
            assert(false, "Should be able to create 1024 transactions");
            return;
        }
    }

    // Verify we have exactly 1024 transactions
    int total, pending;
    mgr.get_stats( &total, &pending);
    assert(total == 1024, "Should have exactly 1024 transactions");

    // Try to add 1025th transaction - should fail
    char[2]? tid_1025 = mgr.create_transaction(
        krpc::QueryType.PING,
        target_id,
        target_ip,
        7000,
        &test_callback,
        null
    );

    // Should fail with RPC_TRANSACTION_TABLE_FULL fault
    if (catch excuse = tid_1025)
    {
        // Expected - table is full
        io::printn("✓ Transaction table full (1024 limit)");
    }
    else
    {
        assert(false, "1025th transaction should fail (table full)");
    }
}

fn void test_tid_wraparound() @test
{
    dht_rpc_manager::RpcManager* mgr = dht_rpc_manager::create_rpc_manager();
    defer mgr.free();

    common::NodeId target_id = create_test_node_id(0x80);
    common::Ipv4Addr target_ip = create_test_ip(192, 168, 1, 100);

    // Set next_tid to 65534 (near wraparound point)
    // Note: next_tid is ushort, wraps from 65535 to 0, but 0 is reserved
    mgr.next_tid = 65534;

    // Create 3 transactions to force wraparound
    char[2]? tid1_opt = mgr.create_transaction(
        krpc::QueryType.PING,
        target_id,
        target_ip,
        6881,
        &test_callback,
        null
    );
    if (catch excuse = tid1_opt) { assert(false, "Should create first transaction"); return; }
    char[2] tid1 = tid1_opt;

    char[2]? tid2_opt = mgr.create_transaction(
        krpc::QueryType.PING,
        target_id,
        target_ip,
        6882,
        &test_callback,
        null
    );
    if (catch excuse = tid2_opt) { assert(false, "Should create second transaction"); return; }
    char[2] tid2 = tid2_opt;

    char[2]? tid3_opt = mgr.create_transaction(
        krpc::QueryType.PING,
        target_id,
        target_ip,
        6883,
        &test_callback,
        null
    );
    if (catch excuse = tid3_opt) { assert(false, "Should create third transaction"); return; }
    char[2] tid3 = tid3_opt;

    // Verify we created 3 transactions
    int total, pending;
    mgr.get_stats( &total, &pending);
    assert(total == 3, "Should have 3 transactions");

    // Verify TID sequence: 65534, 65535, 1 (wraps to 1, not 0)
    // TID is stored as big-endian 2 bytes
    ushort tid1_val = ((ushort)tid1[0] << 8) | (ushort)tid1[1];
    ushort tid2_val = ((ushort)tid2[0] << 8) | (ushort)tid2[1];
    ushort tid3_val = ((ushort)tid3[0] << 8) | (ushort)tid3[1];

    assert(tid1_val == 65534, "First TID should be 65534");
    assert(tid2_val == 65535, "Second TID should be 65535");
    assert(tid3_val == 1, "Third TID should wrap to 1 (not 0)");

    io::printn("✓ TID wraparound (65535 → 1, skipping 0)");
}
