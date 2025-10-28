module libtorrent::krpc;

import std::io;
import std::time;
import std::collections::list;
import libtorrent::bencode;
import libtorrent::common;

/**
 * KRPC Protocol Implementation (BEP 5)
 * ====================================
 * KRPC (Kademlia RPC) is the protocol used by BitTorrent's DHT.
 * It consists of bencode-encoded dictionaries sent over UDP.
 *
 * Message Types:
 * - Query ("y": "q") - Request from client
 * - Response ("y": "r") - Success response
 * - Error ("y": "e") - Error response
 *
 * Query Types:
 * - ping - Check if node is alive
 * - find_node - Locate nodes near target ID
 * - get_peers - Find peers for info hash
 * - announce_peer - Announce self as peer
 */

// ============================================================================
// Fault Definitions (BEP 5 Error Codes)
// ============================================================================

faultdef KRPC_GENERIC_ERROR;        // 201: Generic Error
faultdef KRPC_SERVER_ERROR;         // 202: Server Error
faultdef KRPC_PROTOCOL_ERROR;       // 203: Protocol Error (malformed packet, bad token)
faultdef KRPC_METHOD_UNKNOWN;       // 204: Method Unknown
faultdef KRPC_INVALID_MESSAGE;      // Invalid message format
faultdef KRPC_INVALID_TRANSACTION;  // Invalid transaction ID

// ============================================================================
// Constants
// ============================================================================

const usz TRANSACTION_ID_LEN = 2;    // Transaction IDs are typically 2 bytes
const usz NODE_ID_LEN = 20;          // Node IDs are 160 bits (20 bytes)
const usz NODE_INFO_LEN = 26;        // Compact node info: 20-byte ID + 6-byte address
const usz PEER_INFO_LEN = 6;         // Compact peer info: 4-byte IP + 2-byte port

const String CLIENT_VERSION = "LC01";  // "LC" = libtorrent-c3, version 01

// ============================================================================
// Type Aliases
// ============================================================================

alias TransactionList = List{Transaction};

// ============================================================================
// Enums
// ============================================================================

/**
 * KRPC message type
 */
enum MessageType {
    QUERY,      // "q" - Query message
    RESPONSE,   // "r" - Response message
    ERROR       // "e" - Error message
}

/**
 * KRPC query type
 */
enum QueryType {
    PING,           // "ping" - Health check
    FIND_NODE,      // "find_node" - Locate nodes
    GET_PEERS,      // "get_peers" - Find peers for torrent
    ANNOUNCE_PEER   // "announce_peer" - Announce self as peer
}

// ============================================================================
// Core Data Structures
// ============================================================================

/**
 * Base KRPC message (common fields for all message types)
 */
struct KrpcMessage {
    MessageType type;          // Message type (query, response, or error)
    String transaction_id;     // Transaction ID (2-4 bytes, echoed in response)
    String version;            // Client version (BEP 20) - optional
}

/**
 * KRPC query message
 */
struct KrpcQuery {
    KrpcMessage base;          // Base message fields
    QueryType query_type;      // Type of query
    InfoHash node_id;          // Querying node's ID (20 bytes)

    // Query-specific arguments (union-like structure)
    // For ping: no additional args
    // For find_node: InfoHash target
    // For get_peers: InfoHash info_hash
    // For announce_peer: see AnnouncePeerArgs
    void* args;                // Pointer to query-specific args
}

/**
 * KRPC response message
 */
struct KrpcResponse {
    KrpcMessage base;          // Base message fields
    QueryType query_type;      // Type of query this responds to
    InfoHash node_id;          // Responding node's ID (20 bytes)

    // Response-specific data (union-like structure)
    // For ping: no additional data
    // For find_node: char[] nodes (compact node info)
    // For get_peers: see GetPeersResponseData
    // For announce_peer: no additional data
    void* data;                // Pointer to response-specific data
}

/**
 * KRPC error message
 */
struct KrpcError {
    KrpcMessage base;          // Base message fields
    int code;                  // Error code (201-204)
    String message;            // Error description
}

// ============================================================================
// Query-Specific Structures
// ============================================================================

/**
 * find_node query arguments
 */
struct FindNodeArgs {
    InfoHash target;           // ID of node being sought
}

/**
 * get_peers query arguments
 */
struct GetPeersArgs {
    InfoHash info_hash;        // Torrent info hash
}

/**
 * announce_peer query arguments
 */
struct AnnouncePeerArgs {
    InfoHash info_hash;        // Torrent info hash
    ushort port;               // Port number
    String token;              // Token from get_peers response
    bool implied_port;         // Use source port if true (optional, default false)
}

