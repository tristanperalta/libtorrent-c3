module libtorrent::udp_tracker::test;

import libtorrent::udp_tracker;
import libtorrent::tracker;
import libtorrent::torrent;
import libtorrent::bencode;
import libtorrent::async_udp;
import libtorrent::event_loop;
import uv;
import std::io;
import std::net::url;

// Test context for tracking results
struct TestContext
{
    bool completed;
    bool success;
    int status;
    tracker::TrackerResponse* response;
    event_loop::EventLoop* loop;
}

// Mock tracker server context
struct MockTrackerServer
{
    async_udp::UdpSocket* socket;
    event_loop::EventLoop* loop;
    int port;
    long connection_id;
    bool should_respond;
    bool send_invalid_response;
}

// ============================================================================
// Mock Tracker Server
// ============================================================================

fn void mock_tracker_on_recv(async_udp::UdpSocket* socket, char[] data, uv::Sockaddr* addr, void* user_data)
{
    MockTrackerServer* server = (MockTrackerServer*)user_data;

    if (!server.should_respond)
    {
        return;  // Don't respond (simulate timeout)
    }

    if (data.len < 16)
    {
        return;  // Invalid request
    }

    // Parse action and transaction_id from request
    // UDP tracker protocol: connection_id (8 bytes at 0), action (4 bytes at 8), transaction_id (4 bytes at 12)
    int action = ((int)data[8] << 24) | ((int)data[9] << 16) | ((int)data[10] << 8) | (int)data[11];
    int transaction_id = ((int)data[12] << 24) | ((int)data[13] << 16) | ((int)data[14] << 8) | (int)data[15];

    if (action == udp_tracker::ACTION_CONNECT)
    {
        // Send connect response
        char[16] response;

        // Action (0 = connect)
        response[0] = 0;
        response[1] = 0;
        response[2] = 0;
        response[3] = 0;

        // Transaction ID (4 bytes at offset 4)
        response[4] = data[12];
        response[5] = data[13];
        response[6] = data[14];
        response[7] = data[15];

        // Connection ID (8 bytes at offset 8)
        server.connection_id = 0x0123456789ABCDEF;
        long conn_id = server.connection_id;
        response[8] = (char)(conn_id >> 56);
        response[9] = (char)(conn_id >> 48);
        response[10] = (char)(conn_id >> 40);
        response[11] = (char)(conn_id >> 32);
        response[12] = (char)(conn_id >> 24);
        response[13] = (char)(conn_id >> 16);
        response[14] = (char)(conn_id >> 8);
        response[15] = (char)conn_id;

        async_udp::send_to(socket, addr, response[..], null, null);
    }
    else if (action == udp_tracker::ACTION_ANNOUNCE)
    {
        if (server.send_invalid_response)
        {
            // Send properly-sized response with wrong transaction ID
            char[20] invalid_response;

            // Action (1 = announce)
            invalid_response[0] = 0;
            invalid_response[1] = 0;
            invalid_response[2] = 0;
            invalid_response[3] = 1;

            // WRONG Transaction ID (will cause validation to fail)
            invalid_response[4] = 0xFF;
            invalid_response[5] = 0xFF;
            invalid_response[6] = 0xFF;
            invalid_response[7] = 0xFF;

            // Interval/leechers/seeders (valid but irrelevant)
            for (int i = 8; i < 20; i++)
            {
                invalid_response[i] = 0;
            }

            async_udp::send_to(socket, addr, invalid_response[..], null, null);
            return;
        }

        // Send announce response
        char[20] response;

        // Action (1 = announce)
        response[0] = 0;
        response[1] = 0;
        response[2] = 0;
        response[3] = 1;

        // Transaction ID
        response[4] = data[12];
        response[5] = data[13];
        response[6] = data[14];
        response[7] = data[15];

        // Interval (1800 seconds)
        response[8] = 0;
        response[9] = 0;
        response[10] = 0x07;
        response[11] = 0x08;

        // Leechers (5)
        response[12] = 0;
        response[13] = 0;
        response[14] = 0;
        response[15] = 5;

        // Seeders (10)
        response[16] = 0;
        response[17] = 0;
        response[18] = 0;
        response[19] = 10;

        async_udp::send_to(socket, addr, response[..], null, null);
    }
}

fn MockTrackerServer*? create_mock_tracker(event_loop::EventLoop* loop, int port)
{
    MockTrackerServer* server = mem::new(MockTrackerServer);

    // Create UDP socket
    async_udp::UdpSocket*? socket_opt = async_udp::create(loop);
    if (catch err = socket_opt)
    {
        free(server);
        return err?;
    }
    server.socket = socket_opt;

    // Bind to localhost
    async_udp::bind(server.socket, "127.0.0.1", port);

    // Start receiving
    server.loop = loop;
    server.port = port;
    server.connection_id = 0;
    server.should_respond = true;
    server.send_invalid_response = false;

    async_udp::recv_start(server.socket, null, &mock_tracker_on_recv, server);

    return server;
}

