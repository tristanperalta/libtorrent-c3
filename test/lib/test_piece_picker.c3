module libtorrent::piece_picker::test;

import libtorrent::piece_picker;
import std::io;

// ============================================================================
// Creation and Initialization Tests
// ============================================================================

fn void test_create_picker() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(10);
    defer picker.free();

    assert(picker.num_pieces == 10, "Should track 10 pieces");
    assert(picker.pieces_complete == 0, "Should start with 0 complete");
    assert(picker.pieces_downloading == 0, "Should start with 0 downloading");
}

fn void test_initial_state_all_free() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    // All pieces should start as FREE
    for (usz i = 0; i < 5; i++)
    {
        assert(picker.pieces[i].state == piece_picker::PieceState.FREE, "Piece should start FREE");
        assert(picker.pieces[i].availability == 0, "Piece should start with 0 availability");
    }
}

fn void test_create_large_picker() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(10000);
    defer picker.free();

    assert(picker.num_pieces == 10000, "Should handle large number of pieces");
    assert(picker.pieces.len == 10000, "Should allocate correct array size");
}

// ============================================================================
// Peer Bitfield Update Tests
// ============================================================================

fn void test_update_peer_bitfield() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    // Peer has pieces 0, 2, 4
    bool[5] peer_pieces = {true, false, true, false, true};

    picker.update_peer_bitfield(peer_pieces[..])!!;

    assert(picker.get_availability(0) == 1, "Piece 0 availability should be 1");
    assert(picker.get_availability(1) == 0, "Piece 1 availability should be 0");
    assert(picker.get_availability(2) == 1, "Piece 2 availability should be 1");
    assert(picker.get_availability(3) == 0, "Piece 3 availability should be 0");
    assert(picker.get_availability(4) == 1, "Piece 4 availability should be 1");
}

fn void test_update_multiple_peers() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(3);
    defer picker.free();

    // Peer 1 has piece 0
    bool[3] peer1 = {true, false, false};
    picker.update_peer_bitfield(peer1[..])!!;

    // Peer 2 has pieces 0 and 1
    bool[3] peer2 = {true, true, false};
    picker.update_peer_bitfield(peer2[..])!!;

    // Peer 3 has all pieces
    bool[3] peer3 = {true, true, true};
    picker.update_peer_bitfield(peer3[..])!!;

    assert(picker.get_availability(0) == 3, "Piece 0 should have availability 3");
    assert(picker.get_availability(1) == 2, "Piece 1 should have availability 2");
    assert(picker.get_availability(2) == 1, "Piece 2 should have availability 1");
}

fn void test_update_bitfield_wrong_size() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    bool[3] wrong_size = {true, false, true};
    fault? result = picker.update_peer_bitfield(wrong_size[..]);

    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail on wrong bitfield size");
}

// ============================================================================
// Peer Has Piece Tests
// ============================================================================

fn void test_peer_has_piece() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    picker.peer_has_piece(2)!!;
    assert(picker.get_availability(2) == 1, "Piece 2 should have availability 1");

    picker.peer_has_piece(2)!!;
    assert(picker.get_availability(2) == 2, "Piece 2 should have availability 2");
}

fn void test_peer_has_piece_out_of_bounds() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    fault? result = picker.peer_has_piece(10);
    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail on out of bounds index");
}

// ============================================================================
// Rarest-First Piece Selection Tests
// ============================================================================

fn void test_pick_rarest_piece() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    // Set up availability: piece 0=3, 1=1, 2=2, 3=0, 4=1
    for (usz i = 0; i < 3; i++) picker.peer_has_piece(0)!!;
    for (usz i = 0; i < 1; i++) picker.peer_has_piece(1)!!;
    for (usz i = 0; i < 2; i++) picker.peer_has_piece(2)!!;
    for (usz i = 0; i < 1; i++) picker.peer_has_piece(4)!!;

    // Peer has pieces 0, 1, 2, 4 (not 3)
    bool[5] peer_pieces = {true, true, true, false, true};

    // Should pick piece 1 or 4 (both have availability 1)
    uint? piece_opt = picker.pick_piece(peer_pieces[..]);
    piece_opt!!;
    uint piece = piece_opt!!;

    assert(piece == 1 || piece == 4, "Should pick rarest piece (1 or 4)");
    assert(picker.get_availability(piece) == 1, "Picked piece should have lowest availability");
}

