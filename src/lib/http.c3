module libtorrent::http;

<*
 HTTP Client Module
 ==================
 Interface-based HTTP client that supports multiple backends.

 Currently supported backends:
 - CurlClient: Blocking HTTP client using libcurl

 Future backends:
 - LibuvClient: Async HTTP client using libuv
 - MockClient: Mock client for testing
*>

// Faults
faultdef HTTP_CONNECT_FAILED;
faultdef HTTP_REQUEST_FAILED;
faultdef HTTP_INVALID_URL;

<*
 HTTP response structure.
 Returned by all HttpClient implementations.
*>
struct HttpResponse {
    int status;      // HTTP status code
    String body;     // Response body
}

<*
 HttpClient interface.
 All HTTP client backends must implement these methods.
*>
interface HttpClient {
    fn HttpResponse? request(String method, String path, String[] headers, String body);
    fn void close();
}

<*
 Create an HTTP client using the default backend (curl).

 @param host : "The hostname to connect to"
 @param port : "The port number"
 @param use_tls : "Whether to use HTTPS (true) or HTTP (false)"
 @return "An 'any' containing the HttpClient implementation, or null on failure"
*>
fn any http_client(String host, ushort port, bool use_tls = false) @public {
    return curl_client(host, port, use_tls);
}
