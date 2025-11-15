module libtorrent::udp_tracker;

import libtorrent::common;
import async::dns;
import async::udp;
import async::timer;
import async::event_loop;
import libtorrent::tracker;
import libtorrent::metainfo;
import uv;
import std::io;
import std::net::url;
import std::time;
import std::math::random;
import std::os::linux; // For htonl, htons, ntohl, ntohs
import std::core::log;

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

// Protocol buffer sizes (BEP 15)
const usz CONNECT_REQUEST_SIZE = 16;       // protocol_id(8) + action(4) + transaction_id(4)
const usz CONNECT_RESPONSE_SIZE = 16;      // action(4) + transaction_id(4) + connection_id(8)
const usz ANNOUNCE_REQUEST_SIZE = 98;      // Full announce request size
const usz ANNOUNCE_RESPONSE_MIN_SIZE = 20; // Minimum response before peers

// Network byte order conversion functions.
// UDP tracker protocol uses big-endian (network byte order).
// Note: htonl, htons, ntohl, ntohs are provided by std::os::linux

<*
 Convert 64-bit integer from host to network byte order.
 Uses inline endianness detection - the compiler should optimize this.
*>
fn long htonll(long x) @inline
{
    // Check endianness inline - compiler will optimize this constant check
    char[4] test = {0x01, 0x02, 0x03, 0x04};
    if (*(int*)&test == 0x04030201)
    {
        // Little-endian: need to swap
        return ((long)(x & 0xFF) << 56) |
               ((long)(x & 0xFF00) << 40) |
               ((long)(x & 0xFF0000) << 24) |
               ((long)(x & 0xFF000000) << 8) |
               ((long)(x & 0xFF00000000) >> 8) |
               ((long)(x & 0xFF0000000000) >> 24) |
               ((long)(x & 0xFF000000000000) >> 40) |
               ((ulong)x >> 56);
    }
    // Big-endian: no swap needed
    return x;
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
    common::InfoHash info_hash;
    common::PeerId peer_id;
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
    // Note: Peer data is parsed separately from raw bytes
}

struct ErrorResponse {
    int action;
    int transaction_id;
}

// ============================================================================
// Pack/Unpack Helper Functions
// ============================================================================

<*
 Pack 64-bit integer into buffer at offset in network byte order.
*>
fn void pack_int64(char[] buffer, usz offset, long value) @inline
{
    long net_value = htonll(value);
    char* p = (char*)&net_value;
    buffer[offset..offset+7] = p[0..7];
}

<*
 Pack 32-bit integer into buffer at offset in network byte order.
*>
fn void pack_int32(char[] buffer, usz offset, int value) @inline
{
    int net_value = (int)linux::htonl((uint)value);
    char* p = (char*)&net_value;
    buffer[offset..offset+3] = p[0..3];
}

<*
 Pack 16-bit integer into buffer at offset in network byte order.
*>
fn void pack_int16(char[] buffer, usz offset, ushort value) @inline
{
    ushort net_value = linux::htons(value);
    char* p = (char*)&net_value;
    buffer[offset..offset+1] = p[0..1];
}

<*
 Unpack 64-bit integer from buffer at offset from network byte order.
*>
fn long unpack_int64(char[] buffer, usz offset) @inline
{
    long net_value;
    char* p = (char*)&net_value;
    p[0..7] = buffer[offset..offset+7];
    return ntohll(net_value);
}

<*
 Unpack 32-bit integer from buffer at offset from network byte order.
*>
fn int unpack_int32(char[] buffer, usz offset) @inline
{
    int net_value;
    char* p = (char*)&net_value;
    p[0..3] = buffer[offset..offset+3];
    return (int)linux::ntohl((uint)net_value);
}

<*
 Unpack 16-bit integer from buffer at offset from network byte order.
*>
fn ushort unpack_int16(char[] buffer, usz offset) @inline
{
    ushort net_value;
    char* p = (char*)&net_value;
    p[0..1] = buffer[offset..offset+1];
    return linux::ntohs(net_value);
}

