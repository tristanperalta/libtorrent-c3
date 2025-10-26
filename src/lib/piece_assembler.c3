module libtorrent::piece_assembler;

import std::hash::sha1;
import async::work;
import async::event_loop;
import std::io;

<*
 Piece Assembler and Verifier
 =============================
 Assembles blocks into a complete piece and verifies the SHA-1 hash asynchronously.

 Usage:
   PieceAssembler assembler = create(piece_index, piece_length, expected_hash, block_size);
   defer free(&assembler);

   assembler.add_block(offset, data);
   assembler.add_block(offset2, data2);

   if (assembler.is_complete()) {
       // Verify asynchronously (SHA-1 runs in thread pool)
       assembler.verify(loop, &on_verify_complete, user_data);
   }

   // Callback receives verification result
   fn void on_verify_complete(uint piece_index, bool verified, void* user_data) {
       if (verified) {
           // Hash verified! Piece is valid
       }
   }
*>

// Faults
faultdef BLOCK_INVALID_OFFSET;

// Callback for async verification
alias VerifyCallback = fn void(uint piece_index, bool verified, void* user_data);

// Context for async verification
struct VerifyContext
{
    uint piece_index;
    char[] piece_data;         // Copy of data to hash
    char[20] expected_hash;
    char[20] actual_hash;      // Result computed in thread pool
    VerifyCallback callback;
    void* user_data;
    async::work::WorkContext* work_ctx;
}

<*
 Piece assembler state.
*>
struct PieceAssembler
{
    uint piece_index;       // Index of this piece
    uint piece_length;      // Total piece length
    char[20] expected_hash; // Expected SHA-1 hash
    char[] data;            // Assembled piece data
    bool[] received;        // Track which parts have been received
    usz blocks_received;    // Count of blocks received
    usz total_blocks;       // Total blocks needed
    uint block_size;        // Size of each block (last may be smaller)
}

<*
 Create a piece assembler.

 @param piece_index : "Index of the piece"
 @param piece_length : "Total length of the piece"
 @param expected_hash : "Expected SHA-1 hash (20 bytes)"
 @param block_size : "Size of blocks (typically 16KB)"
 @return "Initialized assembler"
*>
fn PieceAssembler create(uint piece_index, uint piece_length, char[20] expected_hash, uint block_size) @public
{
    PieceAssembler assembler;
    assembler.piece_index = piece_index;
    assembler.piece_length = piece_length;
    assembler.block_size = block_size;
    assembler.blocks_received = 0;

    // Copy expected hash
    for (usz i = 0; i < 20; i++)
    {
        assembler.expected_hash[i] = expected_hash[i];
    }

    // Calculate number of blocks
    assembler.total_blocks = (usz)((piece_length + block_size - 1) / block_size);

    // Allocate data buffer
    assembler.data = mem::new_array(char, piece_length);

    // Track which blocks received
    assembler.received = mem::new_array(bool, assembler.total_blocks);
    for (usz i = 0; i < assembler.total_blocks; i++)
    {
        assembler.received[i] = false;
    }

    return assembler;
}

<*
 Free a piece assembler.
*>
fn void free(PieceAssembler* assembler) @public
{
    if (assembler.data.len > 0)
    {
        std::core::mem::free(assembler.data);
        assembler.data = {};
    }

    if (assembler.received.len > 0)
    {
        std::core::mem::free(assembler.received);
        assembler.received = {};
    }
}

<*
 Add a block of data to the piece.

 @param offset : "Offset within piece"
 @param block_data : "Block data to add"
 @return "Fault if offset invalid"
*>
fn fault? PieceAssembler.add_block(&self, uint offset, char[] block_data) @public
{
    // Validate offset
    if (offset >= self.piece_length)
    {
        return BLOCK_INVALID_OFFSET?;
    }

    // Validate that block doesn't exceed piece length
    if (offset + block_data.len > self.piece_length)
    {
        return BLOCK_INVALID_OFFSET?;
    }

    // Calculate block index
    usz block_index = (usz)(offset / self.block_size);
    if (block_index >= self.total_blocks)
    {
        return BLOCK_INVALID_OFFSET?;
    }

    // Copy data into piece buffer
    for (usz i = 0; i < block_data.len; i++)
    {
        self.data[offset + i] = block_data[i];
    }

    // Mark block as received (don't double-count)
    if (!self.received[block_index])
    {
        self.received[block_index] = true;
        self.blocks_received++;
    }

    return {};
}

