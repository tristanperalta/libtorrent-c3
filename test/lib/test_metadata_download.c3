module libtorrent::metadata_download::test;

import libtorrent::metadata_download;
import libtorrent::metadata_exchange;
import libtorrent::common;
import libtorrent::logger;
import std::hash::sha1;

/**
 * Test metadata download manager creation
 */
fn void test_metadata_download_create() @test
{
    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = (char)i;
    }

    metadata_download::MetadataDownload* md = metadata_download::create(info_hash);
    defer md.free();

    assert(!md.is_complete(), "Should not be complete initially");
    assert(md.get_progress() == 0, "Should have 0 progress initially");
    assert(md.get_num_pieces() == 0, "Should have 0 pieces before size is set");

    // Verify info_hash was copied
    for (usz i = 0; i < 20; i++)
    {
        assert(md.info_hash[i] == (char)i, "Info hash should match");
    }
}

/**
 * Test setting metadata size
 */
fn void test_metadata_download_set_size() @test
{
    defer logger::free_logger();

    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = 0;
    }

    metadata_download::MetadataDownload* md = metadata_download::create(info_hash);
    defer md.free();

    // Set size to 50KB (needs 4 pieces: 16KB + 16KB + 16KB + 2KB)
    md.set_metadata_size(50000);

    assert(md.get_num_pieces() == 4, "Should calculate 4 pieces for 50KB");
    assert(md.get_progress() == 0, "Should still have 0 pieces received");
}

/**
 * Test requesting pieces
 */
fn void test_metadata_download_request_pieces() @test
{
    defer logger::free_logger();

    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = 0;
    }

    metadata_download::MetadataDownload* md = metadata_download::create(info_hash);
    defer md.free();

    md.set_metadata_size(32768);  // Exactly 2 pieces

    // Should be able to request first piece
    int piece1 = md.get_next_piece_to_request();
    assert(piece1 == 0, "First piece should be index 0");

    md.mark_piece_requested((uint)piece1);

    // Should be able to request second piece
    int piece2 = md.get_next_piece_to_request();
    assert(piece2 == 1, "Second piece should be index 1");

    md.mark_piece_requested((uint)piece2);

    // Should not be able to request more (all requested)
    int piece3 = md.get_next_piece_to_request();
    assert(piece3 == -1, "Should return -1 when all pieces requested");
}

/**
 * Test maximum outstanding requests limit
 */
fn void test_metadata_download_max_requests() @test
{
    defer logger::free_logger();

    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = 0;
    }

    metadata_download::MetadataDownload* md = metadata_download::create(info_hash);
    defer md.free();

    // Set size large enough for 10 pieces
    md.set_metadata_size(163840);  // 10 * 16KB

    // Request up to MAX_OUTSTANDING_REQUESTS (3)
    for (uint i = 0; i < 3; i++)
    {
        int piece = md.get_next_piece_to_request();
        assert(piece >= 0, "Should be able to request piece");
        md.mark_piece_requested((uint)piece);
    }

    // Next request should fail (at limit)
    int piece = md.get_next_piece_to_request();
    assert(piece == -1, "Should not allow more than MAX_OUTSTANDING_REQUESTS");
}

/**
 * Test handling DATA messages
 */
fn void test_metadata_download_handle_data() @test
{
    defer logger::free_logger();

    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = 0;
    }

    metadata_download::MetadataDownload* md = metadata_download::create(info_hash);
    defer md.free();

    md.set_metadata_size(32768);  // 2 pieces

    // Request piece 0
    int piece_idx = md.get_next_piece_to_request();
    md.mark_piece_requested((uint)piece_idx);

    // Simulate receiving piece 0
    char[100] dummy_data;
    for (usz i = 0; i < 100; i++)
    {
        dummy_data[i] = (char)(i % 256);
    }

    bool complete = md.handle_data(0, dummy_data[..]);
    assert(!complete, "Should not be complete after 1 of 2 pieces");
    assert(md.get_progress() == 1, "Should have 1 piece received");
}

/**
 * Test handling REJECT messages
 */
fn void test_metadata_download_handle_reject() @test
{
    defer logger::free_logger();

    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = 0;
    }

    metadata_download::MetadataDownload* md = metadata_download::create(info_hash);
    defer md.free();

    md.set_metadata_size(16384);  // 1 piece

    // Request piece 0
    int piece_idx = md.get_next_piece_to_request();
    assert(piece_idx == 0, "Should get piece 0");
    md.mark_piece_requested((uint)piece_idx);

    // No more pieces to request (only 1 piece, and it's requested)
    int piece_idx2 = md.get_next_piece_to_request();
    assert(piece_idx2 == -1, "Should not have more pieces");

    // Handle reject for piece 0
    md.handle_reject(0);

    // Should be able to request piece 0 again
    int piece_idx3 = md.get_next_piece_to_request();
    assert(piece_idx3 == 0, "Should be able to re-request piece 0 after reject");
}

/**
 * Test complete download with hash verification
 */
fn void test_metadata_download_complete() @test
{
    // Create metadata to download
    String metadata_str = "d4:name8:test.txt12:piece lengthi262144ee";
    char[] metadata = (char[])metadata_str;

    // Calculate expected info_hash
    char[20] info_hash = sha1::hash(metadata[..]);

    metadata_download::MetadataDownload* md = metadata_download::create(info_hash);
    defer md.free();
    defer logger::free_logger();  // Clean up logger to prevent memory leak

    // Set size
    md.set_metadata_size((uint)metadata.len);
    assert(md.get_num_pieces() == 1, "Should need 1 piece for small metadata");

    // Request and receive piece 0
    int piece_idx = md.get_next_piece_to_request();
    assert(piece_idx == 0, "Should get piece 0");
    md.mark_piece_requested((uint)piece_idx);

    bool complete = md.handle_data(0, metadata);
    assert(complete, "Should be complete after receiving all pieces");
    assert(md.is_complete(), "is_complete() should return true");

    // Get metadata
    char[] result = md.get_metadata()!!;

    // Verify it matches
    assert(result.len == metadata.len, "Metadata length should match");
    foreach (i, b : metadata)
    {
        assert(result[i] == b, "Metadata content should match");
    }
}

