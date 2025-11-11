module libtorrent_test::mocks::mock_state_provider;

import libtorrent::ports::state_provider;
import std::collections::map;

/**
 * MockStateProvider
 * ==================
 * Test double for StateProvider interface.
 *
 * Features:
 * - In-memory HashMap storage (no filesystem I/O)
 * - Configurable success/failure behavior
 * - Call tracking for verification
 * - Manual state injection for testing
 *
 * Usage:
 *   MockStateProvider* mock = create();
 *   mock.set_should_fail_load(false);
 *
 *   // Inject state for testing
 *   state_provider::DownloadState test_state;
 *   // ... populate test_state
 *   mock.set_state("ubuntu.torrent", test_state);
 *
 *   // Use as StateProvider interface
 *   state_provider::StateProvider* provider = (state_provider::StateProvider*)mock;
 *   state = provider.load_state("ubuntu.torrent")!!;
 *
 *   // Verify behavior
 *   assert(mock.load_state_called);
 *   assert(mock.load_state_call_count == 1);
 */

// MockStateProvider struct
struct MockStateProvider (state_provider::StateProvider)
{
    void* _vtable;
    void* _typeinfo;

    // In-memory storage
    HashMap{String, state_provider::DownloadState} states;

    // Configuration (simulate failures)
    bool should_fail_load;
    bool should_fail_save;
    bool should_fail_delete;
    String error_message_to_return;

    // Call tracking
    bool load_state_called;
    uint load_state_call_count;
    bool save_state_called;
    uint save_state_call_count;
    bool has_state_called;
    uint has_state_call_count;
    bool delete_state_called;
    uint delete_state_call_count;

    // Last call parameters
    String last_torrent_path;
    state_provider::DownloadState last_state_saved;
}

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Deep copy a char[] array.
 */
fn char[] copy_char_array(char[] src)
{
    if (src.len == 0) return {};
    char[] dest = mem::new_array(char, src.len);
    foreach (i, byte : src)
    {
        dest[i] = byte;
    }
    return dest;
}

// ============================================================================
// Factory
// ============================================================================

/**
 * Create a MockStateProvider instance.
 *
 * @return "MockStateProvider instance"
 */
fn MockStateProvider* create() @public
{
    MockStateProvider* mock = mem::new(MockStateProvider);

    // Initialize HashMap
    mock.states.init(mem);

    // Default configuration (success mode)
    mock.should_fail_load = false;
    mock.should_fail_save = false;
    mock.should_fail_delete = false;
    mock.error_message_to_return = "";

    // Initialize call tracking
    mock.load_state_called = false;
    mock.load_state_call_count = 0;
    mock.save_state_called = false;
    mock.save_state_call_count = 0;
    mock.has_state_called = false;
    mock.has_state_call_count = 0;
    mock.delete_state_called = false;
    mock.delete_state_call_count = 0;

    mock.last_torrent_path = "";

    return mock;
}

/**
 * Create a MockStateProvider as a StateProvider interface pointer.
 *
 * @return "StateProvider interface pointer to mock"
 */
fn state_provider::StateProvider* create_as_interface() @public
{
    MockStateProvider* mock = create();
    return (state_provider::StateProvider*)mock;
}

// ============================================================================
// Configuration Methods
// ============================================================================

/**
 * Configure load failure simulation.
 *
 * @param should_fail : "True to simulate load failures"
 */
fn void MockStateProvider.set_should_fail_load(&self, bool should_fail) @public
{
    self.should_fail_load = should_fail;
}

/**
 * Configure save failure simulation.
 *
 * @param should_fail : "True to simulate save failures"
 */
fn void MockStateProvider.set_should_fail_save(&self, bool should_fail) @public
{
    self.should_fail_save = should_fail;
}

/**
 * Configure delete failure simulation.
 *
 * @param should_fail : "True to simulate delete failures"
 */
fn void MockStateProvider.set_should_fail_delete(&self, bool should_fail) @public
{
    self.should_fail_delete = should_fail;
}

