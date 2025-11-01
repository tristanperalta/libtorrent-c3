module libtorrent::http;
import curl;
import libc;
import async::work;
import async::event_loop;

<*
 Curl-based HTTP client implementation.
 Uses libcurl for HTTP requests (blocking I/O).
*>
struct CurlClient (HttpClient) {
    String host;
    ushort port;
    bool use_tls;
    Curl* handle;
}

// Callback for async HTTP requests
alias HttpCallback = fn void(HttpResponse* response, int status, void* user_data);

<*
 Response buffer for curl write callback.
 Uses heap allocation to avoid temp allocator issues in worker threads.
*>
struct ResponseBuffer
{
    char* data;
    usz size;
    usz capacity;
}

<*
 Context for async HTTP request running in thread pool.
*>
struct HttpWorkContext
{
    // Request parameters
    String url;          // Full URL to request
    String method;       // HTTP method
    String body;         // Request body (for POST)

    // Response data
    HttpResponse response;
    bool success;

    // Curl handle (created in work thread)
    Curl* curl_handle;

    // Response buffer (heap allocated)
    ResponseBuffer* response_buf;

    // Work context (needed for cleanup)
    async::event_loop::WorkContext* work_ctx;

    // User callback
    HttpCallback callback;
    void* user_data;
}

<*
 Create a new CurlClient.

 @param host : "The hostname to connect to"
 @param port : "The port number"
 @param use_tls : "Whether to use HTTPS"
 @return "Pointer to CurlClient, or null if initialization failed"
*>
fn CurlClient* curl_client(String host, ushort port, bool use_tls) @public {
    Curl* handle = curl::easy_init();
    if (!handle) return null;

    CurlClient* client = mem::new(CurlClient);
    *client = {
        .host = host.copy(mem),
        .port = port,
        .use_tls = use_tls,
        .handle = handle
    };
    return client;
}

<*
 Make an HTTP request.
 Implements HttpClient.request() interface method.

 @param self : "The CurlClient instance"
 @param method : "HTTP method (e.g., 'GET', 'POST')"
 @param path : "Request path (e.g., '/api/v1/resource')"
 @param headers : "Array of headers (pass empty array {} if none)"
 @param body : "Request body (for POST/PUT requests)"
 @return "HttpResponse or fault on error"
*>
fn HttpResponse? CurlClient.request(CurlClient* self, String method,
                                     String path, String[] headers,
                                     String body) @dynamic {
    // Build full URL
    DString url;
    url.appendf("%s://%s:%d%s",
                self.use_tls ? "https" : "http",
                self.host,
                self.port,
                path);

    // Set URL
    curl::CURLcode res = curl::easy_setopt(self.handle, curl::CURLOPT_URL, url.str_view());
    if (res != curl::CURLcode.CURLE_OK) return HTTP_REQUEST_FAILED?;

    // Set HTTP method
    if (method == "POST") {
        curl::easy_setopt(self.handle, curl::CURLOPT_POST, 1L);
        if (body.len > 0) {
            curl::easy_setopt(self.handle, curl::CURLOPT_POSTFIELDS, body);
            curl::easy_setopt(self.handle, curl::CURLOPT_POSTFIELDSIZE, (long)body.len);
        }
    } else if (method == "GET") {
        curl::easy_setopt(self.handle, curl::CURLOPT_HTTPGET, 1L);
    }
    // TODO: Add support for other methods (PUT, DELETE, etc.)

    // Setup write callback to collect response
    DString response_buffer;
    curl::easy_setopt(self.handle, curl::CURLOPT_WRITEFUNCTION, &write_callback);
    curl::easy_setopt(self.handle, curl::CURLOPT_WRITEDATA, &response_buffer);

    // Perform the request
    res = curl::easy_perform(self.handle);
    if (res != curl::CURLcode.CURLE_OK) {
        return HTTP_REQUEST_FAILED?;
    }

    // Get HTTP status code
    long status;
    curl::easy_getinfo(self.handle, curl::CURLINFO_RESPONSE_CODE, &status);

    HttpResponse response;
    response.status = (int)status;
    response.body = response_buffer.copy_str(mem);
    return response;
}

