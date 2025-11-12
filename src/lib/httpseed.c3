module libtorrent::httpseed;

import std::io;
import std::time;
import std::net::url;
import std::encoding::hex;
import libc;
import async::event_loop;
import libtorrent::metainfo;
import libtorrent::http;
import libtorrent::common;
import libtorrent::storage_manager;
import libtorrent::event_bus;
import libtorrent::event_types;

<*
 * BEP 17 HTTP Seeding Implementation
 * ===================================
 * Hoffman-style HTTP seeding using httpseeds from torrent metadata.
 *
 * BEP 17 Specification:
 * - HTTP servers act as dynamic seed proxies (typically CGI/script)
 * - Use query parameters to request specific pieces/ranges
 * - URL format: <base_url>?info_hash=<hex>&piece=<N>&ranges=<start>-<end>
 * - Permanently discard URL on hash mismatch
 * - Support 503 response with retry-after delay (ASCII integer seconds)
 *
 * Differences from BEP 19:
 * - BEP 17: Query params, dynamic server, same URL for all pieces
 * - BEP 19: Range headers, static files, URL construction per file
 *>

// Faults
faultdef HTTPSEED_INVALID_URL;
faultdef HTTPSEED_HTTP_ERROR;
faultdef HTTPSEED_NO_AVAILABLE_URLS;

// Maximum consecutive failures before temporary disable
const uint MAX_CONSECUTIVE_FAILURES = 3;

// Backoff time after failures (seconds)
const long FAILURE_BACKOFF_SECONDS = 60;

<*
 * HttpSeedUrl tracks the state of a single BEP 17 httpseed URL.
 *>
struct HttpSeedUrl
{
    String url;                    // Base URL from torrent metadata
    bool enabled;                  // false if permanently disabled (hash mismatch)
    uint consecutive_failures;     // Count of recent failures
    long last_failure_time;        // Unix timestamp of last failure
}

<*
 * HttpSeedDownload tracks an active piece download from an httpseed.
 *>
struct HttpSeedDownload
{
    uint piece_index;              // Which piece is being downloaded
    HttpSeedUrl* url;              // Which URL is being used
    char[] piece_data;             // Buffer for received data
    bool active;                   // Is this download slot in use?
    void* callback;                // Completion callback (PieceCallback)
    void* user_data;               // User data for callback
    HttpSeedManager* manager;      // Manager reference (for event publishing)
}

// Callback for piece completion
alias PieceCallback = fn void(uint piece_index, char[] data, void* user_data);

<*
 * HttpSeedManager coordinates all BEP 17 httpseed operations.
 *>
struct HttpSeedManager
{
    event_loop::EventLoop* loop;        // Event loop for async operations
    HttpSeedUrl[] urls;                 // All URLs from httpseeds
    HttpSeedDownload[] downloads;       // Active download slots
    char[20] info_hash;                 // Info hash for URL construction
    uint piece_length;                  // Bytes per piece
    uint last_piece_length;             // Length of final piece
    uint num_pieces;                    // Total number of pieces
    usz max_concurrent;                 // Max concurrent downloads
    usz next_url_index;                 // Round-robin index for URL selection
    event_bus::EventBus* event_bus;     // Event bus for publishing HttpSeed events (can be null)
    ulong total_bytes_downloaded;       // Track total bytes downloaded from all URLs
    bool shutting_down;                 // Prevents callback execution after .free()
}

<*
 * Create an HttpSeedManager from torrent metadata.
 *
 * @param loop : "Event loop for async operations"
 * @param torrent : "Torrent metadata containing httpseeds"
 * @param event_bus : "Event bus for publishing HttpSeed events (can be null)"
 * @param max_concurrent : "Maximum concurrent httpseed downloads"
 * @return "Initialized HttpSeedManager or null if no httpseeds"
 *>
