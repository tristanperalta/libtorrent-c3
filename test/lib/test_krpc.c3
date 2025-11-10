module libtorrent::krpc::test;

import std::io;
import std::time;
import libtorrent::krpc;
import libtorrent::common;
import libtorrent::bencode;

// Import krpc types for convenience
alias TransactionTracker = krpc::TransactionTracker;
alias Transaction = krpc::Transaction;
alias QueryType = krpc::QueryType;
alias MessageType = krpc::MessageType;

/**
 * KRPC Protocol Test Suite
 * ========================
 * Tests for KRPC protocol data structures and transaction management.
 */

// ============================================================================
// Transaction Tracker Tests
// ============================================================================

fn void test_create_transaction_tracker() @test
{
    krpc::TransactionTracker tracker = krpc::create_transaction_tracker();
    defer tracker.free();

    assert(tracker.next_id == 1, "Initial transaction ID should be 1");
    assert(tracker.active.len() == 0, "Active list should be empty initially");
}

fn void test_generate_transaction_id() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();
    defer tracker.free();

    // Generate first transaction ID
    String tid1 = tracker.generate_transaction_id();
    defer free(tid1);

    assert(tid1.len == 2, "Transaction ID should be 2 bytes");
    assert(tracker.next_id == 2, "Counter should increment to 2");

    // Generate second transaction ID
    String tid2 = tracker.generate_transaction_id();
    defer free(tid2);

    assert(tid2.len == 2, "Transaction ID should be 2 bytes");
    assert(tracker.next_id == 3, "Counter should increment to 3");

    // Transaction IDs should be different
    bool different = (tid1[0] != tid2[0]) || (tid1[1] != tid2[1]);
    assert(different, "Sequential transaction IDs should be different");

    io::printn("✓ Transaction ID generation works correctly");
}

fn void test_transaction_id_wraps() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();
    defer (void)tracker.free();

    // Set counter near max
    tracker.next_id = 65535;

    String tid1 = tracker.generate_transaction_id();
    defer free(tid1);

    assert(tracker.next_id == 0, "Counter should wrap to 0 after 65535");

    String tid2 = tracker.generate_transaction_id();
    defer free(tid2);

    assert(tracker.next_id == 1, "Counter should be 1 after wrapping");

    io::printn("✓ Transaction ID counter wraps correctly");
}

// ============================================================================
// Transaction Tracking Tests
// ============================================================================

fn void test_track_transaction() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();
    defer (void)tracker.free();

    // Create a transaction
    String tid = tracker.generate_transaction_id();
    defer free(tid);

    Transaction t;
    t.transaction_id = tid;
    t.query_type = QueryType.PING;
    t.sent_at_sec = (long)time::now().to_seconds();
    t.callback_data = null;

    // Track it
    tracker.track_transaction( t);

    assert(tracker.active.len() == 1, "Should have 1 active transaction");

    io::printn("✓ Transaction tracking works");
}

fn void test_track_multiple_transactions() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();
    defer (void)tracker.free();

    long now_sec = (long)time::now().to_seconds();

    // Track 3 transactions
    for (int i = 0; i < 3; i++)
    {
        String tid = tracker.generate_transaction_id();

        Transaction t;
        t.transaction_id = tid;
        t.query_type = QueryType.GET_PEERS;
        t.sent_at_sec = now_sec;
        t.callback_data = null;

        tracker.track_transaction( t);
        free(tid);  // track_transaction makes a copy
    }

    assert(tracker.active.len() == 3, "Should have 3 active transactions");

    io::printn("✓ Multiple transaction tracking works");
}

// ============================================================================
// Transaction Finding Tests
// ============================================================================

fn void test_find_transaction_index() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();
    defer (void)tracker.free();

    String tid = tracker.generate_transaction_id();
    defer free(tid);

    Transaction t;
    t.transaction_id = tid;
    t.query_type = QueryType.PING;
    t.sent_at_sec = (long)time::now().to_seconds();
    t.callback_data = null;

    tracker.track_transaction( t);

    // Find the transaction
    usz idx = tracker.find_transaction_index(tid);
    assert(idx == 0, "Should find transaction at index 0");

    io::printn("✓ Finding transaction by ID works");
}

fn void test_find_transaction_not_found() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();
    defer (void)tracker.free();

    // Try to find non-existent transaction
    char[2] fake_tid = {0xFF, 0xFF};
    usz idx = tracker.find_transaction_index((String)fake_tid[..]);

    assert(idx == usz.max, "Should return usz.max for non-existent transaction");

    io::printn("✓ Finding non-existent transaction returns usz.max");
}

fn void test_find_transaction() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();
    defer (void)tracker.free();

    String tid = tracker.generate_transaction_id();
    defer free(tid);

    Transaction t;
    t.transaction_id = tid;
    t.query_type = QueryType.GET_PEERS;
    t.sent_at_sec = (long)time::now().to_seconds();
    t.callback_data = null;

    tracker.track_transaction( t);

    // Find the transaction
    Transaction? found = tracker.find_transaction( tid);
    if (catch err = found)
    {
        assert(false, "Should find the transaction");
        return;
    }

    assert(found.query_type == QueryType.GET_PEERS, "Query type should match");

    io::printn("✓ Finding transaction returns correct data");
}

fn void test_find_transaction_returns_fault_when_not_found() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();
    defer (void)tracker.free();

    char[2] fake_tid = {0xFF, 0xFF};
    Transaction? result = tracker.find_transaction( (String)fake_tid[..]);

    if (catch err = result)
    {
        io::printn("✓ Returns fault when transaction not found");
    }
    else
    {
        assert(false, "Should return fault for non-existent transaction");
    }
}

// ============================================================================
// Transaction Removal Tests
// ============================================================================

fn void test_remove_transaction() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();
    defer (void)tracker.free();

    String tid = tracker.generate_transaction_id();
    defer free(tid);

    Transaction t;
    t.transaction_id = tid;
    t.query_type = QueryType.PING;
    t.sent_at_sec = (long)time::now().to_seconds();
    t.callback_data = null;

    tracker.track_transaction( t);  // track_transaction makes a copy

    assert(tracker.active.len() == 1, "Should have 1 transaction");

    // Remove it (use tid before it's freed)
    tracker.remove_transaction( tid);

    assert(tracker.active.len() == 0, "Should have 0 transactions after removal");

    io::printn("✓ Transaction removal works");
}

fn void test_remove_transaction_from_multiple() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();
    defer (void)tracker.free();

    long now_sec = (long)time::now().to_seconds();

    // Track 3 transactions
    String tid1 = tracker.generate_transaction_id();
    String tid2 = tracker.generate_transaction_id();
    String tid3 = tracker.generate_transaction_id();

    defer free(tid1);
    defer free(tid2);
    defer free(tid3);

    Transaction t1;
    t1.transaction_id = tid1;
    t1.query_type = QueryType.PING;
    t1.sent_at_sec = now_sec;
    t1.callback_data = null;

    Transaction t2;
    t2.transaction_id = tid2;
    t2.query_type = QueryType.GET_PEERS;
    t2.sent_at_sec = now_sec;
    t2.callback_data = null;

    Transaction t3;
    t3.transaction_id = tid3;
    t3.query_type = QueryType.ANNOUNCE_PEER;
    t3.sent_at_sec = now_sec;
    t3.callback_data = null;

    tracker.track_transaction( t1);
    tracker.track_transaction( t2);
    tracker.track_transaction( t3);

    assert(tracker.active.len() == 3, "Should have 3 transactions");

    // Remove middle one (use tid2 before it's freed)
    tracker.remove_transaction( tid2);

    assert(tracker.active.len() == 2, "Should have 2 transactions after removal");

    // Check that the right ones remain
    usz idx1 = tracker.find_transaction_index(tid1);
    usz idx3 = tracker.find_transaction_index(tid3);
    usz idx2 = tracker.find_transaction_index(tid2);

    assert(idx1 != usz.max, "Transaction 1 should still exist");
    assert(idx3 != usz.max, "Transaction 3 should still exist");
    assert(idx2 == usz.max, "Transaction 2 should be removed");

    io::printn("✓ Removing transaction from middle of list works");
}

fn void test_remove_nonexistent_transaction() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();
    defer (void)tracker.free();

    // Try to remove non-existent transaction (should not crash)
    char[2] fake_tid = {0xFF, 0xFF};
    tracker.remove_transaction( (String)fake_tid[..]);

    assert(tracker.active.len() == 0, "Should still have 0 transactions");

    io::printn("✓ Removing non-existent transaction does not crash");
}

// ============================================================================
// Expired Transaction Tests
// ============================================================================

