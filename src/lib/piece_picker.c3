module libtorrent::piece_picker;

import std::io;
import std::collections::list;

<*
 Piece Picker - Rarest-First Algorithm
 ======================================
 Selects which pieces to download from which peers using the rarest-first
 strategy to maximize swarm efficiency.

 The rarest-first algorithm prioritizes downloading pieces that the fewest
 peers have, which helps distribute rare pieces throughout the swarm.

 Usage:
   PiecePicker picker = create(num_pieces);
   defer free(&picker);

   picker.update_peer_pieces(peer_id, bitfield);
   uint? piece = picker.pick_piece(peer_id);
   if (piece) {
       // Download piece from peer
       picker.mark_downloading(piece!!);
   }
*>

// State of a piece in the picker.
enum PieceState : const char
{
    FREE = 0,         // Not requested yet
    DOWNLOADING = 1,  // Currently being downloaded
    COMPLETE = 2      // Downloaded and verified
}

// Information about a single piece.
struct PieceInfo
{
    uint availability;  // How many peers have this piece
    PieceState state;   // Current state
}

// Piece picker state.
struct PiecePicker
{
    PieceInfo[] pieces;      // Info about each piece
    usz num_pieces;          // Total number of pieces
    usz pieces_complete;     // Count of completed pieces
    usz pieces_downloading;  // Count of pieces being downloaded
}

// Faults
faultdef PIECE_INDEX_OUT_OF_BOUNDS;
faultdef NO_PIECES_AVAILABLE;

<*
 Create a new piece picker.

 @param num_pieces : "Total number of pieces in torrent"
 @return "Initialized piece picker"
*>
fn PiecePicker create(usz num_pieces) @public
{
    PiecePicker picker;
    picker.num_pieces = num_pieces;
    picker.pieces_complete = 0;
    picker.pieces_downloading = 0;

    // Allocate and initialize piece info
    picker.pieces = mem::new_array(PieceInfo, num_pieces);
    for (usz i = 0; i < num_pieces; i++)
    {
        picker.pieces[i].availability = 0;
        picker.pieces[i].state = PieceState.FREE;
    }

    return picker;
}

<*
 Free a piece picker.

 @param picker : "Piece picker to free"
*>
fn void free(PiecePicker* picker) @public
{
    if (picker.pieces.len > 0)
    {
        std::core::mem::free(picker.pieces);
        picker.pieces = {};
    }
    picker.num_pieces = 0;
}

<*
 Update which pieces a peer has (from BITFIELD message).

 @param peer_pieces : "Bitfield of pieces the peer has (true = has piece)"
 @return "Fault if bitfield size doesn't match"
*>
fn fault? PiecePicker.update_peer_bitfield(&self, bool[] peer_pieces) @public
{
    if (peer_pieces.len != self.num_pieces)
    {
        return PIECE_INDEX_OUT_OF_BOUNDS?;
    }

    // Update availability for each piece
    for (usz i = 0; i < self.num_pieces; i++)
    {
        if (peer_pieces[i])
        {
            self.pieces[i].availability++;
        }
    }

    return {};
}

<*
 Mark that a peer has a specific piece (from HAVE message).

 @param piece_index : "Index of piece the peer has"
 @return "Fault if index out of bounds"
*>
fn fault? PiecePicker.peer_has_piece(&self, uint piece_index) @public
{
    if (piece_index >= self.num_pieces)
    {
        return PIECE_INDEX_OUT_OF_BOUNDS?;
    }

    self.pieces[piece_index].availability++;
    return {};
}

<*
 Pick the next piece to download from a peer using rarest-first algorithm.

 Selects the rarest piece (lowest availability) that:
 - The peer has
 - We don't have (not complete or downloading)

 @param peer_pieces : "Bitfield of pieces the peer has"
 @return "Piece index to download, or fault if no pieces available"
