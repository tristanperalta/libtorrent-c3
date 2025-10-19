module libtorrent::udp_tracker;

import std::net::udp;
import std::net::url;
import std::net;
import std::time;
import std::math::random;
import libtorrent::tracker;
import libtorrent::torrent;

<*
 BitTorrent UDP Tracker Protocol (BEP 15)
 =========================================
 Implements UDP tracker communication for BitTorrent clients.

 UDP trackers provide 50% less overhead than HTTP trackers by using
 a compact binary protocol over UDP instead of HTTP+bencode.

 Protocol Overview:
 1. Send connect request, receive connection_id
 2. Use connection_id to send announce request
 3. Receive peer list in compact format

 Connection IDs expire after 60 seconds of inactivity.
*>

// Faults
faultdef UDP_TRACKER_CONNECT_FAILED;
faultdef UDP_TRACKER_ANNOUNCE_FAILED;
faultdef UDP_TRACKER_INVALID_RESPONSE;
faultdef UDP_TRACKER_TIMEOUT;
faultdef UDP_TRACKER_PROTOCOL_ERROR;

// Protocol Constants
const long UDP_PROTOCOL_ID = 0x41727101980;  // Magic constant for connect

// Action codes
const int ACTION_CONNECT = 0;
const int ACTION_ANNOUNCE = 1;
const int ACTION_SCRAPE = 2;
const int ACTION_ERROR = 3;

// Event codes (same as HTTP tracker)
const int EVENT_NONE = 0;
const int EVENT_COMPLETED = 1;
const int EVENT_STARTED = 2;
const int EVENT_STOPPED = 3;

// Timeouts and retries
const int UDP_INITIAL_TIMEOUT_SECONDS = 2;  // 2 * 2^n for retry n (was 15, reduced for testing)
const int UDP_MAX_RETRIES = 3;                // Maximum n value (was 8, reduced for testing)

<*
 UDP tracker implementation.
*>
struct UdpTracker (tracker::Tracker) {
    char _dummy;  // C3 doesn't allow zero-sized structs
}

// Network byte order conversion functions.
// UDP tracker protocol uses big-endian (network byte order).

<*
 Convert 32-bit integer from host to network byte order.

 @param x : "Host byte order integer"
 @return "Network byte order (big-endian) integer"
*>
fn int htonl(int x) @inline
{
    // Check if we're on a little-endian system
    // C3 doesn't have __BYTE_ORDER__, so we do runtime check
    // This will be optimized away by the compiler on constant paths
    char[4] test = {0x01, 0x02, 0x03, 0x04};
    int test_int = *(int*)&test;

    if (test_int == 0x04030201) {
        // Little-endian: need to swap
        return ((x & 0xFF) << 24) |
               ((x & 0xFF00) << 8) |
               ((x & 0xFF0000) >> 8) |
               (int)((uint)x >> 24);
    } else {
        // Big-endian: no swap needed
        return x;
    }
}

<*
 Convert 32-bit integer from network to host byte order.

 @param x : "Network byte order integer"
 @return "Host byte order integer"
*>
fn int ntohl(int x) @inline
{
    // ntohl is same as htonl (symmetric operation)
    return htonl(x);
}

<*
 Convert 16-bit integer from host to network byte order.

 @param x : "Host byte order short"
 @return "Network byte order (big-endian) short"
*>
fn ushort htons(ushort x) @inline
{
    char[2] test = {0x01, 0x02};
    ushort test_short = *(ushort*)&test;

    if (test_short == 0x0201) {
        // Little-endian: need to swap
        return ((x & 0xFF) << 8) | ((x & 0xFF00) >> 8);
    } else {
        // Big-endian: no swap needed
        return x;
    }
}

<*
 Convert 16-bit integer from network to host byte order.

 @param x : "Network byte order short"
 @return "Host byte order short"
*>
fn ushort ntohs(ushort x) @inline
{
    // ntohs is same as htons (symmetric operation)
    return htons(x);
}

<*
 Convert 64-bit integer from host to network byte order.

 @param x : "Host byte order long"
 @return "Network byte order (big-endian) long"
