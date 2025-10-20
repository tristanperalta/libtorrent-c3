module libtorrent::udp_tracker;

import libtorrent::async_dns;
import libtorrent::async_udp;
import libtorrent::async_timer;
import libtorrent::event_loop;
import libtorrent::tracker;
import libtorrent::metainfo;
import uv;
import std::io;
import std::net::url;
import std::time;
import std::math::random;

<*
 Async UDP Tracker Implementation
 =================================
 Non-blocking UDP tracker client using async DNS, UDP, and timers.

 This eliminates the 15-60 second event loop blocking that occurs with
 the synchronous UDP tracker implementation.

 Usage:
   async_announce(loop, torrent, port, event, &on_complete, user_data);
*>

// ============================================================================
// UDP Tracker Protocol Utilities
// ============================================================================

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
const int UDP_INITIAL_TIMEOUT_SECONDS = 2;  // 2 * 2^n for retry n
const int UDP_MAX_RETRIES = 3;                // Maximum n value

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
*>
fn int ntohl(int x) @inline
{
    return htonl(x);
}

<*
 Convert 16-bit integer from host to network byte order.
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
*>
fn ushort ntohs(ushort x) @inline
{
    return htons(x);
}

<*
 Convert 64-bit integer from host to network byte order.
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
*>
fn long ntohll(long x) @inline
{
    return htonll(x);
}

// Protocol structures

struct ConnectRequest {
    long protocol_id;
    int action;
    int transaction_id;
}

struct ConnectResponse {
    int action;
    int transaction_id;
    long connection_id;
}

struct AnnounceRequest {
    long connection_id;
    int action;
    int transaction_id;
    char[20] info_hash;
    char[20] peer_id;
    long downloaded;
    long left;
    long uploaded;
    int event;
    int ip_address;
    int key;
    int num_want;
    ushort port;
}

struct AnnounceResponse {
    int action;
    int transaction_id;
    int interval;
    int leechers;
    int seeders;
    tracker::Peer[] peers_data;
}

struct ErrorResponse {
    int action;
    int transaction_id;
}

<*
 Pack connect request into byte buffer.
*>
fn void pack_connect_request(int transaction_id, char[] buffer) @public
{
    assert(buffer.len >= 16, "Buffer too small for connect request");

    long protocol_id_net = htonll(UDP_PROTOCOL_ID);
    char* p = (char*)&protocol_id_net;
    buffer[0..7] = p[0..7];

    int action_net = htonl(ACTION_CONNECT);
    p = (char*)&action_net;
    buffer[8..11] = p[0..3];

    int tid_net = htonl(transaction_id);
    p = (char*)&tid_net;
    buffer[12..15] = p[0..3];
}

<*
 Unpack connect response from byte buffer.
*>
fn ConnectResponse? unpack_connect_response(char[] buffer) @public
{
    if (buffer.len < 16) {
        return UDP_TRACKER_INVALID_RESPONSE?;
    }

    ConnectResponse response;

    int action_net;
    char* p = (char*)&action_net;
    p[0..3] = buffer[0..3];
    response.action = ntohl(action_net);

    if (response.action != ACTION_CONNECT) {
        if (response.action == ACTION_ERROR) {
            return UDP_TRACKER_PROTOCOL_ERROR?;
        }
        return UDP_TRACKER_INVALID_RESPONSE?;
    }

    int tid_net;
    p = (char*)&tid_net;
    p[0..3] = buffer[4..7];
    response.transaction_id = ntohl(tid_net);

    long cid_net;
    p = (char*)&cid_net;
    p[0..7] = buffer[8..15];
    response.connection_id = ntohll(cid_net);

    return response;
}

<*
 Pack announce request into byte buffer.
