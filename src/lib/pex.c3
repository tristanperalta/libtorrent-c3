module libtorrent::pex;

import std::io;
import libtorrent::bencode;
import libtorrent::common;

<*
 PEX (Peer Exchange) - BEP 11
 =============================
 Implements peer exchange protocol for sharing peer lists between clients.

 BEP 11 Specification Summary:
 - Extension name: "ut_pex"
 - Rate limit: Maximum 1 PEX message per minute per peer
 - Max peers per message: 50 added + 50 dropped (per address family)
 - Message format: Bencoded dictionary with:
   - "added": IPv4 peers in compact format (6 bytes each: 4 IP + 2 port)
   - "added.f": Flags for each added peer (1 byte per peer)
   - "added6": IPv6 peers in compact format (18 bytes each)
   - "added6.f": Flags for each IPv6 peer
   - "dropped": IPv4 peers that disconnected (6 bytes each)
   - "dropped6": IPv6 peers that disconnected (18 bytes each)

 Peer Flags (bitfield):
 - 0x01: Prefers encryption
 - 0x02: Seed/upload-only
 - 0x04: Supports uTP
 - 0x08: Supports ut_holepunch
 - 0x10: Reachable (not firewalled)
*>

// Faults
faultdef PEX_INVALID_MESSAGE;
faultdef PEX_INVALID_COMPACT_FORMAT;

// PEX peer flags (BEP 11)
enum PexFlags : const char
{
    PREFERS_ENCRYPTION = 0x01,
    SEED = 0x02,
    SUPPORTS_UTP = 0x04,
    SUPPORTS_HOLEPUNCH = 0x08,
    REACHABLE = 0x10
}

<*
 Single peer in PEX message (IPv4).
*>
struct PexPeer
{
    common::Ipv4Addr ip;    // IPv4 address
    ushort port;            // Port number
    char flags;             // Peer flags (PexFlags bitfield)
}

<*
 Single peer in PEX message (IPv6).
*>
struct PexPeerV6
{
    common::Ipv6Addr ip;    // IPv6 address
    ushort port;            // Port number
    char flags;             // Peer flags (PexFlags bitfield)
}

<*
 PEX message payload.

 Contains lists of added and dropped peers (IPv4 and IPv6).
 Each list can contain up to 50 peers (BEP 11 requirement).
*>
struct PexMessage
{
    PexPeer[] added;      // Newly connected IPv4 peers
    PexPeer[] dropped;    // Recently disconnected IPv4 peers
    PexPeerV6[] added6;   // Newly connected IPv6 peers
    PexPeerV6[] dropped6; // Recently disconnected IPv6 peers
}

// ============================================================================
// IP Address Validation (Security)
// ============================================================================

<*
 Check if an IPv4 address is in a private/reserved range.

 BEP 11 Security: We should not accept or broadcast peers with private or
 reserved IP addresses to prevent network abuse and security issues.

 Private/Reserved ranges:
 - 0.0.0.0/8        (current network)
 - 10.0.0.0/8       (private)
 - 127.0.0.0/8      (loopback)
 - 169.254.0.0/16   (link-local)
 - 172.16.0.0/12    (private)
 - 192.168.0.0/16   (private)
 - 224.0.0.0/4      (multicast)
 - 240.0.0.0/4      (reserved)

 @param ip : "IPv4 address to check"
 @return "True if the IP is private/reserved and should be rejected"
*>
fn bool is_private_or_reserved_ip(common::Ipv4Addr ip) @public
{
    char first = ip[0];
    char second = ip[1];

    // 0.0.0.0/8 - Current network
    if (first == 0) return true;

    // 10.0.0.0/8 - Private network
    if (first == 10) return true;

    // 127.0.0.0/8 - Loopback
    if (first == 127) return true;

    // 169.254.0.0/16 - Link-local
    if (first == 169 && second == 254) return true;

    // 172.16.0.0/12 - Private network (172.16.0.0 - 172.31.255.255)
    if (first == 172 && second >= 16 && second <= 31) return true;

    // 192.168.0.0/16 - Private network
    if (first == 192 && second == 168) return true;

    // 224.0.0.0/4 - Multicast (224-239)
    if (first >= 224 && first <= 239) return true;

    // 240.0.0.0/4 - Reserved (240-255)
    if (first >= 240) return true;

    // Public IP address
    return false;
}

