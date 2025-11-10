module libtorrent::download_state_provider;

import std::io;

/**
 * Download State Provider Interface (BEP 21)
 * ===========================================
 *
 * Uses C3's native interface system for clean polymorphism.
 * Provides abstraction for persisting and loading download state.
 *
 * Current implementation: ResumeDataProvider (bencode files)
 * Future implementations:
 * - SQLiteStateProvider (database)
 * - JsonStateProvider (JSON files)
 * - ApiStateProvider (remote API)
 * - MockStateProvider (testing)
 */

faultdef STATE_LOAD_ERROR;
faultdef STATE_SAVE_ERROR;

/**
 * Download state structure.
 * Contains all resumable state for a torrent download.
 */
struct DownloadState
{
    // BEP 21: File selection
    String file_selection;       // Comma-separated file indices (e.g., "0,2,4")

    // Future extensibility:
    // bool is_partial_seed;     // Partial seed status
    // String[] completed_files;  // List of fully completed files
    // long total_downloaded;     // Total bytes downloaded
    // long total_uploaded;       // Total bytes uploaded
    // String last_tracker_url;   // Last successful tracker
    // etc.

    int version;                 // State format version
}

/**
 * Free download state resources.
 */
fn void DownloadState.free(&self)
{
    if (self.file_selection.len > 0)
    {
        free(self.file_selection);
    }
}

/**
 * StateProvider interface - defines contract for state persistence.
 *
 * Implementations must declare @dynamic methods matching this interface.
 * C3's interface system provides compile-time type safety and runtime dispatch.
 */
interface StateProvider
{
    fn DownloadState? load_state(String torrent_path);
    fn void? save_state(String torrent_path, DownloadState* state);
    fn bool has_state(String torrent_path);
    fn void? delete_state(String torrent_path);
}