*>
fn void pack_announce_request(AnnounceRequest* request, char[] buffer) @public
{
    assert(buffer.len >= 98, "Buffer too small for announce request");

    char* p;
    usz offset = 0;

    long cid_net = htonll(request.connection_id);
    p = (char*)&cid_net;
    buffer[offset..offset+7] = p[0..7];
    offset += 8;

    int action_net = htonl(request.action);
    p = (char*)&action_net;
    buffer[offset..offset+3] = p[0..3];
    offset += 4;

    int tid_net = htonl(request.transaction_id);
    p = (char*)&tid_net;
    buffer[offset..offset+3] = p[0..3];
    offset += 4;

    buffer[offset..offset+19] = request.info_hash[0..19];
    offset += 20;

    buffer[offset..offset+19] = request.peer_id[0..19];
    offset += 20;

    long downloaded_net = htonll(request.downloaded);
    p = (char*)&downloaded_net;
    buffer[offset..offset+7] = p[0..7];
    offset += 8;

    long left_net = htonll(request.left);
    p = (char*)&left_net;
    buffer[offset..offset+7] = p[0..7];
    offset += 8;

    long uploaded_net = htonll(request.uploaded);
    p = (char*)&uploaded_net;
    buffer[offset..offset+7] = p[0..7];
    offset += 8;

    int event_net = htonl(request.event);
    p = (char*)&event_net;
    buffer[offset..offset+3] = p[0..3];
    offset += 4;

    int ip_net = htonl(request.ip_address);
    p = (char*)&ip_net;
    buffer[offset..offset+3] = p[0..3];
    offset += 4;

    int key_net = htonl(request.key);
    p = (char*)&key_net;
    buffer[offset..offset+3] = p[0..3];
    offset += 4;

    int num_want_net = htonl(request.num_want);
    p = (char*)&num_want_net;
    buffer[offset..offset+3] = p[0..3];
    offset += 4;

    ushort port_net = htons(request.port);
    p = (char*)&port_net;
    buffer[offset..offset+1] = p[0..1];
}

<*
 Unpack announce response from byte buffer.
*>
fn AnnounceResponse? unpack_announce_response(char[] buffer, char[]* peers_out) @public
{
    if (buffer.len < 20) {
        return UDP_TRACKER_INVALID_RESPONSE?;
    }

    AnnounceResponse response;

    char* p;

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

    int tid_net;
    p = (char*)&tid_net;
    p[0..3] = buffer[4..7];
    response.transaction_id = ntohl(tid_net);

    int interval_net;
    p = (char*)&interval_net;
    p[0..3] = buffer[8..11];
    response.interval = ntohl(interval_net);

    int leechers_net;
    p = (char*)&leechers_net;
    p[0..3] = buffer[12..15];
    response.leechers = ntohl(leechers_net);

    int seeders_net;
    p = (char*)&seeders_net;
    p[0..3] = buffer[16..19];
    response.seeders = ntohl(seeders_net);

    if (buffer.len > 20) {
        *peers_out = buffer[20..buffer.len-1];
    } else {
        char[] empty;
        *peers_out = empty;
    }

    return response;
}

<*
 Generate random transaction ID.
*>
fn int generate_transaction_id() @public
{
    random::DefaultRandom rng;
    random::seed(&rng, (uint)time::now().to_seconds());
    int high = random::next_in_range(&rng, 0, 0xFFFF);
    int low = random::next_in_range(&rng, 0, 0xFFFF);
    return (high << 16) | low;
}

<*
 Convert event string to event code.
*>
fn int event_string_to_code(String event) @public
{
    if (event == "started") return EVENT_STARTED;
    if (event == "stopped") return EVENT_STOPPED;
    if (event == "completed") return EVENT_COMPLETED;
    return EVENT_NONE;
}

// ============================================================================
// Async UDP Tracker Implementation
// ============================================================================

// Error codes for async announce
const int ASYNC_ERROR_TIMEOUT = -1;
const int ASYNC_ERROR_CONNECT_FAILED = -2;
const int ASYNC_ERROR_ANNOUNCE_FAILED = -3;
const int ASYNC_ERROR_INVALID_RESPONSE = -4;
const int ASYNC_ERROR_DNS_FAILED = -5;
const int ASYNC_ERROR_INVALID_URL = -6;

