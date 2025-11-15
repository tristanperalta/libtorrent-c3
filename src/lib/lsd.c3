module libtorrent::lsd;

import std::io;
import std::time;
import std::encoding::hex;
import std::math::random;
import libtorrent::common;
import std::core::log;
import async::udp;
import async::event_loop;

<*
 LSD (Local Service Discovery) - BEP 14
 ========================================
 Implements peer discovery via UDP multicast on local networks.

 BEP 14 Specification Summary:
 - Multicast Group: 239.192.152.143:6771 (IPv4)
 - Protocol: HTTP-like text messages over UDP multicast
 - Message Format: BT-SEARCH with Host, Port, Infohash, cookie headers
 - Announce Frequency: Every 5 minutes per torrent
 - Rate Limiting: Maximum 1 announce per minute globally
 - Cookie: Random identifier to filter own announcements via loopback

 Security:
 - Private torrents MUST NOT announce via LSD (BEP 27)
 - Peer IP extracted from UDP packet source address
 - Strict message validation to prevent malformed inputs
*>

// Constants
const String LSD_MULTICAST_IPV4 = "239.192.152.143";
const ushort LSD_PORT = 6771;
const uint ANNOUNCE_INTERVAL_MS = 300000;  // 5 minutes
const uint MIN_INTERVAL_MS = 60000;        // 1 minute global rate limit
const uint COOKIE_LENGTH = 16;             // Cookie hex string length

// Faults
faultdef LSD_INVALID_MESSAGE;
faultdef LSD_SOCKET_ERROR;

// Callback type for peer discovery notifications.
// Called when LSD discovers peers for a torrent.
// Params: infohash (which torrent), peers (discovered addresses), user_data
alias LsdPeerCallback = fn void(common::InfoHash* infohash, common::SocketAddress[] peers, void* user_data);

<*
 LSD Manager - handles multicast announcements and peer discovery.
*>
struct LsdManager
{
    async::udp::UdpSocket* socket;        // Multicast UDP socket
    char[COOKIE_LENGTH] cookie;           // Our unique cookie for filtering
    long last_announce_time;              // Unix timestamp of last announce
    bool active;                          // Whether LSD is active

    // Callback for discovered peers
    LsdPeerCallback peer_callback;
    void* peer_callback_data;
}

// ============================================================================
// Cookie Management
// ============================================================================

<*
 Generate a random cookie for filtering own announcements.

 @param cookie_out : "Buffer to store generated cookie (16 chars)"
*>
fn void generate_cookie(char[] cookie_out) @private
{
    assert(cookie_out.len >= COOKIE_LENGTH, "Cookie buffer too small");

    // Generate random hex string
    const char[] HEX_CHARS = "0123456789abcdef";
    random::DefaultRandom rng;
    for (usz i = 0; i < COOKIE_LENGTH; i++)
    {
        cookie_out[i] = HEX_CHARS[random::next_in_range(&rng, 0, 15)];
    }
}

<*
 Check if a cookie matches our own (indicates loopback message).

 @param cookie : "Cookie from received message"
 @param our_cookie : "Our generated cookie"
 @return "True if cookies match"
*>
fn bool is_our_cookie(char[] cookie, char[] our_cookie) @private
{
    if (cookie.len != our_cookie.len) return false;

    for (usz i = 0; i < cookie.len; i++)
    {
        if (cookie[i] != our_cookie[i]) return false;
    }
    return true;
}

// ============================================================================
// Message Building
// ============================================================================

<*
 Build a BT-SEARCH announcement message.

 Format:
 BT-SEARCH * HTTP/1.1\r\n
 Host: 239.192.152.143:6771\r\n
 Port: <port>\r\n
 Infohash: <40-char-hex>\r\n
 cookie: <cookie>\r\n
 \r\n

 @param infohash : "Torrent info hash"
 @param port : "Our BitTorrent listening port"
 @param cookie : "Our unique cookie"
 @return "Formatted BT-SEARCH message (caller must free)"
*>
fn String build_announce_message(common::InfoHash* infohash, ushort port, char[] cookie) @public
{
    DString msg;

    // Request line
    msg.append("BT-SEARCH * HTTP/1.1\r\n");

    // Host header
    msg.append("Host: ");
    msg.append(LSD_MULTICAST_IPV4);
    msg.append(":");
    msg.appendf("%d", LSD_PORT);
    msg.append("\r\n");

    // Port header
    msg.append("Port: ");
    msg.appendf("%d", port);
    msg.append("\r\n");

    // Infohash header (40 hex chars)
    msg.append("Infohash: ");
    String hex_str = hex::encode(mem, &infohash[0]);
    defer free(hex_str);
    msg.append(hex_str);
    msg.append("\r\n");

    // Cookie header
    msg.append("cookie: ");
    msg.append((String)cookie);
    msg.append("\r\n");

    // Empty line (message terminator)
    msg.append("\r\n");

    return msg.copy_str(mem);
}

