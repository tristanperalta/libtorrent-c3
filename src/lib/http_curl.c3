module libtorrent::http;
import curl;

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
    DString* buffer = (DString*)userp;
    usz realsize = size * nmemb;
    char[] slice = data[:realsize];
    buffer.append(slice);
    return realsize;
}