*>
fn long htonll(long x) @inline
{
    char[8] test = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08};
    long test_long = *(long*)&test;

    if (test_long == 0x0807060504030201L) {
        // Little-endian: need to swap
        return ((long)(x & 0xFF) << 56) |
               ((long)(x & 0xFF00) << 40) |
               ((long)(x & 0xFF0000) << 24) |
               ((long)(x & 0xFF000000) << 8) |
               ((long)(x & 0xFF00000000) >> 8) |
               ((long)(x & 0xFF0000000000) >> 24) |
               ((long)(x & 0xFF000000000000) >> 40) |
               ((ulong)x >> 56);
    } else {
        // Big-endian: no swap needed
        return x;
    }
}

<*
 Convert 64-bit integer from network to host byte order.

 @param x : "Network byte order long"
 @return "Host byte order long"
*>
fn long ntohll(long x) @inline
{
    // ntohll is same as htonll (symmetric operation)
    return htonll(x);
}

<*
 Connect request structure.
 16 bytes total.
*>
struct ConnectRequest {
    long protocol_id;     // 0x41727101980 (magic constant)
    int action;           // 0 for connect
    int transaction_id;   // Random ID to match request/response
}

<*
 Connect response structure.
 16 bytes total.
*>
struct ConnectResponse {
    int action;           // Should be 0
    int transaction_id;   // Should match request
    long connection_id;   // Valid for 60 seconds
}

<*
 Announce request structure.
 98 bytes total.
*>
struct AnnounceRequest {
    long connection_id;   // From connect response
    int action;           // 1 for announce
    int transaction_id;   // Random ID
    char[20] info_hash;   // Torrent info hash
    char[20] peer_id;     // Our peer ID
    long downloaded;      // Bytes downloaded
    long left;            // Bytes remaining
    long uploaded;        // Bytes uploaded
    int event;            // 0=none, 1=completed, 2=started, 3=stopped
    int ip_address;       // 0 = default (use sender IP)
    int key;              // Random key for identification
    int num_want;         // Number of peers wanted (-1 = default)
    ushort port;          // Our listening port
}

<*
 Announce response structure.
 20 bytes + 6*n bytes for peers.
*>
struct AnnounceResponse {
    int action;           // Should be 1
    int transaction_id;   // Should match request
    int interval;         // Re-announce interval in seconds
    int leechers;         // Number of incomplete peers
    int seeders;          // Number of complete peers
    tracker::Peer[] peers_data;  // Parsed peer data
    // Followed by compact peer list (6 bytes per peer)
}

<*
 Error response structure.
 8 bytes + variable message length.
*>
struct ErrorResponse {
    int action;           // Should be 3
    int transaction_id;   // Should match request
    // Followed by error message (null-terminated string)
}

<*
 Pack connect request into byte buffer.

 @param transaction_id : "Random transaction ID"
 @param buffer : "Output buffer (must be at least 16 bytes)"
*>
fn void pack_connect_request(int transaction_id, char[] buffer)
{
    assert(buffer.len >= 16, "Buffer too small for connect request");

    // Pack protocol_id (8 bytes)
    long protocol_id_net = htonll(UDP_PROTOCOL_ID);
    char* p = (char*)&protocol_id_net;
    buffer[0..7] = p[0..7];

    // Pack action (4 bytes)
    int action_net = htonl(ACTION_CONNECT);
    p = (char*)&action_net;
    buffer[8..11] = p[0..3];

    // Pack transaction_id (4 bytes)
    int tid_net = htonl(transaction_id);
    p = (char*)&tid_net;
    buffer[12..15] = p[0..3];
}

<*
 Unpack connect response from byte buffer.

 @param buffer : "Input buffer (must be at least 16 bytes)"
 @return "Parsed ConnectResponse or fault"
*>
fn ConnectResponse? unpack_connect_response(char[] buffer)
{
    if (buffer.len < 16) {
        return UDP_TRACKER_INVALID_RESPONSE?;
    }

    ConnectResponse response;

    // Unpack action (4 bytes)
    int action_net;
    char* p = (char*)&action_net;
    p[0..3] = buffer[0..3];
    response.action = ntohl(action_net);

    if (response.action != ACTION_CONNECT) {
        // Might be an error response
        if (response.action == ACTION_ERROR) {
            return UDP_TRACKER_PROTOCOL_ERROR?;
        }
        return UDP_TRACKER_INVALID_RESPONSE?;
    }

    // Unpack transaction_id (4 bytes)
    int tid_net;
    p = (char*)&tid_net;
    p[0..3] = buffer[4..7];
    response.transaction_id = ntohl(tid_net);

    // Unpack connection_id (8 bytes)
    long cid_net;
    p = (char*)&cid_net;
    p[0..7] = buffer[8..15];
    response.connection_id = ntohll(cid_net);

    return response;
}

