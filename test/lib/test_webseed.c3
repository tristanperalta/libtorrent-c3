module test_webseed;

import std::io;
import libtorrent::webseed;
import libtorrent::metainfo;
import async::event_loop;

<*
 * Unit tests for BEP 19 web seeding implementation.
 *>

// Test: WebSeedManager initialization with no web seeds
fn void test_webseed_init_no_seeds() @test
{
    // Create a minimal torrent without web seeds
    metainfo::TorrentFile torrent;
    torrent.url_list = {};
    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;  // 1 MB
    torrent.info.piece_length = 16384;  // 16 KB pieces
    torrent.info.is_multi_file = false;

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Should return null when no web seeds
    webseed::WebSeedManager* mgr = webseed::create(&loop, &torrent, null,5);
    assert(mgr == null, "Manager should be null when no web seeds");
}

// Test: WebSeedManager initialization with web seeds
fn void test_webseed_init_with_seeds() @test
{
    // Create a torrent with web seeds
    metainfo::TorrentFile torrent;
    torrent.url_list = mem::new_array(String, 3);
    torrent.url_list[0] = "http://mirror1.example.com/files/".copy(mem);
    torrent.url_list[1] = "http://mirror2.example.com/files/".copy(mem);
    torrent.url_list[2] = "https://mirror3.example.com/files/".copy(mem);

    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;  // 1 MB
    torrent.info.piece_length = 16384;  // 16 KB pieces
    torrent.info.is_multi_file = false;

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Create manager
    webseed::WebSeedManager* mgr = webseed::create(&loop, &torrent, null,5);
    assert(mgr != null, "Manager should be created with web seeds");
    defer if (mgr) mgr.free();

    // Check initialization
    assert(mgr.get_enabled_count() == 3, "All 3 URLs should be enabled initially");
    assert(mgr.get_active_count() == 0, "No active downloads initially");

    // Cleanup
    foreach (url : torrent.url_list) free(url);
    free(torrent.url_list);
}

// Test:URL availability and blacklisting (BEP 19)

fn void test_webseed_url_blacklisting() @test
{
    // Create a torrent with web seeds
    metainfo::TorrentFile torrent;
    torrent.url_list = mem::new_array(String, 2);
    torrent.url_list[0] = "http://bad-mirror.example.com/files/".copy(mem);
    torrent.url_list[1] = "http://good-mirror.example.com/files/".copy(mem);

    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;  // 1 MB
    torrent.info.piece_length = 16384;  // 16 KB pieces
    torrent.info.is_multi_file = false;

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    webseed::WebSeedManager* mgr = webseed::create(&loop, &torrent, null,5);
    assert(mgr != null, "Manager should be created");
    defer if (mgr) mgr.free();

    // Initially all enabled
    assert(mgr.get_enabled_count() == 2, "Both URLs should be enabled");

    // Get first URL and mark it as permanently failed (hash mismatch - BEP 19)
    webseed::WebSeedUrl* bad_url = &mgr.urls[0];
    mgr.mark_url_failed(bad_url);

    // BEP 19: URL should be permanently disabled after hash mismatch
    assert(mgr.get_enabled_count() == 1, "Only 1 URL should remain enabled after blacklist");
    assert(!bad_url.enabled, "Bad URL should be disabled");
    assert(mgr.urls[1].enabled, "Good URL should still be enabled");

    // Cleanup
    foreach (url : torrent.url_list) free(url);
    free(torrent.url_list);
}

// Test:URL temporary failure and backoff