<*
 Close and cleanup the HTTP client.
 Implements HttpClient.close() interface method.

 @param self : "The CurlClient instance"
*>
fn void CurlClient.close(CurlClient* self) @dynamic {
    if (self.handle) {
        curl::easy_cleanup(self.handle);
        self.handle = null;
    }
    if (self.host.len > 0) {
        free(self.host);
    }
    free(self);
}

<*
 Curl write callback function.
 Called by libcurl to write received data.

 @param data : "Pointer to received data"
 @param size : "Size of each data element"
 @param nmemb : "Number of data elements"
 @param userp : "User pointer (DString buffer in our case)"
 @return "Number of bytes processed"
*>
fn usz write_callback(char* data, usz size, usz nmemb, void* userp) {
    ResponseBuffer* buffer = (ResponseBuffer*)userp;
    usz realsize = size * nmemb;

    // Grow buffer if needed
    usz needed = buffer.size + realsize;
    if (needed > buffer.capacity)
    {
        usz new_capacity = buffer.capacity * 2;
        if (new_capacity < needed) new_capacity = needed + 1024;

        // Use libc realloc for untracked memory
        char* new_data = (char*)libc::realloc(buffer.data, new_capacity);
        if (!new_data) return 0;  // Out of memory

        buffer.data = new_data;
        buffer.capacity = new_capacity;
    }

    // Copy data
    for (usz i = 0; i < realsize; i++)
    {
        buffer.data[buffer.size + i] = data[i];
    }
    buffer.size += realsize;

    return realsize;
}

// ============================================================================
// Async HTTP Request (Thread Pool)
// ============================================================================

<*
 Work function - runs in THREAD POOL (can block!).
 Performs the HTTP request using libcurl.
 Uses heap allocation only - no temp allocator needed.
*>
fn void do_http_work(void* input, void** output)
{
    HttpWorkContext* ctx = (HttpWorkContext*)input;
    ctx.success = false;

    // Create response buffer (heap allocated with untracked libc malloc)
    // Use libc malloc because this memory will be freed in a different thread
    ctx.response_buf = mem::new(ResponseBuffer);
    ctx.response_buf.capacity = 4096;
    ctx.response_buf.size = 0;
    ctx.response_buf.data = (char*)libc::malloc(4096);

    // Create curl handle for this thread
    ctx.curl_handle = curl::easy_init();
    if (!ctx.curl_handle)
    {
        *output = ctx;
        return;
    }

    // Set URL
    curl::easy_setopt(ctx.curl_handle, curl::CURLOPT_URL, ctx.url);

    // Set HTTP method
    if (ctx.method == "POST")
    {
        curl::easy_setopt(ctx.curl_handle, curl::CURLOPT_POST, 1L);
        if (ctx.body.len > 0)
        {
            curl::easy_setopt(ctx.curl_handle, curl::CURLOPT_POSTFIELDS, ctx.body);
            curl::easy_setopt(ctx.curl_handle, curl::CURLOPT_POSTFIELDSIZE, (long)ctx.body.len);
        }
    }
    else if (ctx.method == "GET")
    {
        curl::easy_setopt(ctx.curl_handle, curl::CURLOPT_HTTPGET, 1L);
    }

    // Setup write callback to collect response
    curl::easy_setopt(ctx.curl_handle, curl::CURLOPT_WRITEFUNCTION, &write_callback);
    curl::easy_setopt(ctx.curl_handle, curl::CURLOPT_WRITEDATA, ctx.response_buf);

    // Perform the request (THIS BLOCKS - but we're in thread pool!)
    curl::CURLcode res = curl::easy_perform(ctx.curl_handle);

    if (res == curl::CURLcode.CURLE_OK)
    {
        // Get HTTP status code
        long status;
        curl::easy_getinfo(ctx.curl_handle, curl::CURLINFO_RESPONSE_CODE, &status);

        // Store response (convert buffer to string)
        // Use libc malloc for untracked memory that will be freed in main thread
        ctx.response.status = (int)status;
        if (ctx.response_buf.size > 0)
        {
            char* response_data = (char*)libc::malloc(ctx.response_buf.size);
            for (usz i = 0; i < ctx.response_buf.size; i++)
            {
                response_data[i] = ctx.response_buf.data[i];
            }
            ctx.response.body = (String)response_data[:ctx.response_buf.size];
        }
        else
        {
            ctx.response.body = "";
        }
        ctx.success = true;
    }

    // Clean up curl handle
    curl::easy_cleanup(ctx.curl_handle);
    ctx.curl_handle = null;

    // Free response buffer (using libc free for untracked memory)
    libc::free(ctx.response_buf.data);
    free(ctx.response_buf);

    *output = ctx;
}