<*
 Pack announce request into byte buffer.

 @param request : "Announce request to pack"
 @param buffer : "Output buffer (must be at least 98 bytes)"
*>
fn void pack_announce_request(AnnounceRequest* request, char[] buffer)
{
    assert(buffer.len >= 98, "Buffer too small for announce request");

    char* p;
    usz offset = 0;

    // connection_id (8 bytes)
    long cid_net = htonll(request.connection_id);
    p = (char*)&cid_net;
    buffer[offset..offset+7] = p[0..7];
    offset += 8;

    // action (4 bytes)
    int action_net = htonl(request.action);
    p = (char*)&action_net;
    buffer[offset..offset+3] = p[0..3];
    offset += 4;

    // transaction_id (4 bytes)
    int tid_net = htonl(request.transaction_id);
    p = (char*)&tid_net;
    buffer[offset..offset+3] = p[0..3];
    offset += 4;

    // info_hash (20 bytes)
    buffer[offset..offset+19] = request.info_hash[0..19];
    offset += 20;

    // peer_id (20 bytes)
    buffer[offset..offset+19] = request.peer_id[0..19];
    offset += 20;

    // downloaded (8 bytes)
    long downloaded_net = htonll(request.downloaded);
    p = (char*)&downloaded_net;
    buffer[offset..offset+7] = p[0..7];
    offset += 8;

    // left (8 bytes)
    long left_net = htonll(request.left);
    p = (char*)&left_net;
    buffer[offset..offset+7] = p[0..7];
    offset += 8;

    // uploaded (8 bytes)
    long uploaded_net = htonll(request.uploaded);
    p = (char*)&uploaded_net;
    buffer[offset..offset+7] = p[0..7];
    offset += 8;

    // event (4 bytes)
    int event_net = htonl(request.event);
    p = (char*)&event_net;
    buffer[offset..offset+3] = p[0..3];
    offset += 4;

    // ip_address (4 bytes)
    int ip_net = htonl(request.ip_address);
    p = (char*)&ip_net;
    buffer[offset..offset+3] = p[0..3];
    offset += 4;

    // key (4 bytes)
    int key_net = htonl(request.key);
    p = (char*)&key_net;
    buffer[offset..offset+3] = p[0..3];
    offset += 4;

    // num_want (4 bytes)
    int num_want_net = htonl(request.num_want);
    p = (char*)&num_want_net;
    buffer[offset..offset+3] = p[0..3];
    offset += 4;

    // port (2 bytes)
    ushort port_net = htons(request.port);
    p = (char*)&port_net;
    buffer[offset..offset+1] = p[0..1];
}

<*
 Unpack announce response from byte buffer.

 @param buffer : "Input buffer (at least 20 bytes + peer data)"
 @param peers_out : "Output array for peers"
 @return "Parsed AnnounceResponse or fault"
*>
fn AnnounceResponse? unpack_announce_response(char[] buffer, char[]* peers_out)
{
    if (buffer.len < 20) {
        return UDP_TRACKER_INVALID_RESPONSE?;
    }

    AnnounceResponse response;

    char* p;

    // Unpack action (4 bytes)
    int action_net;
    p = (char*)&action_net;
    p[0..3] = buffer[0..3];
    response.action = ntohl(action_net);

    if (response.action != ACTION_ANNOUNCE) {
        if (response.action == ACTION_ERROR) {
            return UDP_TRACKER_PROTOCOL_ERROR?;
        }
        return UDP_TRACKER_INVALID_RESPONSE?;
    }

    // Unpack transaction_id (4 bytes)
    int tid_net;
    p = (char*)&tid_net;
    p[0..3] = buffer[4..7];
    response.transaction_id = ntohl(tid_net);

    // Unpack interval (4 bytes)
    int interval_net;
    p = (char*)&interval_net;
    p[0..3] = buffer[8..11];
    response.interval = ntohl(interval_net);

    // Unpack leechers (4 bytes)
    int leechers_net;
    p = (char*)&leechers_net;
    p[0..3] = buffer[12..15];
    response.leechers = ntohl(leechers_net);

    // Unpack seeders (4 bytes)
    int seeders_net;
    p = (char*)&seeders_net;
    p[0..3] = buffer[16..19];
    response.seeders = ntohl(seeders_net);

    // Extract peer data (rest of buffer)
    if (buffer.len > 20) {
        usz peer_data_len = buffer.len - 20;
        *peers_out = buffer[20..buffer.len-1];
    } else {
        char[] empty;
        *peers_out = empty;
    }

    return response;
}

