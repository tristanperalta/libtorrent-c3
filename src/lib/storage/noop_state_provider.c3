module libtorrent::storage::noop;

import libtorrent::storage;

/**
 * NoOpStateProvider - No-op implementation of StateProvider interface.
 * =======================================================================
 *
 * Provides a stateless mode where no resume data is persisted to disk.
 * All save operations succeed silently (no-op), and all load operations
 * fail (no state available).
 *
 * Use cases:
 * - Testing without file I/O side effects
 * - Embedded systems with no persistent storage
 * - Seeding-only mode (no need to resume downloads)
 * - Privacy mode (leave no traces on disk)
 * - Stateless/ephemeral deployments
 *
 * Example:
 *   storage::StateProvider* provider = noop_storage::create();
 *   // All operations will no-op or return "not found"
 */

/**
 * NoOpStateProvider struct.
 * No internal state needed - all operations are stateless.
 */
struct NoOpStateProvider (storage::StateProvider)
{
    void*[2] _dummy;  // C3 interfaces may need extra space for vtable metadata
}

// ============================================================================
// StateProvider Interface Implementation
// ============================================================================

/**
 * Load state implementation (always fails).
 * Returns error to indicate no state is available.
 */
fn storage::DownloadState? NoOpStateProvider.load_state(&self, String torrent_path) @dynamic
{
    // Always fail - no state is persisted
    return storage::STATE_LOAD_ERROR?;
}

/**
 * Save state implementation (no-op).
 * Succeeds silently without persisting anything.
 */
fn void? NoOpStateProvider.save_state(&self, String torrent_path, storage::DownloadState* state) @dynamic
{
    // Do nothing, succeed silently
    // No disk I/O performed
}

/**
 * Has state implementation (always false).
 * Since nothing is persisted, state never exists.
 */
fn bool NoOpStateProvider.has_state(&self, String torrent_path) @dynamic
{
    return false;  // Never has state
}

/**
 * Delete state implementation (no-op).
 * Succeeds silently since there's nothing to delete.
 */
fn void? NoOpStateProvider.delete_state(&self, String torrent_path) @dynamic
{
    // Do nothing, succeed silently
    // Nothing to delete
}

fn void NoOpStateProvider.free(&self) @dynamic
{
    // Free the provider itself
    free(self);
}

// ============================================================================
// Factory Function
// ============================================================================

/**
 * Create a no-op state provider (stateless mode).
 *
 * @return "Provider instance (no persistence)"
 */
fn storage::StateProvider* create() @public
{
    NoOpStateProvider* provider = mem::new(NoOpStateProvider);
    return (storage::StateProvider*)provider;
}