fn HttpSeedManager* create(event_loop::EventLoop* loop,
                           metainfo::TorrentFile* torrent,
                           event_bus::EventBus* event_bus,
                           usz max_concurrent = 20) @public
{
    // No httpseeds available
    if (torrent.httpseeds.len == 0)
    {
        return null;
    }

    HttpSeedManager* mgr = mem::new(HttpSeedManager);
    mgr.loop = loop;
    mgr.info_hash = torrent.info_hash;
    mgr.piece_length = (uint)torrent.info.piece_length;
    mgr.num_pieces = torrent.info.calculate_num_pieces();
    mgr.last_piece_length = torrent.info.calculate_last_piece_length();
    mgr.max_concurrent = max_concurrent;
    mgr.next_url_index = 0;
    mgr.event_bus = event_bus;
    mgr.total_bytes_downloaded = 0;
    mgr.shutting_down = false;

    // Initialize URL list
    mgr.urls = mem::new_array(HttpSeedUrl, torrent.httpseeds.len);
    foreach (i, url_str : torrent.httpseeds)
    {
        mgr.urls[i].url = url_str.copy(mem);
        mgr.urls[i].enabled = true;
        mgr.urls[i].consecutive_failures = 0;
        mgr.urls[i].last_failure_time = 0;
    }

    // Initialize download slots
    mgr.downloads = mem::new_array(HttpSeedDownload, max_concurrent);
    foreach (i, &download : mgr.downloads)
    {
        download.active = false;
        download.piece_data = {};
    }

    return mgr;
}

<*
 * Free HttpSeedManager resources.
 *>
fn void HttpSeedManager.free(&self) @public
{
    // Set shutdown flag FIRST to prevent callbacks from accessing freed memory
    self.shutting_down = true;

    // Free URL strings
    foreach (url : self.urls)
    {
        if (url.url.len > 0) free(url.url);
    }
    if (self.urls.len > 0) free(self.urls);

    // Free download slots
    foreach (download : self.downloads)
    {
        if (download.piece_data.len > 0) free(download.piece_data);
    }
    if (self.downloads.len > 0) free(self.downloads);

    free(self);
}

<*
 * Check if a URL is currently available for use.
 * URLs are unavailable if permanently disabled or temporarily backed off.
 *>
fn bool HttpSeedUrl.is_available(&self)
{
    if (!self.enabled) return false;  // Permanently disabled

    // Check if in backoff period
    if (self.consecutive_failures >= MAX_CONSECUTIVE_FAILURES)
    {
        long now = (long)time::now().to_seconds();
        long backoff_duration = FAILURE_BACKOFF_SECONDS * (long)(1 << (self.consecutive_failures - MAX_CONSECUTIVE_FAILURES));
        if (now - self.last_failure_time < backoff_duration)
        {
            return false;  // Still in backoff
        }
    }

    return true;
}

<*
 * Get the next available URL for downloading using round-robin selection.
 * This distributes load across multiple httpseed URLs.
 *
 * @return "Pointer to available HttpSeedUrl, or null if none available"
 *>
fn HttpSeedUrl* HttpSeedManager.get_available_url(&self)
{
    if (self.urls.len == 0) return null;

    // Try all URLs starting from next_url_index (round-robin)
    usz start_index = self.next_url_index;
    for (usz i = 0; i < self.urls.len; i++)
    {
        usz index = (start_index + i) % self.urls.len;
        if (self.urls[index].is_available())
        {
            self.next_url_index = (index + 1) % self.urls.len;  // Move to next for next call
            return &self.urls[index];
        }
    }

    return null;  // No available URLs
}

<*
 * Find a free download slot.
 *
 * @return "Pointer to free slot, or null if all busy"
 *>
fn HttpSeedDownload* HttpSeedManager.get_free_slot(&self)
{
    foreach (&download : self.downloads)
    {
        if (!download.active) return download;
    }
    return null;  // All slots busy
}

<*
 * Parse URL into components (host, port, path, TLS flag).
 * Simple URL parser for HTTP/HTTPS URLs.
 *
 * @param url_str : "URL to parse"
 * @param host : "Output: hostname"
 * @param port : "Output: port number"
 * @param path : "Output: path component"
 * @param use_tls : "Output: whether to use HTTPS"
 * @return "fault? if URL parsing fails"
 *>