fn void test_get_expired_transactions_none() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();
    defer (void)tracker.free();

    String tid = tracker.generate_transaction_id();
    defer free(tid);

    Transaction t;
    t.transaction_id = tid;
    t.query_type = QueryType.PING;
    t.sent_at_sec = (long)time::now().to_seconds();
    t.callback_data = null;

    tracker.track_transaction( t);

    // Check for expired transactions (timeout = 10 seconds)
    TransactionList expired = tracker.get_expired_transactions( 10);
    defer expired.free();

    assert(expired.len() == 0, "Should have no expired transactions");

    io::printn("✓ No transactions expire when timeout not reached");
}

fn void test_get_expired_transactions_one() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();
    defer (void)tracker.free();

    String tid = tracker.generate_transaction_id();
    defer free(tid);

    long now_sec = (long)time::now().to_seconds();

    Transaction t;
    t.transaction_id = tid;
    t.query_type = QueryType.GET_PEERS;
    t.sent_at_sec = now_sec - 15;  // 15 seconds ago
    t.callback_data = null;

    tracker.track_transaction( t);

    // Check for expired transactions (timeout = 10 seconds)
    TransactionList expired = tracker.get_expired_transactions( 10);
    defer expired.free();

    assert(expired.len() == 1, "Should have 1 expired transaction");

    Transaction exp = expired.get(0);
    assert(exp.query_type == QueryType.GET_PEERS, "Expired transaction should have correct type");

    io::printn("✓ Expired transaction is detected correctly");
}

fn void test_get_expired_transactions_mixed() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();
    defer (void)tracker.free();

    long now_sec = (long)time::now().to_seconds();

    // Add 3 transactions: 1 expired, 2 fresh
    String tid1 = tracker.generate_transaction_id();
    String tid2 = tracker.generate_transaction_id();
    String tid3 = tracker.generate_transaction_id();

    Transaction t1;
    t1.transaction_id = tid1;
    t1.query_type = QueryType.PING;
    t1.sent_at_sec = now_sec - 20;  // Expired
    t1.callback_data = null;

    Transaction t2;
    t2.transaction_id = tid2;
    t2.query_type = QueryType.GET_PEERS;
    t2.sent_at_sec = now_sec - 5;   // Fresh
    t2.callback_data = null;

    Transaction t3;
    t3.transaction_id = tid3;
    t3.query_type = QueryType.ANNOUNCE_PEER;
    t3.sent_at_sec = now_sec - 2;   // Fresh
    t3.callback_data = null;

    tracker.track_transaction( t1);
    tracker.track_transaction( t2);
    tracker.track_transaction( t3);

    free(tid1);
    free(tid2);
    free(tid3);

    // Check for expired transactions (timeout = 10 seconds)
    TransactionList expired = tracker.get_expired_transactions( 10);
    defer expired.free();

    assert(expired.len() == 1, "Should have 1 expired transaction");
    assert(tracker.active.len() == 3, "All transactions should still be in tracker");

    Transaction exp = expired.get(0);
    assert(exp.query_type == QueryType.PING, "Expired transaction should be the PING");

    io::printn("✓ Mixed expired/fresh transactions handled correctly");
}

// ============================================================================
// Memory Management Tests
// ============================================================================

fn void test_free_transaction_tracker() @test
{
    TransactionTracker tracker = krpc::create_transaction_tracker();

    long now_sec = (long)time::now().to_seconds();

    // Add multiple transactions
    for (int i = 0; i < 5; i++)
    {
        String tid = tracker.generate_transaction_id();

        Transaction t;
        t.transaction_id = tid;
        t.query_type = QueryType.PING;
        t.sent_at_sec = now_sec;
        t.callback_data = null;

        tracker.track_transaction( t);
        free(tid);
    }

    assert(tracker.active.len() == 5, "Should have 5 transactions");

    // Free tracker (should not crash or leak memory)
    tracker.free();

    io::printn("✓ Transaction tracker cleanup works without leaks");
}

// ============================================================================
// Utility Function Tests
// ============================================================================

fn void test_error_code_to_fault() @test
{
    // Test that error_code_to_fault returns faults for various codes
    if (catch err = krpc::error_code_to_fault(201))
    {
        // Expected - should return a fault
    }
    if (catch err = krpc::error_code_to_fault(202))
    {
        // Expected - should return a fault
    }
    if (catch err = krpc::error_code_to_fault(203))
    {
        // Expected - should return a fault
    }
    if (catch err = krpc::error_code_to_fault(204))
    {
        // Expected - should return a fault
    }
    if (catch err = krpc::error_code_to_fault(999))
    {
        // Expected - should return a fault for unknown codes
    }

    io::printn("✓ Error code to fault conversion works");
}

// ============================================================================
// Query Type Tests
// ============================================================================

fn void test_query_type_enum() @test
{
    // Test that query type enum values are distinct
    assert(QueryType.PING != QueryType.FIND_NODE, "PING != FIND_NODE");
    assert(QueryType.PING != QueryType.GET_PEERS, "PING != GET_PEERS");
    assert(QueryType.PING != QueryType.ANNOUNCE_PEER, "PING != ANNOUNCE_PEER");
    assert(QueryType.FIND_NODE != QueryType.GET_PEERS, "FIND_NODE != GET_PEERS");
    assert(QueryType.FIND_NODE != QueryType.ANNOUNCE_PEER, "FIND_NODE != ANNOUNCE_PEER");
    assert(QueryType.GET_PEERS != QueryType.ANNOUNCE_PEER, "GET_PEERS != ANNOUNCE_PEER");

    io::printn("✓ Query type enum values are distinct");
}

fn void test_message_type_enum() @test
{
    // Test that message type enum values are distinct
    assert(MessageType.QUERY != MessageType.RESPONSE, "QUERY != RESPONSE");
    assert(MessageType.QUERY != MessageType.ERROR, "QUERY != ERROR");
    assert(MessageType.RESPONSE != MessageType.ERROR, "RESPONSE != ERROR");

    io::printn("✓ Message type enum values are distinct");
}

// ============================================================================
// Message Encoding Tests
// ============================================================================

// Helper function to create test node IDs and info hashes
fn InfoHash create_test_node_id(char seed)
{
    InfoHash id;
    for (usz i = 0; i < 20; i++)
    {
        id[i] = (char)(seed + i);
    }
    return id;
}

fn void test_encode_ping_query() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    char[2] tid = {0xAA, 0xAA};

    String encoded = krpc::encode_ping_query((String)tid[..], node_id);
    defer free(encoded);

    // Decode to verify structure
    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    assert(root.type == bencode::BencodeType.DICT, "Root should be dictionary");

    // Check message type
    BencodeValue* y_val = root.dict_get("y");
    assert(y_val != null && y_val.type == bencode::BencodeType.STRING, "Should have 'y' string");
    assert((String)y_val.string == "q", "Message type should be 'q'");

    // Check query method
    BencodeValue* q_val = root.dict_get("q");
    assert(q_val != null && (String)q_val.string == "ping", "Query method should be 'ping'");

    // Check arguments
    BencodeValue* a_val = root.dict_get("a");
    assert(a_val != null && a_val.type == bencode::BencodeType.DICT, "Should have arguments dict");

    BencodeValue* id_val = a_val.dict_get("id");
    assert(id_val != null && id_val.string.len == 20, "Node ID should be 20 bytes");

    io::printn("✓ Ping query encodes correctly");
}

fn void test_encode_find_node_query() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash target = create_test_node_id(0x50);
    char[2] tid = {0xAA, 0xBB};

    String encoded = krpc::encode_find_node_query((String)tid[..], node_id, target, false, false);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check query method
    BencodeValue* q_val = root.dict_get("q");
    assert((String)q_val.string == "find_node", "Query method should be 'find_node'");

    // Check arguments
    BencodeValue* a_val = root.dict_get("a");
    BencodeValue* target_val = a_val.dict_get("target");
    assert(target_val != null && target_val.string.len == 20, "Target should be 20 bytes");

    io::printn("✓ Find node query encodes correctly");
}

fn void test_encode_get_peers_query() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash info_hash = create_test_node_id(0x90);
    char[2] tid = {0xCC, 0xDD};

    String encoded = krpc::encode_get_peers_query((String)tid[..], node_id, info_hash, false, false);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check query method
    BencodeValue* q_val = root.dict_get("q");
    assert((String)q_val.string == "get_peers", "Query method should be 'get_peers'");

    // Check info_hash
    BencodeValue* a_val = root.dict_get("a");
    BencodeValue* info_hash_val = a_val.dict_get("info_hash");
    assert(info_hash_val != null && info_hash_val.string.len == 20, "Info hash should be 20 bytes");

    io::printn("✓ Get peers query encodes correctly");
}

