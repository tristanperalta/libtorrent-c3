module libtorrent::bitfield;

import std::io;

<*
 Bitfield for tracking piece availability
 =========================================
 Efficiently tracks which pieces are available using bit manipulation.

 Each bit represents one piece:
 - 1 = piece is available
 - 0 = piece is not available

 Usage:
   Bitfield bf = create(100);  // Track 100 pieces
   defer free(bf);

   bf.set_piece(5);
   bool has = bf.has_piece(5);  // true
*>

// Bitfield structure for tracking piece availability.
// Uses a byte array where each bit represents one piece.
struct Bitfield
{
    char[] data;      // Byte array storing the bits
    usz num_pieces;   // Total number of pieces
}

<*
 Create a new bitfield for tracking pieces.

 @param num_pieces : "Number of pieces to track"
 @return "Initialized bitfield (caller must free)"
*>
fn Bitfield create(usz num_pieces) @public
{
    // Calculate how many bytes we need
    // Add 7 before dividing to round up
    usz num_bytes = (num_pieces + 7) / 8;

    Bitfield bf;
    bf.data = mem::new_array(char, num_bytes);
    bf.num_pieces = num_pieces;

    // Initialize all bits to 0 (no pieces)
    for (usz i = 0; i < num_bytes; i++) bf.data[i] = 0;

    return bf;
}

<*
 Free a bitfield's memory.

*>
fn void Bitfield.free(&self) @public
{
    if (self.data.len > 0)
    {
        std::core::mem::free(self.data);
        self.data = {};
    }
    self.num_pieces = 0;
}

<*
 Mark a piece as available (set bit to 1).

 @param index : "Piece index to set"
*>
fn void Bitfield.set_piece(&self, usz index) @public
{
    if (index >= self.num_pieces) return;

    usz byte_index = index / 8;
    usz bit_index = index % 8;

    // Set the bit (leftmost bit is piece 0)
    self.data[byte_index] |= (char)(1 << (7 - bit_index));
}

<*
 Mark a piece as unavailable (set bit to 0).

 @param index : "Piece index to clear"
*>
fn void Bitfield.clear_piece(&self, usz index) @public
{
    if (index >= self.num_pieces) return;

    usz byte_index = index / 8;
    usz bit_index = index % 8;

    // Clear the bit
    self.data[byte_index] &= ~((char)(1 << (7 - bit_index)));
}

<*
 Check if a piece is available.

 @param index : "Piece index to check"
 @return "True if piece is available"
*>
fn bool Bitfield.has_piece(&self, usz index) @public
{
    if (index >= self.num_pieces) return false;

    usz byte_index = index / 8;
    usz bit_index = index % 8;

    // Check the bit
    return (self.data[byte_index] & (char)(1 << (7 - bit_index))) != 0;
}

<*
 Get the raw byte array for sending in BITFIELD message.

 @return "Byte array view (does not need to be freed)"
*>
fn char[] Bitfield.to_bytes(&self) @public
{
    return self.data;
}

<*
 Create a bitfield from received bytes (BITFIELD message).

 @param data : "Byte array from BITFIELD message"
 @param num_pieces : "Total number of pieces in torrent"
 @return "Initialized bitfield (caller must free)"
*>
fn Bitfield from_bytes(char[] data, usz num_pieces) @public
{
    Bitfield bf;
    bf.num_pieces = num_pieces;

    // Calculate expected size
    usz expected_bytes = (num_pieces + 7) / 8;

    // Allocate buffer
    bf.data = mem::new_array(char, expected_bytes);

    // Copy available data
    usz copy_len = data.len < expected_bytes ? data.len : expected_bytes;
    for (usz i = 0; i < copy_len; i++)
    {
        bf.data[i] = data[i];
    }

    // Zero-fill remaining bytes if data was too short
    for (usz i = copy_len; i < expected_bytes; i++)
    {
        bf.data[i] = 0;
    }

    return bf;
}

<*
 Count how many pieces are available.

 @return "Number of pieces marked as available"
*>
fn usz Bitfield.count_pieces(&self) @public
{
    usz count = 0;

    for (usz i = 0; i < self.num_pieces; i++)
    {
        if (self.has_piece(i)) count++;
    }

    return count;
}

<*
 Set all pieces to available.

*>
fn void Bitfield.set_all(&self) @public
{
    for (usz i = 0; i < self.data.len; i++) self.data[i] = (char)0xFF;

    // Clear any extra bits in the last byte
    usz num_bytes = (self.num_pieces + 7) / 8;
    if (num_bytes > 0)
    {
        usz bits_in_last_byte = self.num_pieces % 8;
        if (bits_in_last_byte != 0)
        {
            // Create a mask for the valid bits in the last byte
            char mask = (char)((0xFF << (8 - bits_in_last_byte)) & 0xFF);
            self.data[num_bytes - 1] &= mask;
        }
    }
}

<*
 Clear all pieces to unavailable.

*>
fn void Bitfield.clear_all(&self) @public
{
    for (usz i = 0; i < self.data.len; i++) self.data[i] = 0;
}

<*
 Check if bitfield is completely empty (no pieces).

 @return "True if no pieces are available"
*>
fn bool Bitfield.is_empty(&self) @public
{
    foreach (b : self.data)
    {
        if (b != 0) return false;
    }
    return true;
}

<*
 Check if bitfield is completely full (all pieces).

 @return "True if all pieces are available"
*>
fn bool Bitfield.is_full(&self) @public
{
    return self.count_pieces() == self.num_pieces;
}
