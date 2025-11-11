module libtorrent::adapters::fastresume_test @test;

import std::io;
import libtorrent::adapters::fastresume_state_provider;
import libtorrent::ports::state_provider;
import async::file;

/**
 * FastResume Unit Tests
 * =====================
 *
 * Tests for BEP 21 (Extension for Partial Seeds) FastResume implementation.
 *
 * UPDATE: Now using wrapper functions instead of interface methods!
 * C3's interface system doesn't work with heap-allocated structs, so we use
 * public wrapper functions: fastresume_state_provider::load() and ::save()
 *
 * These tests verify:
 * - Save/load round-trip for download state
 * - Bencode encoding/decoding correctness
 * - File I/O operations
 * - Error handling (missing files, corrupt data, etc.)
 */

// Test torrent path (use temp directory to avoid conflicts)
const String TEST_TORRENT_PATH = "/tmp/test_fastresume.torrent";

/**
 * Test provider creation and cleanup.
 */
fn void test_create_provider() @test
{
    fastresume_state_provider::FastResumeStateProvider* provider = fastresume_state_provider::create();
    assert(provider != null, "Provider should not be null");
    free(provider);
}

/**
 * Test save and load round-trip with minimal state.
 */
fn void test_save_load_minimal_state() @test
{
    // Create minimal download state
    state_provider::DownloadState state;
    state.version = state_provider::STATE_VERSION;
    state.file_selection = "0,1,2";  // Select first 3 files
    state.have_pieces = {};
    state.total_downloaded = 0;
    state.total_uploaded = 0;
    state.added_time = 0;
    state.completed_time = 0;
    state.active_time = 0;
    state.seeding_time = 0;
    state.last_seen_complete = 0;
    state.unfinished = {};
    state.file_priority = {};
    state.upload_rate_limit = 0;
    state.download_rate_limit = 0;
    state.max_connections = 0;
    state.max_uploads = 0;
    state.paused = false;
    state.auto_managed = false;
    state.sequential_download = false;
    state.seed_mode = false;
    state.save_path = "";
    state.activity_date = 0;
    state.corrupt = 0;
    state.bandwidth_priority = 0;
    state.ratio_limit = 0.0;
    state.idle_limit = 0;
    state.speed_limit_up_enabled = false;
    state.speed_limit_down_enabled = false;

    // Save using wrapper function
    if (catch err = fastresume_state_provider::save(TEST_TORRENT_PATH, &state))
    {
        assert(false, "Save should succeed");
        return;
    }

    // Load using wrapper function
    state_provider::DownloadState? loaded_opt = fastresume_state_provider::load(TEST_TORRENT_PATH);
    if (catch err = loaded_opt)
    {
        assert(false, "Load should succeed");
        return;
    }

    state_provider::DownloadState loaded = loaded_opt;
    defer loaded.free();

    // Verify round-trip
    assert(loaded.version == state.version, "Version should match");
    // Note: file_selection is not stored in fastresume format (use file_priority instead)
    assert(loaded.file_selection == "", "File selection should be empty (not stored in fastresume)");

    // Cleanup
    String fastresume_path = fastresume_state_provider::get_fastresume_path(TEST_TORRENT_PATH);
    defer free(fastresume_path);
    (void)file::delete(fastresume_path);

    io::printn("Save/load minimal state round-trip works ✓");
}

/**
 * Test save and load with have_pieces bitfield.
 */
