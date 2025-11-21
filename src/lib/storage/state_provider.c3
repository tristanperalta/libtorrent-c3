module libtorrent::storage;

import std::io;

/**
 * Download State Provider Interface
 * ===================================
 *
 * Uses C3's native interface system for clean polymorphism.
 * Provides abstraction for persisting and loading download state.
 *
 * Inspired by major BitTorrent clients (qBittorrent, Transmission, Deluge)
 * that persist comprehensive resume data including piece verification status,
 * partial piece data, statistics, and timing information.
 *
 * Implementations:
 * - FastResumeStateProvider (libtorrent-compatible fastresume format)
 * - SQLiteStateProvider (database backend for scalability - planned)
 * - NoOpStateProvider (stateless mode)
 * - MockStateProvider (testing)
 */

faultdef STATE_LOAD_ERROR;
faultdef STATE_SAVE_ERROR;

// State format version
const int STATE_VERSION = 2;  // Current version: comprehensive resume data

/**
 * Unfinished piece data (for resume).
 * Stores which blocks have been received for incomplete pieces.
 */
struct UnfinishedPiece
{
    uint piece_index;               // Index of the piece
    char[] blocks_bitmask;          // Bitfield: 1 bit per block
                                    // Length: (num_blocks + 7) / 8 bytes
    uint num_blocks_received;       // Count of received blocks
}

/**
 * Free unfinished piece resources.
 */
fn void UnfinishedPiece.free(&self)
{
    if (self.blocks_bitmask.len > 0)
    {
        free(self.blocks_bitmask);
    }
}

/**
 * File resume data for validation (per-file).
 * Used to detect file changes since last session.
 * Follows libtorrent-rasterbar's approach (mtime + size checking).
 */
struct FileResumeData
{
    long mtime;      // File modification timestamp (Unix time)
    ulong size;      // File size in bytes
}

/**
 * Download state structure.
 * Contains all resumable state for a torrent download.
 *
 * Comprehensive format inspired by qBittorrent, Transmission, and Deluge.
 */
struct DownloadState
{
    // ===== ESSENTIAL FIELDS (Priority 1) =====
    // Must be in all adapters, critical for resume

    int version;                    // State format version (current: 2)

    // Piece verification status
    char[] have_pieces;             // Bitfield: 1 bit per piece (compact format)
                                    // Bit set = piece verified and available
                                    // Length: (num_pieces + 7) / 8 bytes

    // File selection (BEP 21 - already implemented in v1)
    String file_selection;          // Comma-separated file indices (e.g., "0,2,4")

    // ===== IMPORTANT FIELDS (Priority 2) =====
    // Significantly improve user experience

    // Download/upload statistics
    ulong total_downloaded;         // Total bytes downloaded (all time)
    ulong total_uploaded;           // Total bytes uploaded (all time)

    // Timing data
    long added_time;                // Unix timestamp when torrent was added
    long completed_time;            // Unix timestamp when download completed (0=incomplete)
    uint active_time;               // Seconds torrent was active (unpaused)
    uint seeding_time;              // Seconds spent seeding
    long last_seen_complete;        // Last time we saw a complete seed

    // Partial piece data (critical for resume)
    UnfinishedPiece[] unfinished;   // Partially downloaded pieces

    // ===== OPTIONAL FIELDS (Priority 3) =====
    // Nice to have, can be added incrementally

    // Per-file priorities
    char[] file_priority;           // One byte per file: 0=skip, 1-7=priority

    // Rate limits (per-torrent)
    int upload_rate_limit;          // Bytes/second (0=unlimited)
    int download_rate_limit;        // Bytes/second (0=unlimited)

    // Connection limits
    int max_connections;            // Max peer connections (0=default)
    int max_uploads;                // Max simultaneous uploads (0=default)

    // State flags
    bool paused;                    // Paused state
    bool auto_managed;              // Auto-management enabled
    bool sequential_download;       // Sequential mode
    bool seed_mode;                 // Seed mode (skip hash checks)

    // Network data (for quick reconnection)
    String save_path;               // Download directory

    // File validation data (libtorrent-rasterbar compatible)
    FileResumeData[] file_resume;   // Per-file mtime+size for validation

    // ===== TRANSMISSION-SPECIFIC FIELDS =====
    // Fields used by Transmission BitTorrent client

    long activity_date;             // Last activity timestamp (Transmission: activity-date)
    ulong corrupt;                  // Bytes found corrupt during verification
    int bandwidth_priority;         // Upload/download priority (-1=low, 0=normal, 1=high)
    double ratio_limit;             // Seed ratio limit (0=use global, -1=unlimited)
    uint idle_limit;                // Idle seeding time limit in minutes (0=use global)
    bool speed_limit_up_enabled;    // Whether upload speed limit is enabled
    bool speed_limit_down_enabled;  // Whether download speed limit is enabled
}

/**
 * Free download state resources.
 */
fn void DownloadState.free(&self)
{
    // Essential fields
    if (self.file_selection.len > 0) free(self.file_selection);
    if (self.have_pieces.len > 0) free(self.have_pieces);

    // Important fields
    foreach (i, piece : self.unfinished)
    {
        piece.free();
    }
    if (self.unfinished.len > 0) free(self.unfinished);

    // Optional fields
    if (self.file_priority.len > 0) free(self.file_priority);
    if (self.save_path.len > 0) free(self.save_path);
    if (self.file_resume.len > 0) free(self.file_resume);
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
    fn void free();
}