fn void test_encode_announce_peer_query() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash info_hash = create_test_node_id(0x90);
    char[2] tid = {0xEE, 0xFF};
    String token = "aoeusnth";

    String encoded = krpc::encode_announce_peer_query((String)tid[..], node_id, info_hash,
                                                      6881, token, true);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check query method
    BencodeValue* q_val = root.dict_get("q");
    assert((String)q_val.string == "announce_peer", "Query method should be 'announce_peer'");

    // Check arguments
    BencodeValue* a_val = root.dict_get("a");

    BencodeValue* port_val = a_val.dict_get("port");
    assert(port_val != null && port_val.integer == 6881, "Port should be 6881");

    BencodeValue* token_val = a_val.dict_get("token");
    assert(token_val != null, "Token should be present");

    BencodeValue* implied_port_val = a_val.dict_get("implied_port");
    assert(implied_port_val != null && implied_port_val.integer == 1, "Implied port should be 1");

    io::printn("✓ Announce peer query encodes correctly");
}

fn void test_encode_announce_peer_query_no_implied_port() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash info_hash = create_test_node_id(0x90);
    char[2] tid = {0x11, 0x22};
    String token = "testtoken";

    String encoded = krpc::encode_announce_peer_query((String)tid[..], node_id, info_hash,
                                                      8080, token, false);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    BencodeValue* a_val = root.dict_get("a");
    BencodeValue* implied_port_val = a_val.dict_get("implied_port");
    assert(implied_port_val != null && implied_port_val.integer == 0, "Implied port should be 0");

    io::printn("✓ Announce peer query with explicit port encodes correctly");
}

fn void test_encode_ping_response() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0xAA, 0xAA};

    String encoded = krpc::encode_ping_response((String)tid[..], node_id);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check message type
    BencodeValue* y_val = root.dict_get("y");
    assert((String)y_val.string == "r", "Message type should be 'r' (response)");

    // Check response dict
    BencodeValue* r_val = root.dict_get("r");
    assert(r_val != null && r_val.type == bencode::BencodeType.DICT, "Should have response dict");

    BencodeValue* id_val = r_val.dict_get("id");
    assert(id_val != null && id_val.string.len == 20, "Node ID should be 20 bytes");

    io::printn("✓ Ping response encodes correctly");
}

fn void test_encode_find_node_response() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0xBB, 0xCC};

    // Create compact node info (26 bytes: 20-byte ID + 4-byte IP + 2-byte port)
    char[26] node_info;
    for (usz i = 0; i < 20; i++) node_info[i] = (char)(0x40 + i);
    node_info[20] = 192; // IP: 192.168.1.100
    node_info[21] = 168;
    node_info[22] = 1;
    node_info[23] = 100;
    node_info[24] = 0x1A; // Port: 6881 (big endian)
    node_info[25] = 0xE1;

    char[] empty_nodes6 = {};
    String encoded = krpc::encode_find_node_response((String)tid[..], node_id, node_info[..], empty_nodes6);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check response contains nodes
    BencodeValue* r_val = root.dict_get("r");
    BencodeValue* nodes_val = r_val.dict_get("nodes");
    assert(nodes_val != null && nodes_val.string.len == 26, "Nodes should be 26 bytes");

    io::printn("✓ Find node response encodes correctly");
}

fn void test_encode_find_node_response_multiple_nodes() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0xDD, 0xEE};

    // Create compact info for 3 nodes (78 bytes total)
    char[78] nodes;
    for (usz i = 0; i < 78; i++) nodes[i] = (char)i;

    char[] empty_nodes6 = {};
    String encoded = krpc::encode_find_node_response((String)tid[..], node_id, nodes[..], empty_nodes6);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    BencodeValue* r_val = root.dict_get("r");
    BencodeValue* nodes_val = r_val.dict_get("nodes");
    assert(nodes_val.string.len == 78, "Should have 78 bytes (3 nodes)");

    io::printn("✓ Find node response with multiple nodes encodes correctly");
}

fn void test_encode_get_peers_response_with_values() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0xFF, 0x00};
    String token = "testtoken";

    // Create compact peer info (2 peers, 12 bytes total)
    char[12] peers;
    // Peer 1: 192.168.1.10:6881
    peers[0] = 192;
    peers[1] = 168;
    peers[2] = 1;
    peers[3] = 10;
    peers[4] = 0x1A;
    peers[5] = 0xE1;
    // Peer 2: 192.168.1.20:6882
    peers[6] = 192;
    peers[7] = 168;
    peers[8] = 1;
    peers[9] = 20;
    peers[10] = 0x1A;
    peers[11] = 0xE2;

    String encoded = krpc::encode_get_peers_response_with_values((String)tid[..], node_id,
                                                                 token, peers[..]);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check response contains values list
    BencodeValue* r_val = root.dict_get("r");
    BencodeValue* values_val = r_val.dict_get("values");
    assert(values_val != null && values_val.type == bencode::BencodeType.LIST, "Should have values list");
    assert(values_val.list.size == 2, "Should have 2 peer entries");

    // Check token
    BencodeValue* token_val = r_val.dict_get("token");
    assert(token_val != null, "Token should be present");

    io::printn("✓ Get peers response with values encodes correctly");
}

fn void test_encode_get_peers_response_with_nodes() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0x00, 0xFF};
    String token = "aoeusnth";

    // Create compact node info (26 bytes)
    char[26] nodes;
    for (usz i = 0; i < 26; i++) nodes[i] = (char)(0x50 + i);

    char[] empty_nodes6 = {};
    String encoded = krpc::encode_get_peers_response_with_nodes((String)tid[..], node_id,
                                                                token, nodes[..], empty_nodes6);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check response contains nodes
    BencodeValue* r_val = root.dict_get("r");
    BencodeValue* nodes_val = r_val.dict_get("nodes");
    assert(nodes_val != null && nodes_val.string.len == 26, "Should have nodes (26 bytes)");

    // Check token
    BencodeValue* token_val = r_val.dict_get("token");
    assert(token_val != null, "Token should be present");

    io::printn("✓ Get peers response with nodes encodes correctly");
}

fn void test_encode_announce_peer_response() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0x12, 0x34};

    String encoded = krpc::encode_announce_peer_response((String)tid[..], node_id);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check message type
    BencodeValue* y_val = root.dict_get("y");
    assert((String)y_val.string == "r", "Message type should be 'r'");

    // Check response has node ID
    BencodeValue* r_val = root.dict_get("r");
    BencodeValue* id_val = r_val.dict_get("id");
    assert(id_val != null && id_val.string.len == 20, "Should have node ID");

    io::printn("✓ Announce peer response encodes correctly");
}

fn void test_encode_error() @test
{
    char[2] tid = {0x56, 0x78};
    String message = "A Generic Error Occurred";

    String encoded = krpc::encode_error((String)tid[..], 201, message);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check message type
    BencodeValue* y_val = root.dict_get("y");
    assert((String)y_val.string == "e", "Message type should be 'e' (error)");

    // Check error list
    BencodeValue* e_val = root.dict_get("e");
    assert(e_val != null && e_val.type == bencode::BencodeType.LIST, "Should have error list");
    assert(e_val.list.size == 2, "Error list should have 2 elements");

    // Check error code
    BencodeValue* code_val = e_val.list[0];
    assert(code_val.type == bencode::BencodeType.INTEGER && code_val.integer == 201,
           "Error code should be 201");

    // Check error message
    BencodeValue* msg_val = e_val.list[1];
    assert(msg_val.type == bencode::BencodeType.STRING, "Error message should be string");

    io::printn("✓ Error message encodes correctly");
}

fn void test_encode_error_various_codes() @test
{
    char[2] tid = {0x90, 0xAB};

    // Test all error codes
    String enc201 = krpc::encode_error((String)tid[..], 201, "Generic Error");
    defer free(enc201);

    String enc202 = krpc::encode_error((String)tid[..], 202, "Server Error");
    defer free(enc202);

    String enc203 = krpc::encode_error((String)tid[..], 203, "Protocol Error");
    defer free(enc203);

    String enc204 = krpc::encode_error((String)tid[..], 204, "Method Unknown");
    defer free(enc204);

    // Verify they all decode
    BencodeValue* r201 = bencode::decode(enc201)!!;
    defer r201.free();

    BencodeValue* r202 = bencode::decode(enc202)!!;
    defer r202.free();

    BencodeValue* r203 = bencode::decode(enc203)!!;
    defer r203.free();

    BencodeValue* r204 = bencode::decode(enc204)!!;
    defer r204.free();

    io::printn("✓ All error codes encode correctly");
}

fn void test_encode_includes_version() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    char[2] tid = {0xAB, 0xCD};

    String encoded = krpc::encode_ping_query((String)tid[..], node_id);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check version field
    BencodeValue* v_val = root.dict_get("v");
    assert(v_val != null && v_val.type == bencode::BencodeType.STRING, "Should have version");
    assert((String)v_val.string == "LC01", "Version should be 'LC01'");

    io::printn("✓ Messages include version field");
}