*>
fn uint? PiecePicker.pick_piece(&self, bool[] peer_pieces) @public
{
    if (peer_pieces.len != self.num_pieces)
    {
        return PIECE_INDEX_OUT_OF_BOUNDS?;
    }

    // Find rarest piece the peer has that we need
    uint best_piece_index = 0;
    uint lowest_availability = uint.max;
    bool found = false;

    for (usz i = 0; i < self.num_pieces; i++)
    {
        // Skip if peer doesn't have this piece
        if (!peer_pieces[i]) continue;

        // Skip if we already have or are downloading
        if (self.pieces[i].state != PieceState.FREE) continue;

        // Check if this is rarer than current best
        if (self.pieces[i].availability < lowest_availability)
        {
            lowest_availability = self.pieces[i].availability;
            best_piece_index = (uint)i;
            found = true;
        }
    }

    if (!found)
    {
        return NO_PIECES_AVAILABLE?;
    }

    return best_piece_index;
}

<*
 Mark a piece as currently being downloaded.

 @param piece_index : "Index of piece"
 @return "Fault if index out of bounds or piece already complete"
*>
fn fault? PiecePicker.mark_downloading(&self, uint piece_index) @public
{
    if (piece_index >= self.num_pieces)
    {
        return PIECE_INDEX_OUT_OF_BOUNDS?;
    }

    if (self.pieces[piece_index].state == PieceState.FREE)
    {
        self.pieces[piece_index].state = PieceState.DOWNLOADING;
        self.pieces_downloading++;
    }

    return {};
}

<*
 Mark a piece as complete (downloaded and verified).

 @param piece_index : "Index of piece"
 @return "Fault if index out of bounds"
*>
fn fault? PiecePicker.mark_complete(&self, uint piece_index) @public
{
    if (piece_index >= self.num_pieces)
    {
        return PIECE_INDEX_OUT_OF_BOUNDS?;
    }

    PieceState old_state = self.pieces[piece_index].state;
    self.pieces[piece_index].state = PieceState.COMPLETE;

    // Update counters
    if (old_state == PieceState.DOWNLOADING)
    {
        self.pieces_downloading--;
    }
    if (old_state != PieceState.COMPLETE)
    {
        self.pieces_complete++;
    }

    return {};
}

<*
 Mark a piece as free (e.g., if download failed).

 @param piece_index : "Index of piece"
 @return "Fault if index out of bounds"
*>
fn fault? PiecePicker.mark_free(&self, uint piece_index) @public
{
    if (piece_index >= self.num_pieces)
    {
        return PIECE_INDEX_OUT_OF_BOUNDS?;
    }

    if (self.pieces[piece_index].state == PieceState.DOWNLOADING)
    {
        self.pieces_downloading--;
    }

    self.pieces[piece_index].state = PieceState.FREE;
    return {};
}

<*
 Check if we have a specific piece.

 @param piece_index : "Index of piece"
 @return "True if we have the piece"
*>
fn bool PiecePicker.have_piece(&self, uint piece_index) @public
{
    if (piece_index >= self.num_pieces) return false;
    return self.pieces[piece_index].state == PieceState.COMPLETE;
}

<*
 Check if all pieces are complete.

 @return "True if download is complete"
*>
fn bool PiecePicker.is_complete(&self) @public
{
    return self.pieces_complete == self.num_pieces;
}

<*
 Get download progress statistics.

 @param total : "Output: total pieces"
 @param complete : "Output: completed pieces"
 @param downloading : "Output: pieces being downloaded"
*>
fn void PiecePicker.get_progress(&self, usz* total, usz* complete, usz* downloading) @public
{
    *total = self.num_pieces;
    *complete = self.pieces_complete;
    *downloading = self.pieces_downloading;
}

<*
 Get availability count for a piece.

 @param piece_index : "Index of piece"
 @return "Number of peers that have this piece, or 0 if out of bounds"
*>
fn uint PiecePicker.get_availability(&self, uint piece_index) @public
{
    if (piece_index >= self.num_pieces) return 0;
    return self.pieces[piece_index].availability;
}
