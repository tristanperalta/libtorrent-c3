module libtorrent::trackers;

import libtorrent::metainfo;
import libtorrent::common;
import async::event_loop;
import libtorrent::trackers::http;
import libtorrent::trackers::udp;
import libtorrent::bencode;
import std::net::url;
import std::time;
import std::math::random;

/*
 BitTorrent Tracker Interface (Hexagonal Architecture Port)
 ===========================================================

 Defines the abstract interface for tracker protocol implementations.

 Implementations:
 - HttpTracker (trackers/http_tracker.c3) - BEP 3 HTTP/HTTPS tracker
 - UdpTracker (trackers/udp_tracker.c3) - BEP 15 UDP tracker

 This interface follows hexagonal architecture principles, matching the
 patterns used by Transport (network/transport.c3) and PeerDiscovery
 (discovery/peer_discovery.c3).
*/

// ============================================================================
// Callback Type Definitions
// ============================================================================

<*
 Tracker response structure.
 Contains information received from the tracker.
*>
struct TrackerResponse
{
    long interval;                   // Re-announce interval in seconds
    long min_interval;               // Minimum announce interval (optional)
    long complete;                   // Number of seeders
    long incomplete;                 // Number of leechers
    long downloaders;                // BEP 21: Active downloaders (0 if not provided)
    common::SocketAddress[] peers;   // List of peers
    String failure_reason;           // Error message if request failed (empty if none)
    String warning_message;          // Optional warning from tracker (empty if none)
    int retry_in_minutes;            // BEP 31: Minutes until retry (-1 = "never", 0 = not set, >0 = minutes)
}

<*
 Callback invoked when announce completes (success or failure).

 @param response : "Tracker response (null on error)"
 @param status : "0 on success, negative error code on failure"
 @param user_data : "User-provided context pointer"
*>
alias AnnounceCallback = fn void(TrackerResponse* response, int status, void* user_data);

// ============================================================================
// Tracker Interface
// ============================================================================

<*
 Tracker interface - abstraction for HTTP/UDP tracker protocols.

 This interface provides a unified API for communicating with BitTorrent
 trackers regardless of the underlying protocol (HTTP, UDP, etc.).

 Lifecycle:
 1. Create: Use factory function (create_from_url)
 2. Announce: Call announce() with callback
 3. Close: Call close() when done
 4. Free: Caller must free after close()
*>
interface Tracker
{
    // Announce to tracker (async operation).
    // Initiates an asynchronous announce request. The callback will be
    // invoked when the operation completes (either success or failure).
    fn void announce(
        metainfo::TorrentFile* torrent,
        ushort port,
        String event,
        AnnounceCallback callback,
        void* user_data,
        int timeout_seconds
    );

    // Close tracker connection and clean up resources.
    // After calling close(), no further operations should be performed.
    fn void close();

    // Get tracker URL (e.g., "http://tracker.example.com/announce")
    fn String get_url();

    // Get tracker protocol type ("http", "udp", etc.)
    fn String get_protocol();
}

// ============================================================================
// Factory Function
// ============================================================================

// Fault for invalid tracker protocol
faultdef TRACKER_INVALID_PROTOCOL;

<*
 Create tracker from URL (factory function).

 This is the primary entry point for creating tracker instances.
 The protocol is automatically determined from the URL scheme.

 Supported protocols:
 - http:// and https:// - HTTP tracker (BEP 3)
 - udp:// - UDP tracker (BEP 15)

 Example usage:
   Tracker* tracker = create_from_url(loop, "http://tracker.example.com/announce")!!;
   tracker.announce(torrent, port, "started", &callback, user_data, 60);
   tracker.close();
   tracker.free();

 @param loop : "Event loop for async operations"
 @param url : "Tracker URL (determines protocol)"
 @return "Tracker instance (caller must free) or fault on error"