<*
 Validate a peer for security before accepting from PEX.

 Checks:
 - IP address is not private/reserved
 - Port is valid (non-zero)

 @param peer : "Peer to validate"
 @return "True if peer is valid and safe to use"
*>
fn bool is_valid_pex_peer(PexPeer* peer) @public
{
    // Check for invalid port
    if (peer.port == 0) return false;

    // Check for private/reserved IP
    if (is_private_or_reserved_ip(peer.ip)) return false;

    return true;
}

<*
 Check if an IPv6 address is in a private/reserved range.

 BEP 11 Security: We should not accept or broadcast peers with private or
 reserved IPv6 addresses to prevent network abuse and security issues.

 Private/Reserved ranges:
 - ::/128        (unspecified)
 - ::1/128       (loopback)
 - fc00::/7      (unique local addresses)
 - fe80::/10     (link-local)
 - ff00::/8      (multicast)

 @param ip : "IPv6 address to check (16 bytes)"
 @return "True if the IP is private/reserved and should be rejected"
*>
fn bool is_private_or_reserved_ipv6(common::Ipv6Addr ip) @public
{
    // ::/128 - Unspecified address
    bool is_unspecified = true;
    for (usz i = 0; i < 16; i++)
    {
        if (ip[i] != 0)
        {
            is_unspecified = false;
            break;
        }
    }
    if (is_unspecified) return true;

    // ::1/128 - Loopback
    bool is_loopback = true;
    for (usz i = 0; i < 15; i++)
    {
        if (ip[i] != 0)
        {
            is_loopback = false;
            break;
        }
    }
    if (is_loopback && ip[15] == 1) return true;

    // fc00::/7 - Unique Local Addresses (ULA)
    if ((ip[0] & 0xFE) == 0xFC) return true;

    // fe80::/10 - Link-Local
    if (ip[0] == 0xFE && (ip[1] & 0xC0) == 0x80) return true;

    // ff00::/8 - Multicast
    if (ip[0] == 0xFF) return true;

    // Public IPv6 address
    return false;
}

<*
 Validate an IPv6 peer for security before accepting from PEX.

 Checks:
 - IP address is not private/reserved
 - Port is valid (non-zero)

 @param peer : "IPv6 peer to validate"
 @return "True if peer is valid and safe to use"
*>
fn bool is_valid_pex_peer_v6(PexPeerV6* peer) @public
{
    // Check for invalid port
    if (peer.port == 0) return false;

    // Check for private/reserved IP
    if (is_private_or_reserved_ipv6(peer.ip)) return false;

    return true;
}

// ============================================================================
// Compact Format Conversion (BEP 23)
// ============================================================================

<*
 Write a single peer to buffer in compact format (6 bytes).

 Helper function to avoid code duplication.

 @param buffer : "Buffer to write to"
 @param offset : "Offset in buffer to start writing"
 @param peer : "Peer to encode"
*>
fn void write_compact_peer(char[] buffer, usz offset, PexPeer* peer) @private
{
    // IP address (4 bytes)
    buffer[offset + 0] = (char)peer.ip[0];
    buffer[offset + 1] = (char)peer.ip[1];
    buffer[offset + 2] = (char)peer.ip[2];
    buffer[offset + 3] = (char)peer.ip[3];

    // Port (2 bytes, big-endian)
    buffer[offset + 4] = (char)((peer.port >> 8) & 0xFF);
    buffer[offset + 5] = (char)(peer.port & 0xFF);
}

