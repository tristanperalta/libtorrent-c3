module libtorrent::download_manager;

import libtorrent::piece_picker;
import libtorrent::block_manager;
import libtorrent::piece_assembler;
import async::event_loop;
import std::io;

<*
 Download Manager - Coordination Layer
 ======================================
 Integrates piece selection, block management, and piece assembly to coordinate
 downloading a torrent from multiple peers.

 This is the top-level download coordination layer that:
 - Uses PiecePicker to select which pieces to download (rarest-first)
 - Manages multiple concurrent piece downloads with BlockManager
 - Assembles and verifies completed pieces with PieceAssembler (async)
 - Handles failures and retries

 Usage:
   DownloadManager manager = create(loop, num_pieces, piece_length, last_piece_length,
                                     piece_hashes, max_concurrent, block_size);
   defer free(&manager);

   // Update peer availability
   manager.update_peer_bitfield(peer_bitfield)!!;
   manager.peer_has_piece(piece_index)!!;

   // Start downloading
   manager.start_piece_download(peer_pieces)!!;

   // Get block to request
   BlockRequest? req = manager.get_next_block_request();
   if (req) {
       // Send REQUEST message to peer
       manager.mark_block_requested(req!!.piece_index, req!!.offset)!!;
   }

   // Receive block from peer
   manager.receive_block(piece_index, offset, block_data)!!;

   // Complete piece when all blocks received (async verification)
   manager.complete_piece(piece_index, &on_piece_complete, user_data);

   // Callback receives verified piece data
   fn void on_piece_complete(uint piece_index, char[] piece_data, bool success, void* user_data) {
       if (success) {
           // Piece verified! Write to disk
       }
   }
*>

// Faults
faultdef INVALID_PIECE_INDEX;
faultdef NO_PIECES_TO_REQUEST;
faultdef PIECE_NOT_DOWNLOADING;
faultdef PIECE_ALREADY_DOWNLOADING;
faultdef INVALID_BITFIELD_SIZE;

// Callback for async piece completion
alias CompletePieceCallback = fn void(uint piece_index, char[] piece_data, bool success, void* user_data);

// Context for async piece completion
struct CompletePieceContext
{
    DownloadManager* manager;
    uint piece_index;
    usz download_slot;           // Index in active_downloads array
    CompletePieceCallback callback;
    void* user_data;
}

// Information about a piece currently being downloaded
struct DownloadingPiece
{
    uint piece_index;                         // Which piece this is
    block_manager::BlockManager blocks;       // Block tracking
    piece_assembler::PieceAssembler assembler;  // Assembly and verification
    bool active;                              // Is this slot in use?
}

// Download manager - coordinates piece downloads
struct DownloadManager
{
    event_loop::EventLoop* loop;              // Event loop for async operations
    piece_picker::PiecePicker picker;         // Piece selection strategy
    DownloadingPiece[] active_downloads;      // Concurrent downloads
    usz max_concurrent_pieces;                // Max pieces to download at once
    uint piece_length;                        // Standard piece length
    uint last_piece_length;                   // Last piece may be shorter
    char[] piece_hashes;                      // All piece hashes (20 bytes each)
    uint num_pieces;                          // Total number of pieces
    uint block_size;                          // Block size (typically 16KB)
}

<*
 Create a download manager.

 @param loop : "Event loop for async operations"
 @param num_pieces : "Total number of pieces"
 @param piece_length : "Standard piece length in bytes"
 @param last_piece_length : "Last piece length (may be shorter)"
 @param piece_hashes : "SHA-1 hashes for all pieces (20 * num_pieces bytes)"
 @param max_concurrent : "Maximum concurrent piece downloads"
 @param block_size : "Block size in bytes (typically 16384)"
 @return "Initialized download manager"