fn void test_webseed_url_temporary_failure() @test
{
    // Create a torrent with one web seed
    metainfo::TorrentFile torrent;
    torrent.url_list = mem::new_array(String, 1);
    torrent.url_list[0] = "http://flaky-mirror.example.com/files/".copy(mem);

    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;  // 1 MB
    torrent.info.piece_length = 16384;  // 16 KB pieces
    torrent.info.is_multi_file = false;

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    webseed::WebSeedManager* mgr = webseed::create(&loop, &torrent, null,5);
    assert(mgr != null, "Manager should be created");
    defer if (mgr) mgr.free();

    webseed::WebSeedUrl* url = &mgr.urls[0];

    // Initially available
    assert(url.is_available(), "URL should be available initially");
    assert(url.consecutive_failures == 0, "No failures initially");

    // Mark temporary failures (HTTP errors, timeouts)
    mgr.mark_url_temporary_failure(url);
    assert(url.consecutive_failures == 1, "Failure count should be 1");
    assert(url.enabled, "URL should still be enabled (not permanently disabled)");

    mgr.mark_url_temporary_failure(url);
    assert(url.consecutive_failures == 2, "Failure count should be 2");
    assert(url.enabled, "URL should still be enabled");

    mgr.mark_url_temporary_failure(url);
    assert(url.consecutive_failures == 3, "Failure count should be 3");
    assert(url.enabled, "URL should still be enabled (backoff, not disabled)");

    // After MAX_CONSECUTIVE_FAILURES (3), URL enters backoff period
    // It's still enabled but temporarily unavailable
    // Note: is_available() checks backoff timing, which we can't easily test without time manipulation

    // Mark success to reset
    mgr.mark_url_success(url);
    assert(url.consecutive_failures == 0, "Failure count should reset to 0");
    assert(url.last_failure_time == 0, "Last failure time should be reset");

    // Cleanup
    free(torrent.url_list[0]);
    free(torrent.url_list);
}

// Test:Range header construction

fn void test_webseed_range_header() @test
{
    // Create a torrent with web seeds
    metainfo::TorrentFile torrent;
    torrent.url_list = mem::new_array(String, 1);
    torrent.url_list[0] = "http://mirror.example.com/files/".copy(mem);

    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;  // 1 MB
    torrent.info.piece_length = 16384;  // 16 KB pieces (64 pieces total)
    torrent.info.is_multi_file = false;

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    webseed::WebSeedManager* mgr = webseed::create(&loop, &torrent, null,5);
    assert(mgr != null, "Manager should be created");
    defer if (mgr) mgr.free();

    // Test piece 0: bytes 0-16383
    String range0 = mgr.construct_range_header(0);
    defer free(range0);
    assert(range0 == "Range: bytes=0-16383", "Range header for piece 0 incorrect");

    // Test piece 1: bytes 16384-32767
    String range1 = mgr.construct_range_header(1);
    defer free(range1);
    assert(range1 == "Range: bytes=16384-32767", "Range header for piece 1 incorrect");

    // Test last piece (63): bytes 1032192-1048575 (last piece is full size)
    String range_last = mgr.construct_range_header(63);
    defer free(range_last);
    assert(range_last == "Range: bytes=1032192-1048575", "Range header for last piece incorrect");

    // Cleanup
    free(torrent.url_list[0]);
    free(torrent.url_list);
}

// Test:Single-file URL construction

fn void test_webseed_single_file_url() @test
{
    String base_url1 = "http://mirror.example.com/files/file.iso";
    String url1 = webseed::construct_single_file_url(base_url1);
    defer free(url1);
    assert(url1 == base_url1, "Single-file URL should match base URL");

    String base_url2 = "https://mirror2.example.com/path/to/file.iso";
    String url2 = webseed::construct_single_file_url(base_url2);
    defer free(url2);
    assert(url2 == base_url2, "Single-file URL with path should match base URL");
}

// Test:Multi-file URL construction

fn void test_webseed_multi_file_url() @test
{
    // Base URL without trailing slash
    String base1 = "http://mirror.example.com/files";
    String result1 = webseed::construct_multi_file_url(base1, "my-torrent", "subdir/file.txt");
    defer free(result1);
    assert(result1 == "http://mirror.example.com/files/my-torrent/subdir/file.txt",
           "Multi-file URL without trailing slash incorrect");

    // Base URL with trailing slash
    String base2 = "http://mirror.example.com/files/";
    String result2 = webseed::construct_multi_file_url(base2, "my-torrent", "subdir/file.txt");
    defer free(result2);
    assert(result2 == "http://mirror.example.com/files/my-torrent/subdir/file.txt",
           "Multi-file URL with trailing slash incorrect");

    // Torrent name with special characters (should be URL encoded)
    String base3 = "http://mirror.example.com/files/";
    String result3 = webseed::construct_multi_file_url(base3, "my torrent", "file.txt");
    defer free(result3);
    assert(result3.contains("my%20torrent"), "Special characters should be URL encoded");
}

// Test:Maximum concurrent downloads limit