<*
 Encode IPv4 peer to compact format (6 bytes: 4 IP + 2 port).

 Format: <ip0><ip1><ip2><ip3><port_hi><port_lo>

 @param peer : "Peer to encode"
 @return "6-byte compact representation (caller must free)"
*>
fn char[] encode_compact_peer(PexPeer* peer) @public
{
    char[] compact = mem::new_array(char, 6);
    write_compact_peer(compact, 0, peer);
    return compact;
}

<*
 Encode array of IPv4 peers to compact format.

 @param peers : "Array of peers to encode"
 @return "Compact byte string (6 bytes per peer, caller must free)"
*>
fn char[] encode_compact_peers(PexPeer[] peers) @public
{
    if (peers.len == 0) return {};

    char[] compact = mem::new_array(char, peers.len * 6);

    foreach (i, peer : peers)
    {
        write_compact_peer(compact, i * 6, &peer);
    }

    return compact;
}

<*
 Decode compact format to array of IPv4 addresses and ports.

 @param compact : "Compact peer data (must be multiple of 6 bytes)"
 @return "Array of IP/port pairs or fault if invalid format"
*>
fn PexPeer[]? decode_compact_peers(char[] compact, char[] flags) @public
{
    // Validate length (must be multiple of 6 bytes)
    if (compact.len % 6 != 0)
    {
        return PEX_INVALID_COMPACT_FORMAT?;
    }

    usz peer_count = compact.len / 6;

    // Validate flags length (must match peer count or be empty)
    if (flags.len > 0 && flags.len != peer_count)
    {
        return PEX_INVALID_COMPACT_FORMAT?;
    }

    if (peer_count == 0) return {};

    PexPeer[] peers = mem::new_array(PexPeer, peer_count);

    for (usz i = 0; i < peer_count; i++)
    {
        usz offset = i * 6;

        // Extract IP address (4 bytes)
        peers[i].ip[0] = (char)compact[offset + 0];
        peers[i].ip[1] = (char)compact[offset + 1];
        peers[i].ip[2] = (char)compact[offset + 2];
        peers[i].ip[3] = (char)compact[offset + 3];

        // Extract port (2 bytes, big-endian)
        peers[i].port = ((ushort)compact[offset + 4] << 8) |
                        ((ushort)compact[offset + 5]);

        // Extract flags if available
        if (flags.len > 0)
        {
            peers[i].flags = flags[i];
        }
        else
        {
            peers[i].flags = 0;
        }
    }

    return peers;
}

// ============================================================================
// IPv6 Compact Format Conversion (BEP 7)
// ============================================================================

<*
 Write a single IPv6 peer to buffer in compact format (18 bytes).

 Helper function to avoid code duplication.

 @param buffer : "Buffer to write to"
 @param offset : "Offset in buffer to start writing"
 @param peer : "IPv6 peer to encode"
*>
fn void write_compact_peer_v6(char[] buffer, usz offset, PexPeerV6* peer) @private
{
    // IP address (16 bytes)
    for (usz i = 0; i < 16; i++)
    {
        buffer[offset + i] = peer.ip[i];
    }

    // Port (2 bytes, big-endian)
    buffer[offset + 16] = (char)((peer.port >> 8) & 0xFF);
    buffer[offset + 17] = (char)(peer.port & 0xFF);
}

<*
 Encode IPv6 peer to compact format (18 bytes: 16 IP + 2 port).

 Format: <ip0><ip1>...<ip15><port_hi><port_lo>

 @param peer : "IPv6 peer to encode"
 @return "18-byte compact representation (caller must free)"
*>
fn char[] encode_compact_peer_v6(PexPeerV6* peer) @public
{
    char[] compact = mem::new_array(char, 18);
    write_compact_peer_v6(compact, 0, peer);
    return compact;
}

<*
 Encode array of IPv6 peers to compact format.

 @param peers : "Array of IPv6 peers to encode"
 @return "Compact byte string (18 bytes per peer, caller must free)"