// Callback type for async announce completion
// If successful, response is non-null and status is 0
// If failed, response is null and status contains negative error code
alias AnnounceCallback = fn void(tracker::TrackerResponse* response, int status, void* user_data);

// State machine states
enum AnnounceState
{
    RESOLVING_DNS,
    CONNECTING,
    ANNOUNCING,
    COMPLETED,
    FAILED,
}

// Context for async announce operation
struct AnnounceContext
{
    event_loop::EventLoop* loop;
    metainfo::TorrentFile* torrent;
    ushort port;
    String event;
    AnnounceCallback callback;
    void* user_data;

    // State
    AnnounceState state;
    int retry;
    int transaction_id;
    long connection_id;
    bool receiving;  // Track if recv_start has been called
    int initial_timeout_seconds;  // Initial timeout (0 = use default)

    // Network resources
    async_udp::UdpSocket* socket;
    async_timer::Timer* timeout_timer;
    uv::Sockaddr* tracker_addr;
    String tracker_host;  // Keep hostname alive for async DNS
    String tracker_port_str;  // Keep port string alive for async DNS
    String tracker_ip;
    ushort tracker_port;

    // Buffers
    char[16] connect_request;
    char[16] connect_response;
    char[98] announce_request;
    char[] announce_response;

    // Results
    tracker::TrackerResponse result;
    int error;
}

<*
 Clean up resources and invoke user callback.
*>
fn void cleanup_and_callback(AnnounceContext* ctx)
{
    // Stop and close timer if active
    if (ctx.timeout_timer)
    {
        async_timer::stop(ctx.timeout_timer);
        async_timer::close(ctx.timeout_timer);
        ctx.timeout_timer = null;
    }

    // Close socket if open
    if (ctx.socket)
    {
        async_udp::recv_stop(ctx.socket);
        async_udp::close(ctx.socket);
        ctx.socket = null;
    }

    // Free tracker address
    if (ctx.tracker_addr)
    {
        free(ctx.tracker_addr);
        ctx.tracker_addr = null;
    }

    // Free tracker host
    if (ctx.tracker_host.len > 0)
    {
        free(ctx.tracker_host);
    }

    // Free tracker port string
    if (ctx.tracker_port_str.len > 0)
    {
        free(ctx.tracker_port_str);
    }

    // Free tracker IP
    if (ctx.tracker_ip.len > 0)
    {
        free(ctx.tracker_ip);
    }

    // Free announce response buffer
    if (ctx.announce_response.len > 0)
    {
        free(ctx.announce_response);
    }

    // Invoke user callback
    if (ctx.callback)
    {
        if (ctx.state == AnnounceState.COMPLETED)
        {
            // Pass null as the fault to indicate success
            ctx.callback(&ctx.result, 0, ctx.user_data);
        }
        else
        {
            ctx.callback(null, ctx.error, ctx.user_data);
        }
    }

    // Free context
    free(ctx);
}

<*
 Handle timeout - retry or fail.
*>
fn void on_timeout(async_timer::Timer* timer, void* user_data)
{
    AnnounceContext* ctx = (AnnounceContext*)user_data;

    // Stop timer
    async_timer::stop(timer);

    // Check if we should retry
    if (ctx.retry < udp_tracker::UDP_MAX_RETRIES)
    {
        ctx.retry++;

        // Retry the current operation
        if (ctx.state == AnnounceState.CONNECTING)
        {
            start_connect_attempt(ctx);
        }
        else if (ctx.state == AnnounceState.ANNOUNCING)
        {
            start_announce_attempt(ctx);
        }
    }
    else
    {
        // Max retries exceeded
        ctx.state = AnnounceState.FAILED;
        ctx.error = ASYNC_ERROR_TIMEOUT;
        cleanup_and_callback(ctx);
    }
}

<*
 Handle announce response.
