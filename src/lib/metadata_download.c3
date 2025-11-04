module libtorrent::metadata_download;

import std::io;
import std::time;
import libtorrent::metadata_exchange;
import libtorrent::common;
import libtorrent::bencode;
import libtorrent::logger;
import std::hash::sha1;

/**
 * BEP 9: Metadata Download Manager
 * =================================
 *
 * Manages downloading torrent metadata (info dictionary) from peers using
 * the ut_metadata extension protocol. This enables magnet link support.
 *
 * Features:
 * - Tracks metadata piece download state
 * - Requests pieces from multiple peers in parallel
 * - Reassembles metadata from 16KB pieces
 * - Verifies metadata hash matches info_hash from magnet link
 * - Handles peer failures and retries
 */

// ============================================================================
// Constants
// ============================================================================

const uint MAX_OUTSTANDING_REQUESTS = 3;  // Max concurrent piece requests
const uint REQUEST_TIMEOUT_SEC = 30;      // Timeout for piece requests

// ============================================================================
// Structures
// ============================================================================

/**
 * State of a single metadata piece
 */
enum PieceState : const char
{
    IDLE = 0,        // Not requested yet
    REQUESTED = 1,   // Request sent, waiting for response
    RECEIVED = 2     // Data received successfully
}

/**
 * Information about a metadata piece
 */
struct PieceInfo
{
    PieceState state;
    long request_time_sec;  // When we requested this piece (for timeout detection)
    char[] data;            // Piece data (only valid when state == RECEIVED)
}

/**
 * Metadata download manager
 */
struct MetadataDownload
{
    common::InfoHash info_hash;  // Expected info hash for verification
    uint total_size;             // Total metadata size in bytes (0 = unknown)
    uint num_pieces;             // Number of 16KB pieces needed
    PieceInfo[] pieces;          // State of each piece
    uint pieces_received;        // Number of pieces successfully downloaded
    bool complete;               // All pieces received and verified
    char[] metadata;             // Complete reassembled metadata (only valid when complete)
}

// ============================================================================
// Faults
// ============================================================================

faultdef METADATA_DOWNLOAD_INCOMPLETE;
faultdef METADATA_DOWNLOAD_HASH_MISMATCH;
faultdef METADATA_DOWNLOAD_INVALID_SIZE;

// ============================================================================
// Creation and Cleanup
// ============================================================================

/**
 * Create a metadata download manager
 *
 * @param info_hash : "Expected info hash (from magnet link)"
 * @return "New metadata download manager"
 */
fn MetadataDownload* create(common::InfoHash info_hash) @public
{
    MetadataDownload* md = mem::new(MetadataDownload);

    // Copy info hash
    for (usz i = 0; i < 20; i++)
    {
        md.info_hash[i] = info_hash[i];
    }

    md.total_size = 0;
    md.num_pieces = 0;
    md.pieces = {};
    md.pieces_received = 0;
    md.complete = false;
    md.metadata = {};

    return md;
}

/**
 * Free metadata download manager and resources
 */
fn void MetadataDownload.free(&self) @public
{
    // Free piece data
    foreach (piece : self.pieces)
    {
        if (piece.data.len > 0)
        {
            free(piece.data);
        }
    }

    if (self.pieces.len > 0)
    {
        free(self.pieces);
    }

    // Free complete metadata
    if (self.metadata.len > 0)
    {
        free(self.metadata);
    }

    free(self);
}

// ============================================================================
// Metadata Size Initialization
// ============================================================================

/**
 * Set the total metadata size (learned from peer's extension handshake)
 *
 * This initializes the piece tracking array.
 *
 * @param total_size : "Total metadata size in bytes"
 */
fn void MetadataDownload.set_metadata_size(&self, uint total_size) @public
{
    if (self.total_size > 0)
    {
        return;  // Already initialized
    }

    self.total_size = total_size;
    self.num_pieces = metadata_exchange::calculate_num_pieces(total_size);

    // Allocate piece tracking array
    self.pieces = mem::new_array(PieceInfo, self.num_pieces);

    // Initialize all pieces to IDLE
    for (uint i = 0; i < self.num_pieces; i++)
    {
        self.pieces[i].state = PieceState.IDLE;
        self.pieces[i].request_time_sec = 0;
        self.pieces[i].data = {};
    }

    logger::logf(logger::LogLevel.INFO, "[Metadata] Initialized download: %d bytes in %d pieces",
                 total_size, self.num_pieces);
}

// ============================================================================
// Piece Requesting
// ============================================================================

/**
 * Get the next piece that needs to be requested
 *
 * Returns the piece index of a piece in IDLE state, or -1 if all pieces are
 * either REQUESTED or RECEIVED.
 *
 * @return "Piece index to request, or -1 if nothing to request"
 */
fn int MetadataDownload.get_next_piece_to_request(&self) @public
{
    if (self.num_pieces == 0)
    {
        return -1;  // Not initialized yet
    }

    // Count outstanding requests
    uint outstanding = 0;
    for (uint i = 0; i < self.num_pieces; i++)
    {
        if (self.pieces[i].state == PieceState.REQUESTED)
        {
            outstanding++;
        }
    }

    // Don't request more if we're at the limit
    if (outstanding >= MAX_OUTSTANDING_REQUESTS)
    {
        return -1;
    }

    // Find first IDLE piece
    for (uint i = 0; i < self.num_pieces; i++)
    {
        if (self.pieces[i].state == PieceState.IDLE)
        {
            return (int)i;
        }
    }

    return -1;  // All pieces requested or received
}