fn void test_save_load_with_pieces() @test
{
    // Create state with some verified pieces
    state_provider::DownloadState state;
    state.version = state_provider::STATE_VERSION;
    state.file_selection = "0";

    // Create bitfield for 100 pieces (13 bytes = ceil(100/8))
    char[] pieces = mem::new_array(char, 13);
    defer free(pieces);

    // Mark pieces 0, 5, 10, 15 as verified
    pieces[0] |= (1 << 7);  // Piece 0 (bit 0)
    pieces[0] |= (1 << 2);  // Piece 5 (bit 5)
    pieces[1] |= (1 << 5);  // Piece 10 (bit 2 of byte 1)
    pieces[1] |= (1 << 0);  // Piece 15 (bit 7 of byte 1)

    state.have_pieces = pieces;
    state.total_downloaded = 1024 * 1024;
    state.total_uploaded = 512 * 1024;
    state.added_time = 1234567890;
    state.completed_time = 0;
    state.active_time = 3600;
    state.seeding_time = 0;
    state.last_seen_complete = 0;
    state.unfinished = {};
    state.file_priority = {};
    state.upload_rate_limit = 0;
    state.download_rate_limit = 0;
    state.max_connections = 50;
    state.max_uploads = 4;
    state.paused = false;
    state.auto_managed = true;
    state.sequential_download = false;
    state.seed_mode = false;
    state.save_path = "/tmp/downloads";
    state.activity_date = 0;
    state.corrupt = 0;
    state.bandwidth_priority = 0;
    state.ratio_limit = 2.0;
    state.idle_limit = 0;
    state.speed_limit_up_enabled = false;
    state.speed_limit_down_enabled = false;

    // Save
    if (catch err = fastresume_state_provider::save(TEST_TORRENT_PATH, &state))
    {
        assert(false, "Save with pieces should succeed");
        return;
    }

    // Load
    state_provider::DownloadState? loaded_opt = fastresume_state_provider::load(TEST_TORRENT_PATH);
    if (catch err = loaded_opt)
    {
        assert(false, "Load with pieces should succeed");
        return;
    }

    state_provider::DownloadState loaded = loaded_opt;
    defer loaded.free();

    // Verify statistics
    assert(loaded.total_downloaded == state.total_downloaded, "Downloaded bytes should match");
    assert(loaded.total_uploaded == state.total_uploaded, "Uploaded bytes should match");
    assert(loaded.added_time == state.added_time, "Added time should match");
    assert(loaded.active_time == state.active_time, "Active time should match");
    assert(loaded.max_connections == state.max_connections, "Max connections should match");
    assert(loaded.auto_managed == state.auto_managed, "Auto-managed flag should match");
    assert(loaded.ratio_limit == state.ratio_limit, "Ratio limit should match");

    // Verify have_pieces bitfield
    assert(loaded.have_pieces.len == pieces.len, "Pieces bitfield length should match");
    for (usz i = 0; i < pieces.len; i++)
    {
        assert(loaded.have_pieces[i] == pieces[i], "Pieces bitfield should match byte-for-byte");
    }

    // Cleanup
    String fastresume_path = fastresume_state_provider::get_fastresume_path(TEST_TORRENT_PATH);
    defer free(fastresume_path);
    (void)file::delete(fastresume_path);

    io::printn("Save/load with have_pieces bitfield works ✓");
}

/**
 * Test load failure when file doesn't exist.
 */
fn void test_load_nonexistent_file() @test
{
    String nonexistent_path = "/tmp/nonexistent_torrent_12345.torrent";

    state_provider::DownloadState? result = fastresume_state_provider::load(nonexistent_path);

    // Should fail with fault
    if (catch err = result)
    {
        // Expected - file doesn't exist
        io::printn("Load nonexistent file correctly returns fault ✓");
        return;
    }

    // If we got here, something is wrong
    assert(false, "Load should fail for nonexistent file");
}

/**
 * Test that get_fastresume_path generates correct path.
 */
fn void test_get_fastresume_path() @test
{
    String torrent_path = "/home/user/downloads/ubuntu.torrent";
    String fastresume_path = fastresume_state_provider::get_fastresume_path(torrent_path);
    defer free(fastresume_path);

    // Should append .fastresume
    assert(fastresume_path == "/home/user/downloads/ubuntu.torrent.fastresume",
           "FastResume path should append .fastresume");

    io::printn("get_fastresume_path generates correct path ✓");
}

/**
 * Test save and load with file_priority array.
 */