fn void close_mock_tracker(MockTrackerServer* server)
{
    async_udp::recv_stop(server.socket);
    async_udp::close(server.socket);
    free(server);
}

// ============================================================================
// Test Helper: Create Test Torrent
// ============================================================================

fn torrent::TorrentFile* create_test_torrent(String tracker_url)
{
    torrent::TorrentFile* torrent = mem::new(torrent::TorrentFile);

    torrent.announce = tracker_url;

    // Info hash (20 bytes) - it's a fixed-size array
    for (int i = 0; i < 20; i++)
    {
        torrent.info_hash[i] = (char)i;
    }

    // Info
    torrent.info.name = "test.txt";
    torrent.info.piece_length = 16384;
    torrent.info.length = 1024;
    torrent.info.pieces = {};

    return torrent;
}

fn void free_test_torrent(torrent::TorrentFile* torrent)
{
    free(torrent);
}

// ============================================================================
// Successful Announce Test
// ============================================================================

fn void on_announce_success(tracker::TrackerResponse* response, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;
    ctx.status = status;
    ctx.response = response;

    io::printfn("Callback called: status=%d, response=%s", status, response ? "non-null" : "null");

    if (response)
    {
        io::printfn("Response: interval=%d, complete=%d, incomplete=%d",
                    response.interval, response.complete, response.incomplete);
    }

    if (status == 0 && response)
    {
        // Verify response
        if (response.interval == 1800 &&
            response.complete == 10 &&
            response.incomplete == 5)
        {
            ctx.success = true;
            io::printfn("Success!");
        }
        else
        {
            io::printfn("Response values don't match expected");
        }
    }
    else
    {
        io::printfn("Status not 0 or response is null");
    }
}

fn void test_async_announce_success() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    // Create mock tracker server on port 9100
    MockTrackerServer*? server_opt = create_mock_tracker(&loop, 9100);
    if (catch err = server_opt)
    {
        assert(false, "Should create mock tracker");
        return;
    }
    MockTrackerServer* server = server_opt;

    // Create test torrent
    // NOTE: Using localhost instead of 127.0.0.1 due to getaddrinfo issues with IP addresses
    torrent::TorrentFile* torrent = create_test_torrent("udp://localhost:9100/announce");
    defer free_test_torrent(torrent);

    // Test context
    TestContext ctx;
    ctx.completed = false;
    ctx.success = false;
    ctx.status = 0;
    ctx.response = null;
    ctx.loop = &loop;

    // Start async announce
    udp_tracker::async_announce(&loop, torrent, 6881, "started", &on_announce_success, &ctx);

    // Run event loop until completed
    int max_iterations = 500;
    int iterations = 0;
    while (!ctx.completed && iterations < max_iterations)
    {
        loop.run_once();
        iterations++;
    }

    assert(ctx.completed, "Announce should complete");
    assert(ctx.success, "Announce should succeed");
    assert(ctx.status == 0, "Status should be 0");
    assert(ctx.response != null, "Response should not be null");

    // Close mock server before cleanup
    close_mock_tracker(server);

    // Clean up event loop
    while (loop.is_alive())
    {
        loop.run_once();
    }
}

// ============================================================================
// DNS Failure Test
// ============================================================================

fn void on_announce_dns_fail(tracker::TrackerResponse* response, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;
    ctx.status = status;
    ctx.response = response;

    if (status == udp_tracker::ASYNC_ERROR_DNS_FAILED && response == null)
    {
        ctx.success = true;
    }
}

fn void test_async_announce_dns_failure() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    // Create test torrent with invalid hostname
    torrent::TorrentFile* torrent = create_test_torrent("udp://this-hostname-does-not-exist-12345.invalid:6969/announce");
    defer free_test_torrent(torrent);

    TestContext ctx;
    ctx.completed = false;
    ctx.success = false;
    ctx.status = 0;
    ctx.response = null;
    ctx.loop = &loop;

    // Start async announce
    udp_tracker::async_announce(&loop, torrent, 6881, "started", &on_announce_dns_fail, &ctx);

    // Run event loop until completed
    int max_iterations = 500;
    int iterations = 0;
    while (!ctx.completed && iterations < max_iterations)
    {
        loop.run_once();
        iterations++;
    }

    assert(ctx.completed, "Announce should complete");
    assert(ctx.success, "Should fail with DNS error");
    assert(ctx.status == udp_tracker::ASYNC_ERROR_DNS_FAILED, "Status should be DNS_FAILED");
    assert(ctx.response == null, "Response should be null on error");

    // Clean up event loop
    while (loop.is_alive())
    {
        loop.run_once();
    }
}

// ============================================================================
// Invalid URL Test
// ============================================================================