*>
fn Tracker*? create_from_url(event_loop::EventLoop* loop, String url) @public
{
    if (url.starts_with("http://") || url.starts_with("https://"))
    {
        return (Tracker*)http::create(loop, url);
    }
    else if (url.starts_with("udp://"))
    {
        return (Tracker*)udp::create(loop, url);
    }
    else
    {
        // Unknown protocol
        return TRACKER_INVALID_PROTOCOL?;
    }
}

// ============================================================================
// Additional Faults
// ============================================================================

faultdef TRACKER_CONNECT_FAILED;
faultdef TRACKER_REQUEST_FAILED;
faultdef TRACKER_INVALID_RESPONSE;
faultdef TRACKER_URL_INVALID;
faultdef TRACKER_UNSUPPORTED_PROTOCOL;

// ============================================================================
// Constants
// ============================================================================

// Default number of peers to request from tracker (BEP 3 standard)
const int DEFAULT_NUMWANT @public = 50;

// Peer ID prefix constants
const usz PEER_ID_PREFIX_LENGTH = 8;
const String PEER_ID_PREFIX = "-C30001-";

// ============================================================================
// Helper Functions
// ============================================================================

<*
 Generate a random 20-byte peer ID.
 Format: -C30001-XXXXXXXXXXXX
 where X are random bytes.

 @return "A 20-byte peer ID"
*>
fn common::PeerId generate_peer_id() @public
{
    common::PeerId peer_id;

    // Client ID prefix: -C30001-
    foreach (i, c : PEER_ID_PREFIX)
    {
        peer_id[i] = c;
    }

    // Generate random bytes for remainder
    random::DefaultRandom rng;
    random::seed(&rng, (uint)time::now().to_seconds());

    for (usz i = PEER_ID_PREFIX_LENGTH; i < common::PEER_ID_SIZE; i++)
    {
        peer_id[i] = (char)random::next_in_range(&rng, 0, 255);
    }

    return peer_id;
}

<*
 Build tracker announce URL with query parameters.

 @param tracker_url : "The base tracker URL from torrent file"
 @param info_hash : "20-byte torrent info hash"
 @param peer_id : "20-byte peer ID"
 @param port : "Our listening port"
 @param uploaded : "Bytes uploaded"
 @param downloaded : "Bytes downloaded"
 @param left : "Bytes remaining to download"
 @param event : "Event type (started/stopped/completed/empty)"
 @param numwant : "Number of peers requested (default 50)"
 @return "Complete announce URL with query parameters"
*>
fn String build_announce_url(String tracker_url, common::InfoHash* info_hash,
                              common::PeerId* peer_id, ushort port,
                              long uploaded, long downloaded, long left,
                              String event, int numwant) @public
{
    DString url;
    url.append(tracker_url);

    // Add query separator (check if URL already has query params)
    usz? question_pos = tracker_url.index_of_char('?');
    if (catch excuse = question_pos) {
        url.append_char('?');
    } else {
        url.append_char('&');
    }

    // Encode info_hash
    char[] hash_bytes = ((char*)info_hash)[:common::SHA1_HASH_SIZE];
    String encoded_hash = url::encode(mem, (String)hash_bytes, url::UrlEncodingMode.QUERY);
    defer free(encoded_hash);
    url.appendf("info_hash=%s", encoded_hash);

    // Encode peer_id
    char[] peer_bytes = ((char*)peer_id)[:common::PEER_ID_SIZE];
    String encoded_peer = url::encode(mem, (String)peer_bytes, url::UrlEncodingMode.QUERY);
    defer free(encoded_peer);
    url.appendf("&peer_id=%s", encoded_peer);

    // Add other parameters
    url.appendf("&port=%d", port);
    url.appendf("&uploaded=%d", uploaded);
    url.appendf("&downloaded=%d", downloaded);
    url.appendf("&left=%d", left);
    url.append("&compact=1");  // Request compact format
    url.appendf("&numwant=%d", numwant);  // Number of peers requested

    // Add event if not empty
    if (event.len > 0) {
        url.appendf("&event=%s", event);
    }

    return url.copy_str(mem);
}

