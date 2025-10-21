module libtorrent::tracker;

import libtorrent::http;
import libtorrent::bencode;
import libtorrent::metainfo;
import libtorrent::udp_tracker;
import libtorrent::http_tracker;
import libtorrent::event_loop;
import std::net::url;
import std::time;
import std::math::random;

<*
 BitTorrent Tracker Communication Module
 ========================================
 Implements the BitTorrent tracker protocol (BEP 3 and BEP 15).

 Provides a unified interface for HTTP/HTTPS and UDP trackers.
*>

// Faults
faultdef TRACKER_CONNECT_FAILED;
faultdef TRACKER_REQUEST_FAILED;
faultdef TRACKER_INVALID_RESPONSE;
faultdef TRACKER_URL_INVALID;
faultdef TRACKER_UNSUPPORTED_PROTOCOL;

// Default number of peers to request from tracker (BEP 3 standard)
const int DEFAULT_NUMWANT = 50;

// Peer ID and hash size constants
const usz PEER_ID_SIZE = 20;
const usz PEER_ID_PREFIX_LENGTH = 8;
const String PEER_ID_PREFIX = "-C30001-";
const usz SHA1_HASH_SIZE = 20;

// Compact peer format constants (BEP 3)
const usz COMPACT_PEER_SIZE = 6;
const usz IPV4_ADDR_SIZE = 4;
const usz COMPACT_PEER_PORT_SIZE = 2;

<*
 Tracker interface - all tracker implementations must implement this.
 Provides a unified way to announce to different tracker types (HTTP/UDP).
*>
interface Tracker
{
    fn TrackerResponse? announce(metainfo::TorrentFile* torrent, ushort port, String event);
    fn void free();
}

<*
 Peer structure representing a BitTorrent peer.
 Contains IPv4 address and port number.
*>
struct Peer {
    char[4] ip;      // IPv4 address in network byte order
    ushort port;     // Port number
}

<*
 Tracker response structure.
 Contains information received from the tracker.
*>
struct TrackerResponse {
    long interval;          // Re-announce interval in seconds
    long min_interval;      // Minimum announce interval (optional)
    long complete;          // Number of seeders
    long incomplete;        // Number of leechers
    Peer[] peers;          // List of peers
    String failure_reason; // Error message if request failed (empty if none)
    String warning_message; // Optional warning from tracker (empty if none)
}

<*
 HTTP/HTTPS tracker implementation.
*>
struct HttpTracker (Tracker) {
    char _dummy;  // C3 doesn't allow zero-sized structs
}

<*
 Generate a random 20-byte peer ID.
 Format: -C30001-XXXXXXXXXXXX
 where X are random bytes.

 @return "A 20-byte peer ID"
