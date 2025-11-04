module libtorrent::magnet_link;

import std::io;
import std::collections::list;
import std::net::url;
import std::encoding::hex;
import std::encoding::base32;

/**
 * BEP 9: Magnet URI Format Parser
 * ================================
 *
 * Parses magnet links of the format:
 * magnet:?xt=urn:btih:<info-hash>&dn=<name>&tr=<tracker-url>&x.pe=<peer>
 *
 * Required parameter:
 * - xt: exact topic (info hash) - urn:btih:<40-char-hex> or urn:btih:<32-char-base32>
 *
 * Optional parameters:
 * - dn: display name (URL encoded)
 * - tr: tracker URL (can appear multiple times)
 * - x.pe: peer address as host:port (can appear multiple times)
 */

// ============================================================================
// Structures
// ============================================================================

/**
 * Parsed magnet link components
 */
struct MagnetLink
{
    char[20] info_hash;  // Required: BitTorrent info hash (20 bytes)
    String name;         // Optional: Display name (empty if not present)
    String[] trackers;   // Optional: Tracker URLs
    String[] peers;      // Optional: Peer addresses (host:port format)
}

// ============================================================================
// Fault Definitions
// ============================================================================

faultdef MAGNET_INVALID_FORMAT;
faultdef MAGNET_MISSING_XT;
faultdef MAGNET_INVALID_INFOHASH;
faultdef MAGNET_INVALID_URN;

// ============================================================================
// Info Hash Decoding Functions
// ============================================================================

/**
 * Decode a hex-encoded info hash (40 characters -> 20 bytes)
 * Uses C3's standard library hex decoder
 *
 * @param hex_str : "40-character hex string"
 * @return "20-byte info hash or fault"
 */
fn char[20]? decode_hex_info_hash(String hex_str) @private
{
    if (hex_str.len != 40)
    {
        return MAGNET_INVALID_INFOHASH?;
    }

    // Use C3's hex decoder
    char[]? decoded = hex::decode(mem, (char[])hex_str);
    if (catch decoded)
    {
        return MAGNET_INVALID_INFOHASH?;
    }
    defer free(decoded);

    // Verify we got exactly 20 bytes
    if (decoded.len != 20)
    {
        return MAGNET_INVALID_INFOHASH?;
    }

    // Copy to fixed-size array
    char[20] hash;
    foreach (i, b : decoded)
    {
        hash[i] = b;
    }

    return hash;
}

/**
 * Decode a base32-encoded info hash (32 characters -> 20 bytes)
 * Uses C3's standard library base32 decoder
 *
 * @param base32_str : "32-character base32 string"
 * @return "20-byte info hash or fault"
 */
fn char[20]? decode_base32_info_hash(String base32_str) @private
{
    if (base32_str.len != 32)
    {
        return MAGNET_INVALID_INFOHASH?;
    }

    // Use C3's base32 decoder (no padding for magnet links)
    char[]? decoded = base32::decode(mem, (char[])base32_str, padding: '\0');
    if (catch decoded)
    {
        return MAGNET_INVALID_INFOHASH?;
    }
    defer free(decoded);

    // Verify we got exactly 20 bytes
    if (decoded.len != 20)
    {
        return MAGNET_INVALID_INFOHASH?;
    }

    // Copy to fixed-size array
    char[20] hash;
    foreach (i, b : decoded)
    {
        hash[i] = b;
    }

    return hash;
}

/**
 * Parse the xt (exact topic) parameter to extract info hash
 *
 * @param xt_value : "Value of xt parameter (e.g., urn:btih:ABC123...)"
 * @return "20-byte info hash or fault"
 */
fn char[20]? parse_xt_parameter(String xt_value) @private
{
    // Expected format: urn:btih:<info-hash>
    // <info-hash> can be 40-char hex or 32-char base32

    if (!xt_value.starts_with("urn:btih:"))
    {
        return MAGNET_INVALID_URN?;
    }

    String hash_str = xt_value[9..];  // Skip "urn:btih:"

    // Try hex first (40 chars)
    if (hash_str.len == 40)
    {
        return decode_hex_info_hash(hash_str);
    }
    // Try base32 (32 chars)
    else if (hash_str.len == 32)
    {
        return decode_base32_info_hash(hash_str);
    }
    else
    {
        return MAGNET_INVALID_INFOHASH?;
    }
}