fn fault? parse_url(String url_str, String* host, ushort* port, String* path, bool* use_tls)
{
    // Simple URL parsing: {scheme}://{host}:{port}/{path}
    // Extract scheme
    usz? scheme_end_opt = url_str.index_of("://");
    if (catch scheme_end_opt) return HTTPSEED_INVALID_URL?;
    usz scheme_end = scheme_end_opt;

    String scheme = url_str[:scheme_end];
    *use_tls = (scheme == "https");

    usz start = scheme_end + 3;  // Skip "://"

    // Extract host and optional port
    usz? path_start_opt = url_str.index_of_char_from('/', start);
    usz path_start;
    if (catch path_start_opt)
    {
        path_start = url_str.len;
        *path = "/".copy(mem);
    }
    else
    {
        path_start = path_start_opt;
        *path = url_str[path_start..].copy(mem);
    }

    String host_port = url_str[start:path_start - start];
    usz? port_sep_opt = host_port.index_of_char(':');

    if (catch port_sep_opt)
    {
        *host = host_port.copy(mem);
        *port = *use_tls ? 443 : 80;
    }
    else
    {
        usz port_sep = port_sep_opt;
        *host = host_port[:port_sep].copy(mem);
        String port_str = host_port[port_sep + 1..];
        // Parse port
        int? parsed_port = port_str.to_int();
        if (catch parsed_port)
        {
            return HTTPSEED_INVALID_URL?;
        }
        *port = (ushort)parsed_port;
    }

    return {};
}

<*
 * Convert info_hash bytes to hexadecimal string.
 * BEP 17 requires info_hash as URL-encoded hex string.
 *
 * @param info_hash : "20-byte info hash"
 * @return "40-character hex string (caller must free)"
 *>
fn String info_hash_to_hex(char[20] info_hash)
{
    return hex::encode(mem, info_hash[..]);
}

<*
 * Construct BEP 17 URL with query parameters.
 *
 * Format: <base_url>?info_hash=<hex>&piece=<N>&ranges=<start>-<end>
 *
 * @param base_url : "Base URL from httpseeds"
 * @param info_hash : "20-byte info hash"
 * @param piece_index : "Piece index to download"
 * @param start_byte : "Start offset within piece (usually 0)"
 * @param end_byte : "End offset within piece (usually piece_length - 1)"
 * @return "Full URL with query params (caller must free)"
 *>
fn String construct_bep17_url(String base_url,
                                char[20] info_hash,
                                uint piece_index,
                                uint start_byte,
                                uint end_byte)
{
    DString url;

    // Start with base URL
    url.append(base_url);

    // Add query parameter separator
    if (base_url.contains("?"))
    {
        url.append("&");  // URL already has query params
    }
    else
    {
        url.append("?");  // First query param
    }

    // Add info_hash parameter (as hex)
    String hex_hash = info_hash_to_hex(info_hash);
    defer free(hex_hash);
    url.append("info_hash=");
    url.append(hex_hash);

    // Add piece parameter
    url.appendf("&piece=%d", piece_index);

    // Add ranges parameter
    url.appendf("&ranges=%d-%d", start_byte, end_byte);

    return url.copy_str(mem);
}

<*
 * Parse retry-after value from 503 response body.
 * BEP 17: 503 response body contains ASCII integer (seconds to wait).
 *
 * @param body : "Response body (expected to be ASCII integer)"
 * @return "Retry delay in seconds, or 0 if parsing fails"
 *>
fn uint parse_retry_after(String body)
{
    // BEP 17: Body should contain ASCII integer
    // Example: "120" means wait 120 seconds
    if (body.len == 0) return 0;

    // Try to parse as integer
    int? delay_opt = body.to_int();
    if (catch err = delay_opt)
    {
        return 0;  // Parse failed
    }

    int delay = delay_opt;
    return (uint)(delay > 0 ? delay : 0);
}

<*
 * Start downloading a piece from an httpseed.
 *
 * @param piece_index : "Index of piece to download"
 * @param callback : "Completion callback"
 * @param user_data : "User data passed to callback"
 * @return "fault? if download cannot be started"
 *>