<*
 Generate random transaction ID.

 @return "Random 32-bit transaction ID"
*>
fn int generate_transaction_id()
{
    random::DefaultRandom rng;
    random::seed(&rng, (uint)time::now().to_seconds());
    // Generate a random 32-bit value by combining two 16-bit values
    int high = random::next_in_range(&rng, 0, 0xFFFF);
    int low = random::next_in_range(&rng, 0, 0xFFFF);
    return (high << 16) | low;
}

<*
 Convert event string to event code.

 @param event : "Event string (started/stopped/completed or empty)"
 @return "Event code"
*>
fn int event_string_to_code(String event)
{
    if (event == "started") return EVENT_STARTED;
    if (event == "stopped") return EVENT_STOPPED;
    if (event == "completed") return EVENT_COMPLETED;
    return EVENT_NONE;
}

<*
 Perform UDP connect handshake with tracker.
 Implements retry with exponential backoff (15 * 2^n seconds).

 @param host : "Tracker hostname"
 @param tracker_port : "Tracker port"
 @return "Connection ID or fault"
*>
fn long? udp_connect(String host, ushort tracker_port)
{
    // Generate transaction ID
    int transaction_id = generate_transaction_id();

    // Pack connect request
    char[16] request;
    pack_connect_request(transaction_id, request[..]);

    // Try to connect with exponential backoff
    for (int retry = 0; retry <= UDP_MAX_RETRIES; retry++)
    {
        // Connect to UDP tracker
        udp::UdpSocket? socket = udp::connect(host, tracker_port);
        if (catch err = socket) {
            return UDP_TRACKER_CONNECT_FAILED?;
        }
        defer (void)socket.close();

        // Send connect request
        usz? written = socket.write(request[..]);
        if (catch err = written) {
            continue;  // Try next retry
        }

        // Calculate timeout: 15 * 2^retry seconds
        int timeout_ms = (UDP_INITIAL_TIMEOUT_SECONDS * (1 << retry)) * 1000;

        // Wait for response with timeout using poll
        net::Poll[1] polls;
        polls[0].socket = socket.sock;
        polls[0].events = net::SUBSCRIBE_ANY_READ;

        ulong? poll_result = net::poll_ms(polls[..], timeout_ms);
        if (catch err = poll_result) {
            continue;  // Poll error - retry
        }

        if (poll_result == 0) {
            // Timeout - retry
            continue;
        }

        // Check if socket has data to read
        if (!(polls[0].revents & net::POLL_EVENT_READ)) {
            continue;  // No data - retry
        }

        // Read response
        char[16] response;
        usz? read_result = socket.read(response[..]);

        if (catch err = read_result) {
            continue;  // Read error - retry
        }

        // Unpack connect response
        ConnectResponse? conn_response = unpack_connect_response(response[..]);
        if (catch err = conn_response) {
            return err?;
        }

        // Verify transaction ID matches
        if (conn_response.transaction_id != transaction_id) {
            return UDP_TRACKER_INVALID_RESPONSE?;
        }

        return conn_response.connection_id;
    }

    return UDP_TRACKER_TIMEOUT?;
}

<*
 Perform UDP announce to tracker.

 @param host : "Tracker hostname"
 @param tracker_port : "Tracker port"
 @param connection_id : "Connection ID from connect"
 @param torrent : "Torrent file"
 @param port : "Our listening port"
 @param event : "Event string"
 @return "Announce response or fault"
