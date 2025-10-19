module libtorrent::bitfield::test;

import libtorrent::bitfield;
import std::io;

// ============================================================================
// Creation and Basic Tests
// ============================================================================

fn void test_create_bitfield() @test
{
    bitfield::Bitfield bf = bitfield::create(100);
    defer bitfield::free(&bf);

    assert(bf.num_pieces == 100, "Should track 100 pieces");
    assert(bf.data.len == 13, "Should allocate 13 bytes for 100 pieces");
}

fn void test_create_exact_byte_boundary() @test
{
    bitfield::Bitfield bf = bitfield::create(8);
    defer bitfield::free(&bf);

    assert(bf.num_pieces == 8, "Should track 8 pieces");
    assert(bf.data.len == 1, "Should allocate exactly 1 byte");
}

fn void test_create_empty() @test
{
    bitfield::Bitfield bf = bitfield::create(0);
    defer bitfield::free(&bf);

    assert(bf.num_pieces == 0, "Should track 0 pieces");
    assert(bf.data.len == 0, "Should allocate 0 bytes");
}

// ============================================================================
// Set and Has Piece Tests
// ============================================================================

fn void test_set_and_has_piece() @test
{
    bitfield::Bitfield bf = bitfield::create(100);
    defer bitfield::free(&bf);

    // Initially should not have any pieces
    assert(!bf.has_piece(0), "Should not have piece 0 initially");
    assert(!bf.has_piece(50), "Should not have piece 50 initially");

    // Set some pieces
    bf.set_piece(0);
    bf.set_piece(7);   // Last bit of first byte
    bf.set_piece(8);   // First bit of second byte
    bf.set_piece(50);
    bf.set_piece(99);  // Last piece

    // Verify they're set
    assert(bf.has_piece(0), "Should have piece 0");
    assert(bf.has_piece(7), "Should have piece 7");
    assert(bf.has_piece(8), "Should have piece 8");
    assert(bf.has_piece(50), "Should have piece 50");
    assert(bf.has_piece(99), "Should have piece 99");

    // Verify others are not set
    assert(!bf.has_piece(1), "Should not have piece 1");
    assert(!bf.has_piece(6), "Should not have piece 6");
    assert(!bf.has_piece(9), "Should not have piece 9");
    assert(!bf.has_piece(51), "Should not have piece 51");
}

fn void test_set_out_of_bounds() @test
{
    bitfield::Bitfield bf = bitfield::create(10);
    defer bitfield::free(&bf);

    // Should not crash when setting out of bounds
    bf.set_piece(10);  // index == num_pieces
    bf.set_piece(100); // way out of bounds

    // Should still be all zeros
    assert(bf.is_empty(), "Should still be empty");
}

fn void test_has_out_of_bounds() @test
{
    bitfield::Bitfield bf = bitfield::create(10);
    defer bitfield::free(&bf);

    // Out of bounds should return false
    assert(!bf.has_piece(10), "Out of bounds should return false");
    assert(!bf.has_piece(100), "Way out of bounds should return false");
}

// ============================================================================
// Clear Piece Tests
// ============================================================================

fn void test_clear_piece() @test
{
    bitfield::Bitfield bf = bitfield::create(100);
    defer bitfield::free(&bf);

    // Set a piece then clear it
    bf.set_piece(42);
    assert(bf.has_piece(42), "Should have piece 42");

    bf.clear_piece(42);
    assert(!bf.has_piece(42), "Should not have piece 42 after clear");
}

fn void test_clear_multiple_pieces() @test
{
    bitfield::Bitfield bf = bitfield::create(100);
    defer bitfield::free(&bf);

    // Set several pieces
    bf.set_piece(0);
    bf.set_piece(7);
    bf.set_piece(8);
    bf.set_piece(50);

    // Clear some of them
    bf.clear_piece(0);
    bf.clear_piece(8);

    // Verify state
    assert(!bf.has_piece(0), "Piece 0 should be cleared");
    assert(bf.has_piece(7), "Piece 7 should still be set");
    assert(!bf.has_piece(8), "Piece 8 should be cleared");
    assert(bf.has_piece(50), "Piece 50 should still be set");
}

// ============================================================================
// Byte Conversion Tests
// ============================================================================

