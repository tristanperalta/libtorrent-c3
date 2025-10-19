module libtorrent::piece_assembler;

import std::hash::sha1;
import std::io;

<*
 Piece Assembler and Verifier
 =============================
 Assembles blocks into a complete piece and verifies the SHA-1 hash.

 Usage:
   PieceAssembler assembler = create(piece_index, piece_length, expected_hash);
   defer free(&assembler);

   assembler.add_block(offset, data);
   assembler.add_block(offset2, data2);

   if (assembler.is_complete()) {
       fault? result = assembler.verify();
       if (!result) {
           // Hash verified! Piece is valid
           char[] piece_data = assembler.get_data();
       }
   }
*>

// Faults
faultdef PIECE_NOT_COMPLETE;
faultdef PIECE_HASH_MISMATCH;
faultdef BLOCK_INVALID_OFFSET;

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
 Verify the piece SHA-1 hash.

 Must only be called when is_complete() returns true.

 @return "Empty on success, fault if not complete or hash mismatch"
*>
fn fault? PieceAssembler.verify(&self) @public
{
    if (!self.is_complete())
    {
        return PIECE_NOT_COMPLETE?;
    }

    // Calculate SHA-1 hash
    char[20] actual_hash = sha1::hash(self.data);

    // Compare hashes
    for (usz i = 0; i < 20; i++)
    {
        if (actual_hash[i] != self.expected_hash[i])
        {
            return PIECE_HASH_MISMATCH?;
        }
    }

    return {};
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