/**
 * Parse a magnet URI into its components
 *
 * @param uri : "Magnet URI (magnet:?...)"
 * @return "Parsed magnet link or fault"
 */
fn MagnetLink*? parse(String uri) @public
{
    // Verify it starts with "magnet:?"
    if (!uri.starts_with("magnet:?"))
    {
        return MAGNET_INVALID_FORMAT?;
    }

    String query_string = uri[8..];  // Skip "magnet:?"

    // Parse query parameters using C3's standard library
    url::UrlQueryValues params = url::parse_query(mem, query_string);
    defer params.free();

    // Extract xt (exact topic / info hash) - required
    String xt_value;
    bool found_xt = false;
    if (try url::UrlQueryValueList xt_list = params["xt"])
    {
        if (xt_list.len() > 0 && xt_list[0].len > 0)
        {
            xt_value = xt_list[0];
            found_xt = true;
        }
    }

    // Extract dn (display name) - optional
    String display_name = "";
    if (try url::UrlQueryValueList dn_list = params["dn"])
    {
        if (dn_list.len() > 0 && dn_list[0].len > 0)
        {
            display_name = dn_list[0].copy(mem);
        }
    }

    // Extract tr (tracker URLs) - optional, can appear multiple times
    List{String} tracker_list;
    tracker_list.init(mem);
    if (try url::UrlQueryValueList tr_list = params["tr"])
    {
        foreach (tracker : tr_list)
        {
            if (tracker.len > 0)
            {
                tracker_list.push(tracker.copy(mem));
            }
        }
    }

    // Extract x.pe (peer addresses) - optional, can appear multiple times
    List{String} peer_list;
    peer_list.init(mem);
    if (try url::UrlQueryValueList pe_list = params["x.pe"])
    {
        foreach (peer : pe_list)
        {
            if (peer.len > 0)
            {
                peer_list.push(peer.copy(mem));
            }
        }
    }

    // xt is mandatory
    if (!found_xt)
    {
        // Free allocated strings in lists
        foreach (tracker : tracker_list)
        {
            if (tracker.len > 0) free(tracker);
        }
        tracker_list.free();

        foreach (peer : peer_list)
        {
            if (peer.len > 0) free(peer);
        }
        peer_list.free();

        if (display_name.len > 0) free(display_name);
        return MAGNET_MISSING_XT?;
    }

    // Parse info hash from xt parameter
    char[20]? hash_opt = parse_xt_parameter(xt_value);
    if (catch err = hash_opt)
    {
        // Free allocated strings in lists
        foreach (tracker : tracker_list)
        {
            if (tracker.len > 0) free(tracker);
        }
        tracker_list.free();

        foreach (peer : peer_list)
        {
            if (peer.len > 0) free(peer);
        }
        peer_list.free();

        if (display_name.len > 0) free(display_name);
        return err?;
    }

    // Create MagnetLink struct
    MagnetLink* magnet = mem::new(MagnetLink);
    magnet.info_hash = hash_opt;
    magnet.name = display_name;  // Use the display_name (empty literal or allocated string)

    // Convert lists to arrays
    magnet.trackers = mem::new_array(String, tracker_list.len());
    foreach (i, tracker : tracker_list)
    {
        magnet.trackers[i] = tracker;
    }
    tracker_list.free();

    magnet.peers = mem::new_array(String, peer_list.len());
    foreach (i, peer : peer_list)
    {
        magnet.peers[i] = peer;
    }
    peer_list.free();

    return magnet;
}

/**
 * Free a MagnetLink and its resources
 */
fn void MagnetLink.free(&self) @public
{
    if (self.name.len > 0)
    {
        free(self.name);
    }

    foreach (tracker : self.trackers)
    {
        if (tracker.len > 0) free(tracker);
    }
    if (self.trackers.len > 0)
    {
        free(self.trackers);
    }

    foreach (peer : self.peers)
    {
        if (peer.len > 0) free(peer);
    }
    if (self.peers.len > 0)
    {
        free(self.peers);
    }

    free(self);
}