<*
 Parse compact peer list format.
 Each peer is 6 bytes: 4 bytes IP + 2 bytes port (big-endian).

 @param peer_data : "Raw peer data from tracker"
 @return "Array of parsed peers or fault"
*>
fn common::SocketAddress[]? parse_compact_peers(char[] peer_data, Allocator allocator = mem) @public
{
    // Validate length is multiple of 6
    const usz IPV4_COMPACT_SIZE = 6;  // 4 bytes IP + 2 bytes port
    if (peer_data.len % IPV4_COMPACT_SIZE != 0) {
        return TRACKER_INVALID_RESPONSE?;
    }

    usz count = peer_data.len / IPV4_COMPACT_SIZE;
    if (count == 0) {
        common::SocketAddress[] empty;
        return empty;
    }

    common::SocketAddress[] peers = allocator::alloc_array(allocator, common::SocketAddress, count);

    for (usz i = 0; i < count; i++)
    {
        usz offset = i * IPV4_COMPACT_SIZE;

        // Manually parse instead of using slice to avoid C3 compiler issue
        peers[i].addr.is_ipv6 = false;
        peers[i].addr.ipv4.a = peer_data[offset];
        peers[i].addr.ipv4.b = peer_data[offset + 1];
        peers[i].addr.ipv4.c = peer_data[offset + 2];
        peers[i].addr.ipv4.d = peer_data[offset + 3];
        peers[i].port = ((ushort)peer_data[offset + 4] << 8) | (ushort)peer_data[offset + 5];
    }

    return peers;
}

<*
 Parse tracker bencode response.

 @param response_data : "Bencode response from tracker"
 @return "Parsed TrackerResponse or fault"
