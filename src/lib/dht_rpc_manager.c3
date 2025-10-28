module libtorrent::dht_rpc_manager;

import std::io;
import std::time;
import std::collections::map;
import libtorrent::common;
import libtorrent::krpc;

/**
 * DHT RPC Manager
 * ===============
 * Manages DHT RPC transactions, tracking requests and matching responses.
 * Handles timeouts, retries, and transaction ID generation.
 *
 * Key features:
 * - Automatic transaction ID generation (2 bytes)
 * - Request/response matching
 * - Timeout detection and cleanup
 * - Callback-based response handling
 */

// ============================================================================
// Constants
// ============================================================================

const int MAX_TRANSACTIONS = 1024;     // Maximum concurrent transactions
const int TRANSACTION_TIMEOUT_MS = 5000;  // 5 second timeout
const int MAX_RETRIES = 2;             // Retry failed requests up to 2 times

// ============================================================================
// Fault Definitions
// ============================================================================

faultdef RPC_TRANSACTION_TABLE_FULL;
faultdef RPC_TRANSACTION_NOT_FOUND;
faultdef RPC_INVALID_RESPONSE;

// ============================================================================
// Data Structures
// ============================================================================

/**
 * Transaction callback type
 * Called when a response is received or transaction times out
 *
 * @param response The response message (null on timeout)
 * @param userdata User-provided data passed to callback
 */
alias TransactionCallback = fn void(krpc::KrpcMessage* response, void* userdata);

/**
 * Userdata cleanup callback type
 * Called to free userdata when cancelling transactions
 *
 * @param userdata User-provided data to free
 */
alias UserdataCleanup = fn void(void* userdata);

/**
 * Transaction state
 */
enum TransactionState : char
{
    PENDING,      // Waiting for response
    COMPLETED,    // Response received
    TIMEOUT,      // Request timed out
    FAILED        // Request failed (network error, etc.)
}

/**
 * RPC transaction tracking entry
 */
struct Transaction
{
    char[2] transaction_id;       // 2-byte transaction ID
    krpc::QueryType query_type;   // Type of query (ping, find_node, etc.)
    common::NodeId target_id;     // Target node ID
    common::Ipv4Addr target_ip;   // Target IP address
    ushort target_port;           // Target port
    long sent_time;               // Unix timestamp when request was sent
    TransactionCallback callback; // Callback to invoke on response/timeout
    void* userdata;               // User data passed to callback
    TransactionState state;       // Current transaction state
    char retry_count;             // Number of retries attempted
}

/**
 * RPC Manager
 * Manages all active DHT RPC transactions
 */
struct RpcManager
{
    Transaction[MAX_TRANSACTIONS] transactions;
    int transaction_count;
    ushort next_tid;              // Next transaction ID (increments)
}

// ============================================================================
// RPC Manager Lifecycle
// ============================================================================

/**
 * Create a new RPC manager
 *
 * @return Initialized RPC manager (allocated on heap)
 */
fn RpcManager* create_rpc_manager() @public
{
    RpcManager* mgr = mem::new(RpcManager);
    mgr.transaction_count = 0;
    mgr.next_tid = 1;  // Start at 1 (0 is reserved for errors)
    return mgr;
}

/**
 * Cancel all transactions and free their userdata
 * Useful for cleanup when shutting down
 *
 * @param mgr RPC manager
 * @param free_userdata Function to free userdata (can be null)
 */
fn void cancel_all_transactions(RpcManager* mgr, UserdataCleanup free_userdata) @public
{
    for (int i = mgr.transaction_count - 1; i >= 0; i--)
    {
        if (free_userdata && mgr.transactions[i].userdata)
        {
            free_userdata(mgr.transactions[i].userdata);
        }
    }
    mgr.transaction_count = 0;
}

/**
 * Free an RPC manager
 *
 * @param mgr RPC manager to free
 */
fn void free_rpc_manager(RpcManager* mgr) @public
{
    if (mgr) free(mgr);
}

// ============================================================================
// Transaction ID Management
// ============================================================================

/**
 * Generate a unique 2-byte transaction ID
 *
 * @param mgr RPC manager
 * @param tid_out Output buffer for transaction ID (must be 2 bytes)
 */
fn void generate_tid(RpcManager* mgr, char* tid_out)
{
    // Use incrementing counter for transaction IDs
    ushort tid = mgr.next_tid++;

    // Wrap around at 65535
    if (mgr.next_tid == 0) mgr.next_tid = 1;

    // Convert to 2-byte big-endian format
    tid_out[0] = (char)((tid >> 8) & 0xFF);
    tid_out[1] = (char)(tid & 0xFF);
}

/**
 * Find a transaction by transaction ID
 *
 * @param mgr RPC manager
 * @param tid Transaction ID (as String slice)
 * @return Index of transaction, or -1 if not found
 */
fn int find_transaction(RpcManager* mgr, String tid)
{
    // Only match if transaction ID is exactly 2 bytes
    if (tid.len != 2) return -1;

    for (int i = 0; i < mgr.transaction_count; i++)
    {
        if (mgr.transactions[i].transaction_id[0] == tid[0] &&
            mgr.transactions[i].transaction_id[1] == tid[1])
        {
            return i;
        }
    }
    return -1;
}

