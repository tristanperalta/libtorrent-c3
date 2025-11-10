module test_httpseed;

import std::io;
import libtorrent::httpseed;
import libtorrent::metainfo;
import async::event_loop;

<*
 * Unit tests for BEP 17 HTTP seeding (Hoffman-style) implementation.
 *>

// Test: HttpSeedManager initialization with no httpseeds
fn void test_httpseed_init_no_seeds() @test
{
    // Create a minimal torrent without httpseeds
    metainfo::TorrentFile torrent;
    torrent.httpseeds = {};
    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;  // 1 MB
    torrent.info.piece_length = 16384;  // 16 KB pieces
    torrent.info.is_multi_file = false;

    // Create dummy info_hash
    for (usz i = 0; i < 20; i++)
    {
        torrent.info_hash[i] = (char)i;
    }

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Should return null when no httpseeds
    httpseed::HttpSeedManager* mgr = httpseed::create(&loop, &torrent, null, 5);
    assert(mgr == null, "Manager should be null when no httpseeds");
}

// Test: HttpSeedManager initialization with httpseeds
fn void test_httpseed_init_with_seeds() @test
{
    // Create a torrent with httpseeds
    metainfo::TorrentFile torrent;
    torrent.httpseeds = mem::new_array(String, 3);
    torrent.httpseeds[0] = "http://httpseed1.example.com/seed.php".copy(mem);
    torrent.httpseeds[1] = "http://httpseed2.example.com/torrent".copy(mem);
    torrent.httpseeds[2] = "https://httpseed3.example.com/bt".copy(mem);

    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;  // 1 MB
    torrent.info.piece_length = 16384;  // 16 KB pieces
    torrent.info.is_multi_file = false;

    // Create dummy info_hash
    for (usz i = 0; i < 20; i++)
    {
        torrent.info_hash[i] = (char)i;
    }

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Create manager
    httpseed::HttpSeedManager* mgr = httpseed::create(&loop, &torrent, null, 5);
    assert(mgr != null, "Manager should be created with httpseeds");
    defer if (mgr) mgr.free();

    // Check initialization
    assert(mgr.get_available_url_count() == 3, "All 3 URLs should be available initially");
    assert(mgr.get_active_count() == 0, "No active downloads initially");

    // Cleanup
    foreach (url : torrent.httpseeds) free(url);
    free(torrent.httpseeds);
}

// Test: URL blacklisting (BEP 17 requirement)
fn void test_httpseed_url_blacklisting() @test
{
    // Create a torrent with httpseeds
    metainfo::TorrentFile torrent;
    torrent.httpseeds = mem::new_array(String, 2);
    torrent.httpseeds[0] = "http://bad-seed.example.com/seed".copy(mem);
    torrent.httpseeds[1] = "http://good-seed.example.com/seed".copy(mem);

    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;
    torrent.info.piece_length = 16384;
    torrent.info.is_multi_file = false;

    // Create dummy info_hash
    for (usz i = 0; i < 20; i++)
    {
        torrent.info_hash[i] = (char)i;
    }

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    httpseed::HttpSeedManager* mgr = httpseed::create(&loop, &torrent, null, 5);
    assert(mgr != null, "Manager should be created");
    defer if (mgr) mgr.free();

    // Initially both URLs available
    assert(mgr.get_available_url_count() == 2, "Both URLs should be available");

    // Blacklist the bad URL
    mgr.blacklist_url(torrent.httpseeds[0]);

    // Now only one URL available
    assert(mgr.get_available_url_count() == 1, "Only one URL should remain available after blacklist");

    // Cleanup
    foreach (url : torrent.httpseeds) free(url);
    free(torrent.httpseeds);
}

// Test: info_hash to hex conversion (BEP 17 requirement)
fn void test_httpseed_info_hash_hex_encoding() @test
{
    // Create a known info_hash
    char[20] info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)i;  // 0x00, 0x01, 0x02, ..., 0x13
    }

    // Convert to hex
    String hex = httpseed::info_hash_to_hex(info_hash);
    defer free(hex);

    // Expected: "000102030405060708090a0b0c0d0e0f10111213"
    assert(hex.len == 40, "Hex string should be 40 characters (20 bytes * 2)");
    assert(hex[:2] == "00", "First byte should be 00");
    assert(hex[2:2] == "01", "Second byte should be 01");
    assert(hex[38:2] == "13", "Last byte should be 13");
}