// ============================================================================
// Protocol Message Packing/Unpacking
// ============================================================================

<*
 Pack connect request into byte buffer.
*>
fn void pack_connect_request(int transaction_id, char[] buffer) @public
{
    assert(buffer.len >= CONNECT_REQUEST_SIZE, "Buffer too small for connect request");

    pack_int64(buffer, 0, UDP_PROTOCOL_ID);
    pack_int32(buffer, 8, ACTION_CONNECT);
    pack_int32(buffer, 12, transaction_id);
}

<*
 Unpack connect response from byte buffer.
*>
fn ConnectResponse? unpack_connect_response(char[] buffer) @public
{
    if (buffer.len < CONNECT_RESPONSE_SIZE)
    {
        return UDP_TRACKER_INVALID_RESPONSE?;
    }

    ConnectResponse response;
    response.action = unpack_int32(buffer, 0);

    if (response.action != ACTION_CONNECT)
    {
        if (response.action == ACTION_ERROR)
        {
            return UDP_TRACKER_PROTOCOL_ERROR?;
        }
        return UDP_TRACKER_INVALID_RESPONSE?;
    }

    response.transaction_id = unpack_int32(buffer, 4);
    response.connection_id = unpack_int64(buffer, 8);

    return response;
}

<*
 Pack announce request into byte buffer.
*>
fn void pack_announce_request(AnnounceRequest* request, char[] buffer) @public
{
    assert(buffer.len >= ANNOUNCE_REQUEST_SIZE, "Buffer too small for announce request");

    usz offset = 0;

    pack_int64(buffer, offset, request.connection_id);
    offset += 8;

    pack_int32(buffer, offset, request.action);
    offset += 4;

    pack_int32(buffer, offset, request.transaction_id);
    offset += 4;

    buffer[offset..offset+common::SHA1_HASH_SIZE-1] = request.info_hash[0..common::SHA1_HASH_SIZE-1];
    offset += common::SHA1_HASH_SIZE;

    buffer[offset..offset+common::PEER_ID_SIZE-1] = request.peer_id[0..common::PEER_ID_SIZE-1];
    offset += common::PEER_ID_SIZE;

    pack_int64(buffer, offset, request.downloaded);
    offset += 8;

    pack_int64(buffer, offset, request.left);
    offset += 8;

    pack_int64(buffer, offset, request.uploaded);
    offset += 8;

    pack_int32(buffer, offset, request.event);
    offset += 4;

    pack_int32(buffer, offset, request.ip_address);
    offset += 4;

    pack_int32(buffer, offset, request.key);
    offset += 4;

    pack_int32(buffer, offset, request.num_want);
    offset += 4;

    pack_int16(buffer, offset, request.port);
}

<*
 Unpack announce response from byte buffer.