fn void test_encode_transaction_id_preserved() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    char[2] tid = {0xDE, 0xAD};

    String encoded = krpc::encode_ping_query((String)tid[..], node_id);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check transaction ID
    BencodeValue* t_val = root.dict_get("t");
    assert(t_val != null && t_val.string.len == 2, "Transaction ID should be 2 bytes");
    assert(t_val.string[0] == (char)0xDE && t_val.string[1] == (char)0xAD,
           "Transaction ID should match input");

    io::printn("✓ Transaction ID is preserved in encoding");
}

// ============================================================================
// Message Decoding Tests
// ============================================================================

fn void test_decode_message_type_query() @test
{
    String data = "d1:q4:ping1:t2:aa1:y1:qe";
    BencodeValue* root = bencode::decode(data)!!;
    defer root.free();

    MessageType msg_type = krpc::decode_message_type(root)!!;
    assert(msg_type == MessageType.QUERY, "Should decode as QUERY");

    io::printn("✓ Decode message type: query");
}

fn void test_decode_message_type_response() @test
{
    String data = "d1:r1:a1:t2:aa1:y1:re";
    BencodeValue* root = bencode::decode(data)!!;
    defer root.free();

    MessageType msg_type = krpc::decode_message_type(root)!!;
    assert(msg_type == MessageType.RESPONSE, "Should decode as RESPONSE");

    io::printn("✓ Decode message type: response");
}

fn void test_decode_message_type_error() @test
{
    String data = "d1:eli201e24:A Generic Error Occurrede1:t2:aa1:y1:ee";
    BencodeValue* root = bencode::decode(data)!!;
    defer root.free();

    MessageType msg_type = krpc::decode_message_type(root)!!;
    assert(msg_type == MessageType.ERROR, "Should decode as ERROR");

    io::printn("✓ Decode message type: error");
}

fn void test_decode_message_type_invalid() @test
{
    String data = "d1:t2:aa1:y1:xe";  // Invalid type 'x'
    BencodeValue* root = bencode::decode(data)!!;
    defer root.free();

    if (catch err = krpc::decode_message_type(root))
    {
        io::printn("✓ Invalid message type returns fault");
    }
    else
    {
        assert(false, "Should fail for invalid message type");
    }
}

// ============================================================================
// Query Decoding Tests
// ============================================================================

fn void test_decode_ping_query() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    char[2] tid = {0xAA, 0xBB};

    // Encode first
    String encoded = krpc::encode_ping_query((String)tid[..], node_id);
    defer free(encoded);

    // Decode
    krpc::KrpcQuery* query = krpc::decode_query(encoded)!!;
    defer query.free();

    assert(query.base.type == MessageType.QUERY, "Type should be QUERY");
    assert(query.query_type == QueryType.PING, "Query type should be PING");
    assert(query.base.transaction_id.len == 2, "Transaction ID should be 2 bytes");
    assert(query.base.transaction_id[0] == (char)0xAA, "Transaction ID byte 0 should match");
    assert(query.base.transaction_id[1] == (char)0xBB, "Transaction ID byte 1 should match");

    // Check node ID
    for (usz i = 0; i < 20; i++)
    {
        assert(query.node_id[i] == node_id[i], "Node ID should match");
    }

    io::printn("✓ Decode ping query");
}

fn void test_decode_find_node_query() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash target = create_test_node_id(0x50);
    char[2] tid = {0xCC, 0xDD};

    String encoded = krpc::encode_find_node_query((String)tid[..], node_id, target, false, false);
    defer free(encoded);

    krpc::KrpcQuery* query = krpc::decode_query(encoded)!!;
    defer query.free();

    assert(query.query_type == QueryType.FIND_NODE, "Query type should be FIND_NODE");

    // Check target
    krpc::FindNodeArgs* args = (krpc::FindNodeArgs*)query.args;
    for (usz i = 0; i < 20; i++)
    {
        assert(args.target[i] == target[i], "Target should match");
    }

    io::printn("✓ Decode find_node query");
}

fn void test_decode_get_peers_query() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash info_hash = create_test_node_id(0x90);
    char[2] tid = {0xEE, 0xFF};

    String encoded = krpc::encode_get_peers_query((String)tid[..], node_id, info_hash, false, false);
    defer free(encoded);

    krpc::KrpcQuery* query = krpc::decode_query(encoded)!!;
    defer query.free();

    assert(query.query_type == QueryType.GET_PEERS, "Query type should be GET_PEERS");

    // Check info_hash
    krpc::GetPeersArgs* args = (krpc::GetPeersArgs*)query.args;
    for (usz i = 0; i < 20; i++)
    {
        assert(args.info_hash[i] == info_hash[i], "Info hash should match");
    }

    io::printn("✓ Decode get_peers query");
}

fn void test_decode_announce_peer_query() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash info_hash = create_test_node_id(0x90);
    char[2] tid = {0x11, 0x22};
    String token = "aoeusnth";

    String encoded = krpc::encode_announce_peer_query((String)tid[..], node_id, info_hash,
                                                      6881, token, true);
    defer free(encoded);

    krpc::KrpcQuery* query = krpc::decode_query(encoded)!!;
    defer query.free();

    assert(query.query_type == QueryType.ANNOUNCE_PEER, "Query type should be ANNOUNCE_PEER");

    // Check arguments
    krpc::AnnouncePeerArgs* args = (krpc::AnnouncePeerArgs*)query.args;
    for (usz i = 0; i < 20; i++)
    {
        assert(args.info_hash[i] == info_hash[i], "Info hash should match");
    }
    assert(args.port == 6881, "Port should be 6881");
    assert(args.token == token, "Token should match");
    assert(args.implied_port == true, "Implied port should be true");

    io::printn("✓ Decode announce_peer query");
}

fn void test_decode_announce_peer_query_no_implied_port() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash info_hash = create_test_node_id(0x90);
    char[2] tid = {0x33, 0x44};
    String token = "testtoken";

    String encoded = krpc::encode_announce_peer_query((String)tid[..], node_id, info_hash,
                                                      8080, token, false);
    defer free(encoded);

    krpc::KrpcQuery* query = krpc::decode_query(encoded)!!;
    defer query.free();

    krpc::AnnouncePeerArgs* args = (krpc::AnnouncePeerArgs*)query.args;
    assert(args.port == 8080, "Port should be 8080");
    assert(args.implied_port == false, "Implied port should be false");

    io::printn("✓ Decode announce_peer query with explicit port");
}

// ============================================================================
// Response Decoding Tests
// ============================================================================

fn void test_decode_ping_response() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0x55, 0x66};

    String encoded = krpc::encode_ping_response((String)tid[..], node_id);
    defer free(encoded);

    krpc::KrpcResponse* response = krpc::decode_response(encoded, QueryType.PING)!!;
    defer response.free();

    assert(response.base.type == MessageType.RESPONSE, "Type should be RESPONSE");
    assert(response.query_type == QueryType.PING, "Query type should be PING");
    assert(response.base.transaction_id.len == 2, "Transaction ID should be 2 bytes");

    // Check node ID
    for (usz i = 0; i < 20; i++)
    {
        assert(response.node_id[i] == node_id[i], "Node ID should match");
    }

    io::printn("✓ Decode ping response");
}

fn void test_decode_find_node_response() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0x77, 0x88};

    // Create compact node info (26 bytes)
    char[26] node_info;
    for (usz i = 0; i < 20; i++) node_info[i] = (char)(0x40 + i);
    node_info[20] = 192;
    node_info[21] = 168;
    node_info[22] = 1;
    node_info[23] = 100;
    node_info[24] = 0x1A;
    node_info[25] = 0xE1;

    char[] empty_nodes6 = {};
    String encoded = krpc::encode_find_node_response((String)tid[..], node_id, node_info[..], empty_nodes6);
    defer free(encoded);

    krpc::KrpcResponse* response = krpc::decode_response(encoded, QueryType.FIND_NODE)!!;
    defer response.free();

    assert(response.query_type == QueryType.FIND_NODE, "Query type should be FIND_NODE");

    // Check nodes
    krpc::FindNodeResponse* data = (krpc::FindNodeResponse*)response.data;
    assert(data.nodes.len == 26, "Nodes should be 26 bytes");
    for (usz i = 0; i < 26; i++)
    {
        assert(data.nodes[i] == node_info[i], "Node info should match");
    }

    io::printn("✓ Decode find_node response");
}

fn void test_decode_find_node_response_multiple_nodes() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0x99, 0xAA};

    // Create compact info for 3 nodes (78 bytes)
    char[78] nodes;
    for (usz i = 0; i < 78; i++) nodes[i] = (char)(i % 256);

    char[] empty_nodes6 = {};
    String encoded = krpc::encode_find_node_response((String)tid[..], node_id, nodes[..], empty_nodes6);
    defer free(encoded);

    krpc::KrpcResponse* response = krpc::decode_response(encoded, QueryType.FIND_NODE)!!;
    defer response.free();

    krpc::FindNodeResponse* data = (krpc::FindNodeResponse*)response.data;
    assert(data.nodes.len == 78, "Should have 78 bytes (3 nodes)");

    io::printn("✓ Decode find_node response with multiple nodes");
}