// ============================================================================
// Response-Specific Structures
// ============================================================================

/**
 * find_node response data
 */
struct FindNodeResponse {
    char[] nodes;              // Compact node info (26 bytes per node)
}

/**
 * get_peers response data
 * Either contains peer list (values) or node list (nodes), plus token
 */
struct GetPeersResponse {
    String token;              // Opaque token (required for announce_peer)
    char[] values;             // Compact peer info (6 bytes per peer) - empty if no peers
    char[] nodes;              // Compact node info (26 bytes per node) - empty if no nodes
    bool has_values;           // True if values field is present
    bool has_nodes;            // True if nodes field is present
}

// ============================================================================
// Transaction Management
// ============================================================================

/**
 * Transaction state for tracking queries
 */
struct Transaction {
    String transaction_id;     // Transaction ID (2 bytes)
    QueryType query_type;      // Type of query sent
    long sent_at_sec;          // When query was sent (seconds since epoch)
    void* callback_data;       // User data for callback (opaque pointer)
}

/**
 * Transaction tracker (uses List from std::collections)
 */
struct TransactionTracker {
    TransactionList active;    // Active transactions
    ushort next_id;            // Counter for generating transaction IDs
}

// ============================================================================
// Memory Management
// ============================================================================

/**
 * Free KRPC query
 */
fn void free_query(KrpcQuery* query) @public
{
    if (query == null) return;

    if (query.base.transaction_id.len > 0) free(query.base.transaction_id);
    if (query.base.version.len > 0) free(query.base.version);

    // Free query-specific args
    if (query.args != null)
    {
        switch (query.query_type)
        {
            case QueryType.FIND_NODE:
                FindNodeArgs* args = (FindNodeArgs*)query.args;
                free(args);
            case QueryType.GET_PEERS:
                GetPeersArgs* args = (GetPeersArgs*)query.args;
                free(args);
            case QueryType.ANNOUNCE_PEER:
                AnnouncePeerArgs* args = (AnnouncePeerArgs*)query.args;
                if (args.token.len > 0) free(args.token);
                free(args);
            default:
                // ping has no args
        }
    }

    free(query);
}

/**
 * Free KRPC response
 */
fn void free_response(KrpcResponse* response) @public
{
    if (response == null) return;

    if (response.base.transaction_id.len > 0) free(response.base.transaction_id);
    if (response.base.version.len > 0) free(response.base.version);

    // Free response-specific data
    if (response.data != null)
    {
        switch (response.query_type)
        {
            case QueryType.FIND_NODE:
                FindNodeResponse* data = (FindNodeResponse*)response.data;
                if (data.nodes.len > 0) free(data.nodes);
                free(data);
            case QueryType.GET_PEERS:
                GetPeersResponse* data = (GetPeersResponse*)response.data;
                if (data.token.len > 0) free(data.token);
                if (data.values.len > 0) free(data.values);
                if (data.nodes.len > 0) free(data.nodes);
                free(data);
            default:
                // ping and announce_peer have no additional data
        }
    }

    free(response);
}

/**
 * Free KRPC error
 */
fn void free_error(KrpcError* error) @public
{
    if (error == null) return;

    if (error.base.transaction_id.len > 0) free(error.base.transaction_id);
    if (error.base.version.len > 0) free(error.base.version);
    if (error.message.len > 0) free(error.message);

    free(error);
}

// ============================================================================
// Utility Functions
// ============================================================================

/**
 * Convert error code to fault
 */
fn fault? error_code_to_fault(int code) @public
{
    switch (code)
    {
        case 201: return KRPC_GENERIC_ERROR?;
        case 202: return KRPC_SERVER_ERROR?;
        case 203: return KRPC_PROTOCOL_ERROR?;
        case 204: return KRPC_METHOD_UNKNOWN?;
        default:  return KRPC_GENERIC_ERROR?;
    }
}

// ============================================================================
// Transaction Management Functions
// ============================================================================

/**
 * Create a new transaction tracker
 */
fn TransactionTracker create_transaction_tracker() @public
{
    TransactionTracker tracker;
    tracker.active.init(mem);
    tracker.next_id = 1;
    return tracker;
}

/**
 * Generate a transaction ID (2-byte binary string)
 */
fn String generate_transaction_id(TransactionTracker* tracker) @public
{
    // Generate 2-byte transaction ID from counter
    char[2] tid_bytes;
    tid_bytes[0] = (char)((tracker.next_id >> 8) & 0xFF);
    tid_bytes[1] = (char)(tracker.next_id & 0xFF);

    // Increment counter (wraps at 65535)
    tracker.next_id++;

    // Copy to heap
    char[] result = mem::new_array(char, 2);
    result[0] = tid_bytes[0];
    result[1] = tid_bytes[1];

    return (String)result;
}

