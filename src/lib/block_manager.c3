module libtorrent::block_manager;

import std::io;
import std::time;

<*
 Block Manager - Request and Assembly
 ====================================
 Manages block-level requests and assembly for a single piece.

 BitTorrent pieces are typically large (256KB-16MB), so they're downloaded
 in 16KB blocks. This module tracks which blocks have been requested and
 received, and assembles them into a complete piece.

 Usage:
   BlockManager manager = create(piece_index, piece_length);
   defer free(&manager);

   BlockRequest? req = manager.get_next_block(peer_id);
   if (req) {
       // Send REQUEST message to peer
   }

   manager.mark_received(offset, block_data);
   if (manager.is_complete()) {
       char[] piece = manager.assemble_piece();
   }
*>

// Constants
const uint BLOCK_SIZE = 16384;  // 16KB standard block size (2^14)

// Faults
faultdef BLOCK_ALREADY_RECEIVED;
faultdef BLOCK_INVALID_OFFSET;
faultdef PIECE_NOT_COMPLETE;
faultdef NO_BLOCKS_AVAILABLE;

// Block state
enum BlockState : const char
{
    FREE = 0,       // Not requested yet
    REQUESTED = 1,  // Requested but not received
    RECEIVED = 2    // Received and stored
}

// Information about a single block
struct BlockInfo
{
    uint offset;          // Offset within piece
    uint length;          // Block length (last block may be shorter)
    BlockState state;     // Current state
    char[] data;          // Block data (empty if not received)
    long request_time;    // When requested (seconds since epoch)
}

// A block request to send to a peer
struct BlockRequest
{
    uint piece_index;    // Piece index
    uint offset;         // Block offset within piece
    uint length;         // Block length
}

// Block manager for one piece
struct BlockManager
{
    uint piece_index;     // Index of this piece
    uint piece_length;    // Total length of piece
    BlockInfo[] blocks;   // Array of blocks
    usz num_blocks;       // Total number of blocks
    usz blocks_received;  // Count of received blocks
}

<*
 Create a block manager for a piece.

 @param piece_index : "Index of the piece"
 @param piece_length : "Total length of the piece in bytes"
 @return "Initialized block manager"
*>
fn BlockManager create(uint piece_index, uint piece_length) @public
{
    BlockManager manager;
    manager.piece_index = piece_index;
    manager.piece_length = piece_length;
    manager.blocks_received = 0;

    // Calculate number of blocks
    manager.num_blocks = (usz)((piece_length + BLOCK_SIZE - 1) / BLOCK_SIZE);

    // Allocate blocks
    manager.blocks = mem::new_array(BlockInfo, manager.num_blocks);

    // Initialize blocks
    for (usz i = 0; i < manager.num_blocks; i++)
    {
        uint offset = (uint)(i * BLOCK_SIZE);
        uint length = BLOCK_SIZE;

        // Last block may be shorter
        if (offset + length > piece_length)
        {
            length = piece_length - offset;
        }

        manager.blocks[i].offset = offset;
        manager.blocks[i].length = length;
        manager.blocks[i].state = BlockState.FREE;
        manager.blocks[i].data = {};
        manager.blocks[i].request_time = 0;
    }

    return manager;
}

<*
 Free a block manager.

 @param manager : "Block manager to free"
*>
fn void free(BlockManager* manager) @public
{
    // Free block data
    for (usz i = 0; i < manager.num_blocks; i++)
    {
        if (manager.blocks[i].data.len > 0)
        {
            std::core::mem::free(manager.blocks[i].data);
            manager.blocks[i].data = {};
        }
    }

    // Free blocks array
    if (manager.blocks.len > 0)
    {
        std::core::mem::free(manager.blocks);
        manager.blocks = {};
    }

    manager.num_blocks = 0;
}

<*
 Get the next block to request.

 Returns the next FREE block to request. If all blocks are requested
 or received, returns empty optional.

 @return "Block request, or empty if no blocks available"
*>
fn BlockRequest? BlockManager.get_next_block(&self) @public
{
    for (usz i = 0; i < self.num_blocks; i++)
    {
        if (self.blocks[i].state == BlockState.FREE)
        {
            BlockRequest req;
            req.piece_index = self.piece_index;
            req.offset = self.blocks[i].offset;
            req.length = self.blocks[i].length;
            return req;
        }
    }

    // No free blocks - return fault
    return NO_BLOCKS_AVAILABLE?;
}

<*
 Mark a block as requested.

 @param offset : "Block offset within piece"
 @return "Fault if offset is invalid"