fn void test_decode_get_peers_response_with_values() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0xBB, 0xCC};
    String token = "aoeusnth";

    // Create compact peer info (12 bytes = 2 peers)
    char[12] peers;
    peers[0] = 192;
    peers[1] = 168;
    peers[2] = 1;
    peers[3] = 10;
    peers[4] = 0x1A;
    peers[5] = 0xE1;
    peers[6] = 192;
    peers[7] = 168;
    peers[8] = 1;
    peers[9] = 20;
    peers[10] = 0x1A;
    peers[11] = 0xE2;

    String encoded = krpc::encode_get_peers_response_with_values((String)tid[..], node_id,
                                                                 token, peers[..]);
    defer free(encoded);

    krpc::KrpcResponse* response = krpc::decode_response(encoded, QueryType.GET_PEERS)!!;
    defer response.free();

    assert(response.query_type == QueryType.GET_PEERS, "Query type should be GET_PEERS");

    krpc::GetPeersResponse* data = (krpc::GetPeersResponse*)response.data;
    assert(data.token == token, "Token should match");
    assert(data.values.len == 12, "Values should be 12 bytes");
    assert(data.nodes.len == 0, "Nodes should be empty");

    io::printn("✓ Decode get_peers response with values");
}

fn void test_decode_get_peers_response_with_nodes() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0xDD, 0xEE};
    String token = "testtoken";

    // Create compact node info (26 bytes)
    char[26] nodes;
    for (usz i = 0; i < 26; i++) nodes[i] = (char)(0x50 + i);

    char[] empty_nodes6 = {};
    String encoded = krpc::encode_get_peers_response_with_nodes((String)tid[..], node_id,
                                                                token, nodes[..], empty_nodes6);
    defer free(encoded);

    krpc::KrpcResponse* response = krpc::decode_response(encoded, QueryType.GET_PEERS)!!;
    defer response.free();

    krpc::GetPeersResponse* data = (krpc::GetPeersResponse*)response.data;
    assert(data.token == token, "Token should match");
    assert(data.nodes.len == 26, "Nodes should be 26 bytes");
    assert(data.values.len == 0, "Values should be empty");

    io::printn("✓ Decode get_peers response with nodes");
}

fn void test_decode_announce_peer_response() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0xFF, 0x00};

    String encoded = krpc::encode_announce_peer_response((String)tid[..], node_id);
    defer free(encoded);

    krpc::KrpcResponse* response = krpc::decode_response(encoded, QueryType.ANNOUNCE_PEER)!!;
    defer response.free();

    assert(response.query_type == QueryType.ANNOUNCE_PEER, "Query type should be ANNOUNCE_PEER");

    // Check node ID
    for (usz i = 0; i < 20; i++)
    {
        assert(response.node_id[i] == node_id[i], "Node ID should match");
    }

    io::printn("✓ Decode announce_peer response");
}

// ============================================================================
// Error Decoding Tests
// ============================================================================

fn void test_decode_error_generic() @test
{
    char[2] tid = {0x12, 0x34};
    String message = "A Generic Error Occurred";

    String encoded = krpc::encode_error((String)tid[..], 201, message);
    defer free(encoded);

    krpc::KrpcError* error = krpc::decode_error(encoded)!!;
    defer error.free();

    assert(error.base.type == MessageType.ERROR, "Type should be ERROR");
    assert(error.code == 201, "Error code should be 201");
    assert(error.message == message, "Error message should match");
    assert(error.base.transaction_id.len == 2, "Transaction ID should be 2 bytes");

    io::printn("✓ Decode error message (generic)");
}

fn void test_decode_error_server() @test
{
    char[2] tid = {0x56, 0x78};
    String message = "Server Error";

    String encoded = krpc::encode_error((String)tid[..], 202, message);
    defer free(encoded);

    krpc::KrpcError* error = krpc::decode_error(encoded)!!;
    defer error.free();

    assert(error.code == 202, "Error code should be 202");

    io::printn("✓ Decode error message (server)");
}

fn void test_decode_error_protocol() @test
{
    char[2] tid = {0x9A, 0xBC};
    String message = "Protocol Error: malformed packet";

    String encoded = krpc::encode_error((String)tid[..], 203, message);
    defer free(encoded);

    krpc::KrpcError* error = krpc::decode_error(encoded)!!;
    defer error.free();

    assert(error.code == 203, "Error code should be 203");

    io::printn("✓ Decode error message (protocol)");
}

fn void test_decode_error_method_unknown() @test
{
    char[2] tid = {0xDE, 0xF0};
    String message = "Method Unknown";

    String encoded = krpc::encode_error((String)tid[..], 204, message);
    defer free(encoded);

    krpc::KrpcError* error = krpc::decode_error(encoded)!!;
    defer error.free();

    assert(error.code == 204, "Error code should be 204");

    io::printn("✓ Decode error message (method unknown)");
}

// ============================================================================
// Invalid Message Decoding Tests
// ============================================================================

fn void test_decode_query_missing_transaction_id() @test
{
    String data = "d1:q4:ping1:y1:qe";  // Missing 't'

    if (catch err = krpc::decode_query(data))
    {
        io::printn("✓ Query without transaction ID returns fault");
    }
    else
    {
        assert(false, "Should fail for missing transaction ID");
    }
}

fn void test_decode_query_missing_query_method() @test
{
    String data = "d1:t2:aa1:y1:qe";  // Missing 'q'

    if (catch err = krpc::decode_query(data))
    {
        io::printn("✓ Query without method returns fault");
    }
    else
    {
        assert(false, "Should fail for missing query method");
    }
}

fn void test_decode_query_missing_arguments() @test
{
    String data = "d1:q4:ping1:t2:aa1:y1:qe";  // Missing 'a'

    if (catch err = krpc::decode_query(data))
    {
        io::printn("✓ Query without arguments returns fault");
    }
    else
    {
        assert(false, "Should fail for missing arguments");
    }
}

fn void test_decode_query_unknown_method() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    char[20] node_id_bytes;
    for (usz i = 0; i < 20; i++) node_id_bytes[i] = node_id[i];

    // Create a query with unknown method "unknown_method"
    BencodeValue* args = bencode::@bdict(
        "id", bencode::make_string((String)node_id_bytes[..])
    );
    BencodeValue* root = bencode::@bdict(
        "t", bencode::make_string("aa"),
        "y", bencode::make_string("q"),
        "q", bencode::make_string("unknown_method"),
        "a", args
    );
    defer root.free();

    String encoded = root.encode();
    defer free(encoded);

    if (catch err = krpc::decode_query(encoded))
    {
        io::printn("✓ Unknown query method returns fault");
    }
    else
    {
        assert(false, "Should fail for unknown method");
    }
}

fn void test_decode_query_invalid_node_id_length() @test
{
    // Create query with 10-byte node ID (should be 20)
    char[10] short_id;
    for (usz i = 0; i < 10; i++) short_id[i] = (char)i;

    BencodeValue* args = bencode::@bdict(
        "id", bencode::make_string((String)short_id[..])
    );
    BencodeValue* root = bencode::@bdict(
        "t", bencode::make_string("aa"),
        "y", bencode::make_string("q"),
        "q", bencode::make_string("ping"),
        "a", args
    );
    defer root.free();

    String encoded = root.encode();
    defer free(encoded);

    if (catch err = krpc::decode_query(encoded))
    {
        io::printn("✓ Invalid node ID length returns fault");
    }
    else
    {
        assert(false, "Should fail for invalid node ID length");
    }
}

fn void test_decode_response_missing_response_dict() @test
{
    String data = "d1:t2:aa1:y1:re";  // Missing 'r'

    if (catch err = krpc::decode_response(data, QueryType.PING))
    {
        io::printn("✓ Response without response dict returns fault");
    }
    else
    {
        assert(false, "Should fail for missing response dict");
    }
}

fn void test_decode_error_invalid_error_list() @test
{
    // Error list with only 1 element (should be 2)
    String data = "d1:eli201ee1:t2:aa1:y1:ee";

    if (catch err = krpc::decode_error(data))
    {
        io::printn("✓ Error with invalid list returns fault");
    }
    else
    {
        assert(false, "Should fail for invalid error list");
    }
}

// ============================================================================
// Roundtrip Tests (Encode → Decode → Verify)
// ============================================================================