/**
 * Test hash verification failure
 */
fn void test_metadata_download_hash_mismatch() @test
{
    defer logger::free_logger();

    // Create wrong info_hash
    common::InfoHash wrong_hash;
    for (usz i = 0; i < 20; i++)
    {
        wrong_hash[i] = (char)0xFF;  // Wrong hash
    }

    metadata_download::MetadataDownload* md = metadata_download::create(wrong_hash);
    defer md.free();

    // Create some metadata
    String metadata_str = "d4:name8:test.txte";
    char[] metadata = (char[])metadata_str;

    md.set_metadata_size((uint)metadata.len);

    // Request and receive piece
    int piece_idx = md.get_next_piece_to_request();
    md.mark_piece_requested((uint)piece_idx);

    bool complete = md.handle_data(0, metadata);
    assert(!complete, "Should not complete with wrong hash");
    assert(!md.is_complete(), "Should not be marked complete");
}

/**
 * Test multi-piece download
 */
fn void test_metadata_download_multi_piece() @test
{
    defer logger::free_logger();

    // Create metadata that spans 2 pieces
    char[32768] metadata;  // Exactly 2 * 16KB
    for (usz i = 0; i < 32768; i++)
    {
        metadata[i] = (char)(i % 256);
    }

    char[20] info_hash = sha1::hash(metadata[..]);

    metadata_download::MetadataDownload* md = metadata_download::create(info_hash);
    defer md.free();

    md.set_metadata_size(32768);
    assert(md.get_num_pieces() == 2, "Should need 2 pieces");

    // Request and receive piece 0
    int piece0 = md.get_next_piece_to_request();
    assert(piece0 == 0, "Should get piece 0");
    md.mark_piece_requested(0);

    char[] piece0_data = metadata[0..16383];  // First 16KB
    bool complete0 = md.handle_data(0, piece0_data);
    assert(!complete0, "Should not be complete after piece 0");

    // Request and receive piece 1
    int piece1 = md.get_next_piece_to_request();
    assert(piece1 == 1, "Should get piece 1");
    md.mark_piece_requested(1);

    char[] piece1_data = metadata[16384..];  // Second 16KB
    bool complete1 = md.handle_data(1, piece1_data);
    assert(complete1, "Should be complete after piece 1");
    assert(md.is_complete(), "Should be marked complete");

    // Verify assembled metadata
    char[] result = md.get_metadata()!!;

    assert(result.len == 32768, "Assembled metadata length should match");
    for (usz i = 0; i < 32768; i++)
    {
        assert(result[i] == metadata[i], "Assembled metadata should match original");
    }
}

/**
 * Test getting metadata before download completes
 */
fn void test_metadata_download_get_before_complete() @test
{
    defer logger::free_logger();

    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = 0;
    }

    metadata_download::MetadataDownload* md = metadata_download::create(info_hash);
    defer md.free();

    md.set_metadata_size(16384);

    // Try to get metadata before download completes
    char[]? result_opt = md.get_metadata();
    if (catch result_opt)
    {
        // Expected - should fail
    }
    else
    {
        assert(false, "Should fail to get metadata before complete");
    }
}

/**
 * Test duplicate piece handling
 */
fn void test_metadata_download_duplicate_piece() @test
{
    defer logger::free_logger();

    common::InfoHash info_hash;
    for (usz i = 0; i < 20; i++)
    {
        info_hash[i] = 0;
    }

    metadata_download::MetadataDownload* md = metadata_download::create(info_hash);
    defer md.free();

    md.set_metadata_size(32768);  // 2 pieces

    char[100] dummy_data;
    for (usz i = 0; i < 100; i++)
    {
        dummy_data[i] = (char)i;
    }

    // Receive piece 0 twice
    md.handle_data(0, dummy_data[..]);
    assert(md.get_progress() == 1, "Should have 1 piece");

    md.handle_data(0, dummy_data[..]);  // Duplicate
    assert(md.get_progress() == 1, "Should still have 1 piece (duplicate ignored)");
}

/**
 * Test out-of-order piece reception
 */
fn void test_metadata_download_out_of_order() @test
{
    defer logger::free_logger();

    // Create metadata that spans 3 pieces
    char[49152] metadata;  // 3 * 16KB
    for (usz i = 0; i < 49152; i++)
    {
        metadata[i] = (char)(i % 256);
    }

    char[20] info_hash = sha1::hash(metadata[..]);

    metadata_download::MetadataDownload* md = metadata_download::create(info_hash);
    defer md.free();

    md.set_metadata_size(49152);
    assert(md.get_num_pieces() == 3, "Should need 3 pieces");

    // Receive pieces out of order: 2, 0, 1
    md.handle_data(2, metadata[32768..]);
    assert(md.get_progress() == 1, "Should have 1 piece");

    md.handle_data(0, metadata[0..16383]);
    assert(md.get_progress() == 2, "Should have 2 pieces");

    bool complete = md.handle_data(1, metadata[16384..32767]);
    assert(complete, "Should complete after last piece");
    assert(md.is_complete(), "Should be marked complete");

    // Verify assembled metadata
    char[] result = md.get_metadata()!!;

    assert(result.len == 49152, "Assembled metadata length should match");
}