*>
fn DownloadManager create(event_loop::EventLoop* loop, uint num_pieces, uint piece_length, uint last_piece_length,
                           char[] piece_hashes, usz max_concurrent, uint block_size) @public
{
    DownloadManager manager;
    manager.loop = loop;
    manager.num_pieces = num_pieces;
    manager.piece_length = piece_length;
    manager.last_piece_length = last_piece_length;
    manager.block_size = block_size;
    manager.max_concurrent_pieces = max_concurrent;

    // Create piece picker
    manager.picker = piece_picker::create(num_pieces);

    // Copy piece hashes
    manager.piece_hashes = mem::new_array(char, piece_hashes.len);
    for (usz i = 0; i < piece_hashes.len; i++)
    {
        manager.piece_hashes[i] = piece_hashes[i];
    }

    // Allocate active download slots
    manager.active_downloads = mem::new_array(DownloadingPiece, max_concurrent);
    for (usz i = 0; i < max_concurrent; i++)
    {
        manager.active_downloads[i].active = false;
    }

    return manager;
}

<*
 Free a download manager and all associated resources.
*>
fn void free(DownloadManager* manager) @public
{
    // Free piece picker
    piece_picker::free(&manager.picker);

    // Free active downloads
    for (usz i = 0; i < manager.max_concurrent_pieces; i++)
    {
        if (manager.active_downloads[i].active)
        {
            block_manager::free(&manager.active_downloads[i].blocks);
            piece_assembler::free(&manager.active_downloads[i].assembler);
        }
    }

    if (manager.active_downloads.len > 0)
    {
        std::core::mem::free(manager.active_downloads);
        manager.active_downloads = {};
    }

    if (manager.piece_hashes.len > 0)
    {
        std::core::mem::free(manager.piece_hashes);
        manager.piece_hashes = {};
    }
}

<*
 Update piece availability based on peer bitfield.

 @param bitfield : "Peer's piece bitfield (one bool per piece)"
 @return "Fault if bitfield size is wrong"
*>
fn fault? DownloadManager.update_peer_bitfield(&self, bool[] bitfield) @public
{
    if (bitfield.len != self.num_pieces)
    {
        return INVALID_BITFIELD_SIZE?;
    }

    return self.picker.update_peer_bitfield(bitfield);
}

<*
 Update piece availability when peer sends HAVE message.

 @param piece_index : "Index of piece peer has"
 @return "Fault if piece index invalid"
*>
fn fault? DownloadManager.peer_has_piece(&self, uint piece_index) @public
{
    return self.picker.peer_has_piece(piece_index);
}

<*
 Start downloading a new piece.

 Selects the rarest piece that the peer has and we need, then starts
 downloading it by creating block manager and piece assembler.

 @param peer_pieces : "Bitfield of pieces peer has"
 @return "Fault if no slots available or no pieces to request"
*>
fn fault? DownloadManager.start_piece_download(&self, bool[] peer_pieces) @public
{
    // Find free download slot
    usz slot_index = 0;
    bool found_slot = false;
    for (usz i = 0; i < self.max_concurrent_pieces; i++)
    {
        if (!self.active_downloads[i].active)
        {
            slot_index = i;
            found_slot = true;
            break;
        }
    }

    if (!found_slot)
    {
        return NO_PIECES_TO_REQUEST?;
    }

    // Pick piece using rarest-first
    uint? piece_opt = self.picker.pick_piece(peer_pieces);
    if (catch excuse = piece_opt)
    {
        return excuse?;
    }
    uint piece_index = piece_opt;

    // Debug output disabled for logging mode
    // io::printfn("      [DM] Picked piece %d for download", piece_index);

    // Get piece length (last piece may be shorter)
    uint this_piece_length = (piece_index == self.num_pieces - 1)
                              ? self.last_piece_length
                              : self.piece_length;

    // Get expected hash for this piece
    char[20] expected_hash;
    usz hash_offset = (usz)piece_index * 20;
    for (usz i = 0; i < 20; i++)
    {
        expected_hash[i] = self.piece_hashes[hash_offset + i];
    }

    // Mark piece as downloading in picker
    self.picker.mark_downloading(piece_index)!!;

    // Create block manager
    block_manager::BlockManager blocks = block_manager::create(piece_index, this_piece_length);

    // Create piece assembler
    piece_assembler::PieceAssembler assembler = piece_assembler::create(
        piece_index, this_piece_length, expected_hash, self.block_size);

    // Store in download slot
    self.active_downloads[slot_index].piece_index = piece_index;
    self.active_downloads[slot_index].blocks = blocks;
    self.active_downloads[slot_index].assembler = assembler;
    self.active_downloads[slot_index].active = true;

    return {};
}

