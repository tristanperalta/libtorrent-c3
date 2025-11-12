module libtorrent::webseed;

import std::io;
import std::time;
import std::net::url;
import libc;
import async::event_loop;
import libtorrent::metainfo;
import libtorrent::http;
import libtorrent::common;
import libtorrent::storage_manager;
import libtorrent::event_bus;
import libtorrent::event_types;

<*
 * BEP 19 Web Seeding Implementation
 * ==================================
 * GetRight-style HTTP/FTP seeding using url-list from torrent metadata.
 *
 * BEP 19 Specification:
 * - HTTP servers act as "permanently unchoked seeds"
 * - Use HTTP Range headers to download specific pieces
 * - Permanently discard URL on hash mismatch
 * - Support both single-file and multi-file torrents
 *
 * URL Construction:
 * - Single-file: Base URL points to file, use Range: bytes=X-Y
 * - Multi-file: Base URL + torrent name + file path + Range header
 *>

// Faults
faultdef WEBSEED_INVALID_URL;
faultdef WEBSEED_HTTP_ERROR;
faultdef WEBSEED_NO_AVAILABLE_URLS;

// Maximum consecutive failures before temporary disable
const uint MAX_CONSECUTIVE_FAILURES = 3;

// Backoff time after failures (seconds)
const long FAILURE_BACKOFF_SECONDS = 60;

<*
 * WebSeedUrl tracks the state of a single web seed URL.
 *>
struct WebSeedUrl
{
    String url;                    // Base URL from torrent metadata
    bool enabled;                  // false if permanently disabled (hash mismatch)
    uint consecutive_failures;     // Count of recent failures
    long last_failure_time;        // Unix timestamp of last failure
}

<*
 * WebSeedDownload tracks an active piece download from a web seed.
 *>
struct WebSeedDownload
{
    uint piece_index;              // Which piece is being downloaded
    WebSeedUrl* url;               // Which URL is being used
    char[] piece_data;             // Buffer for received data
    bool active;                   // Is this download slot in use?
    void* callback;                // Completion callback (PieceCallback)
    void* user_data;               // User data for callback
    WebSeedManager* manager;       // Manager reference (for event publishing)
}

// Callback for piece completion
alias PieceCallback = fn void(uint piece_index, char[] data, void* user_data);

<*
 * WebSeedManager coordinates all web seed operations.
 *>
struct WebSeedManager
{
    event_loop::EventLoop* loop;        // Event loop for async operations
    WebSeedUrl[] urls;                  // All URLs from url-list
    WebSeedDownload[] downloads;        // Active download slots
    metainfo::TorrentInfo* info;        // Torrent metadata for URL construction
    String torrent_name;                // Torrent name (for multi-file)
    bool is_multi_file;                 // Single-file vs multi-file torrent
    uint piece_length;                  // Bytes per piece
    uint last_piece_length;             // Length of final piece
    uint num_pieces;                    // Total number of pieces
    usz max_concurrent;                 // Max concurrent downloads
    usz next_url_index;                 // Round-robin index for URL selection
    event_bus::EventBus* event_bus;     // Event bus for publishing WebSeed events (can be null)
    ulong total_bytes_downloaded;       // Track total bytes downloaded from all URLs
    bool shutting_down;                 // Prevents callback execution after .free()
}

<*
 * Create a WebSeedManager from torrent metadata.
 *
 * @param loop : "Event loop for async operations"
 * @param torrent : "Torrent metadata containing url-list"
 * @param event_bus : "Event bus for publishing WebSeed events (can be null)"
 * @param max_concurrent : "Maximum concurrent web seed downloads"
 * @return "Initialized WebSeedManager or null if no web seeds"
 *>
fn WebSeedManager* create(event_loop::EventLoop* loop,
                          metainfo::TorrentFile* torrent,
                          event_bus::EventBus* event_bus,
                          usz max_concurrent = 20) @public
{
    // No web seeds available
    if (torrent.url_list.len == 0)
    {
        return null;
    }

    WebSeedManager* mgr = mem::new(WebSeedManager);
    mgr.loop = loop;
    mgr.info = &torrent.info;
    mgr.torrent_name = torrent.info.name;
    mgr.is_multi_file = torrent.info.is_multi_file;
    mgr.piece_length = (uint)torrent.info.piece_length;
    mgr.num_pieces = torrent.info.calculate_num_pieces();
    mgr.last_piece_length = torrent.info.calculate_last_piece_length();
    mgr.max_concurrent = max_concurrent;
    mgr.next_url_index = 0;
    mgr.event_bus = event_bus;
    mgr.total_bytes_downloaded = 0;
    mgr.shutting_down = false;

    // Initialize URL list
    mgr.urls = mem::new_array(WebSeedUrl, torrent.url_list.len);
    foreach (i, url_str : torrent.url_list)
    {
        mgr.urls[i].url = url_str.copy(mem);
        mgr.urls[i].enabled = true;
        mgr.urls[i].consecutive_failures = 0;
        mgr.urls[i].last_failure_time = 0;
    }

    // Initialize download slots
    mgr.downloads = mem::new_array(WebSeedDownload, max_concurrent);
    foreach (i, &download : mgr.downloads)
    {
        download.active = false;
        download.piece_data = {};
    }

    return mgr;
}