fn void on_announce_invalid_url(tracker::TrackerResponse* response, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;
    ctx.status = status;
    ctx.response = response;

    if (status == udp_tracker::ASYNC_ERROR_INVALID_URL && response == null)
    {
        ctx.success = true;
    }
}

fn void test_async_announce_invalid_url() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    // Create test torrent with HTTP URL (not UDP)
    torrent::TorrentFile* torrent = create_test_torrent("http://tracker.example.com:6969/announce");
    defer free_test_torrent(torrent);

    TestContext ctx;
    ctx.completed = false;
    ctx.success = false;
    ctx.status = 0;
    ctx.response = null;
    ctx.loop = &loop;

    // Start async announce - should fail immediately
    udp_tracker::async_announce(&loop, torrent, 6881, "started", &on_announce_invalid_url, &ctx);

    assert(ctx.completed, "Should complete immediately");
    assert(ctx.success, "Should fail with invalid URL");
    assert(ctx.status == udp_tracker::ASYNC_ERROR_INVALID_URL, "Status should be INVALID_URL");
}

// ============================================================================
// Timeout Test
// ============================================================================

fn void on_announce_timeout(tracker::TrackerResponse* response, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;
    ctx.status = status;
    ctx.response = response;

    if (status == udp_tracker::ASYNC_ERROR_TIMEOUT && response == null)
    {
        ctx.success = true;
    }
}

fn void test_async_announce_timeout() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    // Create mock tracker that doesn't respond
    MockTrackerServer*? server_opt = create_mock_tracker(&loop, 9101);
    if (catch err = server_opt)
    {
        assert(false, "Should create mock tracker");
        return;
    }
    MockTrackerServer* server = server_opt;
    server.should_respond = false;  // Don't respond to requests

    // Create test torrent
    torrent::TorrentFile* torrent = create_test_torrent("udp://127.0.0.1:9101/announce");
    defer free_test_torrent(torrent);

    TestContext ctx;
    ctx.completed = false;
    ctx.success = false;
    ctx.status = 0;
    ctx.response = null;
    ctx.loop = &loop;

    // Start async announce with 1-second timeout for fast testing
    // With 1-second timeout: 1s + 2s + 4s = 7 seconds total
    udp_tracker::async_announce(&loop, torrent, 6881, "started", &on_announce_timeout, &ctx, 1);

    // Run event loop - with 1s timeout this should take ~7 seconds
    int max_iterations = 800;  // 8 seconds at 100 iterations/sec
    int iterations = 0;
    while (!ctx.completed && iterations < max_iterations)
    {
        loop.run_once();
        iterations++;
    }

    assert(ctx.completed, "Announce should complete (with timeout)");
    assert(ctx.success, "Should fail with timeout");
    assert(ctx.status == udp_tracker::ASYNC_ERROR_TIMEOUT, "Status should be TIMEOUT");
    assert(ctx.response == null, "Response should be null on error");

    // Close mock server before cleanup
    close_mock_tracker(server);

    // Clean up event loop
    while (loop.is_alive())
    {
        loop.run_once();
    }
}

// ============================================================================
// Invalid Response Test
// ============================================================================

fn void on_announce_invalid_response(tracker::TrackerResponse* response, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;
    ctx.status = status;
    ctx.response = response;

    if (status == udp_tracker::ASYNC_ERROR_INVALID_RESPONSE && response == null)
    {
        ctx.success = true;
    }
}

fn void test_async_announce_invalid_response() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    // Create mock tracker that sends invalid responses
    MockTrackerServer*? server_opt = create_mock_tracker(&loop, 9102);
    if (catch err = server_opt)
    {
        assert(false, "Should create mock tracker");
        return;
    }
    MockTrackerServer* server = server_opt;
    server.send_invalid_response = true;

    // Create test torrent
    torrent::TorrentFile* torrent = create_test_torrent("udp://127.0.0.1:9102/announce");
    defer free_test_torrent(torrent);

    TestContext ctx;
    ctx.completed = false;
    ctx.success = false;
    ctx.status = 0;
    ctx.response = null;
    ctx.loop = &loop;

    // Start async announce
    udp_tracker::async_announce(&loop, torrent, 6881, "started", &on_announce_invalid_response, &ctx);

    // Run event loop until completed
    // The invalid response (wrong transaction ID) should fail immediately
    int max_iterations = 500;
    int iterations = 0;
    while (!ctx.completed && iterations < max_iterations)
    {
        loop.run_once();
        iterations++;
    }

    assert(ctx.completed, "Announce should complete");
    assert(ctx.success, "Should fail with invalid response");
    assert(ctx.status == udp_tracker::ASYNC_ERROR_INVALID_RESPONSE, "Status should be INVALID_RESPONSE");
    assert(ctx.response == null, "Response should be null on error");

    // Close mock server before cleanup
    close_mock_tracker(server);

    // Clean up event loop
    while (loop.is_alive())
    {
        loop.run_once();
    }
}