/**
 * Track a new transaction
 */
fn void track_transaction(TransactionTracker* tracker, Transaction t) @public
{
    // Copy transaction ID to heap
    char[] tid_copy = mem::new_array(char, t.transaction_id.len);
    foreach (i, c : t.transaction_id) tid_copy[i] = c;

    Transaction tracked;
    tracked.transaction_id = (String)tid_copy;
    tracked.query_type = t.query_type;
    tracked.sent_at_sec = t.sent_at_sec;
    tracked.callback_data = t.callback_data;

    // Add to active list
    tracker.active.push(tracked);
}

/**
 * Find a transaction by ID
 * Returns the index of the transaction, or -1 if not found
 */
fn usz find_transaction_index(TransactionTracker* tracker, String tid) @public
{
    foreach (i, &t : tracker.active)
    {
        if (t.transaction_id.len != tid.len) continue;

        // Compare transaction IDs byte by byte
        bool match = true;
        foreach (j, c : tid)
        {
            if (t.transaction_id[j] != c)
            {
                match = false;
                break;
            }
        }

        if (match) return i;
    }

    return usz.max;  // Not found
}

/**
 * Find a transaction by ID (returns copy of transaction)
 * Returns KRPC_INVALID_TRANSACTION if not found
 */
fn Transaction? find_transaction(TransactionTracker* tracker, String tid) @public
{
    usz idx = find_transaction_index(tracker, tid);
    if (idx == usz.max) return KRPC_INVALID_TRANSACTION?;

    // Return copy of element
    return tracker.active.get(idx);
}

/**
 * Remove a transaction by ID
 */
fn void remove_transaction(TransactionTracker* tracker, String tid) @public
{
    foreach (i, &t : tracker.active)
    {
        if (t.transaction_id.len != tid.len) continue;

        // Compare transaction IDs byte by byte
        bool match = true;
        foreach (j, c : tid)
        {
            if (t.transaction_id[j] != c)
            {
                match = false;
                break;
            }
        }

        if (match)
        {
            // Free transaction ID
            free(t.transaction_id);

            // Remove from list
            tracker.active.remove_at(i);
            return;
        }
    }
}

/**
 * Get all expired transactions (older than timeout)
 * @param timeout Timeout in seconds
 * @return List of expired transactions (caller must free list but NOT transaction_ids)
 */
fn TransactionList get_expired_transactions(TransactionTracker* tracker, long timeout_seconds) @public
{
    long now_sec = (long)time::now().to_seconds();
    TransactionList expired;
    expired.init(mem);

    foreach (i, &t : tracker.active)
    {
        long elapsed = now_sec - t.sent_at_sec;
        if (elapsed >= timeout_seconds)
        {
            // Copy expired transaction (shallow copy - IDs still owned by tracker)
            Transaction exp;
            exp.transaction_id = t.transaction_id;
            exp.query_type = t.query_type;
            exp.sent_at_sec = t.sent_at_sec;
            exp.callback_data = t.callback_data;

            expired.push(exp);
        }
    }

    return expired;
}

/**
 * Free transaction tracker
 */
fn void free_transaction_tracker(TransactionTracker* tracker) @public
{
    // Free all transaction IDs
    foreach (&t : tracker.active)
    {
        if (t.transaction_id.len > 0) free(t.transaction_id);
    }

    // Free list
    tracker.active.free();
}

// ============================================================================
// Message Encoding Functions (BEP 5)
// ============================================================================

/**
 * Encode a ping query
 * @param transaction_id Transaction ID (typically 2 bytes)
 * @param node_id Querying node's ID (20 bytes)
 * @return Bencode-encoded query message (caller must free)
 */
fn String encode_ping_query(String transaction_id, InfoHash node_id) @public
{
    BencodeValue* msg = bencode::@bdict_wrap(
        "a", bencode::@bdict_wrap(
            "id", bencode::make_string((String)node_id[..])
        ),
        "q", "ping",
        "t", bencode::make_string(transaction_id),
        "v", CLIENT_VERSION,
        "y", "q"
    );
    defer bencode::free_bencode_value(msg);

    return bencode::encode(msg);
}

/**
 * Encode a find_node query
 * @param transaction_id Transaction ID
 * @param node_id Querying node's ID (20 bytes)
 * @param target Target node ID being sought (20 bytes)
 * @return Bencode-encoded query message (caller must free)
 */