fn void test_to_bytes() @test
{
    bitfield::Bitfield bf = bitfield::create(8);
    defer bitfield::free(&bf);

    // Set pieces 0, 2, 7 (bits: 10100001)
    bf.set_piece(0);
    bf.set_piece(2);
    bf.set_piece(7);

    char[] bytes = bf.to_bytes();
    assert(bytes.len == 1, "Should be 1 byte");
    assert(bytes[0] == (char)0xA1, "Byte should be 0xA1");
}

fn void test_from_bytes() @test
{
    char[2] data;
    data[0] = (char)0xFF;  // All 8 pieces in first byte
    data[1] = (char)0x80;  // Only first piece in second byte

    bitfield::Bitfield bf = bitfield::from_bytes(data[..], 16);
    defer bitfield::free(&bf);

    // Check first byte pieces (0-7)
    for (usz i = 0; i < 8; i++)
    {
        assert(bf.has_piece(i), "First 8 pieces should be set");
    }

    // Check second byte
    assert(bf.has_piece(8), "Piece 8 should be set");
    for (usz i = 9; i < 16; i++)
    {
        assert(!bf.has_piece(i), "Pieces 9-15 should not be set");
    }
}

fn void test_from_bytes_short_data() @test
{
    char[1] data;
    data[0] = (char)0xFF;

    // Request more pieces than data provides
    bitfield::Bitfield bf = bitfield::from_bytes(data[..], 16);
    defer bitfield::free(&bf);

    // First 8 should be set
    for (usz i = 0; i < 8; i++)
    {
        assert(bf.has_piece(i), "First 8 pieces should be set");
    }

    // Rest should be zero
    for (usz i = 8; i < 16; i++)
    {
        assert(!bf.has_piece(i), "Remaining pieces should not be set");
    }
}

// ============================================================================
// Count Pieces Tests
// ============================================================================

fn void test_count_pieces_empty() @test
{
    bitfield::Bitfield bf = bitfield::create(100);
    defer bitfield::free(&bf);

    assert(bf.count_pieces() == 0, "Empty bitfield should have 0 pieces");
}

fn void test_count_pieces() @test
{
    bitfield::Bitfield bf = bitfield::create(100);
    defer bitfield::free(&bf);

    bf.set_piece(0);
    bf.set_piece(50);
    bf.set_piece(99);

    assert(bf.count_pieces() == 3, "Should have 3 pieces");
}

fn void test_count_pieces_full() @test
{
    bitfield::Bitfield bf = bitfield::create(10);
    defer bitfield::free(&bf);

    for (usz i = 0; i < 10; i++)
    {
        bf.set_piece(i);
    }

    assert(bf.count_pieces() == 10, "Should have all 10 pieces");
}

// ============================================================================
// Set All / Clear All Tests
// ============================================================================

fn void test_set_all() @test
{
    bitfield::Bitfield bf = bitfield::create(100);
    defer bitfield::free(&bf);

    bf.set_all();

    // All pieces should be set
    for (usz i = 0; i < 100; i++)
    {
        assert(bf.has_piece(i), "All pieces should be set");
    }

    assert(bf.count_pieces() == 100, "Should count all 100 pieces");
    assert(bf.is_full(), "Should be full");
}

fn void test_set_all_non_byte_boundary() @test
{
    bitfield::Bitfield bf = bitfield::create(10);  // 10 pieces = 2 bytes, but only 2 bits in second byte
    defer bitfield::free(&bf);

    bf.set_all();

    // All 10 pieces should be set
    for (usz i = 0; i < 10; i++)
    {
        assert(bf.has_piece(i), "Piece should be set");
    }

    // Extra bits in last byte should NOT be set
    char[] bytes = bf.to_bytes();
    // First byte should be 0xFF
    assert(bytes[0] == (char)0xFF, "First byte should be 0xFF");
    // Second byte should be 0xC0 (11000000 - only first 2 bits)
    assert(bytes[1] == (char)0xC0, "Second byte should be 0xC0");
}