/**
 * Set error message to return.
 *
 * @param message : "Error message"
 */
fn void MockStateProvider.set_error_message(&self, String message) @public
{
    self.error_message_to_return = message;
}

// ============================================================================
// Test Utilities
// ============================================================================

/**
 * Manually inject state for testing.
 *
 * @param torrent_path : "Path to torrent file"
 * @param state : "State to inject"
 */
fn void MockStateProvider.set_state(&self, String torrent_path, state_provider::DownloadState state) @public
{
    // Store with copied key
    self.states.set(torrent_path.copy(mem), state);
}

/**
 * Clear all stored states.
 */
fn void MockStateProvider.clear_all(&self) @public
{
    // Free all stored states
    self.states.@each(; String key, state_provider::DownloadState state)
    {
        state.free();
        free(key);
    };
    self.states.clear();
}

/**
 * Reset all call tracking counters.
 */
fn void MockStateProvider.reset_call_tracking(&self) @public
{
    self.load_state_called = false;
    self.load_state_call_count = 0;
    self.save_state_called = false;
    self.save_state_call_count = 0;
    self.has_state_called = false;
    self.has_state_call_count = 0;
    self.delete_state_called = false;
    self.delete_state_call_count = 0;
}

// ============================================================================
// StateProvider Interface Implementation
// ============================================================================

fn state_provider::DownloadState? MockStateProvider.load_state(&self, String torrent_path) @dynamic
{
    // Track call
    self.load_state_called = true;
    self.load_state_call_count++;
    self.last_torrent_path = torrent_path.copy(mem);

    // Simulate failure if configured
    if (self.should_fail_load)
    {
        return state_provider::STATE_LOAD_ERROR?;
    }

    // Try to get state from HashMap
    state_provider::DownloadState? stored_opt = self.states.get(torrent_path);
    if (catch excuse = stored_opt)
    {
        return state_provider::STATE_LOAD_ERROR?;  // Not found
    }
    state_provider::DownloadState stored = stored_opt;

    // Deep copy the state
    state_provider::DownloadState copy;
    copy.version = stored.version;
    copy.file_selection = stored.file_selection.copy(mem);
    copy.have_pieces = copy_char_array(stored.have_pieces);
    copy.total_downloaded = stored.total_downloaded;
    copy.total_uploaded = stored.total_uploaded;
    copy.added_time = stored.added_time;
    copy.completed_time = stored.completed_time;
    copy.active_time = stored.active_time;
    copy.seeding_time = stored.seeding_time;
    copy.last_seen_complete = stored.last_seen_complete;

    // Deep copy unfinished pieces
    if (stored.unfinished.len > 0)
    {
        copy.unfinished = mem::new_array(state_provider::UnfinishedPiece, stored.unfinished.len);
        foreach (i, piece : stored.unfinished)
        {
            copy.unfinished[i].piece_index = piece.piece_index;
            copy.unfinished[i].blocks_bitmask = copy_char_array(piece.blocks_bitmask);
            copy.unfinished[i].num_blocks_received = piece.num_blocks_received;
        }
    }
    else
    {
        copy.unfinished = {};
    }

    copy.file_priority = copy_char_array(stored.file_priority);
    copy.upload_rate_limit = stored.upload_rate_limit;
    copy.download_rate_limit = stored.download_rate_limit;
    copy.max_connections = stored.max_connections;
    copy.max_uploads = stored.max_uploads;
    copy.paused = stored.paused;
    copy.auto_managed = stored.auto_managed;
    copy.sequential_download = stored.sequential_download;
    copy.seed_mode = stored.seed_mode;
    copy.save_path = stored.save_path.copy(mem);

    // Transmission-specific fields
    copy.activity_date = stored.activity_date;
    copy.corrupt = stored.corrupt;
    copy.bandwidth_priority = stored.bandwidth_priority;
    copy.ratio_limit = stored.ratio_limit;
    copy.idle_limit = stored.idle_limit;
    copy.speed_limit_up_enabled = stored.speed_limit_up_enabled;
    copy.speed_limit_down_enabled = stored.speed_limit_down_enabled;

    return copy;
}