*>
fn void on_announce_response(async_udp::UdpSocket* socket, char[] data, uv::Sockaddr* addr, void* user_data)
{
    AnnounceContext* ctx = (AnnounceContext*)user_data;

    if (data.len < 20)
    {
        return;  // Invalid response, wait for timeout/retry
    }

    // Stop receiving and timer
    async_udp::recv_stop(socket);
    ctx.receiving = false;  // Reset flag so next phase can start receiving
    async_timer::stop(ctx.timeout_timer);

    // Copy response data
    ctx.announce_response = mem::new_array(char, data.len);
    for (usz i = 0; i < data.len; i++)
    {
        ctx.announce_response[i] = data[i];
    }

    // Parse announce response
    udp_tracker::AnnounceResponse? response = udp_tracker::unpack_announce_response(ctx.announce_response, (char[]*)&ctx.result.peers);

    if (catch err = response)
    {
        ctx.state = AnnounceState.FAILED;
        ctx.error = ASYNC_ERROR_INVALID_RESPONSE;
        cleanup_and_callback(ctx);
        return;
    }

    // Verify transaction ID
    if (response.transaction_id != ctx.transaction_id)
    {
        ctx.state = AnnounceState.FAILED;
        ctx.error = ASYNC_ERROR_INVALID_RESPONSE;
        cleanup_and_callback(ctx);
        return;
    }

    // Success - convert to TrackerResponse
    ctx.result.interval = response.interval;
    ctx.result.min_interval = 0;
    ctx.result.complete = response.seeders;
    ctx.result.incomplete = response.leechers;
    ctx.result.failure_reason = "";
    ctx.result.warning_message = "";

    ctx.state = AnnounceState.COMPLETED;
    cleanup_and_callback(ctx);
}

<*
 Handle announce send completion.
*>
fn void on_announce_sent(async_udp::UdpSocket* socket, int status, void* user_data)
{
    if (status < 0)
    {
        AnnounceContext* ctx = (AnnounceContext*)user_data;
        io::printfn("Announce send failed: %s", (ZString)uv::strerror(status));

        // Retry
        if (ctx.retry < udp_tracker::UDP_MAX_RETRIES)
        {
            ctx.retry++;
            start_announce_attempt(ctx);
        }
        else
        {
            ctx.state = AnnounceState.FAILED;
            ctx.error = ASYNC_ERROR_ANNOUNCE_FAILED;
            cleanup_and_callback(ctx);
        }
    }
}

<*
 Start announce attempt.
*>
fn void start_announce_attempt(AnnounceContext* ctx)
{
    ctx.state = AnnounceState.ANNOUNCING;

    // Generate new transaction ID for this attempt
    ctx.transaction_id = udp_tracker::generate_transaction_id();

    // Build announce request
    udp_tracker::AnnounceRequest request;
    request.connection_id = ctx.connection_id;
    request.action = udp_tracker::ACTION_ANNOUNCE;
    request.transaction_id = ctx.transaction_id;
    request.info_hash = ctx.torrent.info_hash;
    request.peer_id = tracker::generate_peer_id();
    request.downloaded = 0;
    request.left = ctx.torrent.info.length;
    request.uploaded = 0;
    request.event = udp_tracker::event_string_to_code(ctx.event);
    request.ip_address = 0;
    request.key = udp_tracker::generate_transaction_id();
    request.num_want = -1;
    request.port = ctx.port;

    // Pack request
    udp_tracker::pack_announce_request(&request, ctx.announce_request[..]);

    // Start receiving (only on first attempt - after connect phase recv was stopped)
    if (!ctx.receiving)
    {
        async_udp::recv_start(ctx.socket, null, &on_announce_response, ctx);
        ctx.receiving = true;
    }

    // Send announce request
    async_udp::send_to(ctx.socket, ctx.tracker_addr, ctx.announce_request[..],
                       &on_announce_sent, ctx);

    // Start timeout timer
    int base_timeout = ctx.initial_timeout_seconds > 0 ? ctx.initial_timeout_seconds : udp_tracker::UDP_INITIAL_TIMEOUT_SECONDS;
    int timeout_ms = (base_timeout * (1 << ctx.retry)) * 1000;
    async_timer::start(ctx.timeout_timer, (ulong)timeout_ms, 0, &on_timeout, ctx);
}