fn void test_roundtrip_ping() @test
{
    InfoHash original_id = create_test_node_id(0x10);
    char[2] tid = {0xAA, 0xBB};

    // Encode query
    String encoded_query = krpc::encode_ping_query((String)tid[..], original_id);
    defer free(encoded_query);

    // Decode query
    krpc::KrpcQuery* query = krpc::decode_query(encoded_query)!!;
    defer query.free();

    // Verify
    assert(query.query_type == QueryType.PING, "Query type should match");
    for (usz i = 0; i < 20; i++)
    {
        assert(query.node_id[i] == original_id[i], "Node ID should match original");
    }

    // Encode response
    InfoHash response_id = create_test_node_id(0x30);
    String encoded_response = krpc::encode_ping_response((String)tid[..], response_id);
    defer free(encoded_response);

    // Decode response
    krpc::KrpcResponse* response = krpc::decode_response(encoded_response, QueryType.PING)!!;
    defer response.free();

    // Verify
    for (usz i = 0; i < 20; i++)
    {
        assert(response.node_id[i] == response_id[i], "Response node ID should match");
    }

    io::printn("✓ Roundtrip: ping query and response");
}

fn void test_roundtrip_find_node() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash target = create_test_node_id(0x50);
    char[2] tid = {0xCC, 0xDD};

    // Encode and decode query
    String encoded = krpc::encode_find_node_query((String)tid[..], node_id, target, false, false);
    defer free(encoded);

    krpc::KrpcQuery* query = krpc::decode_query(encoded)!!;
    defer query.free();

    // Verify target matches
    krpc::FindNodeArgs* args = (krpc::FindNodeArgs*)query.args;
    for (usz i = 0; i < 20; i++)
    {
        assert(args.target[i] == target[i], "Target should match");
    }

    io::printn("✓ Roundtrip: find_node query");
}

fn void test_roundtrip_get_peers() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash info_hash = create_test_node_id(0x90);
    char[2] tid = {0xEE, 0xFF};

    // Encode and decode query
    String encoded = krpc::encode_get_peers_query((String)tid[..], node_id, info_hash, false, false);
    defer free(encoded);

    krpc::KrpcQuery* query = krpc::decode_query(encoded)!!;
    defer query.free();

    // Verify info_hash matches
    krpc::GetPeersArgs* args = (krpc::GetPeersArgs*)query.args;
    for (usz i = 0; i < 20; i++)
    {
        assert(args.info_hash[i] == info_hash[i], "Info hash should match");
    }

    io::printn("✓ Roundtrip: get_peers query");
}

fn void test_roundtrip_announce_peer() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash info_hash = create_test_node_id(0x90);
    char[2] tid = {0x11, 0x22};
    String token = "aoeusnth";
    ushort port = 6881;

    // Encode and decode query
    String encoded = krpc::encode_announce_peer_query((String)tid[..], node_id, info_hash,
                                                      port, token, true);
    defer free(encoded);

    krpc::KrpcQuery* query = krpc::decode_query(encoded)!!;
    defer query.free();

    // Verify all fields match
    krpc::AnnouncePeerArgs* args = (krpc::AnnouncePeerArgs*)query.args;
    for (usz i = 0; i < 20; i++)
    {
        assert(args.info_hash[i] == info_hash[i], "Info hash should match");
    }
    assert(args.port == port, "Port should match");
    assert(args.token == token, "Token should match");
    assert(args.implied_port == true, "Implied port should match");

    io::printn("✓ Roundtrip: announce_peer query");
}

fn void test_roundtrip_error() @test
{
    char[2] tid = {0x56, 0x78};
    int code = 203;
    String message = "Protocol Error: malformed packet";

    // Encode and decode error
    String encoded = krpc::encode_error((String)tid[..], code, message);
    defer free(encoded);

    krpc::KrpcError* error = krpc::decode_error(encoded)!!;
    defer error.free();

    // Verify
    assert(error.code == code, "Error code should match");
    assert(error.message == message, "Error message should match");
    assert(error.base.transaction_id.len == 2, "Transaction ID length should match");
    assert(error.base.transaction_id[0] == tid[0], "Transaction ID byte 0 should match");
    assert(error.base.transaction_id[1] == tid[1], "Transaction ID byte 1 should match");

    io::printn("✓ Roundtrip: error message");
}

// ============================================================================
// BEP 32: IPv6 Extension Tests ("want" parameter and "nodes6" field)
// ============================================================================

// ----------------------------------------------------------------------------
// "want" Parameter Encoding Tests
// ----------------------------------------------------------------------------

fn void test_encode_find_node_query_want_ipv4_only() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash target = create_test_node_id(0x50);
    char[2] tid = {0xAA, 0xBB};

    // Request IPv4 only
    String encoded = krpc::encode_find_node_query((String)tid[..], node_id, target, true, false);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check "want" parameter
    BencodeValue* a_val = root.dict_get("a");
    BencodeValue* want_val = a_val.dict_get("want");
    assert(want_val != null && want_val.type == bencode::BencodeType.LIST, "Should have 'want' list");
    assert(want_val.list.len() == 1, "Should request 1 type (IPv4)");

    BencodeValue* item = want_val.list.get(0);
    assert(item.type == bencode::BencodeType.STRING, "Want item should be string");
    assert((String)item.string == "n4", "Should request 'n4' (IPv4)");

    io::printn("✓ Find node query with want IPv4 only");
}

fn void test_encode_find_node_query_want_ipv6_only() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash target = create_test_node_id(0x50);
    char[2] tid = {0xCC, 0xDD};

    // Request IPv6 only
    String encoded = krpc::encode_find_node_query((String)tid[..], node_id, target, false, true);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check "want" parameter
    BencodeValue* a_val = root.dict_get("a");
    BencodeValue* want_val = a_val.dict_get("want");
    assert(want_val != null && want_val.type == bencode::BencodeType.LIST, "Should have 'want' list");
    assert(want_val.list.len() == 1, "Should request 1 type (IPv6)");

    BencodeValue* item = want_val.list.get(0);
    assert((String)item.string == "n6", "Should request 'n6' (IPv6)");

    io::printn("✓ Find node query with want IPv6 only");
}

fn void test_encode_find_node_query_want_both() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash target = create_test_node_id(0x50);
    char[2] tid = {0xEE, 0xFF};

    // Request both IPv4 and IPv6
    String encoded = krpc::encode_find_node_query((String)tid[..], node_id, target, true, true);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check "want" parameter
    BencodeValue* a_val = root.dict_get("a");
    BencodeValue* want_val = a_val.dict_get("want");
    assert(want_val != null && want_val.type == bencode::BencodeType.LIST, "Should have 'want' list");
    assert(want_val.list.len() == 2, "Should request 2 types (IPv4 + IPv6)");

    BencodeValue* item0 = want_val.list.get(0);
    BencodeValue* item1 = want_val.list.get(1);
    assert((String)item0.string == "n4", "First item should be 'n4'");
    assert((String)item1.string == "n6", "Second item should be 'n6'");

    io::printn("✓ Find node query with want both IPv4 and IPv6");
}

fn void test_encode_find_node_query_want_neither() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash target = create_test_node_id(0x50);
    char[2] tid = {0x11, 0x22};

    // Request neither (backward compatible mode)
    String encoded = krpc::encode_find_node_query((String)tid[..], node_id, target, false, false);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // "want" parameter should be absent for backward compatibility
    BencodeValue* a_val = root.dict_get("a");
    BencodeValue* want_val = a_val.dict_get("want");
    assert(want_val == null, "Should not have 'want' parameter when both false");

    io::printn("✓ Find node query without want parameter (backward compatible)");
}

fn void test_encode_get_peers_query_want_both() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash info_hash = create_test_node_id(0x90);
    char[2] tid = {0x33, 0x44};

    // Request both IPv4 and IPv6
    String encoded = krpc::encode_get_peers_query((String)tid[..], node_id, info_hash, true, true);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check "want" parameter
    BencodeValue* a_val = root.dict_get("a");
    BencodeValue* want_val = a_val.dict_get("want");
    assert(want_val != null && want_val.type == bencode::BencodeType.LIST, "Should have 'want' list");
    assert(want_val.list.len() == 2, "Should request 2 types");

    io::printn("✓ Get peers query with want parameter");
}

// ----------------------------------------------------------------------------
// "want" Parameter Parsing Tests
// ----------------------------------------------------------------------------

fn void test_parse_find_node_args_want_default() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash target = create_test_node_id(0x50);

    // Create query without "want" parameter (backward compatible)
    char[20] node_id_bytes;
    char[20] target_bytes;
    for (usz i = 0; i < 20; i++) {
        node_id_bytes[i] = node_id[i];
        target_bytes[i] = target[i];
    }

    BencodeValue* args = bencode::@bdict(
        "id", bencode::make_string((String)node_id_bytes[..]),
        "target", bencode::make_string((String)target_bytes[..])
    );
    defer args.free();

    krpc::FindNodeArgs* parsed = krpc::parse_find_node_args(args)!!;
    defer free(parsed);

    // Should default to IPv4 only for backward compatibility
    assert(parsed.want_ipv4 == true, "Should default to wanting IPv4");
    assert(parsed.want_ipv6 == false, "Should default to not wanting IPv6");

    io::printn("✓ Parse find_node args: default want (IPv4 only)");
}