fn String encode_find_node_query(String transaction_id, InfoHash node_id, InfoHash target) @public
{
    BencodeValue* msg = bencode::@bdict_wrap(
        "a", bencode::@bdict_wrap(
            "id", bencode::make_string((String)node_id[..]),
            "target", bencode::make_string((String)target[..])
        ),
        "q", "find_node",
        "t", bencode::make_string(transaction_id),
        "v", CLIENT_VERSION,
        "y", "q"
    );
    defer bencode::free_bencode_value(msg);

    return bencode::encode(msg);
}

/**
 * Encode a get_peers query
 * @param transaction_id Transaction ID
 * @param node_id Querying node's ID (20 bytes)
 * @param info_hash Torrent info hash (20 bytes)
 * @return Bencode-encoded query message (caller must free)
 */
fn String encode_get_peers_query(String transaction_id, InfoHash node_id, InfoHash info_hash) @public
{
    BencodeValue* msg = bencode::@bdict_wrap(
        "a", bencode::@bdict_wrap(
            "id", bencode::make_string((String)node_id[..]),
            "info_hash", bencode::make_string((String)info_hash[..])
        ),
        "q", "get_peers",
        "t", bencode::make_string(transaction_id),
        "v", CLIENT_VERSION,
        "y", "q"
    );
    defer bencode::free_bencode_value(msg);

    return bencode::encode(msg);
}

/**
 * Encode an announce_peer query
 * @param transaction_id Transaction ID
 * @param node_id Querying node's ID (20 bytes)
 * @param info_hash Torrent info hash (20 bytes)
 * @param port Port number the peer is listening on
 * @param token Token from previous get_peers response
 * @param implied_port If true, use source port; if false, use specified port
 * @return Bencode-encoded query message (caller must free)
 */
fn String encode_announce_peer_query(String transaction_id, InfoHash node_id,
                                     InfoHash info_hash, ushort port,
                                     String token, bool implied_port) @public
{
    BencodeValue* msg = bencode::@bdict_wrap(
        "a", bencode::@bdict_wrap(
            "id", bencode::make_string((String)node_id[..]),
            "implied_port", bencode::make_integer(implied_port ? 1 : 0),
            "info_hash", bencode::make_string((String)info_hash[..]),
            "port", bencode::make_integer(port),
            "token", bencode::make_string(token)
        ),
        "q", "announce_peer",
        "t", bencode::make_string(transaction_id),
        "v", CLIENT_VERSION,
        "y", "q"
    );
    defer bencode::free_bencode_value(msg);

    return bencode::encode(msg);
}

/**
 * Encode a ping response
 * @param transaction_id Transaction ID (echo from query)
 * @param node_id Responding node's ID (20 bytes)
 * @return Bencode-encoded response message (caller must free)
 */
fn String encode_ping_response(String transaction_id, InfoHash node_id) @public
{
    BencodeValue* msg = bencode::@bdict_wrap(
        "r", bencode::@bdict_wrap(
            "id", bencode::make_string((String)node_id[..])
        ),
        "t", bencode::make_string(transaction_id),
        "v", CLIENT_VERSION,
        "y", "r"
    );
    defer bencode::free_bencode_value(msg);

    return bencode::encode(msg);
}

/**
 * Encode a find_node response
 * @param transaction_id Transaction ID (echo from query)
 * @param node_id Responding node's ID (20 bytes)
 * @param nodes Compact node info (26 bytes per node: 20-byte ID + 6-byte address)
 * @return Bencode-encoded response message (caller must free)
 */
fn String encode_find_node_response(String transaction_id, InfoHash node_id, char[] nodes) @public
{
    BencodeValue* msg = bencode::@bdict_wrap(
        "r", bencode::@bdict_wrap(
            "id", bencode::make_string((String)node_id[..]),
            "nodes", bencode::make_string((String)nodes)
        ),
        "t", bencode::make_string(transaction_id),
        "v", CLIENT_VERSION,
        "y", "r"
    );
    defer bencode::free_bencode_value(msg);

    return bencode::encode(msg);
}

/**
 * Encode a get_peers response with peer values
 * @param transaction_id Transaction ID (echo from query)
 * @param node_id Responding node's ID (20 bytes)
 * @param token Opaque token for future announce_peer
 * @param values List of compact peer info (6 bytes each: 4-byte IP + 2-byte port)
 * @return Bencode-encoded response message (caller must free)
 */