fn void test_webseed_concurrent_limit() @test
{
    // Create a torrent with many web seeds
    metainfo::TorrentFile torrent;
    torrent.url_list = mem::new_array(String, 10);
    for (usz i = 0; i < 10; i++)
    {
        DString url;
        url.appendf("http://mirror%d.example.com/files/", i);
        torrent.url_list[i] = url.copy_str(mem);
    }

    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;  // 1 MB
    torrent.info.piece_length = 16384;  // 16 KB pieces
    torrent.info.is_multi_file = false;

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Create manager with max 3 concurrent downloads
    webseed::WebSeedManager* mgr = webseed::create(&loop, &torrent, null,3);
    assert(mgr != null, "Manager should be created");
    defer if (mgr) mgr.free();

    // Check that max_concurrent is set correctly
    assert(mgr.max_concurrent == 3, "Max concurrent should be 3");

    // Check that we have 3 download slots
    assert(mgr.downloads.len == 3, "Should have 3 download slots");

    // Cleanup
    foreach (url : torrent.url_list) free(url);
    free(torrent.url_list);
}

// Test:Get available URL when all are disabled

fn void test_webseed_no_available_urls() @test
{
    // Create a torrent with web seeds
    metainfo::TorrentFile torrent;
    torrent.url_list = mem::new_array(String, 2);
    torrent.url_list[0] = "http://mirror1.example.com/files/".copy(mem);
    torrent.url_list[1] = "http://mirror2.example.com/files/".copy(mem);

    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;  // 1 MB
    torrent.info.piece_length = 16384;  // 16 KB pieces
    torrent.info.is_multi_file = false;

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    webseed::WebSeedManager* mgr = webseed::create(&loop, &torrent, null,5);
    assert(mgr != null, "Manager should be created");
    defer if (mgr) mgr.free();

    // Disable all URLs (simulate hash mismatches)
    mgr.mark_url_failed(&mgr.urls[0]);
    mgr.mark_url_failed(&mgr.urls[1]);

    // No available URLs should return null
    webseed::WebSeedUrl* available = mgr.get_available_url();
    assert(available == null, "Should return null when all URLs are disabled");
    assert(mgr.get_enabled_count() == 0, "No URLs should be enabled");

    // Cleanup
    foreach (url : torrent.url_list) free(url);
    free(torrent.url_list);
}

// Test:Download slot management

fn void test_webseed_download_slots() @test
{
    // Create a torrent with web seeds
    metainfo::TorrentFile torrent;
    torrent.url_list = mem::new_array(String, 2);
    torrent.url_list[0] = "http://mirror1.example.com/files/".copy(mem);
    torrent.url_list[1] = "http://mirror2.example.com/files/".copy(mem);

    torrent.info.name = "test.iso";
    torrent.info.length = 1024 * 1024;  // 1 MB
    torrent.info.piece_length = 16384;  // 16 KB pieces
    torrent.info.is_multi_file = false;

    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch loop_opt)
    {
        assert(false, "Failed to create event loop");
        return;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    webseed::WebSeedManager* mgr = webseed::create(&loop, &torrent, null,2);
    assert(mgr != null, "Manager should be created");
    defer if (mgr) mgr.free();

    // Initially all slots should be free
    webseed::WebSeedDownload* slot1 = mgr.get_free_slot();
    assert(slot1 != null, "Should get first free slot");
    assert(!slot1.active, "Slot should not be active initially");

    // Mark slot as active
    slot1.active = true;

    // Get second slot
    webseed::WebSeedDownload* slot2 = mgr.get_free_slot();
    assert(slot2 != null, "Should get second free slot");
    assert(slot2 != slot1, "Should get different slot");

    // Mark second slot as active
    slot2.active = true;

    // All slots busy - should return null
    webseed::WebSeedDownload* slot3 = mgr.get_free_slot();
    assert(slot3 == null, "Should return null when all slots busy");

    // Free first slot
    slot1.active = false;

    // Should be able to get slot again
    webseed::WebSeedDownload* slot4 = mgr.get_free_slot();
    assert(slot4 != null, "Should get freed slot");
    assert(slot4 == slot1, "Should reuse first slot");

    // Cleanup
    foreach (url : torrent.url_list) free(url);
    free(torrent.url_list);
}