<*
 Get the next block to request from any active download.

 @return "Block request, or fault if no blocks available"
*>
fn block_manager::BlockRequest? DownloadManager.get_next_block_request(&self) @public
{
    // Debug: Show state of active downloads on first call
    static bool logged_once = false;
    if (!logged_once)
    {
        usz active_count = 0;
        for (usz i = 0; i < self.max_concurrent_pieces; i++)
        {
            if (self.active_downloads[i].active)
            {
                active_count++;
                usz total_blocks, received_blocks;
                self.active_downloads[i].blocks.get_progress(&total_blocks, &received_blocks);
                io::printfn("    [DM] Slot %d: piece=%d, blocks=%d/%d",
                           i, self.active_downloads[i].piece_index, received_blocks, total_blocks);
            }
        }
        if (active_count == 0)
        {
            io::printfn("    [DM] No active download slots!");
        }
        logged_once = true;
    }

    // Try each active download
    for (usz i = 0; i < self.max_concurrent_pieces; i++)
    {
        if (!self.active_downloads[i].active) continue;

        block_manager::BlockRequest? req = self.active_downloads[i].blocks.get_next_block();
        if (catch excuse = req)
        {
            // This download has no free blocks, try next
            continue;
        }
        // Found a block to request
        return req;
    }

    return block_manager::NO_BLOCKS_AVAILABLE?;
}

<*
 Mark a block as requested.

 @param piece_index : "Piece index"
 @param offset : "Block offset within piece"
 @return "Fault if piece not downloading or offset invalid"
*>
fn fault? DownloadManager.mark_block_requested(&self, uint piece_index, uint offset) @public
{
    // Find active download for this piece
    for (usz i = 0; i < self.max_concurrent_pieces; i++)
    {
        if (self.active_downloads[i].active &&
            self.active_downloads[i].piece_index == piece_index)
        {
            return self.active_downloads[i].blocks.mark_requested(offset);
        }
    }

    return PIECE_NOT_DOWNLOADING?;
}

<*
 Receive a block from a peer.

 @param piece_index : "Piece index"
 @param offset : "Block offset within piece"
 @param data : "Block data"
 @return "Fault if piece not downloading or block invalid"
*>
fn fault? DownloadManager.receive_block(&self, uint piece_index, uint offset, char[] data) @public
{
    // Find active download for this piece
    for (usz i = 0; i < self.max_concurrent_pieces; i++)
    {
        if (self.active_downloads[i].active &&
            self.active_downloads[i].piece_index == piece_index)
        {
            // Mark block as received in block manager
            self.active_downloads[i].blocks.mark_received(offset, data)!!;

            // Add block to piece assembler
            return self.active_downloads[i].assembler.add_block(offset, data);
        }
    }

    return PIECE_NOT_DOWNLOADING?;
}

<*
 Internal callback - called when piece verification completes.
*>
fn void on_piece_verify_complete(uint piece_index, bool verified, void* user_data)
{
    CompletePieceContext* ctx = (CompletePieceContext*)user_data;

    if (!verified)
    {
        // Hash mismatch - call user callback with failure
        if (ctx.callback)
        {
            char[] empty;
            ctx.callback(piece_index, empty, false, ctx.user_data);
        }
        std::core::mem::free(ctx);
        return;
    }

    // Get piece data (make a copy for caller to own)
    char[] source_data = ctx.manager.active_downloads[ctx.download_slot].assembler.get_data();
    char[] piece_data = mem::new_array(char, source_data.len);
    for (usz j = 0; j < source_data.len; j++)
    {
        piece_data[j] = source_data[j];
    }

    // Mark piece as complete in picker
    ctx.manager.picker.mark_complete(piece_index)!!;

    // Free download resources (this frees source_data)
    block_manager::free(&ctx.manager.active_downloads[ctx.download_slot].blocks);
    piece_assembler::free(&ctx.manager.active_downloads[ctx.download_slot].assembler);
    ctx.manager.active_downloads[ctx.download_slot].active = false;

    // Call user callback with success
    if (ctx.callback)
    {
        ctx.callback(piece_index, piece_data, true, ctx.user_data);
    }

    std::core::mem::free(ctx);
}