// ============================================================================
// Transaction Management
// ============================================================================

/**
 * Create a new transaction
 *
 * @param mgr RPC manager
 * @param query_type Type of query
 * @param target_id Target node ID
 * @param target_ip Target IP address
 * @param target_port Target port
 * @param callback Callback to invoke on response/timeout
 * @param userdata User data passed to callback
 * @return Transaction ID (2 bytes), or fault if table is full
 */
fn char[2]? create_transaction(RpcManager* mgr, krpc::QueryType query_type,
                                common::NodeId target_id, common::Ipv4Addr target_ip,
                                ushort target_port, TransactionCallback callback,
                                void* userdata) @public
{
    // Check if transaction table is full
    if (mgr.transaction_count >= MAX_TRANSACTIONS)
    {
        return RPC_TRANSACTION_TABLE_FULL?;
    }

    // Generate new transaction ID
    char[2] tid;
    generate_tid(mgr, &tid[0]);

    // Create transaction entry
    Transaction* txn = &mgr.transactions[mgr.transaction_count];
    txn.transaction_id[0] = tid[0];
    txn.transaction_id[1] = tid[1];
    txn.query_type = query_type;
    for (int i = 0; i < 20; i++) txn.target_id[i] = target_id[i];
    for (int i = 0; i < 4; i++) txn.target_ip[i] = target_ip[i];
    txn.target_port = target_port;
    txn.sent_time = (long)time::now().to_seconds();
    txn.callback = callback;
    txn.userdata = userdata;
    txn.state = TransactionState.PENDING;
    txn.retry_count = 0;

    mgr.transaction_count++;

    return tid;
}

/**
 * Handle a response message
 * Finds the corresponding transaction and invokes its callback
 *
 * @param mgr RPC manager
 * @param response Response message
 * @return true if transaction was found and handled
 */
fn bool handle_response(RpcManager* mgr, krpc::KrpcMessage* response) @public
{
    // Find transaction by ID
    int idx = find_transaction(mgr, response.transaction_id);
    if (idx < 0) return false;

    Transaction* txn = &mgr.transactions[idx];

    // Mark as completed
    txn.state = TransactionState.COMPLETED;

    // Invoke callback
    if (txn.callback)
    {
        txn.callback(response, txn.userdata);
    }

    // Remove transaction (swap with last)
    if (idx < mgr.transaction_count - 1)
    {
        mgr.transactions[idx] = mgr.transactions[mgr.transaction_count - 1];
    }
    mgr.transaction_count--;

    return true;
}

/**
 * Process timeouts
 * Checks for timed-out transactions and invokes their callbacks
 *
 * @param mgr RPC manager
 * @return Number of transactions that timed out
 */
fn int process_timeouts(RpcManager* mgr) @public
{
    long now = (long)time::now().to_seconds();
    int timeout_count = 0;

    // Check each transaction for timeout
    for (int i = mgr.transaction_count - 1; i >= 0; i--)
    {
        Transaction* txn = &mgr.transactions[i];

        // Skip completed/failed transactions
        if (txn.state != TransactionState.PENDING) continue;

        // Check if timeout elapsed
        long elapsed_ms = (now - txn.sent_time) * 1000;
        if (elapsed_ms >= TRANSACTION_TIMEOUT_MS)
        {
            // Mark as timed out
            txn.state = TransactionState.TIMEOUT;

            // Invoke callback with null response
            if (txn.callback)
            {
                txn.callback(null, txn.userdata);
            }

            timeout_count++;

            // Remove transaction (swap with last)
            if (i < mgr.transaction_count - 1)
            {
                mgr.transactions[i] = mgr.transactions[mgr.transaction_count - 1];
            }
            mgr.transaction_count--;
        }
    }

    return timeout_count;
}

/**
 * Cancel a transaction
 *
 * @param mgr RPC manager
 * @param tid Transaction ID (as String slice)
 * @return true if transaction was found and cancelled
 */
fn bool cancel_transaction(RpcManager* mgr, String tid) @public
{
    int idx = find_transaction(mgr, tid);
    if (idx < 0) return false;

    // Remove transaction (swap with last)
    if (idx < mgr.transaction_count - 1)
    {
        mgr.transactions[idx] = mgr.transactions[mgr.transaction_count - 1];
    }
    mgr.transaction_count--;

    return true;
}

/**
 * Get statistics about the RPC manager
 *
 * @param mgr RPC manager
 * @param total_transactions Output: total active transactions
 * @param pending_transactions Output: pending transactions
 */
fn void get_stats(RpcManager* mgr, int* total_transactions, int* pending_transactions) @public
{
    *total_transactions = mgr.transaction_count;

    int pending = 0;
    for (int i = 0; i < mgr.transaction_count; i++)
    {
        if (mgr.transactions[i].state == TransactionState.PENDING)
        {
            pending++;
        }
    }
    *pending_transactions = pending;
}