<*
 * Free WebSeedManager resources.
 *>
fn void WebSeedManager.free(&self) @public
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
fn bool WebSeedUrl.is_available(&self)
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
 * This distributes load across multiple web seed URLs.
 *
 * @return "Pointer to available WebSeedUrl, or null if none available"
 *>
fn WebSeedUrl* WebSeedManager.get_available_url(&self)
{
    if (self.urls.len == 0) return null;

    // Try all URLs starting from next_url_index (round-robin)
    usz start_index = self.next_url_index;
    for (usz i = 0; i < self.urls.len; i++)
    {
        usz index = (start_index + i) % self.urls.len;
        if (self.urls[index].is_available())
        {
            // Advance to next URL for next call
            self.next_url_index = (index + 1) % self.urls.len;
            return &self.urls[index];
        }
    }
    return null;
}

<*
 * Get an available download slot.
 *
 * @return "Pointer to free WebSeedDownload, or null if all busy"
 *>
fn WebSeedDownload* WebSeedManager.get_free_slot(&self)
{
    foreach (&download : self.downloads)
    {
        if (!download.active)
        {
            return download;
        }
    }
    return null;
}

<*
 * Parse URL into components (host, port, path, use_tls).
 *
 * @param url_str : "Full URL string"
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
    if (catch scheme_end_opt) return WEBSEED_INVALID_URL?;
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
            return WEBSEED_INVALID_URL?;
        }
        *port = (ushort)parsed_port;
    }

    return {};
}

<*
 * Construct HTTP Range header for a piece.
 *
 * @param piece_index : "Index of piece to download"
 * @return "Range header string (caller must free)"
 *>
fn String WebSeedManager.construct_range_header(&self, uint piece_index)
{
    ulong start_offset = (ulong)piece_index * (ulong)self.piece_length;
    uint piece_len = (piece_index == self.num_pieces - 1) ? self.last_piece_length : self.piece_length;
    ulong end_offset = start_offset + (ulong)piece_len - 1;  // Inclusive end

    DString header;
    header.appendf("Range: bytes=%d-%d", start_offset, end_offset);
    return header.copy_str(mem);
}

<*
 * Construct URL for single-file torrent piece download.
 * For single-file, the base URL points directly to the file.
 *
 * @param base_url : "Base URL from url-list"
 * @return "Full URL for HTTP request"
 *>
fn String construct_single_file_url(String base_url)
{
    // For single-file torrents, base URL is the file URL
    // Range is specified in HTTP header
    return base_url.copy(mem);
}

<*
 * Construct URL for multi-file torrent piece download.
 * For multi-file, base URL + torrent name + file path.
 *
 * BEP 19: If url-list ends in "/", append torrent name and file path.
 *
 * @param base_url : "Base URL from url-list"
 * @param torrent_name : "Torrent name (directory)"
 * @param file_path : "File path within torrent"
 * @return "Full URL for HTTP request"
 *>
fn String construct_multi_file_url(String base_url, String torrent_name, String file_path)
{
    DString url;

    // Ensure base URL ends with /
    if (!base_url.ends_with("/"))
    {
        url.append(base_url);
        url.append("/");
    }
    else
    {
        url.append(base_url);
    }

    // Add torrent name (URL encoded)
    String encoded_name = url::encode(mem, torrent_name, url::UrlEncodingMode.PATH);
    defer free(encoded_name);
    url.append(encoded_name);
    url.append("/");

    // Add file path (URL encoded)
    String encoded_path = url::encode(mem, file_path, url::UrlEncodingMode.PATH);
    defer free(encoded_path);
    url.append(encoded_path);

    return url.copy_str(mem);
}

<*
 * Start downloading a piece from a web seed.
 *
 * @param piece_index : "Index of piece to download"
 * @param callback : "Completion callback"
 * @param user_data : "User data passed to callback"
 * @return "fault? if download cannot be started"
 *>
