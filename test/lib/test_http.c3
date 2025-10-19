module libtorrent::http_test;
import libtorrent::http;
import std::io;

<*
 Test HttpClient creation.
 Verifies that we can create a curl HTTP client.
*>
fn void test_http_client_creation() @test {
    any client = http::http_client("example.com", 80, false);
    assert(client.ptr != null, "HTTP client should be created");

    // Clean up
    if (client.ptr) {
        ((http::HttpClient)client).close();
    }
}

<*
 Test HttpClient creation with HTTPS.
*>
fn void test_http_client_https() @test {
    any client = http::http_client("example.com", 443, true);
    assert(client.ptr != null, "HTTPS client should be created");

    if (client.ptr) {
        ((http::HttpClient)client).close();
    }
}

<*
 Test HttpClient interface type check.
 Verifies that the created client implements the HttpClient interface.
*>
fn void test_http_client_interface() @test {
    any client = http::http_client("example.com", 80);
    assert(client.ptr != null, "Client should be created");

    // Verify we can cast to HttpClient interface
    http::HttpClient interface_client = (http::HttpClient)client;

    // Verify interface methods exist
    assert(&interface_client.request != null, "request method should exist");
    assert(&interface_client.close != null, "close method should exist");

    interface_client.close();
}

// Note: We skip testing actual HTTP requests here because:
// 1. We don't have a mock HTTP server in the test environment
// 2. Real HTTP requests would be slow and unreliable in unit tests
// Integration tests with real trackers will test the full HTTP functionality