fn void test_parse_find_node_args_want_ipv4_only() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash target = create_test_node_id(0x50);

    char[20] node_id_bytes;
    char[20] target_bytes;
    for (usz i = 0; i < 20; i++) {
        node_id_bytes[i] = node_id[i];
        target_bytes[i] = target[i];
    }

    BencodeValue* want_list = bencode::make_list();
    want_list.list_append(bencode::make_string("n4"));

    BencodeValue* args = bencode::@bdict(
        "id", bencode::make_string((String)node_id_bytes[..]),
        "target", bencode::make_string((String)target_bytes[..]),
        "want", want_list
    );
    defer args.free();

    krpc::FindNodeArgs* parsed = krpc::parse_find_node_args(args)!!;
    defer free(parsed);

    assert(parsed.want_ipv4 == true, "Should want IPv4");
    assert(parsed.want_ipv6 == false, "Should not want IPv6");

    io::printn("✓ Parse find_node args: want IPv4 only");
}

fn void test_parse_find_node_args_want_ipv6_only() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash target = create_test_node_id(0x50);

    char[20] node_id_bytes;
    char[20] target_bytes;
    for (usz i = 0; i < 20; i++) {
        node_id_bytes[i] = node_id[i];
        target_bytes[i] = target[i];
    }

    BencodeValue* want_list = bencode::make_list();
    want_list.list_append(bencode::make_string("n6"));

    BencodeValue* args = bencode::@bdict(
        "id", bencode::make_string((String)node_id_bytes[..]),
        "target", bencode::make_string((String)target_bytes[..]),
        "want", want_list
    );
    defer args.free();

    krpc::FindNodeArgs* parsed = krpc::parse_find_node_args(args)!!;
    defer free(parsed);

    assert(parsed.want_ipv4 == false, "Should not want IPv4");
    assert(parsed.want_ipv6 == true, "Should want IPv6");

    io::printn("✓ Parse find_node args: want IPv6 only");
}

fn void test_parse_find_node_args_want_both() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash target = create_test_node_id(0x50);

    char[20] node_id_bytes;
    char[20] target_bytes;
    for (usz i = 0; i < 20; i++) {
        node_id_bytes[i] = node_id[i];
        target_bytes[i] = target[i];
    }

    BencodeValue* want_list = bencode::make_list();
    want_list.list_append(bencode::make_string("n4"));
    want_list.list_append(bencode::make_string("n6"));

    BencodeValue* args = bencode::@bdict(
        "id", bencode::make_string((String)node_id_bytes[..]),
        "target", bencode::make_string((String)target_bytes[..]),
        "want", want_list
    );
    defer args.free();

    krpc::FindNodeArgs* parsed = krpc::parse_find_node_args(args)!!;
    defer free(parsed);

    assert(parsed.want_ipv4 == true, "Should want IPv4");
    assert(parsed.want_ipv6 == true, "Should want IPv6");

    io::printn("✓ Parse find_node args: want both IPv4 and IPv6");
}

fn void test_parse_get_peers_args_want_both() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash info_hash = create_test_node_id(0x90);

    char[20] node_id_bytes;
    char[20] info_hash_bytes;
    for (usz i = 0; i < 20; i++) {
        node_id_bytes[i] = node_id[i];
        info_hash_bytes[i] = info_hash[i];
    }

    BencodeValue* want_list = bencode::make_list();
    want_list.list_append(bencode::make_string("n4"));
    want_list.list_append(bencode::make_string("n6"));

    BencodeValue* args = bencode::@bdict(
        "id", bencode::make_string((String)node_id_bytes[..]),
        "info_hash", bencode::make_string((String)info_hash_bytes[..]),
        "want", want_list
    );
    defer args.free();

    krpc::GetPeersArgs* parsed = krpc::parse_get_peers_args(args)!!;
    defer free(parsed);

    assert(parsed.want_ipv4 == true, "Should want IPv4");
    assert(parsed.want_ipv6 == true, "Should want IPv6");

    io::printn("✓ Parse get_peers args: want both");
}

// ----------------------------------------------------------------------------
// "nodes6" Field Encoding Tests
// ----------------------------------------------------------------------------

fn void test_encode_find_node_response_with_nodes6_only() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0x55, 0x66};

    // Create compact IPv6 node info (38 bytes: 20-byte ID + 16-byte IPv6 + 2-byte port)
    char[38] node6_info;
    // Node ID
    for (usz i = 0; i < 20; i++) node6_info[i] = (char)(0x60 + i);
    // IPv6 address: 2001:db8::1
    node6_info[20] = 0x20;
    node6_info[21] = 0x01;
    node6_info[22] = 0x0d;
    node6_info[23] = 0xb8;
    for (usz i = 24; i < 34; i++) node6_info[i] = 0x00;
    node6_info[34] = 0x00;
    node6_info[35] = 0x01;
    // Port: 6881 (big endian)
    node6_info[36] = 0x1A;
    node6_info[37] = 0xE1;

    // Empty IPv4 nodes
    char[] empty_nodes = {};

    String encoded = krpc::encode_find_node_response((String)tid[..], node_id, empty_nodes, node6_info[..]);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check response contains nodes6
    BencodeValue* r_val = root.dict_get("r");
    BencodeValue* nodes6_val = r_val.dict_get("nodes6");
    assert(nodes6_val != null && nodes6_val.type == bencode::BencodeType.STRING, "Should have 'nodes6' field");
    assert(nodes6_val.string.len == 38, "nodes6 should be 38 bytes");

    io::printn("✓ Find node response with nodes6 only");
}

fn void test_encode_find_node_response_with_both_nodes_and_nodes6() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0x77, 0x88};

    // Create IPv4 node (26 bytes)
    char[26] node4_info;
    for (usz i = 0; i < 26; i++) node4_info[i] = (char)(0x40 + i);

    // Create IPv6 node (38 bytes)
    char[38] node6_info;
    for (usz i = 0; i < 38; i++) node6_info[i] = (char)(0x60 + i);

    String encoded = krpc::encode_find_node_response((String)tid[..], node_id, node4_info[..], node6_info[..]);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check both nodes and nodes6 are present
    BencodeValue* r_val = root.dict_get("r");

    BencodeValue* nodes_val = r_val.dict_get("nodes");
    assert(nodes_val != null && nodes_val.string.len == 26, "Should have 'nodes' (26 bytes)");

    BencodeValue* nodes6_val = r_val.dict_get("nodes6");
    assert(nodes6_val != null && nodes6_val.string.len == 38, "Should have 'nodes6' (38 bytes)");

    io::printn("✓ Find node response with both nodes and nodes6");
}

fn void test_encode_find_node_response_with_multiple_nodes6() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0x99, 0xAA};

    // Create 3 IPv6 nodes (114 bytes total)
    char[114] nodes6;
    for (usz i = 0; i < 114; i++) nodes6[i] = (char)(i % 256);

    char[] empty_nodes = {};

    String encoded = krpc::encode_find_node_response((String)tid[..], node_id, empty_nodes, nodes6[..]);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    BencodeValue* r_val = root.dict_get("r");
    BencodeValue* nodes6_val = r_val.dict_get("nodes6");
    assert(nodes6_val.string.len == 114, "Should have 114 bytes (3 IPv6 nodes)");

    io::printn("✓ Find node response with multiple nodes6");
}

fn void test_encode_get_peers_response_with_nodes6() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0xBB, 0xCC};
    String token = "testtoken";

    // Create IPv6 node (38 bytes)
    char[38] nodes6;
    for (usz i = 0; i < 38; i++) nodes6[i] = (char)(0x70 + i);

    char[] empty_nodes = {};

    String encoded = krpc::encode_get_peers_response_with_nodes((String)tid[..], node_id, token, empty_nodes, nodes6[..]);
    defer free(encoded);

    BencodeValue* root = bencode::decode(encoded)!!;
    defer root.free();

    // Check response contains nodes6
    BencodeValue* r_val = root.dict_get("r");
    BencodeValue* nodes6_val = r_val.dict_get("nodes6");
    assert(nodes6_val != null && nodes6_val.string.len == 38, "Should have 'nodes6' (38 bytes)");

    // Check token is present
    BencodeValue* token_val = r_val.dict_get("token");
    assert(token_val != null, "Token should be present");

    io::printn("✓ Get peers response with nodes6");
}

// ----------------------------------------------------------------------------
// "nodes6" Field Parsing Tests
// ----------------------------------------------------------------------------