fn String encode_get_peers_response_with_values(String transaction_id, InfoHash node_id,
                                                String token, char[] values) @public
{
    // Build list of 6-byte peer strings
    BencodeValue* values_list = bencode::make_list();

    // Each peer is 6 bytes
    usz num_peers = values.len / PEER_INFO_LEN;
    for (usz i = 0; i < num_peers; i++)
    {
        usz offset = i * PEER_INFO_LEN;
        char[PEER_INFO_LEN] peer_bytes;
        for (usz j = 0; j < PEER_INFO_LEN; j++)
        {
            peer_bytes[j] = values[offset + j];
        }
        bencode::list_append(values_list, bencode::make_string((String)peer_bytes[..]));
    }

    BencodeValue* msg = bencode::@bdict_wrap(
        "r", bencode::@bdict_wrap(
            "id", bencode::make_string((String)node_id[..]),
            "token", bencode::make_string(token),
            "values", values_list
        ),
        "t", bencode::make_string(transaction_id),
        "v", CLIENT_VERSION,
        "y", "r"
    );
    defer bencode::free_bencode_value(msg);

    return bencode::encode(msg);
}

/**
 * Encode a get_peers response with node info (no peers available)
 * @param transaction_id Transaction ID (echo from query)
 * @param node_id Responding node's ID (20 bytes)
 * @param token Opaque token for future announce_peer
 * @param nodes Compact node info (26 bytes per node: 20-byte ID + 6-byte address)
 * @return Bencode-encoded response message (caller must free)
 */
fn String encode_get_peers_response_with_nodes(String transaction_id, InfoHash node_id,
                                               String token, char[] nodes) @public
{
    BencodeValue* msg = bencode::@bdict_wrap(
        "r", bencode::@bdict_wrap(
            "id", bencode::make_string((String)node_id[..]),
            "nodes", bencode::make_string((String)nodes),
            "token", bencode::make_string(token)
        ),
        "t", bencode::make_string(transaction_id),
        "v", CLIENT_VERSION,
        "y", "r"
    );
    defer bencode::free_bencode_value(msg);

    return bencode::encode(msg);
}

/**
 * Encode an announce_peer response
 * @param transaction_id Transaction ID (echo from query)
 * @param node_id Responding node's ID (20 bytes)
 * @return Bencode-encoded response message (caller must free)
 */
fn String encode_announce_peer_response(String transaction_id, InfoHash node_id) @public
{
    BencodeValue* msg = bencode::@bdict_wrap(
        "r", bencode::@bdict_wrap(
            "id", bencode::make_string((String)node_id[..])
        ),
        "t", bencode::make_string(transaction_id),
        "v", CLIENT_VERSION,
        "y", "r"
    );
    defer bencode::free_bencode_value(msg);

    return bencode::encode(msg);
}

/**
 * Encode an error message
 * @param transaction_id Transaction ID (echo from query, or generated)
 * @param error_code Error code (201-204)
 * @param message Error message description
 * @return Bencode-encoded error message (caller must free)
 */
fn String encode_error(String transaction_id, int error_code, String message) @public
{
    BencodeValue* error_list = bencode::@blist_wrap(
        bencode::make_integer(error_code),
        bencode::make_string(message)
    );

    BencodeValue* msg = bencode::@bdict_wrap(
        "e", error_list,
        "t", bencode::make_string(transaction_id),
        "v", CLIENT_VERSION,
        "y", "e"
    );
    defer bencode::free_bencode_value(msg);

    return bencode::encode(msg);
}

// ============================================================================
// Message Decoding Functions (BEP 5)
// ============================================================================

/**
 * Decode message type from bencode root dictionary
 * @param root Decoded bencode dictionary
 * @return Message type or fault
 */
fn MessageType? decode_message_type(BencodeValue* root) @public
{
    if (root.type != bencode::BencodeType.DICT) return KRPC_INVALID_MESSAGE?;

    BencodeValue* y_val = bencode::dict_get(root, "y");
    if (y_val == null || y_val.type != bencode::BencodeType.STRING)
    {
        return KRPC_INVALID_MESSAGE?;
    }

    String y_str = (String)y_val.string;
    if (y_str == "q") return MessageType.QUERY;
    if (y_str == "r") return MessageType.RESPONSE;
    if (y_str == "e") return MessageType.ERROR;

    return KRPC_INVALID_MESSAGE?;
}

/**
 * Parse query type from query method string
 * @param q_value Query method string ("ping", "find_node", etc.)
 * @return Query type or fault
 */
fn QueryType? parse_query_type(String q_value)
{
    if (q_value == "ping") return QueryType.PING;
    if (q_value == "find_node") return QueryType.FIND_NODE;
    if (q_value == "get_peers") return QueryType.GET_PEERS;
    if (q_value == "announce_peer") return QueryType.ANNOUNCE_PEER;

    return KRPC_METHOD_UNKNOWN?;
}

/**
 * Parse find_node query arguments
 */