fn void? MockStateProvider.save_state(&self, String torrent_path, state_provider::DownloadState* state) @dynamic
{
    // Track call
    self.save_state_called = true;
    self.save_state_call_count++;
    self.last_torrent_path = torrent_path.copy(mem);

    // Store a copy of the last saved state for verification
    self.last_state_saved.version = state.version;
    self.last_state_saved.file_selection = state.file_selection.copy(mem);

    // Simulate failure if configured
    if (self.should_fail_save)
    {
        return state_provider::STATE_SAVE_ERROR?;
    }

    // Deep copy and store the state
    state_provider::DownloadState copy;
    copy.version = state.version;
    copy.file_selection = state.file_selection.copy(mem);
    copy.have_pieces = copy_char_array(state.have_pieces);
    copy.total_downloaded = state.total_downloaded;
    copy.total_uploaded = state.total_uploaded;
    copy.added_time = state.added_time;
    copy.completed_time = state.completed_time;
    copy.active_time = state.active_time;
    copy.seeding_time = state.seeding_time;
    copy.last_seen_complete = state.last_seen_complete;

    // Deep copy unfinished pieces
    if (state.unfinished.len > 0)
    {
        copy.unfinished = mem::new_array(state_provider::UnfinishedPiece, state.unfinished.len);
        foreach (i, piece : state.unfinished)
        {
            copy.unfinished[i].piece_index = piece.piece_index;
            copy.unfinished[i].blocks_bitmask = copy_char_array(piece.blocks_bitmask);
            copy.unfinished[i].num_blocks_received = piece.num_blocks_received;
        }
    }
    else
    {
        copy.unfinished = {};
    }

    copy.file_priority = copy_char_array(state.file_priority);
    copy.upload_rate_limit = state.upload_rate_limit;
    copy.download_rate_limit = state.download_rate_limit;
    copy.max_connections = state.max_connections;
    copy.max_uploads = state.max_uploads;
    copy.paused = state.paused;
    copy.auto_managed = state.auto_managed;
    copy.sequential_download = state.sequential_download;
    copy.seed_mode = state.seed_mode;
    copy.save_path = state.save_path.copy(mem);

    // Transmission-specific fields
    copy.activity_date = state.activity_date;
    copy.corrupt = state.corrupt;
    copy.bandwidth_priority = state.bandwidth_priority;
    copy.ratio_limit = state.ratio_limit;
    copy.idle_limit = state.idle_limit;
    copy.speed_limit_up_enabled = state.speed_limit_up_enabled;
    copy.speed_limit_down_enabled = state.speed_limit_down_enabled;

    // Store in HashMap
    self.states.set(torrent_path.copy(mem), copy);
}

fn bool MockStateProvider.has_state(&self, String torrent_path) @dynamic
{
    // Track call
    self.has_state_called = true;
    self.has_state_call_count++;
    self.last_torrent_path = torrent_path.copy(mem);

    // Check if key exists in HashMap
    if (catch excuse = self.states.get(torrent_path))
    {
        return false;  // Not found
    }

    return true;
}

fn void? MockStateProvider.delete_state(&self, String torrent_path) @dynamic
{
    // Track call
    self.delete_state_called = true;
    self.delete_state_call_count++;
    self.last_torrent_path = torrent_path.copy(mem);

    // Simulate failure if configured
    if (self.should_fail_delete)
    {
        return state_provider::STATE_SAVE_ERROR?;
    }

    // Try to remove from HashMap
    state_provider::DownloadState? state_opt = self.states.get(torrent_path);
    if (catch excuse = state_opt)
    {
        // Not found - still succeed (idempotent delete)
        return;
    }

    // Free the stored state
    state_provider::DownloadState state = state_opt;
    state.free();

    // Remove from HashMap
    self.states.remove(torrent_path);
}

fn void MockStateProvider.free(&self) @dynamic
{
    // Free all stored states
    self.clear_all();
    self.states.free();

    // Free the mock itself
    free(self);
}
