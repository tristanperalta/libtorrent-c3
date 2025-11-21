module libtorrent::trackers::http;

import libtorrent::http;
import async::event_loop;
import libtorrent::metainfo;
import std::net::url;
import libc;
import std::io;
import libtorrent::trackers;

// ============================================================================
// HttpTracker struct (implements Tracker interface)
// ============================================================================

<*
 HTTP tracker adapter implementing the Tracker interface.

 Wraps the existing http::async_get functionality with thread pool
 to provide non-blocking HTTP tracker announces.
*>
struct HttpTracker (trackers::Tracker)
{
    event_loop::EventLoop* loop;
    String url;
    bool closed;
}

// ============================================================================
// Factory Function
// ============================================================================

<*
 Create HTTP tracker instance.

 @param loop : "Event loop for async operations"
 @param url : "HTTP tracker URL"
 @return "HttpTracker instance (caller must free)"
*>
fn HttpTracker* create(event_loop::EventLoop* loop, String url) @public
{
    HttpTracker* tracker = mem::new(HttpTracker);
    tracker.loop = loop;
    tracker.url = url.copy(mem);  // Own a copy
    tracker.closed = false;
    return tracker;
}

// ============================================================================
// Tracker Interface Implementation (@dynamic methods)
// ============================================================================

fn void HttpTracker.announce(
    &self,
    metainfo::TorrentFile* torrent,
    ushort port,
    String event,
    trackers::AnnounceCallback callback,
    void* user_data,
    int timeout_seconds
) @dynamic
{
    if (self.closed)
    {
        if (callback) callback(null, -1, user_data);
        return;
    }

    // Delegate to existing async_announce implementation
    async_announce(self.loop, torrent, port, event, callback, user_data, self.url);
}

fn void HttpTracker.close(&self) @dynamic
{
    self.closed = true;
}

fn String HttpTracker.get_url(&self) @dynamic
{
    return self.url;
}

fn String HttpTracker.get_protocol(&self) @dynamic
{
    return "http";
}

fn void HttpTracker.free(&self) @dynamic
{
    if (!self.closed)
    {
        io::eprintn("WARNING: HttpTracker.free() called without close()");
    }
    if (self.url.len > 0) free(self.url);
    free(self);
}

// ============================================================================
// Internal Implementation
// ============================================================================

<*
 Async HTTP Tracker Implementation
 ==================================
 Non-blocking HTTP tracker client using thread pool + libcurl.

 This function is used internally by both:
 - HttpTracker.announce() (new Tracker interface implementation)

 Usage:
   async_announce(loop, torrent, port, event, &on_complete, user_data);
*>

// Error codes for async announce
const int ASYNC_ERROR_HTTP_FAILED = -1;
const int ASYNC_ERROR_INVALID_RESPONSE = -2;
const int ASYNC_ERROR_INVALID_URL = -3;

// Context for async announce operation
struct AnnounceContext
{
    metainfo::TorrentFile* torrent;
    ushort port;
    String event;
    trackers::AnnounceCallback callback;
    void* user_data;

    // Results
    trackers::TrackerResponse result;
    int error;
}

<*
 Clean up resources and invoke user callback.