fn FindNodeArgs*? parse_find_node_args(BencodeValue* args_dict)
{
    BencodeValue* target_val = bencode::dict_get(args_dict, "target");
    if (target_val == null || target_val.type != bencode::BencodeType.STRING)
    {
        return KRPC_INVALID_MESSAGE?;
    }

    if (target_val.string.len != 20) return KRPC_PROTOCOL_ERROR?;

    FindNodeArgs* args = mem::new(FindNodeArgs);
    foreach (i, c : target_val.string) args.target[i] = c;

    return args;
}

/**
 * Parse get_peers query arguments
 */
fn GetPeersArgs*? parse_get_peers_args(BencodeValue* args_dict)
{
    BencodeValue* info_hash_val = bencode::dict_get(args_dict, "info_hash");
    if (info_hash_val == null || info_hash_val.type != bencode::BencodeType.STRING)
    {
        return KRPC_INVALID_MESSAGE?;
    }

    if (info_hash_val.string.len != 20) return KRPC_PROTOCOL_ERROR?;

    GetPeersArgs* args = mem::new(GetPeersArgs);
    foreach (i, c : info_hash_val.string) args.info_hash[i] = c;

    return args;
}

/**
 * Parse announce_peer query arguments
 */
fn AnnouncePeerArgs*? parse_announce_peer_args(BencodeValue* args_dict)
{
    BencodeValue* info_hash_val = bencode::dict_get(args_dict, "info_hash");
    BencodeValue* port_val = bencode::dict_get(args_dict, "port");
    BencodeValue* token_val = bencode::dict_get(args_dict, "token");

    if (info_hash_val == null || info_hash_val.type != bencode::BencodeType.STRING ||
        port_val == null || port_val.type != bencode::BencodeType.INTEGER ||
        token_val == null || token_val.type != bencode::BencodeType.STRING)
    {
        return KRPC_INVALID_MESSAGE?;
    }

    if (info_hash_val.string.len != 20) return KRPC_PROTOCOL_ERROR?;

    AnnouncePeerArgs* args = mem::new(AnnouncePeerArgs);
    foreach (i, c : info_hash_val.string) args.info_hash[i] = c;
    args.port = (ushort)port_val.integer;

    // Copy token
    char[] token_copy = mem::new_array(char, token_val.string.len);
    foreach (i, c : token_val.string) token_copy[i] = c;
    args.token = (String)token_copy;

    // Check for optional implied_port
    BencodeValue* implied_port_val = bencode::dict_get(args_dict, "implied_port");
    args.implied_port = (implied_port_val != null &&
                         implied_port_val.type == bencode::BencodeType.INTEGER &&
                         implied_port_val.integer != 0);

    return args;
}

/**
 * Parse find_node response data
 */
fn FindNodeResponse*? parse_find_node_response(BencodeValue* r_dict)
{
    BencodeValue* nodes_val = bencode::dict_get(r_dict, "nodes");
    if (nodes_val == null || nodes_val.type != bencode::BencodeType.STRING)
    {
        return KRPC_INVALID_MESSAGE?;
    }

    // Validate nodes length is multiple of 26
    if (nodes_val.string.len % NODE_INFO_LEN != 0) return KRPC_PROTOCOL_ERROR?;

    FindNodeResponse* response = mem::new(FindNodeResponse);

    // Copy nodes data
    char[] nodes_copy = mem::new_array(char, nodes_val.string.len);
    foreach (i, c : nodes_val.string) nodes_copy[i] = c;
    response.nodes = nodes_copy;

    return response;
}

/**
 * Parse get_peers response data
 */