fn void test_save_load_with_file_priority() @test
{
    state_provider::DownloadState state;
    state.version = state_provider::STATE_VERSION;
    state.file_selection = "0,1,2,3";
    state.have_pieces = {};

    // Set file priorities (array of 4 files)
    char[] priorities = mem::new_array(char, 4);
    defer free(priorities);
    priorities[0] = 7;  // High priority
    priorities[1] = 4;  // Normal priority
    priorities[2] = 1;  // Low priority
    priorities[3] = 0;  // Don't download

    state.file_priority = priorities;
    state.total_downloaded = 0;
    state.total_uploaded = 0;
    state.added_time = 0;
    state.completed_time = 0;
    state.active_time = 0;
    state.seeding_time = 0;
    state.last_seen_complete = 0;
    state.unfinished = {};
    state.upload_rate_limit = 0;
    state.download_rate_limit = 0;
    state.max_connections = 0;
    state.max_uploads = 0;
    state.paused = false;
    state.auto_managed = false;
    state.sequential_download = false;
    state.seed_mode = false;
    state.save_path = "";
    state.activity_date = 0;
    state.corrupt = 0;
    state.bandwidth_priority = 0;
    state.ratio_limit = 0.0;
    state.idle_limit = 0;
    state.speed_limit_up_enabled = false;
    state.speed_limit_down_enabled = false;

    // Save
    if (catch err = fastresume_state_provider::save(TEST_TORRENT_PATH, &state))
    {
        assert(false, "Save with file_priority should succeed");
        return;
    }

    // Load
    state_provider::DownloadState? loaded_opt = fastresume_state_provider::load(TEST_TORRENT_PATH);
    if (catch err = loaded_opt)
    {
        assert(false, "Load with file_priority should succeed");
        return;
    }

    state_provider::DownloadState loaded = loaded_opt;
    defer loaded.free();

    // Verify file_priority
    assert(loaded.file_priority.len == priorities.len, "File priority array length should match");
    for (usz i = 0; i < priorities.len; i++)
    {
        assert(loaded.file_priority[i] == priorities[i], "File priority values should match");
    }

    // Cleanup
    String fastresume_path = fastresume_state_provider::get_fastresume_path(TEST_TORRENT_PATH);
    defer free(fastresume_path);
    (void)file::delete(fastresume_path);

    io::printn("Save/load with file_priority array works ✓");
}

/**
 * Test save and load with all boolean flags.
 */
fn void test_save_load_boolean_flags() @test
{
    state_provider::DownloadState state;
    state.version = state_provider::STATE_VERSION;
    state.file_selection = "0";
    state.have_pieces = {};
    state.total_downloaded = 0;
    state.total_uploaded = 0;
    state.added_time = 0;
    state.completed_time = 0;
    state.active_time = 0;
    state.seeding_time = 0;
    state.last_seen_complete = 0;
    state.unfinished = {};
    state.file_priority = {};
    state.upload_rate_limit = 0;
    state.download_rate_limit = 0;
    state.max_connections = 0;
    state.max_uploads = 0;

    // Set all boolean flags to true
    state.paused = true;
    state.auto_managed = true;
    state.sequential_download = true;
    state.seed_mode = true;
    state.speed_limit_up_enabled = true;
    state.speed_limit_down_enabled = true;

    state.save_path = "/tmp/test";
    state.activity_date = 0;
    state.corrupt = 0;
    state.bandwidth_priority = 0;
    state.ratio_limit = 0.0;
    state.idle_limit = 0;

    // Save
    if (catch err = fastresume_state_provider::save(TEST_TORRENT_PATH, &state))
    {
        assert(false, "Save with boolean flags should succeed");
        return;
    }

    // Load
    state_provider::DownloadState? loaded_opt = fastresume_state_provider::load(TEST_TORRENT_PATH);
    if (catch err = loaded_opt)
    {
        assert(false, "Load with boolean flags should succeed");
        return;
    }

    state_provider::DownloadState loaded = loaded_opt;
    defer loaded.free();

    // Verify all boolean flags
    assert(loaded.paused == true, "Paused flag should be true");
    assert(loaded.auto_managed == true, "Auto-managed flag should be true");
    assert(loaded.sequential_download == true, "Sequential download flag should be true");
    assert(loaded.seed_mode == true, "Seed mode flag should be true");
    assert(loaded.speed_limit_up_enabled == true, "Speed limit up enabled should be true");
    assert(loaded.speed_limit_down_enabled == true, "Speed limit down enabled should be true");

    // Cleanup
    String fastresume_path = fastresume_state_provider::get_fastresume_path(TEST_TORRENT_PATH);
    defer free(fastresume_path);
    (void)file::delete(fastresume_path);

    io::printn("Save/load with boolean flags works ✓");
}

