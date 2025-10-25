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
 PEX message payload.

 Contains lists of added and dropped peers (IPv4 only for now).
 Each list can contain up to 50 peers (BEP 11 requirement).
*>
struct PexMessage
{
    PexPeer[] added;      // Newly connected peers
    PexPeer[] dropped;    // Recently disconnected peers
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
// PEX Message Encoding/Decoding
// ============================================================================

<*
 Encode a PEX message to bencoded format.

 Format: d5:added<compact_peers>7:added.f<flags>7:dropped<compact_peers>e

 @param msg : "PEX message to encode"
 @return "Bencoded message payload (caller must free)"
*>
fn char[] encode_pex_message(PexMessage* msg) @public
{
    bencode::BencodeValue* dict = bencode::make_dict();
    defer bencode::free_bencode_value(dict);

    // Encode "added" peers
    if (msg.added.len > 0)
    {
        char[] added_compact = encode_compact_peers(msg.added);
        defer free(added_compact);

        bencode::BencodeValue* added_val = bencode::make_string((String)added_compact);
        bencode::dict_set(dict, "added", added_val);

        // Encode "added.f" flags
        char[] flags = mem::new_array(char, msg.added.len);
        defer free(flags);
        foreach (i, peer : msg.added)
        {
            flags[i] = peer.flags;
        }
        bencode::BencodeValue* flags_val = bencode::make_string((String)flags);
        bencode::dict_set(dict, "added.f", flags_val);
    }

    // Encode "dropped" peers
    if (msg.dropped.len > 0)
    {
        char[] dropped_compact = encode_compact_peers(msg.dropped);
        defer free(dropped_compact);

        bencode::BencodeValue* dropped_val = bencode::make_string((String)dropped_compact);
        bencode::dict_set(dict, "dropped", dropped_val);
    }

    // Encode the dictionary using bencode module
    String encoded = bencode::encode(dict);
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
    defer bencode::free_bencode_value(root);

    if (root.type != bencode::BencodeType.DICT)
    {
        return PEX_INVALID_MESSAGE?;
    }

    PexMessage msg;
    msg.added = {};
    msg.dropped = {};

    // Parse "added" field
    bencode::BencodeValue* added_val = bencode::dict_get(root, "added");
    if (added_val && added_val.type == bencode::BencodeType.STRING)
    {
        // Parse "added.f" flags (optional)
        char[] flags = {};
        bencode::BencodeValue* flags_val = bencode::dict_get(root, "added.f");
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

    // Parse "dropped" field
    bencode::BencodeValue* dropped_val = bencode::dict_get(root, "dropped");
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
}