fn fault? HttpSeedManager.start_piece_download(&self, uint piece_index,
                                                PieceCallback callback,
                                                void* user_data) @public
{
    // Find available URL
    HttpSeedUrl* url = self.get_available_url();
    if (!url) return HTTPSEED_NO_AVAILABLE_URLS?;

    // Find available download slot
    HttpSeedDownload* download = self.get_free_slot();
    if (!download) return HTTPSEED_NO_AVAILABLE_URLS?;  // All slots busy

    // Initialize download
    download.active = true;
    download.piece_index = piece_index;
    download.url = url;
    download.callback = callback;
    download.user_data = user_data;
    download.manager = self;

    // Allocate piece buffer
    uint piece_len = (piece_index == self.num_pieces - 1) ? self.last_piece_length : self.piece_length;
    download.piece_data = mem::new_array(char, piece_len);

    // Construct BEP 17 URL with query parameters
    String full_url = construct_bep17_url(
        url.url,
        self.info_hash,
        piece_index,
        0,                    // start_byte (whole piece)
        piece_len - 1         // end_byte (whole piece)
    );
    defer free(full_url);

    // Parse URL to extract host, port, path
    String host;
    ushort port;
    String path;
    bool use_tls;

    if (catch parse_url(full_url, &host, &port, &path, &use_tls))
    {
        // URL parsing failed - mark as permanently disabled
        url.enabled = false;
        download.active = false;
        return HTTPSEED_INVALID_URL?;
    }

    // Log the attempt
    io::printfn("[HttpSeed] Starting download: piece=%d url=%s", piece_index, full_url);

    // Start async HTTP request (BEP 17: no Range header, query params only)
    String[] headers = {};  // No headers needed for BEP 17
    http::request_async_with_headers(
        self.loop, host, port, use_tls,
        "GET", path, headers, "",
        &on_http_piece_received, download
    );

    // Publish download started event
    if (self.event_bus)
    {
        event_types::WebSeedEvent evt = event_types::create_webseed_event(
            piece_index, url.url, true, 0, "", self.total_bytes_downloaded
        );
        self.event_bus.publish(event_types::EVENT_WEBSEED_DOWNLOAD_STARTED, &evt, event_types::WebSeedEvent.sizeof);
    }

    // Cleanup parsed URL components
    free(host);
    free(path);

    return {};
}

<*
 * HTTP response callback for piece downloads.
 * Runs in event loop thread after HTTP request completes.
 *>