*>
fn AnnounceResponse? unpack_announce_response(char[] buffer, char[]* peers_out) @public
{
    if (buffer.len < ANNOUNCE_RESPONSE_MIN_SIZE)
    {
        return UDP_TRACKER_INVALID_RESPONSE?;
    }

    AnnounceResponse response;
    response.action = unpack_int32(buffer, 0);

    if (response.action != ACTION_ANNOUNCE)
    {
        if (response.action == ACTION_ERROR)
        {
            return UDP_TRACKER_PROTOCOL_ERROR?;
        }
        return UDP_TRACKER_INVALID_RESPONSE?;
    }

    response.transaction_id = unpack_int32(buffer, 4);
    response.interval = unpack_int32(buffer, 8);
    response.leechers = unpack_int32(buffer, 12);
    response.seeders = unpack_int32(buffer, 16);

    if (buffer.len > ANNOUNCE_RESPONSE_MIN_SIZE)
    {
        *peers_out = buffer[ANNOUNCE_RESPONSE_MIN_SIZE..buffer.len-1];
    }
    else
    {
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
    async::udp::UdpSocket* socket;
    async::timer::Timer* timeout_timer;
    async::dns::DnsResolver* dns_resolver;
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
        ctx.timeout_timer.stop();
        ctx.timeout_timer.close();
        ctx.timeout_timer = null;
    }

    // Close socket if open
    if (ctx.socket)
    {
        ctx.socket.recv_stop();
        ctx.socket.close();
        ctx.socket = null;
    }

    // Free DNS resolver
    if (ctx.dns_resolver)
    {
        free(ctx.dns_resolver);
        ctx.dns_resolver = null;
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

    // Free TrackerResponse peers array (heap-allocated by parse_compact_peers)
    if (ctx.result.peers.len > 0)
    {
        free(ctx.result.peers);
    }

    // Free context
    free(ctx);
}

<*
 Handle timeout - retry or fail.
*>
fn void on_timeout(async::timer::Timer* timer, void* user_data)
{
    AnnounceContext* ctx = (AnnounceContext*)user_data;

    // Stop timer
    timer.stop();

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
fn void on_announce_response(async::udp::UdpSocket* socket, char[] data, uv::Sockaddr* addr, void* user_data)
{
    AnnounceContext* ctx = (AnnounceContext*)user_data;

    if (data.len < 20)
    {
        return;  // Invalid response, wait for timeout/retry
    }

    // Stop receiving and timer
    socket.recv_stop();
    ctx.receiving = false;  // Reset flag so next phase can start receiving
    ctx.timeout_timer.stop();

    // Copy response data
    ctx.announce_response = mem::new_array(char, data.len);
    ctx.announce_response[..] = data[..];

    // Parse announce response
    char[] raw_peers;
    udp_tracker::AnnounceResponse? response = udp_tracker::unpack_announce_response(ctx.announce_response, &raw_peers);

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

    // Parse compact peer data into SocketAddress[]
    common::SocketAddress[]? peers_opt = tracker::parse_compact_peers(raw_peers);
    if (catch err = peers_opt)
    {
        ctx.result.peers = {};  // Empty array on parse error
    }
    else
    {
        ctx.result.peers = peers_opt;  // Use the already-parsed result
    }

    // Success - convert to TrackerResponse
    ctx.result.interval = response.interval;
    ctx.result.min_interval = 0;
    ctx.result.complete = response.seeders;
    ctx.result.incomplete = response.leechers;
    ctx.result.downloaders = 0;  // BEP 21: UDP trackers don't provide this field
    ctx.result.failure_reason = "";
    ctx.result.warning_message = "";

    ctx.state = AnnounceState.COMPLETED;
    cleanup_and_callback(ctx);
}

<*
 Handle announce send completion.
*>
fn void on_announce_sent(async::udp::UdpSocket* socket, int status, void* user_data)
{
    if (status < 0)
    {
        AnnounceContext* ctx = (AnnounceContext*)user_data;
        log::error("Announce send failed: %s", (ZString)uv::strerror(status));

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
        ctx.socket.recv_start(null, &on_announce_response, ctx);
        ctx.receiving = true;
    }

    // Send announce request
    ctx.socket.send_to(ctx.tracker_addr, ctx.announce_request[..],
                       &on_announce_sent, ctx);

    // Start timeout timer
    int base_timeout = ctx.initial_timeout_seconds > 0 ? ctx.initial_timeout_seconds : udp_tracker::UDP_INITIAL_TIMEOUT_SECONDS;
    int timeout_ms = (base_timeout * (1 << ctx.retry)) * 1000;
    ctx.timeout_timer.start((ulong)timeout_ms, 0, &on_timeout, ctx);
}

<*
 Handle connect response.
*>
fn void on_connect_response(async::udp::UdpSocket* socket, char[] data, uv::Sockaddr* addr, void* user_data)
{
    AnnounceContext* ctx = (AnnounceContext*)user_data;

    if (data.len < 16)
    {
        return;  // Invalid response, wait for timeout/retry
    }

    // Stop receiving and timer
    socket.recv_stop();
    ctx.receiving = false;  // Reset flag so next phase can start receiving
    ctx.timeout_timer.stop();

    // Copy response
    ctx.connect_response[..] = data[0..CONNECT_RESPONSE_SIZE-1];

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
fn void on_connect_sent(async::udp::UdpSocket* socket, int status, void* user_data)
{
    if (status < 0)
    {
        AnnounceContext* ctx = (AnnounceContext*)user_data;
        log::error("Connect send failed: %s", (ZString)uv::strerror(status));

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
        ctx.socket.recv_start(null, &on_connect_response, ctx);
        ctx.receiving = true;
    }

    // Send connect request
    ctx.socket.send_to(ctx.tracker_addr, ctx.connect_request[..],
                       &on_connect_sent, ctx);

    // Start timeout timer
    int base_timeout = ctx.initial_timeout_seconds > 0 ? ctx.initial_timeout_seconds : udp_tracker::UDP_INITIAL_TIMEOUT_SECONDS;
    int timeout_ms = (base_timeout * (1 << ctx.retry)) * 1000;
    ctx.timeout_timer.start((ulong)timeout_ms, 0, &on_timeout, ctx);
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

    // Get first IPv4 or IPv6 address (BEP 7: IPv6 Tracker Extension)
    // Prefer IPv4 for backward compatibility, fallback to IPv6
    uv::AddrInfo* info = result;
    uv::AddrInfo* ipv6_fallback = null;
    bool found = false;

    // First pass: Look for IPv4
    while (info && !found)
    {
        if (info.ai_family == uv::AF_INET && info.ai_socktype == uv::SOCK_DGRAM)
        {
            // Copy the sockaddr
            ctx.tracker_addr = mem::new(uv::Sockaddr);
            *ctx.tracker_addr = *info.ai_addr;

            // Extract IP for display
            ctx.tracker_ip = async::dns::addr_to_string(info.ai_addr);

            found = true;
        }
        else if (info.ai_family == uv::AF_INET6 && info.ai_socktype == uv::SOCK_DGRAM && !ipv6_fallback)
        {
            // Save first IPv6 address as fallback
            ipv6_fallback = info;
        }
        info = info.ai_next;
    }

    // Second pass: Use IPv6 if no IPv4 found
    if (!found && ipv6_fallback)
    {
        ctx.tracker_addr = mem::new(uv::Sockaddr);
        *ctx.tracker_addr = *ipv6_fallback.ai_addr;
        ctx.tracker_ip = async::dns::addr_to_string(ipv6_fallback.ai_addr);
        found = true;
    }

    async::dns::free_result(result);

    if (!found)
    {
        ctx.state = AnnounceState.FAILED;
        ctx.error = ASYNC_ERROR_DNS_FAILED;
        cleanup_and_callback(ctx);
        return;
    }

    // Create UDP socket
    async::udp::UdpSocket*? socket_opt = async::udp::create(ctx.loop);
    if (catch err = socket_opt)
    {
        ctx.state = AnnounceState.FAILED;
        ctx.error = ASYNC_ERROR_CONNECT_FAILED;
        cleanup_and_callback(ctx);
        return;
    }
    ctx.socket = socket_opt;

    // Create timeout timer
    async::timer::Timer*? timer_opt = async::timer::create(ctx.loop);
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
 @param tracker_url_override : "Optional tracker URL override (uses torrent.announce if empty)"
*>
fn void async_announce(event_loop::EventLoop* loop, metainfo::TorrentFile* torrent,
                       ushort port, String event, AnnounceCallback callback,
                       void* user_data, int initial_timeout_seconds = 0,
                       String tracker_url_override = "") @public
{
    // Use override URL if provided, otherwise use torrent.announce
    String tracker_url = tracker_url_override.len > 0 ? tracker_url_override : torrent.announce;

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

    // Create DNS resolver
    ctx.dns_resolver = async::dns::create(loop);

    // Start DNS resolution
    DString port_str;
    port_str.appendf("%d", tracker_port);
    ctx.tracker_port_str = port_str.copy_str(mem);  // Copy to heap for async DNS
    ctx.dns_resolver.resolve(host, ctx.tracker_port_str, &on_dns_resolved, ctx);
}