fn void test_clear_all() @test
{
    bitfield::Bitfield bf = bitfield::create(100);
    defer bitfield::free(&bf);

    // Set some pieces then clear all
    bf.set_piece(0);
    bf.set_piece(50);
    bf.set_piece(99);

    bf.clear_all();

    // All pieces should be cleared
    for (usz i = 0; i < 100; i++)
    {
        assert(!bf.has_piece(i), "All pieces should be cleared");
    }

    assert(bf.count_pieces() == 0, "Should count 0 pieces");
    assert(bf.is_empty(), "Should be empty");
}

// ============================================================================
// Is Empty / Is Full Tests
// ============================================================================

fn void test_is_empty_initially() @test
{
    bitfield::Bitfield bf = bitfield::create(100);
    defer bitfield::free(&bf);

    assert(bf.is_empty(), "New bitfield should be empty");
}

fn void test_is_empty_after_set() @test
{
    bitfield::Bitfield bf = bitfield::create(100);
    defer bitfield::free(&bf);

    bf.set_piece(50);
    assert(!bf.is_empty(), "Bitfield with one piece should not be empty");
}

fn void test_is_full_after_set_all() @test
{
    bitfield::Bitfield bf = bitfield::create(100);
    defer bitfield::free(&bf);

    bf.set_all();
    assert(bf.is_full(), "Bitfield with all pieces should be full");
}

fn void test_is_not_full() @test
{
    bitfield::Bitfield bf = bitfield::create(100);
    defer bitfield::free(&bf);

    // Set all but one piece
    for (usz i = 0; i < 99; i++)
    {
        bf.set_piece(i);
    }

    assert(!bf.is_full(), "Bitfield missing one piece should not be full");
}

// ============================================================================
// Edge Case Tests
// ============================================================================

fn void test_single_piece() @test
{
    bitfield::Bitfield bf = bitfield::create(1);
    defer bitfield::free(&bf);

    assert(!bf.has_piece(0), "Should not have piece initially");

    bf.set_piece(0);
    assert(bf.has_piece(0), "Should have piece after set");
    assert(bf.count_pieces() == 1, "Should count 1 piece");

    bf.clear_piece(0);
    assert(!bf.has_piece(0), "Should not have piece after clear");
}

fn void test_many_pieces() @test
{
    bitfield::Bitfield bf = bitfield::create(10000);
    defer bitfield::free(&bf);

    assert(bf.data.len == 1250, "Should allocate correct bytes for 10000 pieces");

    // Set some pieces at various positions
    bf.set_piece(0);
    bf.set_piece(5000);
    bf.set_piece(9999);

    assert(bf.has_piece(0), "Should have piece 0");
    assert(bf.has_piece(5000), "Should have piece 5000");
    assert(bf.has_piece(9999), "Should have piece 9999");
    assert(bf.count_pieces() == 3, "Should count 3 pieces");
}

fn void test_all_bits_in_byte() @test
{
    bitfield::Bitfield bf = bitfield::create(8);
    defer bitfield::free(&bf);

    // Set each bit one by one
    for (usz i = 0; i < 8; i++)
    {
        bf.set_piece(i);
        assert(bf.has_piece(i), "Piece should be set");
    }

    char[] bytes = bf.to_bytes();
    assert(bytes[0] == (char)0xFF, "All bits should be set (0xFF)");
}

fn void test_roundtrip_conversion() @test
{
    bitfield::Bitfield bf1 = bitfield::create(100);
    defer bitfield::free(&bf1);

    // Set various pieces
    bf1.set_piece(0);
    bf1.set_piece(7);
    bf1.set_piece(8);
    bf1.set_piece(50);
    bf1.set_piece(99);

    // Convert to bytes
    char[] bytes = bf1.to_bytes();

    // Create new bitfield from bytes
    bitfield::Bitfield bf2 = bitfield::from_bytes(bytes, 100);
    defer bitfield::free(&bf2);

    // Should have same pieces
    assert(bf2.has_piece(0), "Should have piece 0");
    assert(bf2.has_piece(7), "Should have piece 7");
    assert(bf2.has_piece(8), "Should have piece 8");
    assert(bf2.has_piece(50), "Should have piece 50");
    assert(bf2.has_piece(99), "Should have piece 99");

    // Should not have others
    assert(!bf2.has_piece(1), "Should not have piece 1");
    assert(!bf2.has_piece(51), "Should not have piece 51");

    assert(bf2.count_pieces() == 5, "Should have same count");
}