*>
fn void cleanup_and_callback(AnnounceContext* ctx, bool success)
{
    // Invoke user callback
    if (ctx.callback)
    {
        if (success)
        {
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
 Handle HTTP response.
*>
fn void on_http_response(http::HttpResponse* response, int status, void* user_data)
{
    AnnounceContext* ctx = (AnnounceContext*)user_data;

    if (status < 0 || !response)
    {
        ctx.error = ASYNC_ERROR_HTTP_FAILED;
        cleanup_and_callback(ctx, false);
        return;
    }

    // Check HTTP status
    if (response.status != 200)
    {
        // Free response body (allocated with libc malloc in worker thread)
        if (response.body.len > 0) {
            libc::free((void*)response.body.ptr);
        }
        ctx.error = ASYNC_ERROR_HTTP_FAILED;
        cleanup_and_callback(ctx, false);
        return;
    }

    // Parse tracker response
    trackers::TrackerResponse? parsed = trackers::parse_tracker_response(response.body);

    // Free response body (allocated with libc malloc in worker thread)
    if (response.body.len > 0) {
        libc::free((void*)response.body.ptr);
    }

    if (catch err = parsed)
    {
        ctx.error = ASYNC_ERROR_INVALID_RESPONSE;
        cleanup_and_callback(ctx, false);
        return;
    }

    // Success
    ctx.result = parsed;
    cleanup_and_callback(ctx, true);
}

<*
 Perform async announce to HTTP tracker.
 Does NOT block the event loop - uses thread pool.

 @param loop : "Event loop"
 @param torrent : "Torrent file"
 @param port : "Our listening port"
 @param event : "Event string (started/stopped/completed or empty)"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
 @param tracker_url_override : "Optional tracker URL override (uses torrent.announce if empty)"
*>
fn void async_announce(event_loop::EventLoop* loop, metainfo::TorrentFile* torrent,
                       ushort port, String event, trackers::AnnounceCallback callback,
                       void* user_data, String tracker_url_override = "") @public
{
    // Use override URL if provided, otherwise use torrent.announce
    String tracker_url = tracker_url_override.len > 0 ? tracker_url_override : torrent.announce;

    if (!tracker_url.starts_with("http://") && !tracker_url.starts_with("https://"))
    {
        if (callback)
        {
            callback(null, ASYNC_ERROR_INVALID_URL, user_data);
        }
        return;
    }

    // Generate peer ID
    char[20] peer_id = trackers::generate_peer_id();

    // Parse tracker URL
    url::Url? tracker_url_parsed = url::parse(mem, tracker_url);
    if (catch err = tracker_url_parsed)
    {
        if (callback)
        {
            callback(null, ASYNC_ERROR_INVALID_URL, user_data);
        }
        return;
    }

    // Determine protocol and port
    bool use_tls = tracker_url_parsed.scheme == "https";
    ushort tracker_port = (ushort)tracker_url_parsed.port;
    if (tracker_port == 0)
    {
        tracker_port = use_tls ? 443 : 80;
    }

    String host = tracker_url_parsed.host.copy(mem);

    // Build announce URL with query parameters
    String announce_url = trackers::build_announce_url(
        tracker_url,
        &torrent.info_hash,
        &peer_id,
        port,
        0,  // uploaded
        0,  // downloaded
        torrent.info.length,  // left
        event,
        trackers::DEFAULT_NUMWANT  // Request 50 peers
    );

    // Parse the full announce URL to extract path + query
    url::Url? full_url = url::parse(mem, announce_url);
    if (catch err = full_url)
    {
        free(host);
        free(announce_url);
        tracker_url_parsed.free();
        if (callback)
        {
            callback(null, ASYNC_ERROR_INVALID_URL, user_data);
        }
        return;
    }

    // Build path + query string for HTTP request
    DString path_and_query;
    path_and_query.append(full_url.path);
    if (full_url.query.len > 0)
    {
        path_and_query.append_char('?');
        path_and_query.append(full_url.query);
    }

    String path = path_and_query.copy_str(mem);

    full_url.free();
    free(announce_url);
    tracker_url_parsed.free();

    // Allocate context
    AnnounceContext* ctx = mem::new(AnnounceContext);
    ctx.torrent = torrent;
    ctx.port = port;
    ctx.event = event;
    ctx.callback = callback;
    ctx.user_data = user_data;
    ctx.result.peers = {};

    // Make async HTTP request (uses thread pool!)
    http::request_async(loop, host, tracker_port, use_tls,
                        "GET", path, "",
                        &on_http_response, ctx);

    free(host);
    free(path);
}