fn void test_pick_piece_skips_complete() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(3);
    defer picker.free();

    // All pieces have same availability
    bool[3] peer_pieces = {true, true, true};
    picker.update_peer_bitfield(peer_pieces[..])!!;

    // Mark piece 0 as complete
    picker.mark_complete(0)!!;

    // Should pick piece 1 or 2, not 0
    uint? piece_opt = picker.pick_piece(peer_pieces[..]);
    piece_opt!!;
    uint piece = piece_opt!!;

    assert(piece != 0, "Should not pick completed piece");
    assert(piece == 1 || piece == 2, "Should pick available piece");
}

fn void test_pick_piece_skips_downloading() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(3);
    defer picker.free();

    bool[3] peer_pieces = {true, true, true};
    picker.update_peer_bitfield(peer_pieces[..])!!;

    // Mark piece 1 as downloading
    picker.mark_downloading(1)!!;

    uint? piece_opt = picker.pick_piece(peer_pieces[..]);
    piece_opt!!;
    uint piece = piece_opt!!;

    assert(piece != 1, "Should not pick downloading piece");
    assert(piece == 0 || piece == 2, "Should pick free piece");
}

fn void test_pick_piece_no_available() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(3);
    defer picker.free();

    // Peer has no pieces
    bool[3] peer_pieces = {false, false, false};
    picker.update_peer_bitfield(peer_pieces[..])!!;

    uint? result = picker.pick_piece(peer_pieces[..]);
    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail when peer has no pieces we need");
}

fn void test_pick_piece_all_complete() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(3);
    defer picker.free();

    bool[3] peer_pieces = {true, true, true};
    picker.update_peer_bitfield(peer_pieces[..])!!;

    // Mark all pieces complete
    picker.mark_complete(0)!!;
    picker.mark_complete(1)!!;
    picker.mark_complete(2)!!;

    uint? result = picker.pick_piece(peer_pieces[..]);
    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail when all pieces are complete");
}

fn void test_pick_piece_wrong_bitfield_size() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    bool[3] wrong_size = {true, true, true};
    uint? result = picker.pick_piece(wrong_size[..]);

    if (catch excuse = result)
    {
        // Expected to fail
        return;
    }
    assert(false, "Should fail on wrong bitfield size");
}

// ============================================================================
// State Transition Tests
// ============================================================================

fn void test_mark_downloading() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    assert(picker.pieces_downloading == 0, "Should start with 0 downloading");

    picker.mark_downloading(2)!!;

    assert(picker.pieces[2].state == piece_picker::PieceState.DOWNLOADING, "Piece should be downloading");
    assert(picker.pieces_downloading == 1, "Should have 1 downloading");
}

fn void test_mark_complete() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    picker.mark_downloading(1)!!;
    assert(picker.pieces_downloading == 1, "Should have 1 downloading");
    assert(picker.pieces_complete == 0, "Should have 0 complete");

    picker.mark_complete(1)!!;

    assert(picker.pieces[1].state == piece_picker::PieceState.COMPLETE, "Piece should be complete");
    assert(picker.pieces_downloading == 0, "Should have 0 downloading");
    assert(picker.pieces_complete == 1, "Should have 1 complete");
}

fn void test_mark_free_from_downloading() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    picker.mark_downloading(3)!!;
    assert(picker.pieces_downloading == 1, "Should have 1 downloading");

    picker.mark_free(3)!!;

    assert(picker.pieces[3].state == piece_picker::PieceState.FREE, "Piece should be free");
    assert(picker.pieces_downloading == 0, "Should have 0 downloading");
}

fn void test_mark_complete_directly_from_free() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    // Can mark complete directly without marking downloading first
    picker.mark_complete(2)!!;

    assert(picker.pieces[2].state == piece_picker::PieceState.COMPLETE, "Piece should be complete");
    assert(picker.pieces_complete == 1, "Should have 1 complete");
}

