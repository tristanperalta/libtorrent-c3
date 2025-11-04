module libtorrent::fast_extension;

import std::hash::sha1;
import libtorrent::common;

/**
 * BEP 6: Fast Extension - Allowed Fast Set Generation
 * ====================================================
 *
 * Implements the canonical algorithm for computing a peer's allowed fast set.
 * The allowed fast set enables new peers to download pieces even while choked,
 * improving the bootstrap phase of BitTorrent's tit-for-tat algorithm.
 *
 * Algorithm (from BEP 6):
 * ----------------------
 * 1. Take the peer's IP address (most significant 3 octets)
 * 2. Append the torrent's info_hash
 * 3. Iteratively hash with SHA-1 to generate piece indices
 * 4. Each hash yields up to 5 piece indices (20 bytes / 4 bytes each)
 * 5. Continue until k unique piece indices are generated
 *
 * Default k=10 pieces (balances abuse prevention with bootstrap effectiveness)
 */

// ============================================================================
// Constants
// ============================================================================

const uint DEFAULT_ALLOWED_FAST_COUNT = 10;

// ============================================================================
// Allowed Fast Set Generation
// ============================================================================

/**
 * Generate the allowed fast set for a peer (BEP 6 canonical algorithm).
 *
 * This produces a deterministic set of piece indices that this peer is allowed
 * to download even when choked. Both peers compute the same set given the same
 * inputs.
 *
 * @param peer_ip : "Peer's IPv4 address (4 bytes)"
 * @param info_hash : "Torrent info hash (20 bytes)"
 * @param num_pieces : "Total number of pieces in torrent"
 * @param k : "Number of pieces in allowed fast set (default 10)"
 * @return "Array of piece indices in allowed fast set"
 */
fn uint[] generate_allowed_fast_set(common::Ipv4Addr peer_ip, common::InfoHash info_hash,
                                     uint num_pieces, uint k) @public
{
    if (k == 0 || num_pieces == 0)
    {
        return {};
    }

    // Allocate result array
    uint[] allowed_fast = mem::new_array(uint, k);
    uint count = 0;

    // Step 1: Start with peer IP (most significant 3 octets) + info hash
    // x = (ip & 0xFFFFFF00) + info_hash
    // Initial x is 24 bytes, then becomes 20 bytes after first SHA-1
    char[] x;
    char[24] initial_x;

    // Write IP address (big-endian, mask last octet)
    initial_x[0] = peer_ip[0];
    initial_x[1] = peer_ip[1];
    initial_x[2] = peer_ip[2];
    initial_x[3] = 0;  // Mask last octet

    // Append info hash
    for (usz i = 0; i < 20; i++)
    {
        initial_x[i + 4] = info_hash[i];
    }

    // Start with 24-byte initial value
    x = mem::new_array(char, 24);
    for (usz i = 0; i < 24; i++)
    {
        x[i] = initial_x[i];
    }

    // Step 2: Iteratively hash to generate piece indices
    while (count < k)
    {
        // x = SHA1(x)
        char[20] hash = sha1::hash(x);

        // Update x to be the hash result (20 bytes for next iteration)
        free(x);
        x = mem::new_array(char, 20);
        for (usz i = 0; i < 20; i++)
        {
            x[i] = hash[i];
        }

        // Extract up to 5 piece indices from this hash
        for (uint i = 0; i < 5 && count < k; i++)
        {
            // Read 4-byte big-endian integer from hash
            uint j = i * 4;
            uint y = ((uint)(hash[j] & 0xFF) << 24) |
                     ((uint)(hash[j + 1] & 0xFF) << 16) |
                     ((uint)(hash[j + 2] & 0xFF) << 8) |
                     ((uint)(hash[j + 3] & 0xFF));

            // Map to piece index
            uint piece_index = y % num_pieces;

            // Check for duplicates (piece already in set)
            bool duplicate = false;
            for (uint n = 0; n < count; n++)
            {
                if (allowed_fast[n] == piece_index)
                {
                    duplicate = true;
                    break;
                }
            }

            // Add if unique
            if (!duplicate)
            {
                allowed_fast[count] = piece_index;
                count++;
            }
        }
    }

    free(x);

    return allowed_fast;
}

/**
 * Generate allowed fast set with default k=10.
 *
 * @param peer_ip : "Peer's IPv4 address"
 * @param info_hash : "Torrent info hash"
 * @param num_pieces : "Total pieces in torrent"
 * @return "Array of 10 piece indices (or fewer if num_pieces < 10)"
 */
fn uint[] generate_default_allowed_fast_set(common::Ipv4Addr peer_ip,
                                             common::InfoHash info_hash,
                                             uint num_pieces) @public
{
    uint k = DEFAULT_ALLOWED_FAST_COUNT;
    if (num_pieces < k) k = num_pieces;  // Don't generate more than available
    return generate_allowed_fast_set(peer_ip, info_hash, num_pieces, k);
}

/**
 * Check if a piece is in the allowed fast set.
 *
 * @param piece_index : "Piece to check"
 * @param allowed_fast : "Allowed fast set"
 * @return "True if piece is allowed fast"
 */
fn bool is_piece_allowed_fast(uint piece_index, uint[] allowed_fast) @public
{
    foreach (allowed_piece : allowed_fast)
    {
        if (allowed_piece == piece_index)
        {
            return true;
        }
    }
    return false;
}