<*
 Handle connect response.
*>
fn void on_connect_response(async_udp::UdpSocket* socket, char[] data, uv::Sockaddr* addr, void* user_data)
{
    AnnounceContext* ctx = (AnnounceContext*)user_data;

    if (data.len < 16)
    {
        return;  // Invalid response, wait for timeout/retry
    }

    // Stop receiving and timer
    async_udp::recv_stop(socket);
    ctx.receiving = false;  // Reset flag so next phase can start receiving
    async_timer::stop(ctx.timeout_timer);

    // Copy response
    for (usz i = 0; i < 16; i++)
    {
        ctx.connect_response[i] = data[i];
    }

    // Parse connect response
    udp_tracker::ConnectResponse? response = udp_tracker::unpack_connect_response(ctx.connect_response[..]);

    if (catch err = response)
    {
        ctx.state = AnnounceState.FAILED;
        ctx.error = ASYNC_ERROR_INVALID_RESPONSE;
        cleanup_and_callback(ctx);
        return;
    }

    // Verify transaction ID
    if (response.transaction_id != ctx.transaction_id)
    {
        ctx.state = AnnounceState.FAILED;
        ctx.error = ASYNC_ERROR_INVALID_RESPONSE;
        cleanup_and_callback(ctx);
        return;
    }

    // Save connection ID
    ctx.connection_id = response.connection_id;

    // Reset retry counter for announce phase
    ctx.retry = 0;

    // Proceed to announce
    start_announce_attempt(ctx);
}

<*
 Handle connect send completion.
*>
fn void on_connect_sent(async_udp::UdpSocket* socket, int status, void* user_data)
{
    if (status < 0)
    {
        AnnounceContext* ctx = (AnnounceContext*)user_data;
        io::printfn("Connect send failed: %s", (ZString)uv::strerror(status));

        // Retry
        if (ctx.retry < udp_tracker::UDP_MAX_RETRIES)
        {
            ctx.retry++;
            start_connect_attempt(ctx);
        }
        else
        {
            ctx.state = AnnounceState.FAILED;
            ctx.error = ASYNC_ERROR_CONNECT_FAILED;
            cleanup_and_callback(ctx);
        }
    }
}

<*
 Start connect attempt.
*>
fn void start_connect_attempt(AnnounceContext* ctx)
{
    ctx.state = AnnounceState.CONNECTING;

    // Generate new transaction ID for this attempt
    ctx.transaction_id = udp_tracker::generate_transaction_id();

    // Pack connect request
    udp_tracker::pack_connect_request(ctx.transaction_id, ctx.connect_request[..]);

    // Start receiving (only on first attempt)
    if (!ctx.receiving)
    {
        async_udp::recv_start(ctx.socket, null, &on_connect_response, ctx);
        ctx.receiving = true;
    }

    // Send connect request
    async_udp::send_to(ctx.socket, ctx.tracker_addr, ctx.connect_request[..],
                       &on_connect_sent, ctx);

    // Start timeout timer
    int base_timeout = ctx.initial_timeout_seconds > 0 ? ctx.initial_timeout_seconds : udp_tracker::UDP_INITIAL_TIMEOUT_SECONDS;
    int timeout_ms = (base_timeout * (1 << ctx.retry)) * 1000;
    async_timer::start(ctx.timeout_timer, (ulong)timeout_ms, 0, &on_timeout, ctx);
}

<*
 Handle DNS resolution completion.