// ============================================================================
// Query Tests
// ============================================================================

fn void test_have_piece() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    assert(!picker.have_piece(2), "Should not have piece initially");

    picker.mark_complete(2)!!;

    assert(picker.have_piece(2), "Should have piece after completion");
}

fn void test_is_complete() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(3);
    defer picker.free();

    assert(!picker.is_complete(), "Should not be complete initially");

    picker.mark_complete(0)!!;
    picker.mark_complete(1)!!;
    assert(!picker.is_complete(), "Should not be complete with 2/3 pieces");

    picker.mark_complete(2)!!;
    assert(picker.is_complete(), "Should be complete with all pieces");
}

fn void test_get_progress() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(10);
    defer picker.free();

    picker.mark_downloading(0)!!;
    picker.mark_downloading(1)!!;
    picker.mark_complete(5)!!;
    picker.mark_complete(6)!!;
    picker.mark_complete(7)!!;

    usz total, complete, downloading;
    picker.get_progress(&total, &complete, &downloading);

    assert(total == 10, "Total should be 10");
    assert(complete == 3, "Complete should be 3");
    assert(downloading == 2, "Downloading should be 2");
}

fn void test_get_availability() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    assert(picker.get_availability(0) == 0, "Should start with 0 availability");

    picker.peer_has_piece(0)!!;
    assert(picker.get_availability(0) == 1, "Should have availability 1");

    picker.peer_has_piece(0)!!;
    assert(picker.get_availability(0) == 2, "Should have availability 2");
}

fn void test_get_availability_out_of_bounds() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    uint avail = picker.get_availability(100);
    assert(avail == 0, "Out of bounds should return 0");
}

// ============================================================================
// Edge Cases
// ============================================================================

fn void test_empty_picker() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(0);
    defer picker.free();

    assert(picker.num_pieces == 0, "Should handle 0 pieces");
    assert(picker.is_complete(), "0 pieces means complete");
}

fn void test_single_piece() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(1);
    defer picker.free();

    bool[1] peer_pieces = {true};
    picker.update_peer_bitfield(peer_pieces[..])!!;

    uint? piece_opt = picker.pick_piece(peer_pieces[..]);
    piece_opt!!;
    assert(piece_opt!! == 0, "Should pick the only piece");

    picker.mark_complete(0)!!;
    assert(picker.is_complete(), "Should be complete");
}

fn void test_rarest_first_deterministic() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(5);
    defer picker.free();

    // Create distinct availability levels
    picker.peer_has_piece(0)!!;
    picker.peer_has_piece(0)!!;
    picker.peer_has_piece(0)!!; // availability 3

    picker.peer_has_piece(1)!!;
    picker.peer_has_piece(1)!!; // availability 2

    picker.peer_has_piece(2)!!; // availability 1

    // Piece 3 and 4 have availability 0

    // Peer has pieces 0, 1, 2
    bool[5] peer_pieces = {true, true, true, false, false};

    uint? piece_opt = picker.pick_piece(peer_pieces[..]);
    piece_opt!!;

    // Should pick piece 2 (lowest availability among available)
    assert(piece_opt!! == 2, "Should pick rarest available piece (piece 2)");
}

// ============================================================================
// Regression Tests for Real-World Scenarios
// ============================================================================

<*
 * Test the scenario that caused the "NO_PIECES_TO_REQUEST" bug:
 * 1. Fresh download (no pieces verified - all FREE)
 * 2. First peer connects and sends BITFIELD with all pieces
 * 3. Try to pick pieces - should succeed
 *
 * This reproduces the exact conditions from the Fedora torrent download bug.
 *>