fn GetPeersResponse*? parse_get_peers_response(BencodeValue* r_dict)
{
    BencodeValue* token_val = bencode::dict_get(r_dict, "token");
    if (token_val == null || token_val.type != bencode::BencodeType.STRING)
    {
        return KRPC_INVALID_MESSAGE?;
    }

    GetPeersResponse* response = mem::new(GetPeersResponse);

    // Copy token
    char[] token_copy = mem::new_array(char, token_val.string.len);
    foreach (i, c : token_val.string) token_copy[i] = c;
    response.token = (String)token_copy;

    // Check for values (peer list)
    BencodeValue* values_val = bencode::dict_get(r_dict, "values");
    if (values_val != null && values_val.type == bencode::BencodeType.LIST)
    {
        // Concatenate all peer info strings
        usz total_len = 0;
        for (usz i = 0; i < values_val.list.size; i++)
        {
            BencodeValue* peer_val = values_val.list[i];
            if (peer_val.type == bencode::BencodeType.STRING)
            {
                total_len += peer_val.string.len;
            }
        }

        char[] values_copy = mem::new_array(char, total_len);
        usz offset = 0;
        for (usz i = 0; i < values_val.list.size; i++)
        {
            BencodeValue* peer_val = values_val.list[i];
            if (peer_val.type == bencode::BencodeType.STRING)
            {
                foreach (c : peer_val.string)
                {
                    values_copy[offset++] = c;
                }
            }
        }

        response.values = values_copy;
        response.has_values = true;
        response.has_nodes = false;
        return response;
    }

    // Check for nodes (node list)
    BencodeValue* nodes_val = bencode::dict_get(r_dict, "nodes");
    if (nodes_val != null && nodes_val.type == bencode::BencodeType.STRING)
    {
        // Validate nodes length
        if (nodes_val.string.len % NODE_INFO_LEN != 0)
        {
            free(response);
            return KRPC_PROTOCOL_ERROR?;
        }

        char[] nodes_copy = mem::new_array(char, nodes_val.string.len);
        foreach (i, c : nodes_val.string) nodes_copy[i] = c;
        response.nodes = nodes_copy;
        response.has_values = false;
        response.has_nodes = true;
        return response;
    }

    // Must have either values or nodes
    free(response);
    return KRPC_INVALID_MESSAGE?;
}

/**
 * Decode a KRPC query message
 * @param data Bencode-encoded message
 * @return Decoded query or fault
 */
fn KrpcQuery*? decode_query(String data) @public
{
    BencodeValue* root = bencode::decode(data)!;
    defer bencode::free_bencode_value(root);

    if (root.type != bencode::BencodeType.DICT) return KRPC_INVALID_MESSAGE?;

    // Extract required fields
    BencodeValue* t_val = bencode::dict_get(root, "t");
    BencodeValue* y_val = bencode::dict_get(root, "y");
    BencodeValue* q_val = bencode::dict_get(root, "q");
    BencodeValue* a_val = bencode::dict_get(root, "a");

    if (t_val == null || t_val.type != bencode::BencodeType.STRING ||
        y_val == null || y_val.type != bencode::BencodeType.STRING ||
        q_val == null || q_val.type != bencode::BencodeType.STRING ||
        a_val == null || a_val.type != bencode::BencodeType.DICT)
    {
        return KRPC_INVALID_MESSAGE?;
    }

    // Verify message type
    if ((String)y_val.string != "q") return KRPC_INVALID_MESSAGE?;

    // Extract node ID from arguments
    BencodeValue* id_val = bencode::dict_get(a_val, "id");
    if (id_val == null || id_val.type != bencode::BencodeType.STRING ||
        id_val.string.len != 20)
    {
        return KRPC_INVALID_MESSAGE?;
    }

    // Create query struct
    KrpcQuery* query = mem::new(KrpcQuery);

    // Copy transaction ID
    char[] tid_copy = mem::new_array(char, t_val.string.len);
    foreach (i, c : t_val.string) tid_copy[i] = c;
    query.base.transaction_id = (String)tid_copy;

    query.base.type = MessageType.QUERY;

    // Copy version if present
    BencodeValue* v_val = bencode::dict_get(root, "v");
    if (v_val != null && v_val.type == bencode::BencodeType.STRING)
    {
        char[] ver_copy = mem::new_array(char, v_val.string.len);
        foreach (i, c : v_val.string) ver_copy[i] = c;
        query.base.version = (String)ver_copy;
    }

    // Copy node ID
    foreach (i, c : id_val.string) query.node_id[i] = c;

    // Parse query type and arguments
    QueryType? qtype_opt = parse_query_type((String)q_val.string);
    if (catch err = qtype_opt)
    {
        // Cleanup allocated memory before returning error
        free_query(query);
        return err?;
    }
    QueryType qtype = qtype_opt;
    query.query_type = qtype;

    switch (qtype)
    {
        case QueryType.PING:
            query.args = null;  // Ping has no additional args

        case QueryType.FIND_NODE:
            query.args = parse_find_node_args(a_val)!;

        case QueryType.GET_PEERS:
            query.args = parse_get_peers_args(a_val)!;

        case QueryType.ANNOUNCE_PEER:
            query.args = parse_announce_peer_args(a_val)!;
    }

    return query;
}

/**
 * Decode a KRPC response message
 * @param data Bencode-encoded message
 * @param expected_query_type Query type that generated this response (for parsing)
 * @return Decoded response or fault
 */