/**
 * Test save and load with file_priority array (roundtrip).
 * Tests that file_priority array is properly saved and loaded.
 */
fn void test_save_load_with_file_priority_roundtrip() @test
{
    state_provider::DownloadState state;
    state.version = state_provider::STATE_VERSION;
    state.file_selection = "";
    state.have_pieces = {};

    // Set file priorities: 5 files with mix of selected (4) and unselected (0)
    // Priority 4 = normal priority (selected), 0 = don't download (unselected)
    char[] priorities = mem::new_array(char, 5);
    defer free(priorities);
    priorities[0] = 4;  // File 0: selected
    priorities[1] = 0;  // File 1: unselected
    priorities[2] = 4;  // File 2: selected
    priorities[3] = 0;  // File 3: unselected
    priorities[4] = 4;  // File 4: selected

    state.file_priority = priorities;
    state.total_downloaded = 0;
    state.total_uploaded = 0;
    state.added_time = 0;
    state.completed_time = 0;
    state.active_time = 0;
    state.seeding_time = 0;
    state.last_seen_complete = 0;
    state.unfinished = {};
    state.upload_rate_limit = 0;
    state.download_rate_limit = 0;
    state.max_connections = 0;
    state.max_uploads = 0;
    state.paused = false;
    state.auto_managed = false;
    state.sequential_download = false;
    state.seed_mode = false;
    state.save_path = "";
    state.activity_date = 0;
    state.corrupt = 0;
    state.bandwidth_priority = 0;
    state.ratio_limit = 0.0;
    state.idle_limit = 0;
    state.speed_limit_up_enabled = false;
    state.speed_limit_down_enabled = false;

    // Save
    if (catch err = fastresume_state_provider::save(TEST_TORRENT_PATH, &state))
    {
        assert(false, "Save with file_priority should succeed");
        return;
    }

    // Load
    state_provider::DownloadState? loaded_opt = fastresume_state_provider::load(TEST_TORRENT_PATH);
    if (catch err = loaded_opt)
    {
        assert(false, "Load with file_priority should succeed");
        return;
    }

    state_provider::DownloadState loaded = loaded_opt;
    defer loaded.free();

    // Verify file_priority roundtrip
    assert(loaded.file_priority.len == priorities.len, "File priority array length should match");
    for (usz i = 0; i < priorities.len; i++)
    {
        assert(loaded.file_priority[i] == priorities[i], "File priority values should match");
    }

    // Cleanup
    String fastresume_path = fastresume_state_provider::get_fastresume_path(TEST_TORRENT_PATH);
    defer free(fastresume_path);
    (void)file::delete(fastresume_path);

    io::printn("Save/load with file_priority roundtrip works ✓");
}

/**
 * Test that priority 0 means unselected (don't download).
 * Tests the semantic meaning of priority values.
 */