<*
 Completion callback - runs in EVENT LOOP thread.
*>
fn void on_http_complete(void* output, int status, void* user_data)
{
    HttpWorkContext* ctx = (HttpWorkContext*)output;

    if (ctx.callback)
    {
        if (ctx.success)
        {
            ctx.callback(&ctx.response, 0, ctx.user_data);
        }
        else
        {
            ctx.callback(null, -1, ctx.user_data);
        }
    }

    // Clean up context strings (allocated in event loop thread)
    if (ctx.url.len > 0) free(ctx.url);
    if (ctx.method.len > 0) free(ctx.method);
    if (ctx.body.len > 0) free(ctx.body);

    // Free work context (async_work doesn't free it per comment in async_work.c3:81-82)
    if (ctx.work_ctx) free(ctx.work_ctx);

    // NOTE: ctx.response.body is NOT freed here!
    // It was allocated in the worker thread and must be freed by the caller
    // after they're done processing the response in their callback.

    free(ctx);
}

<*
 Make an async HTTP request using thread pool.
 Does NOT block the event loop!

 @param loop : "Event loop"
 @param host : "Hostname"
 @param port : "Port number"
 @param use_tls : "Use HTTPS if true"
 @param method : "HTTP method (GET, POST, etc.)"
 @param path : "Request path"
 @param body : "Request body (empty string for GET)"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void request_async(event_loop::EventLoop* loop,
                      String host, ushort port, bool use_tls,
                      String method, String path, String body,
                      HttpCallback callback, void* user_data) @public
{
    // Allocate HTTP work context
    HttpWorkContext* http_ctx = mem::new(HttpWorkContext);

    // Build full URL
    DString url;
    url.appendf("%s://%s:%d%s",
                use_tls ? "https" : "http",
                host, port, path);

    // Initialize context
    http_ctx.url = url.copy_str(mem);
    http_ctx.method = method.copy(mem);
    http_ctx.body = body.len > 0 ? body.copy(mem) : "";
    http_ctx.callback = callback;
    http_ctx.user_data = user_data;
    http_ctx.success = false;

    // Create async work context
    async::event_loop::WorkContext* work_ctx = mem::new(async::event_loop::WorkContext);
    work_ctx.input = http_ctx;
    work_ctx.work_fn = &do_http_work;
    work_ctx.callback = &on_http_complete;
    work_ctx.user_data = user_data;

    // Store work context for cleanup
    http_ctx.work_ctx = work_ctx;

    // Queue work
    int result = loop.queue_work(work_ctx);
    if (result != 0)
    {
        // Failed to queue - call callback with error
        if (callback)
        {
            callback(null, -1, user_data);
        }

        // Clean up (must free work_ctx and http_ctx)
        free(http_ctx.url);
        free(http_ctx.method);
        if (http_ctx.body.len > 0) free(http_ctx.body);
        free(work_ctx);
        free(http_ctx);
    }
}
