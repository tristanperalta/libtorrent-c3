module libtorrent::upload_manager;

import std::collections::map;
import std::collections::list;
import libtorrent::common;
import std::time;

// Faults
faultdef UPLOAD_QUEUE_EMPTY;
faultdef UPLOAD_NO_PEER_QUEUE;

/**
 * Upload Manager
 * ==============
 * Manages upload request queues for all connected peers.
 *
 * Each peer has a queue of pending block requests (REQUEST messages).
 * The manager handles queueing, dequeuing, and cleanup.
 *
 * BEP 3 suggests a maximum queue size of 250 requests per peer to prevent
 * memory exhaustion from malicious peers.
 */

// Maximum number of pending requests per peer (BEP 3 recommendation)
const usz MAX_REQUESTS_PER_PEER = 250;

// Request timeout in seconds (if request sits in queue too long)
const long REQUEST_TIMEOUT_SECONDS = 120;

/**
 * A single upload request from a peer.
 */
struct UploadRequest
{
    uint piece_index;
    uint offset;          // Offset within the piece (begin field in protocol)
    uint length;          // Block length (typically 16KB)
    long timestamp;       // When request was received (for timeout detection)
}

/**
 * Upload request queue for a single peer.
 */
struct PeerUploadQueue
{
    common::SocketAddress peer_addr;
    List{UploadRequest} pending_requests;
    usz max_queue_size;
}

fn void PeerUploadQueue.init(&self, common::SocketAddress addr, usz max_size = MAX_REQUESTS_PER_PEER)
{
    self.peer_addr = addr;
    self.pending_requests.init(mem);
    self.max_queue_size = max_size;
}

fn void PeerUploadQueue.free(&self)
{
    self.pending_requests.free();
}

fn bool PeerUploadQueue.add_request(&self, uint piece_index, uint offset, uint length)
{
    // Check queue capacity
    if (self.pending_requests.len() >= self.max_queue_size)
    {
        return false;  // Queue full
    }

    // Create request
    UploadRequest req;
    req.piece_index = piece_index;
    req.offset = offset;
    req.length = length;
    req.timestamp = (long)time::now().to_seconds();

    // Add to queue
    self.pending_requests.push(req);
    return true;
}

fn UploadRequest? PeerUploadQueue.pop_request(&self)
{
    if (self.pending_requests.is_empty())
    {
        return UPLOAD_QUEUE_EMPTY?;
    }

    return self.pending_requests.pop_first()!;
}

fn usz PeerUploadQueue.len(&self)
{
    return self.pending_requests.len();
}

fn void PeerUploadQueue.clear(&self)
{
    self.pending_requests.clear();
}

/**
 * Upload Manager
 *
 * Manages upload request queues for all peers.
 */
struct UploadManager
{
    HashMap{common::SocketAddress, PeerUploadQueue*} peer_queues;
    DynamicArenaAllocator arena;
}

fn UploadManager* create() @public
{
    UploadManager* mgr = mem::new(UploadManager);
    mgr.peer_queues.init(mem);
    mgr.arena.init(mem, 4096);  // 4KB initial size
    return mgr;
}

fn void UploadManager.free(&self) @public
{
    // Free all peer queues
    self.peer_queues.@each(; common::SocketAddress addr, PeerUploadQueue* queue)
    {
        queue.free();
    };

    self.peer_queues.free();
    self.arena.free();
    free(self);
}

/**
 * Add an upload request for a peer.
 *
 * @param peer_addr "Peer's socket address"
 * @param piece_index "Piece index"
 * @param offset "Offset within piece (begin field)"
 * @param length "Block length"
 * @return "true if added successfully, false if queue full"
 */
fn bool UploadManager.add_request(&self,
                                   common::SocketAddress* peer_addr,
                                   uint piece_index,
                                   uint offset,
                                   uint length) @public
{
    // Get or create peer queue
    PeerUploadQueue**? queue_ref = self.peer_queues.get_ref(*peer_addr);

    PeerUploadQueue* queue;
    if (catch excuse = queue_ref)
    {
        // Create new queue for this peer
        queue = allocator::new(&self.arena, PeerUploadQueue);
        queue.init(*peer_addr);
        self.peer_queues.set(*peer_addr, queue);
    }
    else
    {
        queue = *queue_ref;
    }

    // Add request to queue
    return queue.add_request(piece_index, offset, length);
}

/**
 * Get the next upload request for a peer.
 *
 * @param peer_addr "Peer's socket address"
 * @return "Next request, or fault if queue empty"
 */
fn UploadRequest? UploadManager.process_next_request(&self, common::SocketAddress* peer_addr) @public
{
    PeerUploadQueue**? queue_ref = self.peer_queues.get_ref(*peer_addr);
    if (catch excuse = queue_ref)
    {
        // No queue for this peer
        return UPLOAD_NO_PEER_QUEUE?;
    }

    PeerUploadQueue* queue = *queue_ref;
    return queue.pop_request();
}

/**
 * Get the number of pending requests for a peer.
 *
 * @param peer_addr "Peer's socket address"
 * @return "Number of pending requests"
 */
fn usz UploadManager.get_queue_size(&self, common::SocketAddress* peer_addr) @public
{
    PeerUploadQueue**? queue_ref = self.peer_queues.get_ref(*peer_addr);
    if (catch excuse = queue_ref)
    {
        return 0;
    }

    return (*queue_ref).len();
}

/**
 * Clear all pending requests for a peer.
 * Called when peer disconnects.
 *
 * @param peer_addr "Peer's socket address"
 */
fn void UploadManager.clear_peer_queue(&self, common::SocketAddress* peer_addr) @public
{
    PeerUploadQueue**? queue_ref = self.peer_queues.get_ref(*peer_addr);
    if (catch excuse = queue_ref)
    {
        return;  // No queue for this peer
    }

    PeerUploadQueue* queue = *queue_ref;
    queue.free();  // Free the List's backing array

    // Remove from HashMap
    self.peer_queues.remove(*peer_addr);

    // Note: PeerUploadQueue struct memory will be freed when arena is destroyed
}

/**
 * Remove stale requests (older than REQUEST_TIMEOUT_SECONDS).
 * Should be called periodically.
 */
fn void UploadManager.remove_stale_requests(&self) @public
{
    long now = (long)time::now().to_seconds();

    self.peer_queues.@each(; common::SocketAddress addr, PeerUploadQueue* queue)
    {
        // Filter out stale requests
        List{UploadRequest} fresh_requests;
        fresh_requests.init(mem);

        for (usz i = 0; i < queue.pending_requests.len(); i++)
        {
            UploadRequest req = queue.pending_requests.get(i);
            if (now - req.timestamp < REQUEST_TIMEOUT_SECONDS)
            {
                fresh_requests.push(req);
            }
        }

        // Replace queue with fresh requests
        queue.pending_requests.free();
        queue.pending_requests = fresh_requests;
    };
}

/**
 * Get total number of pending requests across all peers.
 * Useful for monitoring/debugging.
 */
fn usz UploadManager.get_total_pending(&self) @public
{
    usz total = 0;
    self.peer_queues.@each(; common::SocketAddress addr, PeerUploadQueue* queue)
    {
        total += queue.len();
    };
    return total;
}