*>
fn char[PEER_ID_SIZE] generate_peer_id()
{
    char[PEER_ID_SIZE] peer_id;

    // Client ID prefix: -C30001-
    foreach (i, c : PEER_ID_PREFIX)
    {
        peer_id[i] = c;
    }

    // Generate random bytes for remainder
    random::DefaultRandom rng;
    random::seed(&rng, (uint)time::now().to_seconds());

    for (usz i = PEER_ID_PREFIX_LENGTH; i < PEER_ID_SIZE; i++)
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
fn String build_announce_url(String tracker_url, char[SHA1_HASH_SIZE]* info_hash,
                              char[PEER_ID_SIZE]* peer_id, ushort port,
                              long uploaded, long downloaded, long left,
                              String event, int numwant)
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
    char[] hash_bytes = ((char*)info_hash)[:SHA1_HASH_SIZE];
    String encoded_hash = url::encode(mem, (String)hash_bytes, url::UrlEncodingMode.QUERY);
    defer free(encoded_hash);
    url.appendf("info_hash=%s", encoded_hash);

    // Encode peer_id
    char[] peer_bytes = ((char*)peer_id)[:PEER_ID_SIZE];
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
fn Peer[]? parse_compact_peers(char[] peer_data)
{
    // Validate length is multiple of COMPACT_PEER_SIZE
    if (peer_data.len % COMPACT_PEER_SIZE != 0) {
        return TRACKER_INVALID_RESPONSE?;
    }

    usz count = peer_data.len / COMPACT_PEER_SIZE;
    if (count == 0) {
        Peer[] empty;
        return empty;
    }

    Peer[] peers = mem::new_array(Peer, count);

    for (usz i = 0; i < count; i++)
    {
        usz offset = i * COMPACT_PEER_SIZE;

        // Copy IPv4 address (4 bytes)
        foreach (j, byte : peer_data[offset:IPV4_ADDR_SIZE])
        {
            peers[i].ip[j] = byte;
        }

        // Parse port (2 bytes, big-endian / network byte order)
        char byte_high = peer_data[offset + IPV4_ADDR_SIZE];
        char byte_low = peer_data[offset + IPV4_ADDR_SIZE + 1];
        peers[i].port = (((ushort)byte_high & 0xFF) << 8) | ((ushort)byte_low & 0xFF);
    }

    return peers;
}

<*
 Parse tracker bencode response.

 @param response_data : "Bencode response from tracker"
 @return "Parsed TrackerResponse or fault"
*>
fn TrackerResponse? parse_tracker_response(String response_data)
{
    BencodeValue* root = bencode::decode(response_data)!;
    defer bencode::free_bencode_value(root);

    if (root.type != bencode::BencodeType.DICT) {
        return TRACKER_INVALID_RESPONSE?;
    }

    TrackerResponse response = {};

    // Check for failure first
    if (BencodeValue* failure = bencode::dict_get(root, "failure reason"))
    {
        if (failure.type == bencode::BencodeType.STRING)
        {
            response.failure_reason = ((String)failure.string).copy(mem);
            return response;
        }
    }

    // Extract tracker response fields
    if (BencodeValue* interval = bencode::dict_get(root, "interval"))
    {
        if (interval.type == bencode::BencodeType.INTEGER)
        {
            response.interval = interval.integer;
        }
    }

    if (BencodeValue* min_interval = bencode::dict_get(root, "min interval"))
    {
        if (min_interval.type == bencode::BencodeType.INTEGER)
        {
            response.min_interval = min_interval.integer;
        }
    }

    if (BencodeValue* complete = bencode::dict_get(root, "complete"))
    {
        if (complete.type == bencode::BencodeType.INTEGER)
        {
            response.complete = complete.integer;
        }
    }

    if (BencodeValue* incomplete = bencode::dict_get(root, "incomplete"))
    {
        if (incomplete.type == bencode::BencodeType.INTEGER)
        {
            response.incomplete = incomplete.integer;
        }
    }

    if (BencodeValue* warning = bencode::dict_get(root, "warning message"))
    {
        if (warning.type == bencode::BencodeType.STRING)
        {
            response.warning_message = ((String)warning.string).copy(mem);
        }
    }

    // Extract peers (compact format)
    if (BencodeValue* peers = bencode::dict_get(root, "peers")) {
        if (peers.type == bencode::BencodeType.STRING) {
            // Compact format (binary string)
            response.peers = parse_compact_peers(peers.string)!;
        }
        // TODO: Handle dictionary format for peers (less common)
    }

    return response;
}

<*
 HTTP tracker announce implementation.

 @param torrent : "The torrent file"
 @param our_port : "Our listening port"
 @param event : "Event type (started/stopped/completed or empty string)"
 @return "Tracker response with peer list or fault"
*>
fn TrackerResponse? HttpTracker.announce(HttpTracker* self, metainfo::TorrentFile* torrent, ushort our_port,
                                          String event) @dynamic
{
    // Generate peer ID
    char[PEER_ID_SIZE] peer_id = generate_peer_id();

    // Parse tracker URL
    Url? tracker_url_parsed = url::parse(mem, torrent.announce);
    if (catch err = tracker_url_parsed) {
        return TRACKER_URL_INVALID?;
    }
    defer tracker_url_parsed.free();

    // Determine protocol and port
    bool use_tls = tracker_url_parsed.scheme == "https";
    ushort tracker_port = (ushort)tracker_url_parsed.port;
    if (tracker_port == 0) {
        tracker_port = use_tls ? 443 : 80;
    }

    // Build announce URL with query parameters
    String announce_url = build_announce_url(
        torrent.announce,
        &torrent.info_hash,
        &peer_id,
        our_port,
        0,  // uploaded
        0,  // downloaded
        torrent.info.length,  // left
        event,
        DEFAULT_NUMWANT  // Request 50 peers
    );
    defer free(announce_url);

    // Parse the full announce URL to extract path + query
    Url? full_url = url::parse(mem, announce_url);
    if (catch err = full_url) {
        return TRACKER_URL_INVALID?;
    }
    defer full_url.free();

    // Build path + query string for HTTP request
    DString path_and_query;
    path_and_query.append(full_url.path);
    if (full_url.query.len > 0) {
        path_and_query.append_char('?');
        path_and_query.append(full_url.query);
    }

    // Create HTTP client
    any client = http::http_client(tracker_url_parsed.host, tracker_port, use_tls);
    if (!client.ptr) {
        return TRACKER_CONNECT_FAILED?;
    }
    defer ((http::HttpClient)client).close();

    // Make HTTP GET request
    String[] empty_headers;
    http::HttpResponse? http_response = ((http::HttpClient)client).request(
        "GET",
        path_and_query.str_view(),  // Path + query
        empty_headers,               // No custom headers
        ""                           // No body
    );

    if (catch err = http_response) {
        return TRACKER_REQUEST_FAILED?;
    }
    defer free(http_response.body);

    // Check HTTP status
    if (http_response.status != 200) {
        return TRACKER_REQUEST_FAILED?;
    }

    // Parse bencode response
    return parse_tracker_response(http_response.body);
}

<*
 Free HTTP tracker instance.
*>
fn void HttpTracker.free(HttpTracker* self) @dynamic
{
    // HttpTracker has no dynamic allocations
    free(self);
}

// Announce callback type
alias AnnounceCallback = fn void(TrackerResponse* response, int status, void* user_data);

<*
 Announce to tracker (non-blocking).
 Routes to HTTP or UDP tracker implementation based on URL.

 @param loop : "Event loop"
 @param torrent : "The torrent file"
 @param our_port : "Our listening port"
 @param event : "Event type (started/stopped/completed or empty string)"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void announce(event_loop::EventLoop* loop,
                 metainfo::TorrentFile* torrent,
                 ushort our_port,
                 String event,
                 AnnounceCallback callback,
                 void* user_data) @public
{
    String url = torrent.announce;

    if (url.starts_with("udp://"))
    {
        // Use UDP tracker async
        udp_tracker::async_announce(loop, torrent, our_port, event,
                                     callback, user_data);
    }
    else if (url.starts_with("http://") || url.starts_with("https://"))
    {
        // Use HTTP tracker async (thread pool)
        http_tracker::async_announce(loop, torrent, our_port, event,
                                      callback, user_data);
    }
    else
    {
        // Invalid URL
        if (callback)
        {
            callback(null, -1, user_data);
        }
    }
}