<*
 Check if all blocks have been received.

 @return "True if piece is complete"
*>
fn bool PieceAssembler.is_complete(&self) @public
{
    return self.blocks_received == self.total_blocks;
}

<*
 Work function - runs in thread pool.
 Computes SHA-1 hash of piece data.
*>
fn void do_verify_work(void* input, void** output)
{
    VerifyContext* ctx = (VerifyContext*)input;

    // Compute SHA-1 hash (CPU-intensive, but we're in thread pool!)
    ctx.actual_hash = sha1::hash(ctx.piece_data);

    *output = ctx;
}

<*
 Completion callback - runs in event loop.
 Compares hashes and calls user callback.
*>
fn void on_verify_complete(void* output, int status, void* user_data)
{
    VerifyContext* ctx = (VerifyContext*)output;

    if (status < 0)
    {
        // Thread pool error
        if (ctx.callback)
        {
            ctx.callback(ctx.piece_index, false, ctx.user_data);
        }
        std::core::mem::free(ctx.piece_data);
        if (ctx.work_ctx) std::core::mem::free(ctx.work_ctx);
        std::core::mem::free(ctx);
        return;
    }

    // Compare hashes
    bool verified = true;
    for (usz i = 0; i < 20; i++)
    {
        if (ctx.actual_hash[i] != ctx.expected_hash[i])
        {
            verified = false;
            break;
        }
    }

    // Call user callback
    if (ctx.callback)
    {
        ctx.callback(ctx.piece_index, verified, ctx.user_data);
    }

    // Clean up
    std::core::mem::free(ctx.piece_data);
    if (ctx.work_ctx) std::core::mem::free(ctx.work_ctx);
    std::core::mem::free(ctx);
}

<*
 Verify the piece SHA-1 hash asynchronously using thread pool.

 The SHA-1 computation runs in a background thread, keeping the event loop responsive.
 The callback is invoked in the event loop when verification completes.

 Must only be called when is_complete() returns true.

 @param loop : "Event loop"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void PieceAssembler.verify(&self, event_loop::EventLoop* loop,
                               VerifyCallback callback, void* user_data) @public
{
    if (!self.is_complete())
    {
        // Immediately call callback with failure
        if (callback)
        {
            callback(self.piece_index, false, user_data);
        }
        return;
    }

    // Create verification context
    VerifyContext* ctx = mem::new(VerifyContext);
    ctx.piece_index = self.piece_index;
    ctx.callback = callback;
    ctx.user_data = user_data;

    // Copy expected hash
    for (usz i = 0; i < 20; i++)
    {
        ctx.expected_hash[i] = self.expected_hash[i];
    }

    // Copy piece data (thread pool will access this)
    ctx.piece_data = mem::new_array(char, self.data.len);
    for (usz i = 0; i < self.data.len; i++)
    {
        ctx.piece_data[i] = self.data[i];
    }

    // Create async work context
    async::work::WorkContext* work_ctx = mem::new(async::work::WorkContext);
    work_ctx.input = ctx;
    work_ctx.work_fn = &do_verify_work;
    work_ctx.callback = &on_verify_complete;
    work_ctx.user_data = user_data;
    ctx.work_ctx = work_ctx;

    // Queue work
    int result = async::work::queue_work(loop, work_ctx);
    if (result != 0)
    {
        // Failed to queue - call callback with error
        if (callback)
        {
            callback(self.piece_index, false, user_data);
        }

        // Clean up
        std::core::mem::free(ctx.piece_data);
        std::core::mem::free(work_ctx);
        std::core::mem::free(ctx);
    }
}

<*
 Get the assembled piece data.

 Should only be called after verify() succeeds.

 @return "Piece data (view, not a copy)"
*>
fn char[] PieceAssembler.get_data(&self) @public
{
    return self.data;
}

<*
 Get progress statistics.

 @param total : "Output: total blocks"
 @param received : "Output: received blocks"
*>
fn void PieceAssembler.get_progress(&self, usz* total, usz* received) @public
{
    *total = self.total_blocks;
    *received = self.blocks_received;
}