<*
 Complete a piece download asynchronously (verify hash and return data).

 This should be called when all blocks for a piece have been received.
 It verifies the SHA-1 hash in a background thread and calls the callback
 with the assembled piece data when verification completes.

 @param piece_index : "Piece index to complete"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void DownloadManager.complete_piece(&self, uint piece_index,
                                        CompletePieceCallback callback,
                                        void* user_data) @public
{
    // Find active download for this piece
    for (usz i = 0; i < self.max_concurrent_pieces; i++)
    {
        if (self.active_downloads[i].active &&
            self.active_downloads[i].piece_index == piece_index)
        {
            // Create context
            CompletePieceContext* ctx = mem::new(CompletePieceContext);
            ctx.manager = (DownloadManager*)self;
            ctx.piece_index = piece_index;
            ctx.download_slot = i;
            ctx.callback = callback;
            ctx.user_data = user_data;

            // Verify piece hash asynchronously
            self.active_downloads[i].assembler.verify(self.loop,
                                                       &on_piece_verify_complete,
                                                       ctx);
            return;
        }
    }

    // Piece not downloading - call callback with error
    if (callback)
    {
        char[] empty;
        callback(piece_index, empty, false, user_data);
    }
}

<*
 Mark a piece as failed and return it to FREE state for retry.

 @param piece_index : "Piece index that failed"
 @return "Fault if piece not downloading"
*>
fn fault? DownloadManager.fail_piece(&self, uint piece_index) @public
{
    // Find active download for this piece
    for (usz i = 0; i < self.max_concurrent_pieces; i++)
    {
        if (self.active_downloads[i].active &&
            self.active_downloads[i].piece_index == piece_index)
        {
            // Free download resources
            block_manager::free(&self.active_downloads[i].blocks);
            piece_assembler::free(&self.active_downloads[i].assembler);
            self.active_downloads[i].active = false;

            // Return piece to FREE state in picker
            return self.picker.mark_free(piece_index);
        }
    }

    return PIECE_NOT_DOWNLOADING?;
}

<*
 Check if all pieces are complete.

 @return "True if download is complete"
*>
fn bool DownloadManager.is_complete(&self) @public
{
    return self.picker.is_complete();
}

<*
 Get download progress.

 @param total : "Output: total pieces"
 @param complete : "Output: complete pieces"
 @param downloading : "Output: pieces being downloaded"
*>
fn void DownloadManager.get_progress(&self, usz* total, usz* complete, usz* downloading) @public
{
    self.picker.get_progress(total, complete, downloading);
}

<*
 Check if a specific piece is currently being downloaded.

 @param piece_index : "Piece index to check"
 @return "True if piece is being downloaded"
*>
fn bool DownloadManager.is_piece_downloading(&self, uint piece_index) @public
{
    for (usz i = 0; i < self.max_concurrent_pieces; i++)
    {
        if (self.active_downloads[i].active &&
            self.active_downloads[i].piece_index == piece_index)
        {
            return true;
        }
    }
    return false;
}

<*
 Check if a piece is complete (downloaded and verified).

 @param piece_index : "Piece index to check"
 @return "True if piece is complete"
*>
fn bool DownloadManager.have_piece(&self, uint piece_index) @public
{
    return self.picker.have_piece(piece_index);
}

<*
 Get block progress for a specific piece being downloaded.

 @param piece_index : "Piece index"
 @param total_blocks : "Output: total blocks in piece"
 @param received_blocks : "Output: received blocks"
 @return "Fault if piece not downloading"
*>
fn fault? DownloadManager.get_piece_progress(&self, uint piece_index,
                                              usz* total_blocks, usz* received_blocks) @public
{
    for (usz i = 0; i < self.max_concurrent_pieces; i++)
    {
        if (self.active_downloads[i].active &&
            self.active_downloads[i].piece_index == piece_index)
        {
            self.active_downloads[i].blocks.get_progress(total_blocks, received_blocks);
            return {};
        }
    }

    return PIECE_NOT_DOWNLOADING?;
}