*>
fn char[] encode_compact_peers_v6(PexPeerV6[] peers) @public
{
    if (peers.len == 0) return {};

    char[] compact = mem::new_array(char, peers.len * 18);

    foreach (i, peer : peers)
    {
        write_compact_peer_v6(compact, i * 18, &peer);
    }

    return compact;
}

<*
 Decode compact format to array of IPv6 addresses and ports.

 @param compact : "Compact peer data (must be multiple of 18 bytes)"
 @param flags : "Optional flags array"
 @return "Array of IPv6 IP/port pairs or fault if invalid format"
*>
fn PexPeerV6[]? decode_compact_peers_v6(char[] compact, char[] flags) @public
{
    // Validate length (must be multiple of 18 bytes)
    if (compact.len % 18 != 0)
    {
        return PEX_INVALID_COMPACT_FORMAT?;
    }

    usz peer_count = compact.len / 18;

    // Validate flags length (must match peer count or be empty)
    if (flags.len > 0 && flags.len != peer_count)
    {
        return PEX_INVALID_COMPACT_FORMAT?;
    }

    if (peer_count == 0) return {};

    PexPeerV6[] peers = mem::new_array(PexPeerV6, peer_count);

    for (usz i = 0; i < peer_count; i++)
    {
        usz offset = i * 18;

        // Extract IP address (16 bytes)
        for (usz j = 0; j < 16; j++)
        {
            peers[i].ip[j] = compact[offset + j];
        }

        // Extract port (2 bytes, big-endian)
        peers[i].port = ((ushort)compact[offset + 16] << 8) |
                        ((ushort)compact[offset + 17]);

        // Extract flags if available
        if (flags.len > 0)
        {
            peers[i].flags = flags[i];
        }
        else
        {
            peers[i].flags = 0;
        }
    }

    return peers;
}

// ============================================================================
// PEX Message Encoding/Decoding
// ============================================================================

<*
 Encode a PEX message to bencoded format.

 Format: d5:added<compact_peers>7:added.f<flags>6:added6<compact_ipv6_peers>8:added6.f<flags>7:dropped<compact_peers>8:dropped6<compact_ipv6_peers>e

 @param msg : "PEX message to encode"
 @return "Bencoded message payload (caller must free)"
*>
fn char[] encode_pex_message(PexMessage* msg) @public
{
    bencode::BencodeValue* dict = bencode::make_dict();
    defer dict.free();

    // Encode "added" IPv4 peers
    if (msg.added.len > 0)
    {
        char[] added_compact = encode_compact_peers(msg.added);
        defer free(added_compact);

        bencode::BencodeValue* added_val = bencode::make_string((String)added_compact);
        dict.dict_set("added", added_val);

        // Encode "added.f" flags
        char[] flags = mem::new_array(char, msg.added.len);
        defer free(flags);
        foreach (i, peer : msg.added)
        {
            flags[i] = peer.flags;
        }
        bencode::BencodeValue* flags_val = bencode::make_string((String)flags);
        dict.dict_set("added.f", flags_val);
    }

    // Encode "dropped" IPv4 peers
    if (msg.dropped.len > 0)
    {
        char[] dropped_compact = encode_compact_peers(msg.dropped);
        defer free(dropped_compact);

        bencode::BencodeValue* dropped_val = bencode::make_string((String)dropped_compact);
        dict.dict_set("dropped", dropped_val);
    }

    // Encode "added6" IPv6 peers
    if (msg.added6.len > 0)
    {
        char[] added6_compact = encode_compact_peers_v6(msg.added6);
        defer free(added6_compact);

        bencode::BencodeValue* added6_val = bencode::make_string((String)added6_compact);
        dict.dict_set("added6", added6_val);

        // Encode "added6.f" flags
        char[] flags6 = mem::new_array(char, msg.added6.len);
        defer free(flags6);
        foreach (i, peer : msg.added6)
        {
            flags6[i] = peer.flags;
        }
        bencode::BencodeValue* flags6_val = bencode::make_string((String)flags6);
        dict.dict_set("added6.f", flags6_val);
    }

    // Encode "dropped6" IPv6 peers
    if (msg.dropped6.len > 0)
    {
        char[] dropped6_compact = encode_compact_peers_v6(msg.dropped6);
        defer free(dropped6_compact);

        bencode::BencodeValue* dropped6_val = bencode::make_string((String)dropped6_compact);
        dict.dict_set("dropped6", dropped6_val);
    }

    // Encode the dictionary using bencode module
    String encoded = dict.encode();
    return (char[])encoded;
}