fn void on_http_piece_received(http::HttpResponse* response, int status, void* user_data)
{
    HttpSeedDownload* download = (HttpSeedDownload*)user_data;

    // Check if manager is shutting down (freed while HTTP request was in-flight)
    if (download.manager && download.manager.shutting_down)
    {
        io::printfn("[HttpSeed] Callback received after shutdown, ignoring piece %d", download.piece_index);

        // Cleanup response body and return early
        if (response && response.body.len > 0)
        {
            libc::free((void*)response.body.ptr);
        }
        return;
    }

    // Check if request failed
    if (status != 0 || !response)
    {
        io::printfn("[HttpSeed] HTTP request failed for piece %d", download.piece_index);
        download.url.consecutive_failures++;
        download.url.last_failure_time = (long)time::now().to_seconds();

        // Publish download failed event
        if (download.manager && download.manager.event_bus)
        {
            event_types::WebSeedEvent evt = event_types::create_webseed_event(
                download.piece_index, download.url.url, false, 0, "Network error",
                download.manager.total_bytes_downloaded
            );
            download.manager.event_bus.publish(event_types::EVENT_WEBSEED_DOWNLOAD_FAILED, &evt, event_types::WebSeedEvent.sizeof);
        }

        download.active = false;

        // Call user callback with failure
        if (download.callback)
        {
            PieceCallback callback = (PieceCallback)download.callback;
            callback(download.piece_index, {}, download.user_data);
        }

        return;
    }

    // BEP 17: Check for 503 Service Unavailable (retry-after in body)
    if (response.status == 503)
    {
        uint retry_after = parse_retry_after((String)response.body);
        io::printfn("[HttpSeed] 503 Service Unavailable - retry after %d seconds", retry_after);

        // Update URL state with retry-after delay
        download.url.consecutive_failures++;
        download.url.last_failure_time = (long)time::now().to_seconds();

        // Publish download failed event
        if (download.manager && download.manager.event_bus)
        {
            DString error_msg;
            error_msg.appendf("503 Service Unavailable (retry: %ds)", retry_after);
            String error_str = error_msg.copy_str(mem);
            defer free(error_str);

            event_types::WebSeedEvent evt = event_types::create_webseed_event(
                download.piece_index, download.url.url, false, 0, error_str,
                download.manager.total_bytes_downloaded
            );
            download.manager.event_bus.publish(event_types::EVENT_WEBSEED_DOWNLOAD_FAILED, &evt, event_types::WebSeedEvent.sizeof);
        }

        download.active = false;

        // Call user callback with failure
        if (download.callback)
        {
            PieceCallback callback = (PieceCallback)download.callback;
            callback(download.piece_index, {}, download.user_data);
        }

        return;
    }

    // Check HTTP status code (expect 200 OK for BEP 17)
    if (response.status != 200)
    {
        io::printfn("[HttpSeed] HTTP error %d for piece %d", response.status, download.piece_index);
        download.url.consecutive_failures++;
        download.url.last_failure_time = (long)time::now().to_seconds();

        // Publish download failed event
        if (download.manager && download.manager.event_bus)
        {
            DString error_msg;
            error_msg.appendf("HTTP error %d", response.status);
            String error_str = error_msg.copy_str(mem);
            defer free(error_str);

            event_types::WebSeedEvent evt = event_types::create_webseed_event(
                download.piece_index, download.url.url, false, 0, error_str,
                download.manager.total_bytes_downloaded
            );
            download.manager.event_bus.publish(event_types::EVENT_WEBSEED_DOWNLOAD_FAILED, &evt, event_types::WebSeedEvent.sizeof);
        }

        download.active = false;

        // Call user callback with failure
        if (download.callback)
        {
            PieceCallback callback = (PieceCallback)download.callback;
            callback(download.piece_index, {}, download.user_data);
        }

        return;
    }

    // Success - copy response body to piece buffer
    char[] body = response.body;
    uint expected_len = download.piece_data.len;

    if (body.len != expected_len)
    {
        io::printfn("[HttpSeed] Size mismatch: expected %d, got %d bytes", expected_len, body.len);
        download.url.consecutive_failures++;
        download.url.last_failure_time = (long)time::now().to_seconds();

        download.active = false;

        // Call user callback with failure
        if (download.callback)
        {
            PieceCallback callback = (PieceCallback)download.callback;
            callback(download.piece_index, {}, download.user_data);
        }

        return;
    }

    // Copy data to piece buffer
    libc::memcpy(download.piece_data.ptr, body.ptr, body.len);

    // Reset failure count on success
    download.url.consecutive_failures = 0;

    // Update total bytes downloaded
    if (download.manager)
    {
        download.manager.total_bytes_downloaded += body.len;
    }

    // Publish download completed event
    if (download.manager && download.manager.event_bus)
    {
        event_types::WebSeedEvent evt = event_types::create_webseed_event(
            download.piece_index, download.url.url, true, (uint)body.len, "",
            download.manager.total_bytes_downloaded
        );
        download.manager.event_bus.publish(event_types::EVENT_WEBSEED_DOWNLOAD_COMPLETE, &evt, event_types::WebSeedEvent.sizeof);
    }

    io::printfn("[HttpSeed] Piece %d downloaded successfully (%d bytes)", download.piece_index, body.len);

    // Call user callback with success
    if (download.callback)
    {
        PieceCallback callback = (PieceCallback)download.callback;
        callback(download.piece_index, download.piece_data, download.user_data);
    }

    download.active = false;
}

<*
 * Mark a URL as permanently blacklisted due to hash mismatch.
 * BEP 17 requirement: Permanently discard URLs that serve incorrect data.
 *
 * @param url_string : "URL to blacklist"
 *>
fn void HttpSeedManager.blacklist_url(&self, String url_string) @public
{
    foreach (&url : self.urls)
    {
        if (url.url == url_string)
        {
            url.enabled = false;
            io::printfn("[HttpSeed] Permanently blacklisted: %s", url_string);
            return;
        }
    }
}

<*
 * Get number of active downloads.
 *
 * @return "Count of active download slots"
 *>
fn uint HttpSeedManager.get_active_count(&self) @public
{
    uint count = 0;
    foreach (download : self.downloads)
    {
        if (download.active) count++;
    }
    return count;
}

<*
 * Get number of available (non-blacklisted, non-backed-off) URLs.
 *
 * @return "Count of available URLs"
 *>
fn uint HttpSeedManager.get_available_url_count(&self) @public
{
    uint count = 0;
    foreach (url : self.urls)
    {
        if (url.is_available()) count++;
    }
    return count;
}

<*
 * Get total bytes downloaded from all httpseeds.
 *
 * @return "Total bytes downloaded"
 *>
fn ulong HttpSeedManager.get_total_bytes(&self) @public
{
    return self.total_bytes_downloaded;
}