fn void test_pick_piece_after_empty_verification() @test
{
    // Create picker with realistic number of pieces (similar to Fedora ISO)
    piece_picker::PiecePicker picker = piece_picker::create(9150);
    defer picker.free();

    // Verify initial state (like after failed verification of all pieces)
    assert(picker.pieces_complete == 0, "No pieces should be complete");
    assert(picker.pieces_downloading == 0, "No pieces should be downloading");

    // All pieces should be FREE with 0 availability
    for (usz i = 0; i < 5; i++)
    {
        assert(picker.pieces[i].state == piece_picker::PieceState.FREE,
               "Piece should be FREE after failed verification");
        assert(picker.pieces[i].availability == 0,
               "Piece should have 0 availability before any peers");
    }

    // Peer sends BITFIELD - has all pieces (like a seed)
    bool[] peer_pieces = mem::new_array(bool, 9150);
    defer free(peer_pieces);
    for (usz i = 0; i < 9150; i++)
    {
        peer_pieces[i] = true;
    }

    // Update availability
    picker.update_peer_bitfield(peer_pieces)!!;

    // Verify availability was updated
    for (usz i = 0; i < 5; i++)
    {
        assert(picker.pieces[i].availability == 1,
               "Piece availability should be 1 after BITFIELD");
    }

    // Try to pick a piece - THIS SHOULD SUCCEED
    uint? piece_opt = picker.pick_piece(peer_pieces);
    if (catch excuse = piece_opt)
    {
        assert(false, "Should be able to pick piece after BITFIELD (got fault)");
    }

    uint piece = piece_opt;
    assert(piece < 9150, "Picked piece should be valid");
    assert(picker.pieces[piece].state == piece_picker::PieceState.FREE,
           "Picked piece should still be FREE (not marked yet)");
}

<*
 * Test picking multiple pieces in sequence (filling download slots)
 *>
fn void test_pick_multiple_pieces_sequentially() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(100);
    defer picker.free();

    // Peer has all pieces
    bool[] peer_pieces = mem::new_array(bool, 100);
    defer free(peer_pieces);
    for (usz i = 0; i < 100; i++)
    {
        peer_pieces[i] = true;
    }
    picker.update_peer_bitfield(peer_pieces)!!;

    // Pick 5 pieces (simulating filling 5 download slots)
    uint[5] picked_pieces;
    for (usz i = 0; i < 5; i++)
    {
        uint? piece_opt = picker.pick_piece(peer_pieces);
        piece_opt!!;
        picked_pieces[i] = piece_opt!!;

        // Mark as downloading so it won't be picked again
        picker.mark_downloading(picked_pieces[i])!!;
    }

    // All picked pieces should be unique
    for (usz i = 0; i < 5; i++)
    {
        for (usz j = i + 1; j < 5; j++)
        {
            assert(picked_pieces[i] != picked_pieces[j],
                   "Each picked piece should be unique");
        }
    }

    // Should still be able to pick more pieces
    uint? next_piece = picker.pick_piece(peer_pieces);
    next_piece!!;

    // Verify it's not one we already picked
    bool is_duplicate = false;
    for (usz i = 0; i < 5; i++)
    {
        if (next_piece!! == picked_pieces[i])
        {
            is_duplicate = true;
            break;
        }
    }
    assert(!is_duplicate, "Should pick a new piece not already downloading");
}

<*
 * Test the scenario where all download slots are full
 * (this was causing misleading "NO_PIECES_TO_REQUEST" messages)
 *>
fn void test_pick_piece_when_all_downloading() @test
{
    piece_picker::PiecePicker picker = piece_picker::create(10);
    defer picker.free();

    bool[] peer_pieces = mem::new_array(bool, 10);
    defer free(peer_pieces);
    for (usz i = 0; i < 10; i++)
    {
        peer_pieces[i] = true;
    }
    picker.update_peer_bitfield(peer_pieces)!!;

    // Mark 5 pieces as downloading (simulating full download slots)
    for (usz i = 0; i < 5; i++)
    {
        picker.mark_downloading((uint)i)!!;
    }

    // Should still be able to pick from remaining 5 pieces
    uint? piece_opt = picker.pick_piece(peer_pieces);
    piece_opt!!;
    uint piece = piece_opt!!;

    assert(piece >= 5, "Should pick from pieces not downloading");
    assert(picker.pieces[piece].state == piece_picker::PieceState.FREE,
           "Picked piece should be FREE");
}