// Test: BEP 17 URL construction with query parameters
fn void test_httpseed_url_construction_basic() @test
{
    char[20] info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)(0xAA);  // All bytes are 0xAA
    }

    String base_url = "http://seed.example.com/torrent";
    String url = httpseed::construct_bep17_url(base_url, info_hash, 5, 0, 16383);
    defer free(url);

    // Should contain query parameters
    assert(url.contains("?"), "URL should contain query separator");
    assert(url.contains("info_hash="), "URL should contain info_hash param");
    assert(url.contains("piece=5"), "URL should contain piece param");
    assert(url.contains("ranges=0-16383"), "URL should contain ranges param");

    // info_hash should be hex encoded (40 chars of 'aa')
    assert(url.contains("info_hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
           "info_hash should be hex encoded");
}

// Test: BEP 17 URL construction with existing query params
fn void test_httpseed_url_construction_with_existing_params() @test
{
    char[20] info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)0;
    }

    String base_url = "http://seed.example.com/torrent?key=value";
    String url = httpseed::construct_bep17_url(base_url, info_hash, 10, 100, 200);
    defer free(url);

    // Should use & for additional params (not ?)
    assert(url.contains("?key=value&"), "Should append with & not ?");
    assert(url.contains("&info_hash="), "info_hash should be appended with &");
    assert(url.contains("&piece=10"), "piece should be appended");
    assert(url.contains("&ranges=100-200"), "ranges should be appended");
}

// Test: BEP 17 URL construction for different piece sizes
fn void test_httpseed_url_construction_piece_ranges() @test
{
    char[20] info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)1;
    }

    String base_url = "http://seed.example.com/get";

    // Test piece 0, full 16KB piece
    String url1 = httpseed::construct_bep17_url(base_url, info_hash, 0, 0, 16383);
    defer free(url1);
    assert(url1.contains("piece=0"), "Should reference piece 0");
    assert(url1.contains("ranges=0-16383"), "Should have correct range for full piece");

    // Test piece 100, partial piece (last piece)
    String url2 = httpseed::construct_bep17_url(base_url, info_hash, 100, 0, 8191);
    defer free(url2);
    assert(url2.contains("piece=100"), "Should reference piece 100");
    assert(url2.contains("ranges=0-8191"), "Should have correct range for partial piece");
}

// Test: 503 retry-after parsing (BEP 17)
fn void test_httpseed_parse_retry_after_integer() @test
{
    // BEP 17: 503 response body contains ASCII integer (seconds)
    String body1 = "120";
    uint delay1 = httpseed::parse_retry_after(body1);
    assert(delay1 == 120, "Should parse 120 seconds");

    String body2 = "60";
    uint delay2 = httpseed::parse_retry_after(body2);
    assert(delay2 == 60, "Should parse 60 seconds");

    String body3 = "0";
    uint delay3 = httpseed::parse_retry_after(body3);
    assert(delay3 == 0, "Should parse 0 seconds");
}

// Test: 503 retry-after parsing with invalid input
fn void test_httpseed_parse_retry_after_invalid() @test
{
    // Empty body
    String body1 = "";
    uint delay1 = httpseed::parse_retry_after(body1);
    assert(delay1 == 0, "Empty body should return 0");

    // Non-numeric
    String body2 = "not a number";
    uint delay2 = httpseed::parse_retry_after(body2);
    assert(delay2 == 0, "Invalid input should return 0");

    // Negative number (should clamp to 0)
    String body3 = "-50";
    uint delay3 = httpseed::parse_retry_after(body3);
    assert(delay3 == 0, "Negative should return 0");
}