fn KrpcResponse*? decode_response(String data, QueryType expected_query_type) @public
{
    BencodeValue* root = bencode::decode(data)!;
    defer bencode::free_bencode_value(root);

    if (root.type != bencode::BencodeType.DICT) return KRPC_INVALID_MESSAGE?;

    // Extract required fields
    BencodeValue* t_val = bencode::dict_get(root, "t");
    BencodeValue* y_val = bencode::dict_get(root, "y");
    BencodeValue* r_val = bencode::dict_get(root, "r");

    if (t_val == null || t_val.type != bencode::BencodeType.STRING ||
        y_val == null || y_val.type != bencode::BencodeType.STRING ||
        r_val == null || r_val.type != bencode::BencodeType.DICT)
    {
        return KRPC_INVALID_MESSAGE?;
    }

    // Verify message type
    if ((String)y_val.string != "r") return KRPC_INVALID_MESSAGE?;

    // Extract node ID from response
    BencodeValue* id_val = bencode::dict_get(r_val, "id");
    if (id_val == null || id_val.type != bencode::BencodeType.STRING ||
        id_val.string.len != 20)
    {
        return KRPC_INVALID_MESSAGE?;
    }

    // Create response struct
    KrpcResponse* response = mem::new(KrpcResponse);

    // Copy transaction ID
    char[] tid_copy = mem::new_array(char, t_val.string.len);
    foreach (i, c : t_val.string) tid_copy[i] = c;
    response.base.transaction_id = (String)tid_copy;

    response.base.type = MessageType.RESPONSE;

    // Copy version if present
    BencodeValue* v_val = bencode::dict_get(root, "v");
    if (v_val != null && v_val.type == bencode::BencodeType.STRING)
    {
        char[] ver_copy = mem::new_array(char, v_val.string.len);
        foreach (i, c : v_val.string) ver_copy[i] = c;
        response.base.version = (String)ver_copy;
    }

    // Copy node ID
    foreach (i, c : id_val.string) response.node_id[i] = c;

    // Set query type
    response.query_type = expected_query_type;

    // Parse response data based on query type
    switch (expected_query_type)
    {
        case QueryType.PING:
            response.data = null;  // Ping response has no additional data

        case QueryType.FIND_NODE:
            response.data = parse_find_node_response(r_val)!;

        case QueryType.GET_PEERS:
            response.data = parse_get_peers_response(r_val)!;

        case QueryType.ANNOUNCE_PEER:
            response.data = null;  // Announce response has no additional data
    }

    return response;
}

/**
 * Decode a KRPC error message
 * @param data Bencode-encoded message
 * @return Decoded error or fault
 */
fn KrpcError*? decode_error(String data) @public
{
    BencodeValue* root = bencode::decode(data)!;
    defer bencode::free_bencode_value(root);

    if (root.type != bencode::BencodeType.DICT) return KRPC_INVALID_MESSAGE?;

    // Extract required fields
    BencodeValue* t_val = bencode::dict_get(root, "t");
    BencodeValue* y_val = bencode::dict_get(root, "y");
    BencodeValue* e_val = bencode::dict_get(root, "e");

    if (t_val == null || t_val.type != bencode::BencodeType.STRING ||
        y_val == null || y_val.type != bencode::BencodeType.STRING ||
        e_val == null || e_val.type != bencode::BencodeType.LIST)
    {
        return KRPC_INVALID_MESSAGE?;
    }

    // Verify message type
    if ((String)y_val.string != "e") return KRPC_INVALID_MESSAGE?;

    // Error list must have 2 elements: [code, message]
    if (e_val.list.size != 2) return KRPC_INVALID_MESSAGE?;

    BencodeValue* code_val = e_val.list[0];
    BencodeValue* msg_val = e_val.list[1];

    if (code_val.type != bencode::BencodeType.INTEGER ||
        msg_val.type != bencode::BencodeType.STRING)
    {
        return KRPC_INVALID_MESSAGE?;
    }

    // Create error struct
    KrpcError* error = mem::new(KrpcError);

    // Copy transaction ID
    char[] tid_copy = mem::new_array(char, t_val.string.len);
    foreach (i, c : t_val.string) tid_copy[i] = c;
    error.base.transaction_id = (String)tid_copy;

    error.base.type = MessageType.ERROR;

    // Copy version if present
    BencodeValue* v_val = bencode::dict_get(root, "v");
    if (v_val != null && v_val.type == bencode::BencodeType.STRING)
    {
        char[] ver_copy = mem::new_array(char, v_val.string.len);
        foreach (i, c : v_val.string) ver_copy[i] = c;
        error.base.version = (String)ver_copy;
    }

    error.code = (int)code_val.integer;

    // Copy error message
    char[] msg_copy = mem::new_array(char, msg_val.string.len);
    foreach (i, c : msg_val.string) msg_copy[i] = c;
    error.message = (String)msg_copy;

    return error;
}