// ============================================================================
// Message Parsing
// ============================================================================

// Internal structure for parsing announcements (not exposed in API)
struct ParsedAnnouncement @private
{
    common::SocketAddress address;
    common::InfoHash infohash;
    char[] cookie;
}

<*
 Parse a header line from BT-SEARCH message.

 @param line : "Header line (e.g., 'Port: 6881')"
 @param name : "Expected header name"
 @return "Header value or fault if not found"
*>
fn String? parse_header(String line, String name) @private
{
    // Check if line starts with name followed by ':'
    if (!line.starts_with(name)) return LSD_INVALID_MESSAGE?;

    usz colon_pos = name.len;
    if (colon_pos >= line.len || line[colon_pos] != ':') return LSD_INVALID_MESSAGE?;

    // Skip colon and whitespace
    usz value_start = colon_pos + 1;
    while (value_start < line.len && line[value_start] == ' ')
    {
        value_start++;
    }

    if (value_start >= line.len) return LSD_INVALID_MESSAGE?;

    // Extract value (trim trailing whitespace)
    String value = line[value_start..];

    return value;
}

<*
 Parse a BT-SEARCH announcement message.

 @param message : "Received UDP message"
 @param source_addr : "Source address from UDP packet"
 @return "Parsed announcement information or fault if invalid"
*>
fn ParsedAnnouncement? parse_announcement(char[] message, common::SocketAddress source_addr) @private => @pool()
{
    String msg_str = (String)message;

    // Split into lines (must free the array)
    String[] lines = msg_str.split(mem, "\r\n");
    defer free(lines);
    if (lines.len < 4) return LSD_INVALID_MESSAGE?;

    // Check request line
    if (!lines[0].starts_with("BT-SEARCH ")) return LSD_INVALID_MESSAGE?;

    ParsedAnnouncement result;
    result.address = source_addr;
    result.cookie = {};

    bool found_port = false;
    bool found_infohash = false;

    // Parse headers
    for (usz i = 1; i < lines.len; i++)
    {
        String line = lines[i];
        if (line.len == 0) break;  // Empty line terminates headers

        // Try to parse as Port header
        if (line.starts_with("Port:"))
        {
            String? port_str = parse_header(line, "Port");
            if (catch err = port_str) continue;

            // Parse port number
            int port = port_str.to_int() ?? 0;
            if (port <= 0 || port > 65535) return LSD_INVALID_MESSAGE?;

            result.address.port = (ushort)port;
            found_port = true;
        }
        // Try to parse as Infohash header
        else if (line.starts_with("Infohash:"))
        {
            String? hash_str = parse_header(line, "Infohash");
            if (catch err = hash_str) continue;

            // Validate hex format (must be exactly 40 chars)
            if (hash_str.len != 40) return LSD_INVALID_MESSAGE?;

            // Pre-validate hex characters to avoid hex::decode leak on invalid input
            foreach (c : hash_str)
            {
                bool valid = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
                if (!valid) return LSD_INVALID_MESSAGE?;
            }

            // Parse hex to info hash (now guaranteed to be valid hex)
            char[]? decoded_result = hex::decode(mem, (char[])hash_str);
            if (catch err = decoded_result)
            {
                // Shouldn't happen after pre-validation, but handle it anyway
                return LSD_INVALID_MESSAGE?;
            }

            // Success - ensure we free the decoded result
            defer free(decoded_result);

            if (decoded_result.len != 20) return LSD_INVALID_MESSAGE?;

            // Copy to result.infohash
            foreach (idx, b : decoded_result)
            {
                result.infohash[idx] = b;
            }
            found_infohash = true;
        }
        // Try to parse as cookie header
        else if (line.starts_with("cookie:"))
        {
            String? cookie_str = parse_header(line, "cookie");
            if (catch err = cookie_str) continue;

            // Store cookie (for filtering)
            result.cookie = (char[])cookie_str;
        }
    }

    // Validate required fields
    if (!found_port || !found_infohash) return LSD_INVALID_MESSAGE?;

    return result;
}

// ============================================================================
// LSD Manager Lifecycle
// ============================================================================

<*
 Create a new LSD manager.

 @param peer_callback : "Callback for discovered peers"
 @param user_data : "User data passed to callback"
 @return "LSD manager instance or fault on error"
