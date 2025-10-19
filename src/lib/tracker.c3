module libtorrent::tracker;

import libtorrent::http;
import libtorrent::bencode;
import libtorrent::torrent;
import std::net::url;
import std::time;
import std::math::random;

<*
 BitTorrent Tracker Communication Module
 ========================================
 Implements the BitTorrent tracker protocol (BEP 3).

 Handles announcing to HTTP trackers and parsing peer lists.
*>

// Faults
faultdef TRACKER_CONNECT_FAILED;
faultdef TRACKER_REQUEST_FAILED;
faultdef TRACKER_INVALID_RESPONSE;
faultdef TRACKER_URL_INVALID;

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
 Generate a random 20-byte peer ID.
 Format: -C30001-XXXXXXXXXXXX
 where X are random bytes.

 @return "A 20-byte peer ID"
*>
fn char[20] generate_peer_id()
{
    char[20] peer_id;

    // Client ID prefix: -C30001-
    peer_id[0] = '-';
    peer_id[1] = 'C';
    peer_id[2] = '3';
    peer_id[3] = '0';
    peer_id[4] = '0';
    peer_id[5] = '0';
    peer_id[6] = '1';
    peer_id[7] = '-';

    // Generate 12 random bytes
    // Seed random with current time
    random::DefaultRandom rng;
    random::seed(&rng, (uint)time::now().to_seconds());

    for (usz i = 8; i < 20; i++) {
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
 @return "Complete announce URL with query parameters"
*>
fn String build_announce_url(String tracker_url, char[20]* info_hash,
                              char[20]* peer_id, ushort port,
                              long uploaded, long downloaded, long left,
                              String event)
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

    // Encode info_hash (20 bytes)
    char[] hash_bytes = ((char*)info_hash)[:20];
    String encoded_hash = url::encode(mem, (String)hash_bytes, url::UrlEncodingMode.QUERY);
    defer free(encoded_hash);
    url.appendf("info_hash=%s", encoded_hash);

    // Encode peer_id (20 bytes)
    char[] peer_bytes = ((char*)peer_id)[:20];
    String encoded_peer = url::encode(mem, (String)peer_bytes, url::UrlEncodingMode.QUERY);
    defer free(encoded_peer);
    url.appendf("&peer_id=%s", encoded_peer);

    // Add other parameters
    url.appendf("&port=%d", port);
    url.appendf("&uploaded=%d", uploaded);
    url.appendf("&downloaded=%d", downloaded);
    url.appendf("&left=%d", left);
    url.append("&compact=1");  // Request compact format

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
    // Validate length is multiple of 6
    if (peer_data.len % 6 != 0) {
        return TRACKER_INVALID_RESPONSE?;
    }

    usz count = peer_data.len / 6;
    if (count == 0) {
        Peer[] empty;
        return empty;
    }

    Peer[] peers = mem::new_array(Peer, count);

    for (usz i = 0; i < count; i++) {
        usz offset = i * 6;

        // Copy 4 bytes for IP
        peers[i].ip[0] = peer_data[offset];
        peers[i].ip[1] = peer_data[offset + 1];
        peers[i].ip[2] = peer_data[offset + 2];
        peers[i].ip[3] = peer_data[offset + 3];

        // Parse 2 bytes for port (big-endian / network byte order)
        char byte_high = peer_data[offset + 4];
        char byte_low = peer_data[offset + 5];
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
    if (BencodeValue* failure = bencode::dict_get(root, "failure reason")) {
        if (failure.type == bencode::BencodeType.STRING) {
            response.failure_reason = ((String)failure.string).copy(mem);
            return response;
        }
    }

    // Extract interval (required)
    if (BencodeValue* interval = bencode::dict_get(root, "interval")) {
        if (interval.type == bencode::BencodeType.INTEGER) {
            response.interval = interval.integer;
        }
    }

    // Extract min_interval (optional)
    if (BencodeValue* min_interval = bencode::dict_get(root, "min interval")) {
        if (min_interval.type == bencode::BencodeType.INTEGER) {
            response.min_interval = min_interval.integer;
        }
    }

    // Extract complete (seeders)
    if (BencodeValue* complete = bencode::dict_get(root, "complete")) {
        if (complete.type == bencode::BencodeType.INTEGER) {
            response.complete = complete.integer;
        }
    }

    // Extract incomplete (leechers)
    if (BencodeValue* incomplete = bencode::dict_get(root, "incomplete")) {
        if (incomplete.type == bencode::BencodeType.INTEGER) {
            response.incomplete = incomplete.integer;
        }
    }

    // Extract warning message (optional)
    if (BencodeValue* warning = bencode::dict_get(root, "warning message")) {
        if (warning.type == bencode::BencodeType.STRING) {
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
 Announce to tracker and get peer list.

 @param torrent : "The torrent file"
 @param our_port : "Our listening port"
 @param event : "Event type (started/stopped/completed or empty string)"
 @return "Tracker response with peer list or fault"
*>
fn TrackerResponse? announce(torrent::TorrentFile* torrent, ushort our_port,
                              String event = "") @public
{
    // Generate peer ID
    char[20] peer_id = generate_peer_id();

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
        event
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