*>
fn TrackerResponse? parse_tracker_response(String response_data) @public
{
    bencode::BencodeValue* root = bencode::decode(response_data)!;
    defer root.free();

    if (root.type != bencode::BencodeType.DICT) {
        return TRACKER_INVALID_RESPONSE?;
    }

    TrackerResponse response = {};

    // Check for failure first (but still parse retry_in before returning)
    if (bencode::BencodeValue* failure = root.dict_get("failure reason"))
    {
        if (failure.type == bencode::BencodeType.STRING)
        {
            response.failure_reason = ((String)failure.string).copy(mem);

            // BEP 31: Parse retry_in even with failure_reason
            if (bencode::BencodeValue* retry_in = root.dict_get("retry in"))
            {
                if (retry_in.type == bencode::BencodeType.INTEGER)
                {
                    response.retry_in_minutes = (int)retry_in.integer;
                }
                else if (retry_in.type == bencode::BencodeType.STRING)
                {
                    String retry_str = (String)retry_in.string;
                    if (retry_str == "never")
                    {
                        response.retry_in_minutes = -1;
                    }
                }
            }

            return response;
        }
    }

    // Extract tracker response fields
    if (bencode::BencodeValue* interval = root.dict_get("interval"))
    {
        if (interval.type == bencode::BencodeType.INTEGER)
        {
            response.interval = interval.integer;
        }
    }

    if (bencode::BencodeValue* min_interval = root.dict_get("min interval"))
    {
        if (min_interval.type == bencode::BencodeType.INTEGER)
        {
            response.min_interval = min_interval.integer;
        }
    }

    if (bencode::BencodeValue* complete = root.dict_get("complete"))
    {
        if (complete.type == bencode::BencodeType.INTEGER)
        {
            response.complete = complete.integer;
        }
    }

    if (bencode::BencodeValue* incomplete = root.dict_get("incomplete"))
    {
        if (incomplete.type == bencode::BencodeType.INTEGER)
        {
            response.incomplete = incomplete.integer;
        }
    }

    // BEP 21: Parse downloaders field (active downloaders, excluding partial seeds)
    if (bencode::BencodeValue* downloaders = root.dict_get("downloaders"))
    {
        if (downloaders.type == bencode::BencodeType.INTEGER)
        {
            response.downloaders = downloaders.integer;
        }
    }

    if (bencode::BencodeValue* warning = root.dict_get("warning message"))
    {
        if (warning.type == bencode::BencodeType.STRING)
        {
            response.warning_message = ((String)warning.string).copy(mem);
        }
    }

    // BEP 31: Parse retry_in field (can be integer minutes or string "never")
    if (bencode::BencodeValue* retry_in = root.dict_get("retry in"))
    {
        if (retry_in.type == bencode::BencodeType.INTEGER)
        {
            response.retry_in_minutes = (int)retry_in.integer;
        }
        else if (retry_in.type == bencode::BencodeType.STRING)
        {
            String retry_str = (String)retry_in.string;
            if (retry_str == "never")
            {
                response.retry_in_minutes = -1;  // -1 indicates "never"
            }
        }
    }

    // Extract peers (BEP 7: support both IPv4 "peers" and IPv6 "peers6")
    common::SocketAddress[] ipv4_peers = {};
    common::SocketAddress[] ipv6_peers = {};

    // Parse IPv4 peers from "peers" key
    if (bencode::BencodeValue* peers = root.dict_get("peers"))
    {
        if (peers.type == bencode::BencodeType.STRING)
        {
            // Compact format (6 bytes per peer: 4-byte IP + 2-byte port)
            common::SocketAddress[]? ipv4_result = parse_compact_peers(peers.string);
            if (catch err = ipv4_result)
            {
                ipv4_peers = {};  // Ignore parse errors, continue with IPv6
            }
            else
            {
                ipv4_peers = ipv4_result;
            }
        }
        // TODO: Handle dictionary format for peers (less common)
    }

    // Parse IPv6 peers from "peers6" key (BEP 7)
    if (bencode::BencodeValue* peers6 = root.dict_get("peers6"))
    {
        if (peers6.type == bencode::BencodeType.STRING)
        {
            // Compact IPv6 format (18 bytes per peer: 16-byte IP + 2-byte port)
            usz count = peers6.string.len / common::COMPACT_PEER_IPV6_SIZE;
            if (count > 0 && peers6.string.len % common::COMPACT_PEER_IPV6_SIZE == 0)
            {
                ipv6_peers = mem::new_array(common::SocketAddress, count);
                for (usz i = 0; i < count; i++)
                {
                    usz offset = i * common::COMPACT_PEER_IPV6_SIZE;
                    char[] compact_data = peers6.string[offset:offset + common::COMPACT_PEER_IPV6_SIZE];

                    if (catch err = common::socket_address_from_compact_ipv6(compact_data))
                    {
                        // Skip invalid peer, continue with next
                        continue;
                    }
                    ipv6_peers[i] = common::socket_address_from_compact_ipv6(compact_data)!!;
                }
            }
        }
    }

    // Combine IPv4 and IPv6 peers into single array
    usz total_peers = ipv4_peers.len + ipv6_peers.len;
    if (total_peers > 0)
    {
        response.peers = mem::new_array(common::SocketAddress, total_peers);

        // Copy IPv4 peers first
        for (usz i = 0; i < ipv4_peers.len; i++)
        {
            response.peers[i] = ipv4_peers[i];
        }

        // Then IPv6 peers
        for (usz i = 0; i < ipv6_peers.len; i++)
        {
            response.peers[ipv4_peers.len + i] = ipv6_peers[i];
        }

        // Free temporary arrays
        if (ipv4_peers.len > 0) free(ipv4_peers);
        if (ipv6_peers.len > 0) free(ipv6_peers);
    }
    else
    {
        response.peers = {};  // No peers
    }

    return response;
}
