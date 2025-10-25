module libtorrent::peer_wire::test;

import libtorrent::peer_wire;
import std::io;

// ============================================================================
// Big-Endian Integer Conversion Tests
// ============================================================================

fn void test_u32_endian_conversion() @test
{
    // Test round-trip conversion
    char[4] buffer;
    peer_wire::write_u32_be(buffer[..], 0, 0x12345678);

    // Verify bytes are in big-endian order
    assert(buffer[0] == 0x12, "First byte should be most significant");
    assert(buffer[1] == 0x34, "Second byte");
    assert(buffer[2] == 0x56, "Third byte");
    assert(buffer[3] == 0x78, "Fourth byte (least significant)");

    // Verify read gives back original value
    uint value = peer_wire::read_u32_be(buffer[..], 0);
    assert(value == 0x12345678, "Round-trip conversion should work");
}

fn void test_u32_be_zero() @test
{
    char[4] buffer;
    peer_wire::write_u32_be(buffer[..], 0, 0);

    foreach (b : buffer) assert(b == 0, "All bytes should be zero");

    uint value = peer_wire::read_u32_be(buffer[..], 0);
    assert(value == 0, "Should read back zero");
}

fn void test_u32_be_max() @test
{
    char[4] buffer;
    peer_wire::write_u32_be(buffer[..], 0, 0xFFFFFFFF);

    foreach (b : buffer) assert((usz)b & 0xFF == 0xFF, "All bytes should be 0xFF");

    uint value = peer_wire::read_u32_be(buffer[..], 0);
    assert(value == 0xFFFFFFFF, "Should read back max value");
}

// ============================================================================
// Handshake Tests
// ============================================================================

fn void test_handshake_encode() @test
{
    char[20] info_hash;
    char[20] peer_id;

    // Fill with test data
    for (usz i = 0; i < info_hash.len; i++) info_hash[i] = (char)i;
    for (usz i = 0; i < peer_id.len; i++) peer_id[i] = (char)(i + 20);

    char[] handshake = peer_wire::encode_handshake(info_hash, peer_id);
    defer free(handshake);

    // Verify length
    assert(handshake.len == 68, "Handshake should be 68 bytes");

    // Verify protocol string length
    assert(handshake[0] == 19, "Protocol string length should be 19");

    // Verify protocol string
    String expected = "BitTorrent protocol";
    for (usz i = 0; i < 19; i++)
    {
        assert(handshake[i + 1] == expected[i], "Protocol string should match");
    }

    // Verify reserved bytes - byte 25 (index 5) should have extension bit set (BEP 10)
    for (usz i = 20; i < 28; i++)
    {
        if (i == 25)
        {
            // Byte 5 should have extension protocol bit (0x10) set
            assert(handshake[i] == 0x10, "Reserved byte 5 should have extension bit set");
        }
        else
        {
            assert(handshake[i] == 0, "Other reserved bytes should be zero");
        }
    }

    // Verify info hash
    for (usz i = 0; i < 20; i++)
    {
        assert(handshake[i + 28] == (char)i, "Info hash should match");
    }

    // Verify peer ID
    for (usz i = 0; i < 20; i++)
    {
        assert(handshake[i + 48] == (char)(i + 20), "Peer ID should match");
    }
}