fn fault? WebSeedManager.start_piece_download(&self, uint piece_index,
                                               PieceCallback callback,
                                               void* user_data) @public
{
    // Find available URL
    WebSeedUrl* url = self.get_available_url();
    if (!url) return WEBSEED_NO_AVAILABLE_URLS?;

    // Find available download slot
    WebSeedDownload* download = self.get_free_slot();
    if (!download) return WEBSEED_NO_AVAILABLE_URLS?;  // All slots busy

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

    // Construct Range header
    String range_header = self.construct_range_header(piece_index);
    defer free(range_header);

    // Construct full URL (append filename for single-file torrents if needed)
    String full_url = url.url;
    bool need_free_url = false;
    if (!self.is_multi_file && url.url[url.url.len - 1] == '/')
    {
        // Single-file torrent with directory-style URL - append filename
        DString url_builder;
        url_builder.append(url.url);
        url_builder.append(self.torrent_name);
        full_url = url_builder.copy_str(mem);
        need_free_url = true;
    }
    defer if (need_free_url) free(full_url);

    // Parse URL
    String host;
    ushort port;
    String path;
    bool use_tls;

    if (catch parse_url(full_url, &host, &port, &path, &use_tls))
    {
        // URL parsing failed - mark as permanently disabled
        url.enabled = false;
        download.active = false;
        return WEBSEED_INVALID_URL?;
    }

    // Log the attempt
    io::printfn("[WebSeed] Starting download: piece=%d url=%s", piece_index, full_url);
    io::printfn("[WebSeed] Range: %s", range_header);

    // Start async HTTP request with Range header
    String[] headers = { range_header };
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
    WebSeedDownload* download = (WebSeedDownload*)user_data;

    // Check if manager is shutting down (freed while HTTP request was in-flight)
    if (download.manager && download.manager.shutting_down)
    {
        io::printfn("[WebSeed] Callback received after shutdown, ignoring piece %d", download.piece_index);

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
        io::printfn("[WebSeed] HTTP request failed for piece %d", download.piece_index);
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

    // Check HTTP status code
    if (response.status != 200 && response.status != 206)  // 206 = Partial Content
    {
        io::printfn("[WebSeed] HTTP error %d for piece %d", response.status, download.piece_index);
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
                download.piece_index, download.url.url, false, response.status, error_str,
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

        // Cleanup response body
        if (response.body.len > 0) libc::free((void*)response.body.ptr);
        return;
    }

    // Copy response data to piece buffer
    usz copy_len = response.body.len < download.piece_data.len ? response.body.len : download.piece_data.len;
    for (usz i = 0; i < copy_len; i++)
    {
        download.piece_data[i] = response.body[i];
    }

    io::printfn("[WebSeed] Downloaded piece %d (%d bytes)", download.piece_index, copy_len);

    // Reset failure counter on success
    download.url.consecutive_failures = 0;
    download.url.last_failure_time = 0;

    // Update total bytes downloaded
    if (download.manager)
    {
        download.manager.total_bytes_downloaded += (ulong)copy_len;

        // Publish download complete event
        if (download.manager.event_bus)
        {
            event_types::WebSeedEvent evt = event_types::create_webseed_event(
                download.piece_index, download.url.url, true, response.status, "",
                download.manager.total_bytes_downloaded
            );
            download.manager.event_bus.publish(event_types::EVENT_WEBSEED_DOWNLOAD_COMPLETE, &evt, event_types::WebSeedEvent.sizeof);
        }
    }

    // Call user callback with success
    if (download.callback)
    {
        PieceCallback callback = (PieceCallback)download.callback;
        callback(download.piece_index, download.piece_data[:copy_len], download.user_data);
    }

    // Mark download slot as free
    download.active = false;

    // Cleanup response body (allocated in worker thread with libc::malloc)
    if (response.body.len > 0) libc::free((void*)response.body.ptr);
}

<*
 * Mark a URL as permanently failed due to hash mismatch.
 * BEP 19 requirement: Permanently discard URL on hash verification failure.
 *>
fn void WebSeedManager.mark_url_failed(&self, WebSeedUrl* url) @public
{
    io::printfn("[WebSeed] Permanently disabling URL due to hash mismatch: %s", url.url);
    url.enabled = false;

    // Publish URL disabled event
    if (self.event_bus)
    {
        event_types::WebSeedEvent evt = event_types::create_webseed_event(
            0, url.url, false, 0, "Hash mismatch", self.total_bytes_downloaded
        );
        self.event_bus.publish(event_types::EVENT_WEBSEED_URL_DISABLED, &evt, event_types::WebSeedEvent.sizeof);
    }
}

<*
 * Mark a URL as having a temporary failure (HTTP error, timeout).
 * Uses exponential backoff for retries.
 *>
fn void WebSeedManager.mark_url_temporary_failure(&self, WebSeedUrl* url) @public
{
    url.consecutive_failures++;
    url.last_failure_time = (long)time::now().to_seconds();

    if (url.consecutive_failures >= MAX_CONSECUTIVE_FAILURES)
    {
        io::printfn("[WebSeed] URL temporarily disabled (backoff): %s", url.url);
    }
}

<*
 * Mark a URL as having succeeded.
 * Resets failure counters.
 *>
fn void WebSeedManager.mark_url_success(&self, WebSeedUrl* url) @public
{
    url.consecutive_failures = 0;
    url.last_failure_time = 0;
}

<*
 * Get count of enabled URLs.
 *>
fn uint WebSeedManager.get_enabled_count(&self) @public
{
    uint count = 0;
    foreach (url : self.urls)
    {
        if (url.enabled) count++;
    }
    return count;
}

<*
 * Get count of active downloads.
 *>
fn uint WebSeedManager.get_active_count(&self) @public
{
    uint count = 0;
    foreach (download : self.downloads)
    {
        if (download.active) count++;
    }
    return count;
}
