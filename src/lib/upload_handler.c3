module libtorrent::upload_handler;

import libtorrent::upload_manager;
import libtorrent::storage_manager;
import libtorrent::peer_connection;
import libtorrent::common;
import libtorrent::logger;

/**
 * Upload Handler
 * ==============
 * Processes upload requests and sends PIECE messages to peers.
 *
 * Flow:
 * 1. Peer sends REQUEST message (piece_index, offset, length)
 * 2. Add request to upload queue (upload_manager)
 * 3. Process request: read block from storage
 * 4. Send PIECE message with block data to peer
 */

/**
 * Context passed to storage read callback
 */
struct UploadContext
{
    peer_connection::PeerConnection* peer;
    uint piece_index;
    uint offset;
}

/**
 * Callback when block data has been read from storage.
 * Sends PIECE message to peer.
 */
fn void on_block_read(uint piece_index, uint offset, char[] block_data, int status, void* user_data)
{
    UploadContext* ctx = (UploadContext*)user_data;
    defer free(ctx);

    if (status != 0)
    {
        // Read failed - log error and free block data
        logger::logf(logger::LogLevel.ERROR, "Failed to read block for upload: piece=%d offset=%d status=%d",
                    piece_index, offset, status);
        free(block_data);
        return;
    }

    // Send PIECE message to peer using existing method
    if (catch excuse = ctx.peer.send_piece(piece_index, offset, block_data))
    {
        logger::logf(logger::LogLevel.ERROR, "Failed to send PIECE message: piece=%d offset=%d",
                    piece_index, offset);
    }

    // Free block data (allocated by storage_manager)
    free(block_data);
}

/**
 * Process an upload request for a peer.
 * Reads the requested block from storage and sends PIECE message.
 *
 * @param storage "Storage manager to read from"
 * @param peer "Peer connection to send to"
 * @param req "Upload request"
 */
fn void process_upload_request(storage_manager::StorageManager* storage,
                                peer_connection::PeerConnection* peer,
                                upload_manager::UploadRequest req) @public
{
    // Create context for callback
    UploadContext* ctx = mem::new(UploadContext);
    ctx.peer = peer;
    ctx.piece_index = req.piece_index;
    ctx.offset = req.offset;

    // Read block from storage (async)
    storage.read_block(req.piece_index, req.offset, req.length, &on_block_read, ctx);
}

/**
 * Process all pending upload requests for a peer.
 * Called when peer is unchoked or periodically.
 *
 * @param upload_mgr "Upload manager"
 * @param storage "Storage manager"
 * @param peer "Peer connection"
 * @param peer_addr "Peer's socket address"
 * @param max_requests "Maximum number of requests to process (0 = all)"
 */
fn void process_pending_uploads(upload_manager::UploadManager* upload_mgr,
                                 storage_manager::StorageManager* storage,
                                 peer_connection::PeerConnection* peer,
                                 common::SocketAddress* peer_addr,
                                 usz max_requests = 0) @public
{
    usz processed = 0;

    while (true)
    {
        // Check max requests limit
        if (max_requests > 0 && processed >= max_requests)
        {
            break;
        }

        // Get next request from queue
        upload_manager::UploadRequest? req = upload_mgr.process_next_request(peer_addr);
        if (catch excuse = req)
        {
            // No more requests
            break;
        }

        // Process request
        process_upload_request(storage, peer, req);
        processed++;
    }

    if (processed > 0)
    {
        logger::logf(logger::LogLevel.DEBUG, "Processed %d upload requests for peer", processed);
    }
}