fn void test_handshake_decode() @test
{
    char[20] info_hash;
    char[20] peer_id;

    for (usz i = 0; i < info_hash.len; i++) info_hash[i] = (char)(i * 2);
    for (usz i = 0; i < peer_id.len; i++) peer_id[i] = (char)(i * 3);

    char[] handshake = peer_wire::encode_handshake(info_hash, peer_id);
    defer free(handshake);

    peer_wire::HandshakeMsg? msg_opt = peer_wire::decode_handshake(handshake);
    msg_opt!!; // Should decode successfully

    peer_wire::HandshakeMsg msg = msg_opt!!;

    // Verify reserved bytes - byte 5 should have extension bit (0x10) set
    for (usz i = 0; i < 8; i++)
    {
        if (i == 5)
        {
            assert(msg.reserved[i] == 0x10, "Reserved byte 5 should have extension bit");
        }
        else
        {
            assert(msg.reserved[i] == 0, "Other reserved bytes should be zero");
        }
    }

    // Verify extension support is detected
    assert(peer_wire::handshake_supports_extensions(&msg), "Should support extensions");

    // Verify info hash
    for (usz i = 0; i < 20; i++)
    {
        assert(msg.info_hash[i] == (char)(i * 2), "Info hash should match");
    }

    // Verify peer ID
    for (usz i = 0; i < 20; i++)
    {
        assert(msg.peer_id[i] == (char)(i * 3), "Peer ID should match");
    }
}

fn void test_handshake_decode_too_short() @test
{
    char[67] data;  // 1 byte too short
    peer_wire::HandshakeMsg? result = peer_wire::decode_handshake(data[..]);
    if (catch excuse = result)
    {
        // Expected to fail - test passes
        return;
    }
    assert(false, "Should fail on too-short data");
}

fn void test_handshake_decode_invalid_protocol() @test
{
    char[68] data;
    data[0] = 19;
    String wrong = "Not the right proto";
    foreach (i, c : wrong) data[i + 1] = c;

    peer_wire::HandshakeMsg? result = peer_wire::decode_handshake(data[..]);
    if (catch excuse = result)
    {
        // Expected to fail - test passes
        return;
    }
    assert(false, "Should fail on invalid protocol string");
}

// ============================================================================
// Message Encoding Tests
// ============================================================================

fn void test_encode_keepalive() @test
{
    char[] msg = peer_wire::encode_keepalive();
    defer free(msg);

    assert(msg.len == 4, "Keep-alive should be 4 bytes");

    uint len = peer_wire::read_u32_be(msg, 0);
    assert(len == 0, "Keep-alive length should be 0");
}

fn void test_encode_choke() @test
{
    char[] msg = peer_wire::encode_simple_message(peer_wire::MessageType.CHOKE);
    defer free(msg);

    assert(msg.len == 5, "Choke message should be 5 bytes");

    uint len = peer_wire::read_u32_be(msg, 0);
    assert(len == 1, "Message length should be 1");
    assert(msg[4] == (char)peer_wire::MessageType.CHOKE, "Message ID should be CHOKE");
}

fn void test_encode_unchoke() @test
{
    char[] msg = peer_wire::encode_simple_message(peer_wire::MessageType.UNCHOKE);
    defer free(msg);

    assert(msg.len == 5, "Unchoke message should be 5 bytes");
    assert(msg[4] == (char)peer_wire::MessageType.UNCHOKE, "Message ID should be UNCHOKE");
}

fn void test_encode_interested() @test
{
    char[] msg = peer_wire::encode_simple_message(peer_wire::MessageType.INTERESTED);
    defer free(msg);

    assert(msg.len == 5, "Interested message should be 5 bytes");
    assert(msg[4] == (char)peer_wire::MessageType.INTERESTED, "Message ID should be INTERESTED");
}

fn void test_encode_have() @test
{
    char[] msg = peer_wire::encode_have(42);
    defer free(msg);

    assert(msg.len == 9, "HAVE message should be 9 bytes");

    uint len = peer_wire::read_u32_be(msg, 0);
    assert(len == 5, "Message length should be 5");
    assert(msg[4] == (char)peer_wire::MessageType.HAVE, "Message ID should be HAVE");

    uint piece_index = peer_wire::read_u32_be(msg, 5);
    assert(piece_index == 42, "Piece index should be 42");
}