fn void test_file_priority_zero_means_unselected() @test
{
    state_provider::DownloadState state;
    state.version = state_provider::STATE_VERSION;
    state.file_selection = "";
    state.have_pieces = {};

    // Test with various priority values (0 = unselected, 1-7 = selected)
    char[] priorities = mem::new_array(char, 4);
    defer free(priorities);
    priorities[0] = 0;  // Unselected
    priorities[1] = 7;  // Selected (high priority)
    priorities[2] = 0;  // Unselected
    priorities[3] = 1;  // Selected (low priority)

    state.file_priority = priorities;
    state.total_downloaded = 0;
    state.total_uploaded = 0;
    state.added_time = 0;
    state.completed_time = 0;
    state.active_time = 0;
    state.seeding_time = 0;
    state.last_seen_complete = 0;
    state.unfinished = {};
    state.upload_rate_limit = 0;
    state.download_rate_limit = 0;
    state.max_connections = 0;
    state.max_uploads = 0;
    state.paused = false;
    state.auto_managed = false;
    state.sequential_download = false;
    state.seed_mode = false;
    state.save_path = "";
    state.activity_date = 0;
    state.corrupt = 0;
    state.bandwidth_priority = 0;
    state.ratio_limit = 0.0;
    state.idle_limit = 0;
    state.speed_limit_up_enabled = false;
    state.speed_limit_down_enabled = false;

    // Save
    if (catch err = fastresume_state_provider::save(TEST_TORRENT_PATH, &state))
    {
        assert(false, "Save with mixed priorities should succeed");
        return;
    }

    // Load
    state_provider::DownloadState? loaded_opt = fastresume_state_provider::load(TEST_TORRENT_PATH);
    if (catch err = loaded_opt)
    {
        assert(false, "Load with mixed priorities should succeed");
        return;
    }

    state_provider::DownloadState loaded = loaded_opt;
    defer loaded.free();

    // Verify priorities are preserved
    assert(loaded.file_priority.len == 4, "Should have 4 files");
    assert(loaded.file_priority[0] == 0, "File 0 should be unselected (priority 0)");
    assert(loaded.file_priority[1] == 7, "File 1 should have priority 7");
    assert(loaded.file_priority[2] == 0, "File 2 should be unselected (priority 0)");
    assert(loaded.file_priority[3] == 1, "File 3 should have priority 1");

    // Cleanup
    String fastresume_path = fastresume_state_provider::get_fastresume_path(TEST_TORRENT_PATH);
    defer free(fastresume_path);
    (void)file::delete(fastresume_path);

    io::printn("File priority zero means unselected ✓");
}

/**
 * Test backward compatibility with old fastresume files without file_priority.
 * Old files should still load successfully with empty file_priority.
 */
fn void test_file_priority_backward_compatibility() @test
{
    state_provider::DownloadState state;
    state.version = state_provider::STATE_VERSION;
    state.file_selection = "";
    state.have_pieces = {};
    state.file_priority = {};  // Empty - simulates old fastresume format
    state.total_downloaded = 1024;
    state.total_uploaded = 512;
    state.added_time = 1234567890;
    state.completed_time = 0;
    state.active_time = 3600;
    state.seeding_time = 0;
    state.last_seen_complete = 0;
    state.unfinished = {};
    state.upload_rate_limit = 0;
    state.download_rate_limit = 0;
    state.max_connections = 50;
    state.max_uploads = 4;
    state.paused = false;
    state.auto_managed = true;
    state.sequential_download = false;
    state.seed_mode = false;
    state.save_path = "/tmp/downloads";
    state.activity_date = 0;
    state.corrupt = 0;
    state.bandwidth_priority = 0;
    state.ratio_limit = 2.0;
    state.idle_limit = 0;
    state.speed_limit_up_enabled = false;
    state.speed_limit_down_enabled = false;

    // Save (without file_priority)
    if (catch err = fastresume_state_provider::save(TEST_TORRENT_PATH, &state))
    {
        assert(false, "Save without file_priority should succeed");
        return;
    }

    // Load
    state_provider::DownloadState? loaded_opt = fastresume_state_provider::load(TEST_TORRENT_PATH);
    if (catch err = loaded_opt)
    {
        assert(false, "Load without file_priority should succeed");
        return;
    }

    state_provider::DownloadState loaded = loaded_opt;
    defer loaded.free();

    // Verify file_priority is empty (backward compatible)
    assert(loaded.file_priority.len == 0, "Old fastresume without file_priority should load with empty array");

    // Verify other fields still work
    assert(loaded.total_downloaded == state.total_downloaded, "Downloaded bytes should match");
    assert(loaded.max_connections == state.max_connections, "Max connections should match");

    // Cleanup
    String fastresume_path = fastresume_state_provider::get_fastresume_path(TEST_TORRENT_PATH);
    defer free(fastresume_path);
    (void)file::delete(fastresume_path);

    io::printn("Backward compatibility without file_priority works ✓");
}