// Test: Concurrent download slots
fn void test_httpseed_concurrent_slots() @test
{
    metainfo::TorrentFile torrent;
    torrent.httpseeds = mem::new_array(String, 1);
    torrent.httpseeds[0] = "http://seed.example.com/bt".copy(mem);

    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;
    torrent.info.piece_length = 16384;
    torrent.info.is_multi_file = false;

    for (usz i = 0; i < 20; i++)
    {
        torrent.info_hash[i] = (char)i;
    }

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Create manager with 10 concurrent slots
    httpseed::HttpSeedManager* mgr = httpseed::create(&loop, &torrent, null, 10);
    assert(mgr != null, "Manager should be created");
    defer if (mgr) mgr.free();

    // Check max_concurrent was set
    assert(mgr.max_concurrent == 10, "Should have 10 concurrent slots");

    // Cleanup
    foreach (url : torrent.httpseeds) free(url);
    free(torrent.httpseeds);
}

// Test: Stats tracking
fn void test_httpseed_stats_tracking() @test
{
    metainfo::TorrentFile torrent;
    torrent.httpseeds = mem::new_array(String, 2);
    torrent.httpseeds[0] = "http://seed1.example.com/bt".copy(mem);
    torrent.httpseeds[1] = "http://seed2.example.com/bt".copy(mem);

    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;
    torrent.info.piece_length = 16384;
    torrent.info.is_multi_file = false;

    for (usz i = 0; i < 20; i++)
    {
        torrent.info_hash[i] = (char)i;
    }

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    httpseed::HttpSeedManager* mgr = httpseed::create(&loop, &torrent, null, 5);
    assert(mgr != null, "Manager should be created");
    defer if (mgr) mgr.free();

    // Initially no bytes downloaded
    assert(mgr.get_total_bytes() == 0, "No bytes downloaded initially");
    assert(mgr.get_active_count() == 0, "No active downloads initially");
    assert(mgr.get_available_url_count() == 2, "Both URLs available");

    // Cleanup
    foreach (url : torrent.httpseeds) free(url);
    free(torrent.httpseeds);
}

// Test: Round-robin URL selection
fn void test_httpseed_round_robin_url_selection() @test
{
    metainfo::TorrentFile torrent;
    torrent.httpseeds = mem::new_array(String, 3);
    torrent.httpseeds[0] = "http://seed1.example.com/bt".copy(mem);
    torrent.httpseeds[1] = "http://seed2.example.com/bt".copy(mem);
    torrent.httpseeds[2] = "http://seed3.example.com/bt".copy(mem);

    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;
    torrent.info.piece_length = 16384;
    torrent.info.is_multi_file = false;

    for (usz i = 0; i < 20; i++)
    {
        torrent.info_hash[i] = (char)i;
    }

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    httpseed::HttpSeedManager* mgr = httpseed::create(&loop, &torrent, null, 5);
    assert(mgr != null, "Manager should be created");
    defer if (mgr) mgr.free();

    // Get next URL three times - should cycle through all URLs
    httpseed::HttpSeedUrl* url1 = mgr.get_available_url();
    assert(url1 != null, "Should get first URL");

    httpseed::HttpSeedUrl* url2 = mgr.get_available_url();
    assert(url2 != null, "Should get second URL");
    assert(url2 != url1, "Should be different URL");

    httpseed::HttpSeedUrl* url3 = mgr.get_available_url();
    assert(url3 != null, "Should get third URL");
    assert(url3 != url1 && url3 != url2, "Should be third different URL");

    // Fourth call should wrap around to first URL
    httpseed::HttpSeedUrl* url4 = mgr.get_available_url();
    assert(url4 == url1, "Should wrap around to first URL");

    // Cleanup
    foreach (url : torrent.httpseeds) free(url);
    free(torrent.httpseeds);
}

// Test: Manager cleanup and free
fn void test_httpseed_manager_cleanup() @test
{
    metainfo::TorrentFile torrent;
    torrent.httpseeds = mem::new_array(String, 2);
    torrent.httpseeds[0] = "http://seed1.example.com/bt".copy(mem);
    torrent.httpseeds[1] = "http://seed2.example.com/bt".copy(mem);

    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;
    torrent.info.piece_length = 16384;
    torrent.info.is_multi_file = false;

    for (usz i = 0; i < 20; i++)
    {
        torrent.info_hash[i] = (char)i;
    }

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    httpseed::HttpSeedManager* mgr = httpseed::create(&loop, &torrent, null, 5);
    assert(mgr != null, "Manager should be created");

    // Free should not crash
    mgr.free();

    // Cleanup
    foreach (url : torrent.httpseeds) free(url);
    free(torrent.httpseeds);
}