fn void test_encode_bitfield() @test
{
    char[3] bitfield = {0xFF, 0x00, 0xAA};
    char[] msg = peer_wire::encode_bitfield(bitfield[..]);
    defer free(msg);

    assert(msg.len == 8, "BITFIELD message should be 8 bytes (4 + 1 + 3)");

    uint len = peer_wire::read_u32_be(msg, 0);
    assert(len == 4, "Message length should be 4 (1 + 3)");
    assert(msg[4] == (char)peer_wire::MessageType.BITFIELD, "Message ID should be BITFIELD");

    assert(msg[5] == (char)0xFF, "First bitfield byte");
    assert(msg[6] == (char)0x00, "Second bitfield byte");
    assert(msg[7] == (char)0xAA, "Third bitfield byte");
}

fn void test_encode_request() @test
{
    char[] msg = peer_wire::encode_request(5, 16384, 16384);
    defer free(msg);

    assert(msg.len == 17, "REQUEST message should be 17 bytes");

    uint len = peer_wire::read_u32_be(msg, 0);
    assert(len == 13, "Message length should be 13");
    assert(msg[4] == (char)peer_wire::MessageType.REQUEST, "Message ID should be REQUEST");

    uint index = peer_wire::read_u32_be(msg, 5);
    assert(index == 5, "Piece index should be 5");

    uint begin = peer_wire::read_u32_be(msg, 9);
    assert(begin == 16384, "Begin offset should be 16384");

    uint length = peer_wire::read_u32_be(msg, 13);
    assert(length == 16384, "Block length should be 16384");
}

fn void test_encode_piece() @test
{
    char[10] block;
    for (usz i = 0; i < block.len; i++) block[i] = (char)(i + 100);

    char[] msg = peer_wire::encode_piece(7, 32768, block[..]);
    defer free(msg);

    assert(msg.len == 23, "PIECE message should be 23 bytes (13 + 10)");

    uint len = peer_wire::read_u32_be(msg, 0);
    assert(len == 19, "Message length should be 19 (9 + 10)");
    assert(msg[4] == (char)peer_wire::MessageType.PIECE, "Message ID should be PIECE");

    uint index = peer_wire::read_u32_be(msg, 5);
    assert(index == 7, "Piece index should be 7");

    uint begin = peer_wire::read_u32_be(msg, 9);
    assert(begin == 32768, "Begin offset should be 32768");

    // Verify block data
    for (usz i = 0; i < 10; i++)
    {
        assert(msg[i + 13] == (char)(i + 100), "Block data should match");
    }
}

fn void test_encode_cancel() @test
{
    char[] msg = peer_wire::encode_cancel(3, 8192, 16384);
    defer free(msg);

    assert(msg.len == 17, "CANCEL message should be 17 bytes");
    assert(msg[4] == (char)peer_wire::MessageType.CANCEL, "Message ID should be CANCEL");

    uint index = peer_wire::read_u32_be(msg, 5);
    assert(index == 3, "Piece index should be 3");
}

// ============================================================================
// Message Decoding Tests
// ============================================================================

fn void test_decode_keepalive() @test
{
    char[] msg = peer_wire::encode_keepalive();
    defer free(msg);

    peer_wire::Message? decoded_opt = peer_wire::decode_message(msg);
    decoded_opt!!; // Should decode successfully

    peer_wire::Message decoded = decoded_opt!!;
    assert(decoded.payload.len == 0, "Keep-alive should have no payload");
}

fn void test_decode_choke() @test
{
    char[] msg = peer_wire::encode_simple_message(peer_wire::MessageType.CHOKE);
    defer free(msg);

    peer_wire::Message? decoded_opt = peer_wire::decode_message(msg);
    decoded_opt!!; // Should decode successfully

    peer_wire::Message decoded = decoded_opt!!;
    assert(decoded.type == peer_wire::MessageType.CHOKE, "Should be CHOKE message");
    assert(decoded.payload.len == 0, "Simple messages have no payload");
}

