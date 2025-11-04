module libtorrent::metadata_exchange::test;

import libtorrent::metadata_exchange;
import libtorrent::bencode;
import std::io;

/**
 * BEP 9: Metadata Exchange Protocol Tests
 * ========================================
 *
 * Tests for encoding/decoding ut_metadata messages (REQUEST, DATA, REJECT)
 */

// ============================================================================
// Utility Function Tests
// ============================================================================

fn void test_calculate_num_pieces() @test
{
    // Exact multiple of piece size
    assert(metadata_exchange::calculate_num_pieces(16384) == 1, "16KB should be 1 piece");
    assert(metadata_exchange::calculate_num_pieces(32768) == 2, "32KB should be 2 pieces");

    // Non-exact multiple
    assert(metadata_exchange::calculate_num_pieces(16385) == 2, "16KB + 1 byte should be 2 pieces");
    assert(metadata_exchange::calculate_num_pieces(20000) == 2, "20KB should be 2 pieces");

    // Zero size
    assert(metadata_exchange::calculate_num_pieces(0) == 0, "0 bytes should be 0 pieces");

    // Small size
    assert(metadata_exchange::calculate_num_pieces(100) == 1, "100 bytes should be 1 piece");

    io::printn("Piece calculation works correctly ✓");
}

fn void test_get_piece_size() @test
{
    uint total_size = 50000;  // 4 pieces: 16KB + 16KB + 16KB + 848 bytes

    // First three pieces: full 16KB each
    assert(metadata_exchange::get_piece_size(0, total_size) == 16384, "First piece should be 16KB");
    assert(metadata_exchange::get_piece_size(1, total_size) == 16384, "Second piece should be 16KB");
    assert(metadata_exchange::get_piece_size(2, total_size) == 16384, "Third piece should be 16KB");

    // Fourth piece (last): remainder (50000 - 49152 = 848)
    uint last_piece_size = metadata_exchange::get_piece_size(3, total_size);
    assert(last_piece_size == 848, "Last piece should be 848 bytes");

    // Invalid piece index
    assert(metadata_exchange::get_piece_size(4, total_size) == 0, "Invalid piece should return 0");

    io::printn("Piece size calculation works correctly ✓");
}

// ============================================================================
// REQUEST Message Tests
// ============================================================================

fn void test_request_encode() @test
{
    char[] msg = metadata_exchange::encode_request(5);
    defer free(msg);

    // Should be: d8:msg_typei0e5:piecei5ee
    String expected = "d8:msg_typei0e5:piecei5ee";

    assert(msg.len == expected.len, "Request message should have correct length");

    for (usz i = 0; i < expected.len; i++)
    {
        assert(msg[i] == expected[i], "Request message bytes should match");
    }

    io::printn("REQUEST encoding works correctly ✓");
}

fn void test_request_decode() @test
{
    char[] msg = metadata_exchange::encode_request(7);
    defer free(msg);

    metadata_exchange::MetadataRequest req = metadata_exchange::decode_request(msg)!!;
    assert(req.piece == 7, "Should decode piece index correctly");

    io::printn("REQUEST decoding works correctly ✓");
}

fn void test_request_roundtrip() @test
{
    for (uint piece = 0; piece < 10; piece++)
    {
        char[] encoded = metadata_exchange::encode_request(piece);
        defer free(encoded);

        metadata_exchange::MetadataRequest req = metadata_exchange::decode_request(encoded)!!;
        assert(req.piece == piece, "Roundtrip should preserve piece index");
    }

    io::printn("REQUEST roundtrip works correctly ✓");
}

// ============================================================================
// DATA Message Tests
// ============================================================================