fn void test_parse_find_node_response_with_nodes6() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0xDD, 0xEE};

    // Create IPv6 node (38 bytes)
    char[38] node6_info;
    for (usz i = 0; i < 38; i++) node6_info[i] = (char)(0x80 + i);

    char[] empty_nodes = {};

    String encoded = krpc::encode_find_node_response((String)tid[..], node_id, empty_nodes, node6_info[..]);
    defer free(encoded);

    krpc::KrpcResponse* response = krpc::decode_response(encoded, QueryType.FIND_NODE)!!;
    defer response.free();

    krpc::FindNodeResponse* data = (krpc::FindNodeResponse*)response.data;
    assert(data.has_nodes6 == true, "Should have nodes6");
    assert(data.nodes6.len == 38, "nodes6 should be 38 bytes");

    // Verify content
    for (usz i = 0; i < 38; i++)
    {
        assert(data.nodes6[i] == node6_info[i], "nodes6 content should match");
    }

    io::printn("✓ Parse find_node response with nodes6");
}

fn void test_parse_find_node_response_with_both_nodes_and_nodes6() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0xFF, 0x00};

    // Create IPv4 node (26 bytes)
    char[26] node4_info;
    for (usz i = 0; i < 26; i++) node4_info[i] = (char)(0x40 + i);

    // Create IPv6 node (38 bytes)
    char[38] node6_info;
    for (usz i = 0; i < 38; i++) node6_info[i] = (char)(0x60 + i);

    String encoded = krpc::encode_find_node_response((String)tid[..], node_id, node4_info[..], node6_info[..]);
    defer free(encoded);

    krpc::KrpcResponse* response = krpc::decode_response(encoded, QueryType.FIND_NODE)!!;
    defer response.free();

    krpc::FindNodeResponse* data = (krpc::FindNodeResponse*)response.data;

    // Check IPv4 nodes
    assert(data.nodes.len == 26, "Should have IPv4 nodes (26 bytes)");
    for (usz i = 0; i < 26; i++)
    {
        assert(data.nodes[i] == node4_info[i], "IPv4 nodes should match");
    }

    // Check IPv6 nodes
    assert(data.has_nodes6 == true, "Should have nodes6");
    assert(data.nodes6.len == 38, "nodes6 should be 38 bytes");
    for (usz i = 0; i < 38; i++)
    {
        assert(data.nodes6[i] == node6_info[i], "IPv6 nodes should match");
    }

    io::printn("✓ Parse find_node response with both nodes and nodes6");
}

fn void test_parse_find_node_response_invalid_nodes6_length() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0x11, 0x22};

    char[20] node_id_bytes;
    for (usz i = 0; i < 20; i++) node_id_bytes[i] = node_id[i];

    // Create invalid nodes6 (37 bytes - not a multiple of 38)
    char[37] invalid_nodes6;
    for (usz i = 0; i < 37; i++) invalid_nodes6[i] = (char)i;

    // Include valid nodes field (required for find_node response)
    char[26] valid_nodes;
    for (usz i = 0; i < 26; i++) valid_nodes[i] = (char)(0x50 + i);

    BencodeValue* r_dict = bencode::@bdict(
        "id", bencode::make_string((String)node_id_bytes[..]),
        "nodes", bencode::make_string((String)valid_nodes[..]),
        "nodes6", bencode::make_string((String)invalid_nodes6[..])
    );

    BencodeValue* root = bencode::@bdict(
        "t", bencode::make_string((String)tid[..]),
        "y", bencode::make_string("r"),
        "r", r_dict
    );
    defer root.free();

    String encoded = root.encode();
    defer free(encoded);

    krpc::KrpcResponse* response = krpc::decode_response(encoded, QueryType.FIND_NODE)!!;
    defer response.free();

    krpc::FindNodeResponse* data = (krpc::FindNodeResponse*)response.data;

    // Invalid length should be rejected, has_nodes6 should be false
    assert(data.has_nodes6 == false, "Invalid nodes6 length should be rejected");

    io::printn("✓ Parse find_node response: invalid nodes6 length is rejected");
}

fn void test_parse_get_peers_response_with_nodes6() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0x33, 0x44};
    String token = "aoeusnth";

    // Create IPv6 node (38 bytes)
    char[38] nodes6;
    for (usz i = 0; i < 38; i++) nodes6[i] = (char)(0x90 + i);

    char[] empty_nodes = {};

    String encoded = krpc::encode_get_peers_response_with_nodes((String)tid[..], node_id, token, empty_nodes, nodes6[..]);
    defer free(encoded);

    krpc::KrpcResponse* response = krpc::decode_response(encoded, QueryType.GET_PEERS)!!;
    defer response.free();

    krpc::GetPeersResponse* data = (krpc::GetPeersResponse*)response.data;
    assert(data.has_nodes6 == true, "Should have nodes6");
    assert(data.nodes6.len == 38, "nodes6 should be 38 bytes");
    assert(data.token == token, "Token should match");

    io::printn("✓ Parse get_peers response with nodes6");
}

// ----------------------------------------------------------------------------
// IPv6 Roundtrip Tests
// ----------------------------------------------------------------------------

fn void test_roundtrip_find_node_with_want_parameter() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash target = create_test_node_id(0x50);
    char[2] tid = {0x55, 0x66};

    // Encode query with both IPv4 and IPv6 wanted
    String encoded = krpc::encode_find_node_query((String)tid[..], node_id, target, true, true);
    defer free(encoded);

    // Decode query
    krpc::KrpcQuery* query = krpc::decode_query(encoded)!!;
    defer query.free();

    // Verify want flags
    krpc::FindNodeArgs* args = (krpc::FindNodeArgs*)query.args;
    assert(args.want_ipv4 == true, "Should want IPv4");
    assert(args.want_ipv6 == true, "Should want IPv6");

    io::printn("✓ Roundtrip: find_node with want parameter");
}

fn void test_roundtrip_find_node_with_nodes6() @test
{
    InfoHash node_id = create_test_node_id(0x30);
    char[2] tid = {0x77, 0x88};

    // Create IPv4 and IPv6 nodes
    char[26] nodes4;
    for (usz i = 0; i < 26; i++) nodes4[i] = (char)(0x40 + i);

    char[76] nodes6;  // 2 IPv6 nodes
    for (usz i = 0; i < 76; i++) nodes6[i] = (char)(0x60 + i);

    // Encode response
    String encoded = krpc::encode_find_node_response((String)tid[..], node_id, nodes4[..], nodes6[..]);
    defer free(encoded);

    // Decode response
    krpc::KrpcResponse* response = krpc::decode_response(encoded, QueryType.FIND_NODE)!!;
    defer response.free();

    // Verify both node types
    krpc::FindNodeResponse* data = (krpc::FindNodeResponse*)response.data;
    assert(data.nodes.len == 26, "Should have IPv4 nodes");
    assert(data.has_nodes6 == true, "Should have nodes6 flag set");
    assert(data.nodes6.len == 76, "Should have 2 IPv6 nodes (76 bytes)");

    // Verify content matches
    for (usz i = 0; i < 26; i++)
    {
        assert(data.nodes[i] == nodes4[i], "IPv4 nodes should match original");
    }
    for (usz i = 0; i < 76; i++)
    {
        assert(data.nodes6[i] == nodes6[i], "IPv6 nodes should match original");
    }

    io::printn("✓ Roundtrip: find_node response with nodes6");
}

fn void test_roundtrip_get_peers_with_want_and_nodes6() @test
{
    InfoHash node_id = create_test_node_id(0x10);
    InfoHash info_hash = create_test_node_id(0x90);
    char[2] tid = {0x99, 0xAA};

    // Encode query with want parameter
    String encoded_query = krpc::encode_get_peers_query((String)tid[..], node_id, info_hash, false, true);
    defer free(encoded_query);

    // Decode query and verify
    krpc::KrpcQuery* query = krpc::decode_query(encoded_query)!!;
    defer query.free();

    krpc::GetPeersArgs* query_args = (krpc::GetPeersArgs*)query.args;
    assert(query_args.want_ipv4 == false, "Should not want IPv4");
    assert(query_args.want_ipv6 == true, "Should want IPv6");

    // Encode response with nodes6
    String token = "testtoken";
    char[38] nodes6;
    for (usz i = 0; i < 38; i++) nodes6[i] = (char)(0xA0 + i);
    char[] empty_nodes = {};

    String encoded_response = krpc::encode_get_peers_response_with_nodes((String)tid[..], node_id, token, empty_nodes, nodes6[..]);
    defer free(encoded_response);

    // Decode response and verify
    krpc::KrpcResponse* response = krpc::decode_response(encoded_response, QueryType.GET_PEERS)!!;
    defer response.free();

    krpc::GetPeersResponse* response_data = (krpc::GetPeersResponse*)response.data;
    assert(response_data.has_nodes6 == true, "Should have nodes6");
    assert(response_data.nodes6.len == 38, "Should have 1 IPv6 node");
    assert(response_data.token == token, "Token should match");

    io::printn("✓ Roundtrip: get_peers with want parameter and nodes6");
}