fn void test_decode_have() @test
{
    char[] msg = peer_wire::encode_have(123);
    defer free(msg);

    peer_wire::Message? decoded_opt = peer_wire::decode_message(msg);
    decoded_opt!!; // Should decode successfully

    peer_wire::Message decoded = decoded_opt!!;
    defer free(decoded.payload);

    assert(decoded.type == peer_wire::MessageType.HAVE, "Should be HAVE message");
    assert(decoded.payload.len == 4, "HAVE payload is 4 bytes");

    uint? piece_opt = peer_wire::decode_have(decoded.payload);
    piece_opt!!; // Should decode HAVE payload
    assert(piece_opt!! == 123, "Piece index should be 123");
}

fn void test_decode_request() @test
{
    char[] msg = peer_wire::encode_request(10, 16384, 8192);
    defer free(msg);

    peer_wire::Message? decoded_opt = peer_wire::decode_message(msg);
    decoded_opt!!; // Should decode successfully

    peer_wire::Message decoded = decoded_opt!!;
    defer free(decoded.payload);

    assert(decoded.type == peer_wire::MessageType.REQUEST, "Should be REQUEST message");

    peer_wire::RequestMsg? req_opt = peer_wire::decode_request(decoded.payload);
    req_opt!!; // Should decode REQUEST payload

    peer_wire::RequestMsg req = req_opt!!;
    assert(req.index == 10, "Piece index should be 10");
    assert(req.begin == 16384, "Begin should be 16384");
    assert(req.length == 8192, "Length should be 8192");
}

fn void test_decode_piece() @test
{
    char[256] block;
    for (usz i = 0; i < block.len; i++) block[i] = (char)(i & 0xFF);

    char[] msg = peer_wire::encode_piece(15, 0, block[..]);
    defer free(msg);

    peer_wire::Message? decoded_opt = peer_wire::decode_message(msg);
    decoded_opt!!; // Should decode successfully

    peer_wire::Message decoded = decoded_opt!!;
    defer free(decoded.payload);

    assert(decoded.type == peer_wire::MessageType.PIECE, "Should be PIECE message");

    peer_wire::PieceMsg? piece_opt = peer_wire::decode_piece(decoded.payload);
    piece_opt!!; // Should decode PIECE payload

    peer_wire::PieceMsg piece = piece_opt!!;
    defer free(piece.block);

    assert(piece.index == 15, "Piece index should be 15");
    assert(piece.begin == 0, "Begin should be 0");
    assert(piece.block.len == 256, "Block size should be 256");

    // Verify block data
    for (usz i = 0; i < 256; i++)
    {
        assert(piece.block[i] == (char)(i & 0xFF), "Block data should match");
    }
}

fn void test_decode_incomplete_message() @test
{
    char[3] data = {0, 0, 0};  // Not enough for length prefix
    peer_wire::Message? result = peer_wire::decode_message(data[..]);
    if (catch excuse = result)
    {
        // Expected to fail - test passes
        return;
    }
    assert(false, "Should fail on incomplete data");
}

fn void test_message_total_size() @test
{
    char[] msg = peer_wire::encode_have(42);
    defer free(msg);

    usz? size_opt = peer_wire::message_total_size(msg);
    size_opt!!; // Should calculate size
    assert(size_opt!! == 9, "Total size should be 9 bytes");
}

fn void test_message_total_size_keepalive() @test
{
    char[] msg = peer_wire::encode_keepalive();
    defer free(msg);

    usz? size_opt = peer_wire::message_total_size(msg);
    size_opt!!; // Should calculate size
    assert(size_opt!! == 4, "Keep-alive total size is 4 bytes");
}

fn void test_message_total_size_incomplete() @test
{
    char[3] data;  // Not enough bytes
    usz? result = peer_wire::message_total_size(data[..]);
    if (catch excuse = result)
    {
        // Expected to fail - test passes
        return;
    }
    assert(false, "Should fail on incomplete data");
}
