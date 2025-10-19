module libtorrent::udp_tracker_async;

import libtorrent::async_dns;
import libtorrent::async_udp;
import libtorrent::async_timer;
import libtorrent::event_loop;
import libtorrent::udp_tracker;
import libtorrent::tracker;
import libtorrent::torrent;
import uv;
import std::io;
import std::net::url;

<*
 Async UDP Tracker Implementation
 =================================
 Non-blocking UDP tracker client using async DNS, UDP, and timers.

 This eliminates the 15-60 second event loop blocking that occurs with
 the synchronous UDP tracker implementation.

 Usage:
   async_announce(loop, torrent, port, event, &on_complete, user_data);
*>

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
    torrent::TorrentFile* torrent;
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
fn void async_announce(event_loop::EventLoop* loop, torrent::TorrentFile* torrent,
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
