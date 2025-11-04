module torrent_client::session_message_handler;

import std::io;
import libtorrent::common;
import libtorrent::peer_connection;
import libtorrent::peer_wire;
import libtorrent::download_manager;
import libtorrent::block_manager;
import libtorrent::bitfield;
import libtorrent::peer_pool;
import torrent_client::download_session;

/**
 * Session Message Handler
 * =======================
 * Handles all peer wire protocol messages for download sessions.
 *
 * Extracted from download_session.c3 to improve modularity and testability.
 * Processes messages: BITFIELD, HAVE, HAVE_ALL, HAVE_NONE, PIECE, UNCHOKE,
 * REQUEST, CHOKE.
 */

/**
 * Handle incoming peer wire protocol message.
 *
 * @param peer : "Peer connection that sent the message"
 * @param msg : "Decoded message"
 * @param ip : "Peer IP address"
 * @param port : "Peer port"
 * @param user_data : "DownloadContext pointer"
 */
fn void handle_peer_message(peer_connection::PeerConnection* peer,
                             peer_wire::Message* msg,
                             common::Ipv4Addr ip, ushort port,
                             void* user_data) @public
{
    download_session::DownloadContext* ctx = (download_session::DownloadContext*)user_data;

    // Get peer from pool
    peer_pool::TorrentPeer*? peer_opt = ctx.peer_pool.find_peer(ip, port);
    if (catch err = peer_opt)
    {
        io::eprintfn("  [ERROR] Message from unknown peer %d.%d.%d.%d:%d",
                     ip[0], ip[1], ip[2], ip[3], port);
        return;
    }
    peer_pool::TorrentPeer* peer_info = peer_opt;

    switch (msg.type)
    {
        case peer_wire::MessageType.BITFIELD:
            // Peer sent their bitfield - update piece availability
            if (msg.payload.len > 0)
            {
                peer_info.received_bitfield = true;

                // Convert bitfield bytes to bool array
                usz num_pieces = (usz)((ctx.torrent.info.length + ctx.torrent.info.piece_length - 1) /
                                       ctx.torrent.info.piece_length);
                bool[] has_pieces = mem::new_array(bool, num_pieces);

                // Parse bitfield
                for (usz i = 0; i < num_pieces; i++)
                {
                    usz byte_index = i / 8;
                    usz bit_index = 7 - (i % 8);
                    if (byte_index < msg.payload.len)
                    {
                        has_pieces[i] = (msg.payload[byte_index] & (1 << bit_index)) != 0;
                    }
                }

                // Update download manager
                ctx.dm.update_peer_bitfield(has_pieces)!!;

                // Store the bitfield in the peer's struct (critical for piece selection later!)
                if (peer_info.pieces.data.len > 0)
                {
                    peer_info.pieces.free();
                }
                peer_info.pieces = bitfield::from_bytes(msg.payload, num_pieces);

                io::printfn("  Peer %d.%d.%d.%d:%d sent bitfield",
                            ip[0], ip[1], ip[2], ip[3], port);

                // Count how many pieces the peer has
                int peer_piece_count = 0;
                for (usz i = 0; i < num_pieces; i++)
                {
                    if (has_pieces[i]) peer_piece_count++;
                }
                io::printfn("    Peer has %d/%d pieces", peer_piece_count, (int)num_pieces);

                // Start piece downloads based on peer availability
                // Try to fill all available download slots (up to max_concurrent_pieces)

                int pieces_started = 0;
                for (int i = 0; i < ctx.max_concurrent_pieces; i++)
                {
                    if (catch excuse = ctx.dm.start_piece_download(has_pieces))
                    {
                        // No more pieces to download or no slots available (both are fine)
                        break;
                    }
                    pieces_started++;
                }

                if (pieces_started > 0)
                {
                    io::printfn("    Started downloading %d piece%s",
                               pieces_started, pieces_started == 1 ? "" : "s");
                }

                free(has_pieces);

                // Check if peer is a seed
                if (peer_piece_count == (int)num_pieces)
                {
                    ctx.peer_pool.mark_peer_seed(ip, port)!!;
                }
            }

        case peer_wire::MessageType.HAVE_ALL:
            // BEP 6: Peer has all pieces (replaces BITFIELD for seeds)
            peer_info.received_bitfield = true;

            usz num_pieces = (usz)((ctx.torrent.info.length + ctx.torrent.info.piece_length - 1) /
                                   ctx.torrent.info.piece_length);

            // Create array with all pieces available
            bool[] has_all_pieces = mem::new_array(bool, num_pieces);
            for (usz i = 0; i < num_pieces; i++)
            {
                has_all_pieces[i] = true;
            }

            // Update download manager
            ctx.dm.update_peer_bitfield(has_all_pieces)!!;

            // Store bitfield in peer struct (all pieces set)
            if (peer_info.pieces.data.len > 0)
            {
                peer_info.pieces.free();
            }
            peer_info.pieces = bitfield::create(num_pieces);
            peer_info.pieces.set_all();

            io::printfn("  Peer %d.%d.%d.%d:%d sent HAVE_ALL (seed)",
                        ip[0], ip[1], ip[2], ip[3], port);

            // Start piece downloads
            int pieces_started = 0;
            for (int i = 0; i < ctx.max_concurrent_pieces; i++)
            {
                if (catch excuse = ctx.dm.start_piece_download(has_all_pieces))
                {
                    break;
                }
                pieces_started++;
            }

            if (pieces_started > 0)
            {
                io::printfn("    Started downloading %d piece%s",
                           pieces_started, pieces_started == 1 ? "" : "s");
            }

            free(has_all_pieces);

            // Mark peer as seed
            ctx.peer_pool.mark_peer_seed(ip, port)!!;

        case peer_wire::MessageType.HAVE_NONE:
            // BEP 6: Peer has no pieces (replaces empty BITFIELD for new leechers)
            peer_info.received_bitfield = true;

            usz num_pieces_none = (usz)((ctx.torrent.info.length + ctx.torrent.info.piece_length - 1) /
                                        ctx.torrent.info.piece_length);

            // Create empty bitfield
            if (peer_info.pieces.data.len > 0)
            {
                peer_info.pieces.free();
            }
            peer_info.pieces = bitfield::create(num_pieces_none);

            io::printfn("  Peer %d.%d.%d.%d:%d sent HAVE_NONE (new leecher)",
                        ip[0], ip[1], ip[2], ip[3], port);

            // No pieces to download from this peer yet (wait for HAVE messages)

        case peer_wire::MessageType.HAVE:
            // Peer has a new piece
            if (msg.payload.len >= 4)
            {
                uint piece_index = peer_wire::read_u32_be(msg.payload, 0);
                ctx.dm.peer_has_piece(piece_index)!!;

                // Initialize peer's bitfield if not already done
                if (peer_info.pieces.data.len == 0)
                {
                    usz num_pieces = (usz)((ctx.torrent.info.length + ctx.torrent.info.piece_length - 1) /
                                           ctx.torrent.info.piece_length);
                    peer_info.pieces = bitfield::create(num_pieces);
                }

                // Update peer's bitfield
                peer_info.pieces.set_piece((usz)piece_index);
            }

        case peer_wire::MessageType.PIECE:
            // Received a piece block!
            peer_wire::PieceMsg? piece_msg = peer_wire::decode_piece(msg.payload);
            if (catch err = piece_msg) return;

            // Add block to download manager
            // Note: Piece may no longer be active if it completed while blocks were queued
            if (catch excuse = ctx.dm.receive_block(piece_msg.index, piece_msg.begin, piece_msg.block))
            {
                // Piece not downloading anymore (completed or failed) - ignore late block
                // This is normal when piece completes while blocks are queued in event loop
                return;
            }

            // Track download statistics
            ctx.peer_pool.update_peer_stats(ip, port, (ulong)piece_msg.block.len, 0)!!;

            // Check if piece is complete
            usz total_blocks, received_blocks;
            if (catch excuse = ctx.dm.get_piece_progress(piece_msg.index, &total_blocks, &received_blocks))
            {
                // Piece not downloading, ignore
            }
            else if (received_blocks == total_blocks)
            {
                // Piece complete - verify and write to disk
                ctx.dm.complete_piece(piece_msg.index, &download_session::on_download_piece_complete, ctx);
            }

            // Keep the request pipeline full
            request_blocks_from_peers(ctx);

        case peer_wire::MessageType.UNCHOKE:
            io::printfn("  Peer %d.%d.%d.%d:%d unchoked us",
                        ip[0], ip[1], ip[2], ip[3], port);

            // If we haven't received BITFIELD yet, assume peer has all pieces
            if (!peer_info.received_bitfield)
            {
                io::printfn("    No BITFIELD received - assuming peer has all pieces");

                usz num_pieces = (usz)((ctx.torrent.info.length + ctx.torrent.info.piece_length - 1) /
                                       ctx.torrent.info.piece_length);
                bool[] has_all_pieces = mem::new_array(bool, num_pieces);

                // Set all pieces to true (assume peer has everything)
                for (usz i = 0; i < num_pieces; i++)
                {
                    has_all_pieces[i] = true;
                }

                // Update download manager
                ctx.dm.update_peer_bitfield(has_all_pieces)!!;

                // Store the bitfield in the peer's struct (all pieces = seed)
                if (peer_info.pieces.data.len > 0)
                {
                    peer_info.pieces.free();
                }
                peer_info.pieces = bitfield::create(num_pieces);
                peer_info.pieces.set_all();

                // Start piece downloads
                int pieces_started = 0;
                for (int i = 0; i < ctx.max_concurrent_pieces; i++)
                {
                    if (catch excuse = ctx.dm.start_piece_download(has_all_pieces))
                    {
                        break;
                    }
                    pieces_started++;
                }

                if (pieces_started > 0)
                {
                    io::printfn("    Started downloading %d piece%s",
                               pieces_started, pieces_started == 1 ? "" : "s");
                }

                free(has_all_pieces);
                peer_info.received_bitfield = true;  // Mark as handled

                // Mark as seed if has all pieces
                ctx.peer_pool.mark_peer_seed(ip, port)!!;
            }

            // Try to start new pieces if we have available slots
            usz total, complete, downloading;
            ctx.dm.get_progress(&total, &complete, &downloading);
            if (downloading < (usz)ctx.max_concurrent_pieces)  // We have free slots
            {
                // Convert peer's Bitfield to bool[] for piece picker
                bool[] peer_pieces = mem::new_array(bool, total);
                defer free(peer_pieces);

                for (usz j = 0; j < total; j++)
                {
                    peer_pieces[j] = peer_info.pieces.has_piece(j);
                }

                // Try to fill available slots
                int pieces_started = 0;
                for (int i = 0; i < (ctx.max_concurrent_pieces - (int)downloading); i++)
                {
                    if (catch excuse = ctx.dm.start_piece_download(peer_pieces))
                    {
                        break;
                    }
                    pieces_started++;
                }

                if (pieces_started > 0)
                {
                    io::printfn("    Started %d new piece%s (slots: %d/%d)",
                               pieces_started, pieces_started == 1 ? "" : "s",
                               downloading + pieces_started, ctx.max_concurrent_pieces);
                }
            }

            // Now we can start requesting blocks!
            io::printfn("    Starting block requests...");
            request_blocks_from_peers(ctx);

        case peer_wire::MessageType.REQUEST:
            // BEP 6: Handle incoming block request from peer
            // Every REQUEST must get exactly ONE response: PIECE or REJECT_REQUEST
            peer_wire::RequestMsg? req_opt = peer_wire::decode_request(msg.payload);
            if (catch err = req_opt)
            {
                io::printfn("  Invalid REQUEST message from peer %d.%d.%d.%d:%d",
                            ip[0], ip[1], ip[2], ip[3], port);
                return;
            }

            peer_wire::RequestMsg req = req_opt;

            // For now, reject all requests (upload/seeding not yet implemented)
            // TODO: When upload is implemented, check:
            // 1. Do we have the piece? (ctx.dm.have_piece(req.index))
            // 2. Are we choking the peer? (peer.am_choking)
            // 3. If choking, is piece in peer_allowed_fast set?
            // 4. If yes to all: Read block from storage and send PIECE
            // 5. If no: Send REJECT_REQUEST

            // Send REJECT_REQUEST for all requests (leecher mode)
            if (catch excuse = peer.send_reject_request(req.index, req.begin, req.length))
            {
                io::printfn("  Failed to send REJECT_REQUEST to peer %d.%d.%d.%d:%d: %s",
                            ip[0], ip[1], ip[2], ip[3], port, excuse);
            }

        case peer_wire::MessageType.CHOKE:
            io::printfn("  Peer %d.%d.%d.%d:%d choked us",
                        ip[0], ip[1], ip[2], ip[3], port);

        default:
            // Ignore other message types for now
    }
}