<*
 Decode a PEX message from bencoded format.

 @param data : "Bencoded PEX message payload"
 @return "Decoded PEX message or fault if invalid"
*>
fn PexMessage? decode_pex_message(char[] data) @public
{
    // Parse bencoded dictionary
    bencode::BencodeValue*? root_opt = bencode::decode((String)data);
    if (catch err = root_opt)
    {
        return PEX_INVALID_MESSAGE?;
    }

    bencode::BencodeValue* root = root_opt;
    defer root.free();

    if (root.type != bencode::BencodeType.DICT)
    {
        return PEX_INVALID_MESSAGE?;
    }

    PexMessage msg;
    msg.added = {};
    msg.dropped = {};
    msg.added6 = {};
    msg.dropped6 = {};

    // Parse "added" IPv4 field
    bencode::BencodeValue* added_val = root.dict_get("added");
    if (added_val && added_val.type == bencode::BencodeType.STRING)
    {
        // Parse "added.f" flags (optional)
        char[] flags = {};
        bencode::BencodeValue* flags_val = root.dict_get("added.f");
        if (flags_val && flags_val.type == bencode::BencodeType.STRING)
        {
            flags = flags_val.string;
        }

        // Decode compact peers
        PexPeer[]? peers_opt = decode_compact_peers(added_val.string, flags);
        if (catch err = peers_opt)
        {
            return err?;
        }
        msg.added = peers_opt;
    }

    // Parse "dropped" IPv4 field
    bencode::BencodeValue* dropped_val = root.dict_get("dropped");
    if (dropped_val && dropped_val.type == bencode::BencodeType.STRING)
    {
        // Dropped peers don't have flags
        PexPeer[]? peers_opt = decode_compact_peers(dropped_val.string, {});
        if (catch err = peers_opt)
        {
            return err?;
        }
        msg.dropped = peers_opt;
    }

    // Parse "added6" IPv6 field
    bencode::BencodeValue* added6_val = root.dict_get("added6");
    if (added6_val && added6_val.type == bencode::BencodeType.STRING)
    {
        // Parse "added6.f" flags (optional)
        char[] flags6 = {};
        bencode::BencodeValue* flags6_val = root.dict_get("added6.f");
        if (flags6_val && flags6_val.type == bencode::BencodeType.STRING)
        {
            flags6 = flags6_val.string;
        }

        // Decode compact IPv6 peers
        PexPeerV6[]? peers6_opt = decode_compact_peers_v6(added6_val.string, flags6);
        if (catch err = peers6_opt)
        {
            return err?;
        }
        msg.added6 = peers6_opt;
    }

    // Parse "dropped6" IPv6 field
    bencode::BencodeValue* dropped6_val = root.dict_get("dropped6");
    if (dropped6_val && dropped6_val.type == bencode::BencodeType.STRING)
    {
        // Dropped IPv6 peers don't have flags
        PexPeerV6[]? peers6_opt = decode_compact_peers_v6(dropped6_val.string, {});
        if (catch err = peers6_opt)
        {
            return err?;
        }
        msg.dropped6 = peers6_opt;
    }

    return msg;
}

<*
 Free a PEX message and its peer arrays.

 @param msg : "PEX message to free"
*>
fn void free_pex_message(PexMessage* msg) @public
{
    if (msg.added.len > 0) free(msg.added);
    if (msg.dropped.len > 0) free(msg.dropped);
    if (msg.added6.len > 0) free(msg.added6);
    if (msg.dropped6.len > 0) free(msg.dropped6);
}
