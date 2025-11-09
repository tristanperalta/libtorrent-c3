module libtorrent::upload_manager_test;

import libtorrent::upload_manager;
import libtorrent::common;

// Helper to create test socket addresses
fn common::SocketAddress make_addr(char a, char b, char c, char d, ushort port)
{
    char[] compact = {a, b, c, d, (char)(port >> 8), (char)(port & 0xFF)};
    return common::socket_address_from_compact_ipv4(compact)!!;
}

fn void test_upload_manager_create() @test
{
    upload_manager::UploadManager* mgr = upload_manager::create();
    assert(mgr != null);
    mgr.free();
}

fn void test_upload_manager_add_and_process() @test
{
    upload_manager::UploadManager* mgr = upload_manager::create();
    defer mgr.free();

    common::SocketAddress addr = make_addr(127, 0, 0, 1, 6881);

    // Add request
    bool added = mgr.add_request(&addr, 5, 32768, 16384);
    assert(added, "Should add request");

    // Check queue size
    assert(mgr.get_queue_size(&addr) == 1);

    // Process request
    upload_manager::UploadRequest req = mgr.process_next_request(&addr)!!;
    assert(req.piece_index == 5);
    assert(req.offset == 32768);
    assert(req.length == 16384);

    // Queue should be empty
    assert(mgr.get_queue_size(&addr) == 0);
}

fn void test_upload_manager_queue_limit() @test
{
    upload_manager::UploadManager* mgr = upload_manager::create();
    defer mgr.free();

    common::SocketAddress addr = make_addr(127, 0, 0, 1, 6881);

    // Fill to limit (250)
    for (uint i = 0; i < 250; i++)
    {
        assert(mgr.add_request(&addr, i, 0, 16384));
    }

    // 251st should fail
    assert(!mgr.add_request(&addr, 250, 0, 16384), "Should reject when full");
}

fn void test_upload_manager_fifo_order() @test
{
    upload_manager::UploadManager* mgr = upload_manager::create();
    defer mgr.free();

    common::SocketAddress addr = make_addr(127, 0, 0, 1, 6881);

    mgr.add_request(&addr, 0, 0, 16384);
    mgr.add_request(&addr, 1, 0, 16384);
    mgr.add_request(&addr, 2, 0, 16384);

    assert(mgr.process_next_request(&addr)!!.piece_index == 0);
    assert(mgr.process_next_request(&addr)!!.piece_index == 1);
    assert(mgr.process_next_request(&addr)!!.piece_index == 2);
}

fn void test_upload_manager_multiple_peers() @test
{
    upload_manager::UploadManager* mgr = upload_manager::create();
    defer mgr.free();

    common::SocketAddress peer1 = make_addr(127, 0, 0, 1, 6881);
    common::SocketAddress peer2 = make_addr(192, 168, 1, 100, 6882);

    mgr.add_request(&peer1, 0, 0, 16384);
    mgr.add_request(&peer1, 1, 0, 16384);
    mgr.add_request(&peer2, 5, 0, 16384);

    assert(mgr.get_queue_size(&peer1) == 2);
    assert(mgr.get_queue_size(&peer2) == 1);
    assert(mgr.get_total_pending() == 3);
}

fn void test_upload_manager_clear_queue() @test
{
    upload_manager::UploadManager* mgr = upload_manager::create();
    defer mgr.free();

    common::SocketAddress addr = make_addr(127, 0, 0, 1, 6881);

    mgr.add_request(&addr, 0, 0, 16384);
    mgr.add_request(&addr, 1, 0, 16384);
    assert(mgr.get_queue_size(&addr) == 2);

    mgr.clear_peer_queue(&addr);
    assert(mgr.get_queue_size(&addr) == 0);
}