*>
fn AnnounceResponse? udp_announce(String host, ushort tracker_port, long connection_id,
                                    torrent::TorrentFile* torrent, ushort port, String event)
{
    // Generate transaction ID
    int transaction_id = generate_transaction_id();

    // Generate peer ID
    char[20] peer_id = tracker::generate_peer_id();

    // Build announce request
    AnnounceRequest request;
    request.connection_id = connection_id;
    request.action = ACTION_ANNOUNCE;
    request.transaction_id = transaction_id;
    request.info_hash = torrent.info_hash;
    request.peer_id = peer_id;
    request.downloaded = 0;
    request.left = torrent.info.length;
    request.uploaded = 0;
    request.event = event_string_to_code(event);
    request.ip_address = 0;  // Default (use sender IP)
    request.key = generate_transaction_id();  // Random key
    request.num_want = -1;  // Default number of peers
    request.port = port;

    // Pack announce request
    char[98] request_buf;
    pack_announce_request(&request, request_buf[..]);

    // Try to announce with exponential backoff
    for (int retry = 0; retry <= UDP_MAX_RETRIES; retry++)
    {
        // Connect to UDP tracker
        udp::UdpSocket? socket = udp::connect(host, tracker_port);
        if (catch err = socket) {
            return UDP_TRACKER_CONNECT_FAILED?;
        }
        defer (void)socket.close();

        // Send announce request
        usz? written = socket.write(request_buf[..]);
        if (catch err = written) {
            continue;
        }

        // Calculate timeout
        int timeout_ms = (UDP_INITIAL_TIMEOUT_SECONDS * (1 << retry)) * 1000;

        // Wait for response with timeout using poll
        net::Poll[1] polls;
        polls[0].socket = socket.sock;
        polls[0].events = net::SUBSCRIBE_ANY_READ;

        ulong? poll_result = net::poll_ms(polls[..], timeout_ms);
        if (catch err = poll_result) {
            continue;  // Poll error - retry
        }

        if (poll_result == 0) {
            // Timeout - retry
            continue;
        }

        // Check if socket has data to read
        if (!(polls[0].revents & net::POLL_EVENT_READ)) {
            continue;  // No data - retry
        }

        // Read response (max size: 20 bytes header + lots of peers)
        char[2048] response;
        usz? read_result = socket.read(response[..]);

        if (catch err = read_result) {
            continue;  // Read error - retry
        }

        usz bytes_read = read_result;

        // Unpack announce response
        char[] peers;
        AnnounceResponse? announce_response = unpack_announce_response(response[0..bytes_read-1], &peers);
        if (catch err = announce_response) {
            return err?;
        }

        // Verify transaction ID
        if (announce_response.transaction_id != transaction_id) {
            return UDP_TRACKER_INVALID_RESPONSE?;
        }

        // Parse compact peers
        tracker::Peer[]? parsed_peers = tracker::parse_compact_peers(peers);
        if (catch err = parsed_peers) {
            return UDP_TRACKER_INVALID_RESPONSE?;
        }

        // Store parsed peers (need to keep them alive)
        announce_response.peers_data = parsed_peers;

        return announce_response;
    }

    return UDP_TRACKER_TIMEOUT?;
}

<*
 UDP tracker announce implementation (Tracker interface).

 @param torrent : "The torrent file"
 @param port : "Our listening port"
 @param event : "Event type (started/stopped/completed or empty string)"
 @return "Tracker response with peer list or fault"
*>
fn tracker::TrackerResponse? UdpTracker.announce(UdpTracker* self, torrent::TorrentFile* torrent,
                                                   ushort port, String event) @dynamic
{
    // Parse tracker URL
    String tracker_url = torrent.announce;
    if (!tracker_url.starts_with("udp://")) {
        return tracker::TRACKER_URL_INVALID?;
    }

    // Parse URL to extract host and port
    url::Url? parsed = url::parse(mem, tracker_url);
    if (catch err = parsed) {
        return tracker::TRACKER_URL_INVALID?;
    }
    defer parsed.free();

    String host = parsed.host;
    ushort tracker_port = (ushort)parsed.port;
    if (tracker_port == 0) {
        tracker_port = 80;  // Default UDP tracker port
    }

    // Step 1: Connect to tracker
    long? connection_id = udp_connect(host, tracker_port);
    if (catch err = connection_id) {
        return err?;
    }

    // Step 2: Announce to tracker
    AnnounceResponse? udp_response = udp_announce(host, tracker_port, connection_id, torrent, port, event);
    if (catch err = udp_response) {
        return err?;
    }

    // Step 3: Convert UDP response to TrackerResponse
    tracker::TrackerResponse response;
    response.interval = udp_response.interval;
    response.min_interval = 0;  // UDP tracker doesn't provide this
    response.complete = udp_response.seeders;
    response.incomplete = udp_response.leechers;
    response.peers = udp_response.peers_data;
    response.failure_reason = "";
    response.warning_message = "";

    return response;
}

<*
 Free UDP tracker instance.
*>
fn void UdpTracker.free(UdpTracker* self) @dynamic
{
    // UdpTracker has no dynamic allocations
    free(self);
}