/**
 * Mark a piece as requested
 *
 * @param piece : "Piece index"
 */
fn void MetadataDownload.mark_piece_requested(&self, uint piece) @public
{
    if (piece >= self.num_pieces)
    {
        return;
    }

    self.pieces[piece].state = PieceState.REQUESTED;
    self.pieces[piece].request_time_sec = (long)time::now().to_seconds();
}

/**
 * Check for timed-out requests and reset them to IDLE
 *
 * This allows re-requesting pieces from other peers if a peer doesn't respond.
 */
fn void MetadataDownload.check_timeouts(&self) @public
{
    long now_sec = (long)time::now().to_seconds();

    for (uint i = 0; i < self.num_pieces; i++)
    {
        if (self.pieces[i].state == PieceState.REQUESTED)
        {
            long elapsed_sec = now_sec - self.pieces[i].request_time_sec;

            if (elapsed_sec >= REQUEST_TIMEOUT_SEC)
            {
                logger::logf(logger::LogLevel.WARN, "[Metadata] Piece %d request timed out, retrying", i);
                self.pieces[i].state = PieceState.IDLE;
                self.pieces[i].request_time_sec = 0;
            }
        }
    }
}

// ============================================================================
// Message Handling
// ============================================================================

/**
 * Handle a metadata DATA message from a peer
 *
 * @param piece : "Piece index"
 * @param data : "Piece data"
 * @return "true if this completed the download, false otherwise"
 */
fn bool MetadataDownload.handle_data(&self, uint piece, char[] data) @public
{
    if (piece >= self.num_pieces)
    {
        logger::logf(logger::LogLevel.ERROR, "[Metadata] Received invalid piece index: %d", piece);
        return false;
    }

    if (self.pieces[piece].state == PieceState.RECEIVED)
    {
        // Already have this piece, ignore duplicate
        return false;
    }

    // Store piece data
    self.pieces[piece].data = mem::new_array(char, data.len);
    foreach (i, b : data)
    {
        self.pieces[piece].data[i] = b;
    }

    self.pieces[piece].state = PieceState.RECEIVED;
    self.pieces_received++;

    logger::logf(logger::LogLevel.INFO, "[Metadata] Received piece %d/%d (%d bytes)",
                 piece + 1, self.num_pieces, data.len);

    // Check if download is complete
    if (self.pieces_received == self.num_pieces)
    {
        return try_assemble_metadata(self);
    }

    return false;
}

/**
 * Handle a metadata REJECT message from a peer
 *
 * @param piece : "Piece index that was rejected"
 */
fn void MetadataDownload.handle_reject(&self, uint piece) @public
{
    if (piece >= self.num_pieces)
    {
        return;
    }

    // Reset to IDLE so we can request from another peer
    if (self.pieces[piece].state == PieceState.REQUESTED)
    {
        self.pieces[piece].state = PieceState.IDLE;
        self.pieces[piece].request_time_sec = 0;
        logger::logf(logger::LogLevel.INFO, "[Metadata] Piece %d rejected, will retry with another peer", piece);
    }
}

// ============================================================================
// Metadata Assembly and Verification
// ============================================================================

/**
 * Try to assemble complete metadata from pieces and verify hash
 *
 * @return "true if successful, false if verification failed"
 */
fn bool try_assemble_metadata(MetadataDownload* self) @private
{
    logger::log(logger::LogLevel.INFO, "[Metadata] All pieces received, assembling and verifying...");

    // Allocate buffer for complete metadata
    self.metadata = mem::new_array(char, self.total_size);

    // Copy all pieces into metadata buffer
    uint offset = 0;
    for (uint i = 0; i < self.num_pieces; i++)
    {
        char[] piece_data = self.pieces[i].data;

        foreach (j, b : piece_data)
        {
            if (offset + j < self.total_size)
            {
                self.metadata[offset + j] = b;
            }
        }

        offset += piece_data.len;
    }

    // Verify hash matches info_hash
    char[20] computed_hash = sha1::hash((char[])self.metadata);

    bool hash_matches = true;
    for (usz i = 0; i < 20; i++)
    {
        if (computed_hash[i] != self.info_hash[i])
        {
            hash_matches = false;
            break;
        }
    }

    if (!hash_matches)
    {
        logger::log(logger::LogLevel.ERROR, "[Metadata] Hash verification FAILED - metadata is corrupt");

        // Free invalid metadata
        free(self.metadata);
        self.metadata = {};

        return false;
    }

    logger::log(logger::LogLevel.INFO, "[Metadata] Hash verification PASSED - download complete!");
    self.complete = true;

    return true;
}

/**
 * Get the complete metadata (only valid after download completes)
 *
 * @return "Complete metadata or fault if not complete"
 */
fn char[]? MetadataDownload.get_metadata(&self) @public
{
    if (!self.complete)
    {
        return METADATA_DOWNLOAD_INCOMPLETE?;
    }

    return self.metadata;
}

/**
 * Check if download is complete
 *
 * @return "true if all pieces received and verified"
 */
fn bool MetadataDownload.is_complete(&self) @public
{
    return self.complete;
}

/**
 * Get download progress
 *
 * @return "Number of pieces received (0 to num_pieces)"
 */
fn uint MetadataDownload.get_progress(&self) @public
{
    return self.pieces_received;
}

/**
 * Get total number of pieces
 *
 * @return "Total pieces (0 if not initialized)"
 */
fn uint MetadataDownload.get_num_pieces(&self) @public
{
    return self.num_pieces;
}