/**
 * Request blocks from ready peers to keep the download pipeline full.
 *
 * Attempts to send up to 100 block requests to available peers.
 * Respects BEP 6 Fast Extension choking rules.
 *
 * @param ctx : "Download context"
 */
fn void request_blocks_from_peers(download_session::DownloadContext* ctx) @public
{
    // Try to fill the pipeline with block requests
    int requests_sent = 0;
    for (int attempts = 0; attempts < 100; attempts++)
    {
        // Get next block to request
        block_manager::BlockRequest? req = ctx.dm.get_next_block_request();
        if (catch err = req)
        {
            // No more blocks available right now
            break;
        }

        // Find a ready peer to request from (iterate through peer pool)
        bool requested = false;
        usz total_peers, candidates, connecting, connected;
        ctx.peer_pool.get_stats(&total_peers, &candidates, &connecting, &connected);

        // Count valid peers for debugging
        usz valid_peer_count = 0;
        usz has_connection_count = 0;
        usz is_connected_count = 0;
        usz handshake_ok_count = 0;

        // Get all peers from pool and find one that's READY
        for (usz i = 0; i < ctx.peer_pool.peers.len; i++)
        {
            peer_pool::TorrentPeer* peer_info = ctx.peer_pool.peers[i];

            if (peer_info.connection) has_connection_count++;
            if (peer_info.state == peer_pool::PeerState.CONNECTED) is_connected_count++;
            if (peer_info.handshake_ok) handshake_ok_count++;

            if (peer_info.connection &&
                peer_info.state == peer_pool::PeerState.CONNECTED &&
                peer_info.handshake_ok)
            {
                valid_peer_count++;

                // BEP 6: Check if peer is choking us
                // We can only request if:
                // 1. Peer is not choking us, OR
                // 2. Peer is choking but piece is in allowed_fast set
                if (peer_info.connection.peer_choking)
                {
                    // Check if piece is in allowed_fast set
                    bool is_allowed = false;
                    foreach (allowed_piece : peer_info.connection.allowed_fast_set)
                    {
                        if (allowed_piece == req.piece_index)
                        {
                            is_allowed = true;
                            break;
                        }
                    }

                    if (!is_allowed)
                    {
                        // Skip this peer - choked and piece not in allowed_fast set
                        continue;
                    }
                    // else: proceed to request (choked but piece IS in allowed_fast set)
                }

                // Send REQUEST message
                peer_info.connection.send_request(req.piece_index, req.offset, req.length)!!;

                // Mark block as requested (handle race where piece completes)
                if (catch excuse = ctx.dm.mark_block_requested(req.piece_index, req.offset))
                {
                    // Piece no longer downloading (race condition) - ignore this request
                    break;
                }

                requests_sent++;
                requested = true;
                break;
            }
        }

        if (!requested)
        {
            break;
        }
    }

    if (requests_sent > 0)
    {
        io::printfn("  Sent %d block requests", requests_sent);
    }
}