*>
fn fault? BlockManager.mark_requested(&self, uint offset) @public
{
    // Find block with this offset
    for (usz i = 0; i < self.num_blocks; i++)
    {
        if (self.blocks[i].offset == offset)
        {
            self.blocks[i].state = BlockState.REQUESTED;
            self.blocks[i].request_time = (long)time::now().to_seconds();
            return {};
        }
    }

    return BLOCK_INVALID_OFFSET?;
}

<*
 Mark a block as received and store its data.

 @param offset : "Block offset within piece"
 @param data : "Block data (will be copied)"
 @return "Fault if offset invalid or block already received"
*>
fn fault? BlockManager.mark_received(&self, uint offset, char[] data) @public
{
    // Find block with this offset
    for (usz i = 0; i < self.num_blocks; i++)
    {
        if (self.blocks[i].offset == offset)
        {
            // Check if already received
            if (self.blocks[i].state == BlockState.RECEIVED)
            {
                return BLOCK_ALREADY_RECEIVED?;
            }

            // Verify data length matches expected length
            if (data.len != self.blocks[i].length)
            {
                return BLOCK_INVALID_OFFSET?;
            }

            // Copy block data
            self.blocks[i].data = mem::new_array(char, data.len);
            for (usz j = 0; j < data.len; j++)
            {
                self.blocks[i].data[j] = data[j];
            }

            // Update state
            BlockState old_state = self.blocks[i].state;
            self.blocks[i].state = BlockState.RECEIVED;

            if (old_state != BlockState.RECEIVED)
            {
                self.blocks_received++;
            }

            return {};
        }
    }

    return BLOCK_INVALID_OFFSET?;
}

<*
 Check if all blocks have been received.

 @return "True if piece is complete"
*>
fn bool BlockManager.is_complete(&self) @public
{
    return self.blocks_received == self.num_blocks;
}

<*
 Assemble all blocks into a complete piece.

 Must only be called when is_complete() returns true.

 @return "Complete piece data, or fault if not complete"
*>
fn char[]? BlockManager.assemble_piece(&self) @public
{
    if (!self.is_complete())
    {
        return PIECE_NOT_COMPLETE?;
    }

    // Allocate buffer for complete piece
    char[] piece = mem::new_array(char, self.piece_length);

    // Copy blocks into piece
    for (usz i = 0; i < self.num_blocks; i++)
    {
        uint offset = self.blocks[i].offset;
        char[] block_data = self.blocks[i].data;

        for (usz j = 0; j < block_data.len; j++)
        {
            piece[offset + j] = block_data[j];
        }
    }

    return piece;
}

<*
 Get progress statistics.

 @param total : "Output: total blocks"
 @param received : "Output: received blocks"
*>
fn void BlockManager.get_progress(&self, usz* total, usz* received) @public
{
    *total = self.num_blocks;
    *received = self.blocks_received;
}

<*
 Check if a block has been received.

 @param offset : "Block offset"
 @return "True if block has been received"
*>
fn bool BlockManager.is_received(&self, uint offset) @public
{
    for (usz i = 0; i < self.num_blocks; i++)
    {
        if (self.blocks[i].offset == offset)
        {
            return self.blocks[i].state == BlockState.RECEIVED;
        }
    }
    return false;
}

<*
 Reset a block to FREE state (e.g., if request times out).

 @param offset : "Block offset"
 @return "Fault if offset invalid"
*>
fn fault? BlockManager.reset_block(&self, uint offset) @public
{
    for (usz i = 0; i < self.num_blocks; i++)
    {
        if (self.blocks[i].offset == offset)
        {
            // Free data if it was received
            if (self.blocks[i].data.len > 0)
            {
                if (self.blocks[i].state == BlockState.RECEIVED)
                {
                    self.blocks_received--;
                }
                std::core::mem::free(self.blocks[i].data);
                self.blocks[i].data = {};
            }

            self.blocks[i].state = BlockState.FREE;
            self.blocks[i].request_time = 0;
            return {};
        }
    }

    return BLOCK_INVALID_OFFSET?;
}

<*
 Get time since block was requested (in seconds).

 @param offset : "Block offset"
 @return "Seconds since request, or 0 if not requested"
*>
fn long BlockManager.time_since_request(&self, uint offset) @public
{
    long now = (long)time::now().to_seconds();

    for (usz i = 0; i < self.num_blocks; i++)
    {
        if (self.blocks[i].offset == offset)
        {
            if (self.blocks[i].state == BlockState.REQUESTED && self.blocks[i].request_time > 0)
            {
                return now - self.blocks[i].request_time;
            }
            return 0;
        }
    }

    return 0;
}