*>
fn void on_dns_resolved(uv::AddrInfo* result, int status, void* user_data)
{
    AnnounceContext* ctx = (AnnounceContext*)user_data;

    if (status < 0 || !result)
    {
        ctx.state = AnnounceState.FAILED;
        ctx.error = ASYNC_ERROR_DNS_FAILED;
        cleanup_and_callback(ctx);
        return;
    }

    // Get first IPv4 address
    uv::AddrInfo* info = result;
    bool found = false;

    while (info && !found)
    {
        if (info.ai_family == uv::AF_INET && info.ai_socktype == uv::SOCK_DGRAM)
        {
            // Copy the sockaddr
            ctx.tracker_addr = mem::new(uv::Sockaddr);
            *ctx.tracker_addr = *info.ai_addr;

            // Extract IP for display
            ctx.tracker_ip = async_dns::addr_to_string(info.ai_addr);

            found = true;
        }
        info = info.ai_next;
    }

    async_dns::free_result(result);

    if (!found)
    {
        ctx.state = AnnounceState.FAILED;
        ctx.error = ASYNC_ERROR_DNS_FAILED;
        cleanup_and_callback(ctx);
        return;
    }

    // Create UDP socket
    async_udp::UdpSocket*? socket_opt = async_udp::create(ctx.loop);
    if (catch err = socket_opt)
    {
        ctx.state = AnnounceState.FAILED;
        ctx.error = ASYNC_ERROR_CONNECT_FAILED;
        cleanup_and_callback(ctx);
        return;
    }
    ctx.socket = socket_opt;

    // Create timeout timer
    async_timer::Timer*? timer_opt = async_timer::create(ctx.loop);
    if (catch err = timer_opt)
    {
        ctx.state = AnnounceState.FAILED;
        ctx.error = ASYNC_ERROR_CONNECT_FAILED;
        cleanup_and_callback(ctx);
        return;
    }
    ctx.timeout_timer = timer_opt;

    // Start connect phase
    start_connect_attempt(ctx);
}

<*
 Perform async announce to UDP tracker.
 Does not block the event loop.

 @param loop : "Event loop"
 @param torrent : "Torrent file"
 @param port : "Our listening port"
 @param event : "Event string (started/stopped/completed or empty)"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
 @param initial_timeout_seconds : "Initial timeout in seconds (0 = use default, for testing use 1)"
*>
fn void async_announce(event_loop::EventLoop* loop, metainfo::TorrentFile* torrent,
                       ushort port, String event, AnnounceCallback callback,
                       void* user_data, int initial_timeout_seconds = 0) @public
{
    // Parse tracker URL
    String tracker_url = torrent.announce;
    if (!tracker_url.starts_with("udp://"))
    {
        if (callback)
        {
            callback(null, ASYNC_ERROR_INVALID_URL, user_data);
        }
        return;
    }

    // Parse URL to extract host and port
    url::Url? parsed = url::parse(mem, tracker_url);
    if (catch err = parsed)
    {
        if (callback)
        {
            callback(null, ASYNC_ERROR_INVALID_URL, user_data);
        }
        return;
    }

    String host = parsed.host.copy(mem);
    ushort tracker_port = (ushort)parsed.port;
    if (tracker_port == 0)
    {
        tracker_port = 80;
    }

    parsed.free();

    // Allocate context
    AnnounceContext* ctx = mem::new(AnnounceContext);
    ctx.loop = loop;
    ctx.torrent = torrent;
    ctx.port = port;
    ctx.event = event;
    ctx.callback = callback;
    ctx.user_data = user_data;
    ctx.state = AnnounceState.RESOLVING_DNS;
    ctx.retry = 0;
    ctx.receiving = false;
    ctx.initial_timeout_seconds = initial_timeout_seconds;
    ctx.socket = null;
    ctx.timeout_timer = null;
    ctx.tracker_addr = null;
    ctx.tracker_host = host;  // Store for async DNS, will be freed in cleanup
    ctx.tracker_ip = "";
    ctx.tracker_port = tracker_port;
    ctx.announce_response = {};
    ctx.result.peers = {};

    // Start DNS resolution
    DString port_str;
    port_str.appendf("%d", tracker_port);
    ctx.tracker_port_str = port_str.copy_str(mem);  // Copy to heap for async DNS
    async_dns::resolve(loop, host, ctx.tracker_port_str, &on_dns_resolved, ctx);
}