fn void test_data_encode() @test
{
    char[10] test_data = { 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j' };

    char[] msg = metadata_exchange::encode_data(3, 50000, test_data[..]);
    defer free(msg);

    // Should be: d8:msg_typei1e5:piecei3e10:total_sizei50000ee + binary data
    assert(msg.len > 10, "DATA message should include binary data");

    // Check binary data is appended
    bool data_found = true;
    for (usz i = 0; i < 10; i++)
    {
        if (msg[msg.len - 10 + i] != test_data[i])
        {
            data_found = false;
            break;
        }
    }
    assert(data_found, "Binary data should be appended correctly");

    io::printn("DATA encoding works correctly ✓");
}

fn void test_data_decode() @test
{
    char[10] test_data = { 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j' };

    char[] encoded = metadata_exchange::encode_data(2, 30000, test_data[..]);
    defer free(encoded);

    metadata_exchange::MetadataData data = metadata_exchange::decode_data(encoded)!!;
    defer data.free();

    assert(data.piece == 2, "Should decode piece correctly");
    assert(data.total_size == 30000, "Should decode total_size correctly");
    assert(data.data.len == 10, "Should decode data length correctly");

    // Verify binary data
    for (usz i = 0; i < 10; i++)
    {
        assert(data.data[i] == test_data[i], "Binary data should match");
    }

    io::printn("DATA decoding works correctly ✓");
}

fn void test_data_roundtrip() @test
{
    // Test with various data sizes
    uint[] sizes = { 100, 1000, 16384, 10000 };

    foreach (size : sizes)
    {
        // Create test data
        char[] test_data = mem::new_array(char, size);
        defer free(test_data);

        for (usz i = 0; i < size; i++)
        {
            test_data[i] = (char)(i % 256);
        }

        // Encode
        char[] encoded = metadata_exchange::encode_data(0, size, test_data);
        defer free(encoded);

        // Decode
        metadata_exchange::MetadataData data = metadata_exchange::decode_data(encoded)!!;
        defer data.free();

        assert(data.piece == 0, "Piece should match");
        assert(data.total_size == size, "Total size should match");
        assert(data.data.len == size, "Data length should match");

        // Verify data integrity
        for (usz i = 0; i < size; i++)
        {
            assert(data.data[i] == test_data[i], "Data bytes should match");
        }
    }

    io::printn("DATA roundtrip works correctly ✓");
}

// ============================================================================
// REJECT Message Tests
// ============================================================================

fn void test_reject_encode() @test
{
    char[] msg = metadata_exchange::encode_reject(4);
    defer free(msg);

    // Should be: d8:msg_typei2e5:piecei4ee
    String expected = "d8:msg_typei2e5:piecei4ee";

    assert(msg.len == expected.len, "REJECT message should have correct length");

    for (usz i = 0; i < expected.len; i++)
    {
        assert(msg[i] == expected[i], "REJECT message bytes should match");
    }

    io::printn("REJECT encoding works correctly ✓");
}

fn void test_reject_decode() @test
{
    char[] msg = metadata_exchange::encode_reject(9);
    defer free(msg);

    metadata_exchange::MetadataReject rej = metadata_exchange::decode_reject(msg)!!;
    assert(rej.piece == 9, "Should decode piece index correctly");

    io::printn("REJECT decoding works correctly ✓");
}

fn void test_reject_roundtrip() @test
{
    for (uint piece = 0; piece < 10; piece++)
    {
        char[] encoded = metadata_exchange::encode_reject(piece);
        defer free(encoded);

        metadata_exchange::MetadataReject rej = metadata_exchange::decode_reject(encoded)!!;
        assert(rej.piece == piece, "Roundtrip should preserve piece index");
    }

    io::printn("REJECT roundtrip works correctly ✓");
}

// ============================================================================
// Error Handling Tests
// ============================================================================

fn void test_decode_invalid_message() @test
{
    // Invalid bencode
    char[] invalid = "not bencode";

    if (catch metadata_exchange::decode_request(invalid[..]))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject invalid bencode for REQUEST");
    }

    if (catch metadata_exchange::decode_data(invalid[..]))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject invalid bencode for DATA");
    }

    if (catch metadata_exchange::decode_reject(invalid[..]))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject invalid bencode for REJECT");
    }

    io::printn("Invalid message rejection works correctly ✓");
}

fn void test_decode_wrong_type() @test
{
    // REQUEST message (type 0) decoded as DATA (expects type 1)
    char[] req_msg = metadata_exchange::encode_request(0);
    defer free(req_msg);

    if (catch metadata_exchange::decode_data(req_msg))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject wrong message type");
    }

    // REJECT message (type 2) decoded as REQUEST (expects type 0)
    char[] rej_msg = metadata_exchange::encode_reject(0);
    defer free(rej_msg);

    if (catch metadata_exchange::decode_request(rej_msg))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject wrong message type");
    }

    io::printn("Wrong type rejection works correctly ✓");
}

fn void test_decode_missing_fields() @test
{
    // Message with only msg_type, missing piece field
    String incomplete = "d8:msg_typei0ee";

    if (catch metadata_exchange::decode_request((char[])incomplete))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Should reject incomplete REQUEST");
    }

    io::printn("Missing field rejection works correctly ✓");
}