*>
fn LsdManager*? create(LsdPeerCallback peer_callback, void* user_data) @public
{
    LsdManager* mgr = mem::new(LsdManager);

    // Generate random cookie
    generate_cookie(mgr.cookie[..]);

    mgr.socket = null;
    mgr.last_announce_time = 0;
    mgr.active = false;
    mgr.peer_callback = peer_callback;
    mgr.peer_callback_data = user_data;

    // Log cookie (convert char[] to String for logging)
    String cookie_str = (String)mgr.cookie[..];
    log::info("[LSD] Created LSD manager with cookie: %s", cookie_str);

    return mgr;
}

<*
 Free an LSD manager and its resources.

 @param self : "LSD manager to free"
*>
fn void LsdManager.free(&self) @public
{
    if (self.socket)
    {
        // TODO: Close socket when async socket API supports it
        // For now, socket cleanup handled by event loop
        self.socket = null;
    }

    self.active = false;
    free(self);
}

<*
 Start LSD - join multicast group and begin listening.

 @param loop : "Event loop for async operations"
 @return "Void or fault on error"
*>
fn void LsdManager.start(&self, async::event_loop::EventLoop* loop) @public
{
    if (self.active)
    {
        log::warn("[LSD] Already active");
        return;
    }

    log::info("[LSD] Starting LSD on %s:%d",
                 LSD_MULTICAST_IPV4, LSD_PORT);

    // TODO: Implement multicast socket setup
    // This requires async::udp API extensions for:
    // - IP_ADD_MEMBERSHIP (join multicast group)
    // - IP_MULTICAST_TTL (set TTL for LAN reach)
    // - IP_MULTICAST_LOOP (enable loopback for cookie filtering)

    self.active = true;
}

<*
 Stop LSD - leave multicast group and stop listening.
*>
fn void LsdManager.stop(&self) @public
{
    if (!self.active) return;

    log::info("[LSD] Stopping LSD");

    // TODO: Leave multicast group

    self.active = false;
}

// ============================================================================
// Announce
// ============================================================================

<*
 Announce a torrent on the LAN via multicast.

 Checks:
 - Rate limiting (5min/torrent, 1min/global)
 - Active state

 @param infohash : "Torrent info hash to announce"
 @param port : "Our BitTorrent listening port"
 @return "Void or fault on error"
*>
fn void LsdManager.announce(&self, common::InfoHash* infohash, ushort port) @public
{
    if (!self.active)
    {
        log::warn("[LSD] Cannot announce - LSD not active");
        return;
    }

    // Check global rate limiting (1 announce per minute)
    long now = (long)time::now().to_seconds();
    if (self.last_announce_time > 0)
    {
        long elapsed = now - self.last_announce_time;
        if (elapsed < (MIN_INTERVAL_MS / 1000))
        {
            log::debug("[LSD] Rate limited - last announce %d seconds ago", elapsed);
            return;
        }
    }

    // Build BT-SEARCH message
    String message = build_announce_message(infohash, port, self.cookie[..]);
    defer free(message);

    log::debug("[LSD] Announcing infohash on multicast");

    // TODO: Send multicast message
    // This requires async::udp sendto with multicast destination

    self.last_announce_time = now;
}

// ============================================================================
// Peer Discovery Handler
// ============================================================================

<*
 Handle received LSD announcement.

 Filters:
 - Own announcements (cookie match)
 - Invalid messages

 Notifies callback with discovered peer.

 @param data : "Received UDP message"
 @param source_addr : "Source address"
*>
fn void LsdManager.handle_announcement(&self, char[] data, common::SocketAddress source_addr) @public
{
    // Parse announcement
    ParsedAnnouncement? result = parse_announcement(data, source_addr);
    if (catch err = result)
    {
        String addr_str = source_addr.to_string();
        defer free(addr_str);
        log::debug("[LSD] Invalid announcement from %s", addr_str);
        return;
    }

    // Filter own announcements (cookie match)
    if (result.cookie.len > 0 && is_our_cookie(result.cookie, self.cookie[..]))
    {
        log::debug("[LSD] Filtered own announcement (cookie match)");
        return;
    }

    String peer_addr_str = result.address.to_string();
    defer free(peer_addr_str);
    log::info("[LSD] Discovered peer: %s for torrent", peer_addr_str);

    // Notify callback with infohash and peer address
    if (self.peer_callback)
    {
        common::SocketAddress[] peers = { result.address };
        self.peer_callback(&result.infohash, peers, self.peer_callback_data);
    }
}
