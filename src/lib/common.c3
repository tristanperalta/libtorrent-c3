module libtorrent::common;
import std::net;
import std::io;

<*
 BitTorrent Protocol Common Types and Constants
 ==============================================
 Shared constants and type aliases used across the libtorrent modules.

 This module provides common protocol-level definitions to ensure
 consistency and avoid duplication across tracker, peer, and network code.

 NOTE: Migrating from custom PeerAddr to std::net::InetAddress-based SocketAddress
 for better standard library integration and cleaner IPv6 support.
*>

// Protocol size constants (BEP 3 standard)
const usz IPV4_ADDR_SIZE = 4;     // IPv4 address size in bytes
const usz IPV6_ADDR_SIZE = 16;    // IPv6 address size in bytes (BEP 7)
const usz PEER_ID_SIZE = 20;      // Peer ID size in bytes (BEP 3)
const usz SHA1_HASH_SIZE = 20;    // SHA1 info hash size in bytes (BEP 3)

// BitTorrent handshake constants (BEP 3)
const usz HANDSHAKE_SIZE = 68;            // Total handshake message size
const usz HANDSHAKE_RESERVED_SIZE = 8;    // Reserved bytes in handshake
const String PROTOCOL_STRING = "BitTorrent protocol";  // Protocol identifier
const usz PROTOCOL_STRING_LEN = 19;       // Length of protocol string

// Block and piece constants (BEP 3)
const usz STANDARD_BLOCK_SIZE = 16384;    // Standard 16KB block size

// Compact peer format constants (BEP 3, BEP 7)
const usz COMPACT_PEER_SIZE = 6;          // IPv4 (4) + port (2)
const usz COMPACT_PEER_IPV6_SIZE = 18;    // IPv6 (16) + port (2) - BEP 7
const usz COMPACT_PEER_PORT_SIZE = 2;     // Port size in compact format

// Compact node format constants (BEP 32: DHT IPv6)
const usz COMPACT_NODE_IPV4_SIZE = 26;    // NodeID (20) + IPv4 (4) + port (2)
const usz COMPACT_NODE_IPV6_SIZE = 38;    // NodeID (20) + IPv6 (16) + port (2)

// Type aliases for common protocol types
alias InfoHash = char[SHA1_HASH_SIZE];     // Torrent info hash
alias PeerId = char[PEER_ID_SIZE];         // BitTorrent peer ID
alias NodeId = char[SHA1_HASH_SIZE];       // DHT node ID (BEP 5)
alias Ipv4Addr = char[IPV4_ADDR_SIZE];     // IPv4 address in network byte order
alias Ipv6Addr = char[IPV6_ADDR_SIZE];     // IPv6 address in network byte order (BEP 7)

// Type aliases for block/piece indexing (used across multiple modules)
typedef PieceIndex = uint;
typedef BlockOffset = uint;

// Faults for socket address parsing
faultdef INVALID_COMPACT_FORMAT;

// Compact node decoding result structs (BEP 32)
struct CompactNodeIPv4
{
    NodeId node_id;
    SocketAddress addr;
}

struct CompactNodeIPv6
{
    NodeId node_id;
    SocketAddress addr;
}

<*
 Socket address combining IP address and port (BEP 7: IPv6 support)
 =====================================================================
 Uses std::net::InetAddress for robust dual-stack IP handling.
 This is the NEW PREFERRED type, replacing the custom PeerAddr struct.

 Benefits over PeerAddr:
 - Automatic formatting via Printable interface
 - Built-in utility methods (is_loopback, is_site_local, etc.)
 - Better IPv6 representation (proper colon notation)
 - Standard library integration

 Migration: This will eventually replace PeerAddr throughout the codebase.
*>
struct SocketAddress (Printable)
{
    net::InetAddress addr;  // IPv4 or IPv6 address
    ushort port;            // Port number
}

<*
 Format a SocketAddress for printing (Printable interface).
 Automatically called when using %s in printf/appendf.

 Returns formatted address like "192.168.1.1:6881" for IPv4
 or "[2001:db8::1]:6881" for IPv6 (brackets per RFC 3986).
*>
fn usz? SocketAddress.to_format(&self, Formatter* formatter) @dynamic
{
    if (self.addr.is_ipv6)
    {
        // IPv6: Wrap in brackets per RFC 3986
        return formatter.printf("[%s]:%d", self.addr, self.port);
    }
    // IPv4: Simple dotted-decimal notation
    return formatter.printf("%s:%d", self.addr, self.port);
}

<*
 Create an IPv4 SocketAddress from individual octets.

 Helper function to avoid verbose struct initialization.

 @param a : "First octet (0-255)"
 @param b : "Second octet (0-255)"
 @param c : "Third octet (0-255)"
 @param d : "Fourth octet (0-255)"
 @param port : "Port number"
 @return "IPv4 SocketAddress"
*>
fn SocketAddress create_ipv4_address(char a, char b, char c, char d, ushort port) @public
{
    SocketAddress addr;
    addr.addr.is_ipv6 = false;
    addr.addr.ipv4.a = a;
    addr.addr.ipv4.b = b;
    addr.addr.ipv4.c = c;
    addr.addr.ipv4.d = d;
    addr.port = port;
    return addr;
}

<*
 Create an IPv6 SocketAddress from raw bytes.

 Helper function to avoid verbose struct initialization.

 @param bytes : "16-byte IPv6 address in network byte order"
 @param port : "Port number"
 @return "IPv6 SocketAddress"
*>
fn SocketAddress create_ipv6_address(char[16] bytes, ushort port) @public
{
    SocketAddress addr;
    addr.addr.is_ipv6 = true;

    // Copy IPv6 bytes into InetAddress
    char* ipv6_ptr = (char*)&addr.addr.ipv6;
    for (usz i = 0; i < 16; i++)
    {
        ipv6_ptr[i] = bytes[i];
    }

    addr.port = port;
    return addr;
}

<*
 Peer discovery source
 Tracks where a peer was discovered from for statistics and prioritization.
*>
enum PeerSource : char
{
    MANUAL,         // Manually added
    TRACKER,        // HTTP/UDP tracker announce
    DHT,            // DHT get_peers query
    PEX,            // Peer Exchange (BEP 11)
    LSD,            // Local Service Discovery (BEP 14) - future
    DHT_ANNOUNCE    // DHT announce response - future
}

<*
 Format a socket address for display.
 Returns a formatted string like "192.168.1.1:6881" for IPv4
 or "[2001:db8::1]:6881" for IPv6.

 Uses InetAddress's built-in Printable interface for clean formatting.

 @param self : "Socket address to format"
 @return "Formatted string (caller must free)"
*>
fn String SocketAddress.to_string(&self) @public
{
    DString builder;
    if (self.addr.is_ipv6)
    {
        // IPv6: Wrap address in brackets per RFC 3986
        builder.appendf("[%s]:%d", self.addr, self.port);
    }
    else
    {
        // IPv4: Simple dotted-decimal notation
        builder.appendf("%s:%d", self.addr, self.port);
    }
    return builder.copy_str(mem);
}

<*
 Calculate hash for SocketAddress (for use in HashMap).
 Uses FNV-1a hash algorithm for good distribution.

 @param self : "Socket address to hash"
 @return "32-bit hash value"
*>
fn uint SocketAddress.hash(&self) @public
{
    // FNV-1a hash constants
    const uint FNV_OFFSET_BASIS = 2166136261u;
    const uint FNV_PRIME = 16777619u;

    uint hash = FNV_OFFSET_BASIS;

    // Hash the address bytes
    if (self.addr.is_ipv6)
    {
        // IPv6: Hash all 16 bytes
        char* bytes = (char*)&self.addr.ipv6;
        for (usz i = 0; i < IPV6_ADDR_SIZE; i++)
        {
            hash ^= (uint)bytes[i];
            hash *= FNV_PRIME;
        }
    }
    else
    {
        // IPv4: Hash 4 bytes
        hash ^= (uint)self.addr.ipv4.a;
        hash *= FNV_PRIME;
        hash ^= (uint)self.addr.ipv4.b;
        hash *= FNV_PRIME;
        hash ^= (uint)self.addr.ipv4.c;
        hash *= FNV_PRIME;
        hash ^= (uint)self.addr.ipv4.d;
        hash *= FNV_PRIME;
    }

    // Hash the port (big-endian)
    hash ^= (uint)(self.port >> 8);
    hash *= FNV_PRIME;
    hash ^= (uint)(self.port & 0xFF);
    hash *= FNV_PRIME;

    return hash;
}

<*
 Equality operator overload for SocketAddress (C3 0.7.1+).
 Allows natural comparison syntax: addr1 == addr2

 @param self : "First socket address"
 @param other : "Second socket address"
 @return "true if addresses and ports match"
*>
fn bool SocketAddress.equals(&self, SocketAddress other) @operator(==) @public
{
    // Different IP versions can't be equal
    if (self.addr.is_ipv6 != other.addr.is_ipv6) return false;

    // Ports must match
    if (self.port != other.port) return false;

    // Compare address bytes
    if (self.addr.is_ipv6)
    {
        // IPv6: Compare all 16 bytes
        char* a = (char*)&self.addr.ipv6;
        char* b = (char*)&other.addr.ipv6;
        for (usz i = 0; i < IPV6_ADDR_SIZE; i++)
        {
            if (a[i] != b[i]) return false;
        }
    }
    else
    {
        // IPv4: Compare 4 bytes
        if (self.addr.ipv4.a != other.addr.ipv4.a) return false;
        if (self.addr.ipv4.b != other.addr.ipv4.b) return false;
        if (self.addr.ipv4.c != other.addr.ipv4.c) return false;
        if (self.addr.ipv4.d != other.addr.ipv4.d) return false;
    }

    return true;
}

<*
 Parse a socket address from compact IPv4 format (BEP 3).
 Compact format: 4 bytes (IP) + 2 bytes (port), both big-endian.

 @param bytes : "6-byte compact peer format"
 @return "Parsed socket address, or fault if invalid"
*>
fn SocketAddress? socket_address_from_compact_ipv4(char[] bytes) @public
{
    if (bytes.len != COMPACT_PEER_SIZE) return INVALID_COMPACT_FORMAT?;

    SocketAddress addr;
    addr.addr.is_ipv6 = false;

    // CRITICAL: IPv4 is stored in bits 96-127 (last 4 bytes) of InetAddress
    addr.addr.ipv4.a = bytes[0];
    addr.addr.ipv4.b = bytes[1];
    addr.addr.ipv4.c = bytes[2];
    addr.addr.ipv4.d = bytes[3];

    // Port is big-endian (network byte order)
    addr.port = ((ushort)bytes[4] << 8) | (ushort)bytes[5];

    return addr;
}

<*
 Parse a socket address from compact IPv6 format (BEP 7).
 Compact format: 16 bytes (IP) + 2 bytes (port), both big-endian.

 @param bytes : "18-byte compact peer format"
 @return "Parsed socket address, or fault if invalid"
*>
fn SocketAddress? socket_address_from_compact_ipv6(char[] bytes) @public
{
    if (bytes.len != COMPACT_PEER_IPV6_SIZE) return INVALID_COMPACT_FORMAT?;

    SocketAddress addr;
    addr.addr.is_ipv6 = true;

    // IPv6 uses all 16 bytes - copy directly into the union
    // Note: InetAddress stores IPv6 as array of bytes in network order
    for (usz i = 0; i < IPV6_ADDR_SIZE; i++)
    {
        // Access raw bytes through pointer cast
        ((char*)&addr.addr.ipv6)[i] = bytes[i];
    }

    // Port is big-endian (network byte order)
    addr.port = ((ushort)bytes[16] << 8) | (ushort)bytes[17];

    return addr;
}

<*
 Extract raw IPv4 address bytes (BEP 6: Fast Extension).
 Required for generating allowed_fast piece sets which need raw IP bytes.

 IMPORTANT: Only call this for IPv4 addresses. The function will assert
 if called on an IPv6 address.

 @param self : "Socket address (must be IPv4)"
 @return "4-byte IPv4 address in network byte order"
*>
fn Ipv4Addr SocketAddress.to_ipv4_bytes(&self) @public
{
    assert(!self.addr.is_ipv6, "Cannot extract IPv4 bytes from IPv6 address");

    // Extract IPv4 bytes from bits 96-127 of InetAddress
    Ipv4Addr bytes;
    bytes[0] = self.addr.ipv4.a;
    bytes[1] = self.addr.ipv4.b;
    bytes[2] = self.addr.ipv4.c;
    bytes[3] = self.addr.ipv4.d;

    return bytes;
}

<*
 Encode a DHT node to compact IPv4 format (BEP 32).
 Compact node format: 20 bytes (node ID) + 4 bytes (IP) + 2 bytes (port)
 Total: 26 bytes, all in network byte order (big-endian).

 Used in DHT "nodes" responses for get_peers and find_node queries.

 @param node_id : "20-byte DHT node ID"
 @param addr : "Socket address (must be IPv4)"
 @return "26-byte compact node representation"
*>
fn char[COMPACT_NODE_IPV4_SIZE] encode_compact_node_ipv4(NodeId node_id, SocketAddress addr) @public
{
    assert(!addr.addr.is_ipv6, "Cannot encode IPv6 address as IPv4 compact node");

    char[COMPACT_NODE_IPV4_SIZE] result;

    // Copy node ID (20 bytes)
    for (usz i = 0; i < SHA1_HASH_SIZE; i++)
    {
        result[i] = node_id[i];
    }

    // Copy IPv4 address (4 bytes)
    result[20] = addr.addr.ipv4.a;
    result[21] = addr.addr.ipv4.b;
    result[22] = addr.addr.ipv4.c;
    result[23] = addr.addr.ipv4.d;

    // Copy port (2 bytes, big-endian)
    result[24] = (char)(addr.port >> 8);
    result[25] = (char)(addr.port & 0xFF);

    return result;
}

<*
 Encode a DHT node to compact IPv6 format (BEP 32).
 Compact node format: 20 bytes (node ID) + 16 bytes (IP) + 2 bytes (port)
 Total: 38 bytes, all in network byte order (big-endian).

 Used in DHT "nodes6" responses for get_peers and find_node queries.

 @param node_id : "20-byte DHT node ID"
 @param addr : "Socket address (must be IPv6)"
 @return "38-byte compact node representation"
*>
fn char[COMPACT_NODE_IPV6_SIZE] encode_compact_node_ipv6(NodeId node_id, SocketAddress addr) @public
{
    assert(addr.addr.is_ipv6, "Cannot encode IPv4 address as IPv6 compact node");

    char[COMPACT_NODE_IPV6_SIZE] result;

    // Copy node ID (20 bytes)
    for (usz i = 0; i < SHA1_HASH_SIZE; i++)
    {
        result[i] = node_id[i];
    }

    // Copy IPv6 address (16 bytes)
    char* ipv6_bytes = (char*)&addr.addr.ipv6;
    for (usz i = 0; i < IPV6_ADDR_SIZE; i++)
    {
        result[20 + i] = ipv6_bytes[i];
    }

    // Copy port (2 bytes, big-endian)
    result[36] = (char)(addr.port >> 8);
    result[37] = (char)(addr.port & 0xFF);

    return result;
}

<*
 Decode a DHT node from compact IPv4 format (BEP 32).
 Compact node format: 20 bytes (node ID) + 4 bytes (IP) + 2 bytes (port)

 @param bytes : "26-byte compact node format"
 @return "Tuple of (node_id, socket_address), or fault if invalid"
*>
fn CompactNodeIPv4? decode_compact_node_ipv4(char[] bytes) @public
{
    if (bytes.len != COMPACT_NODE_IPV4_SIZE) return INVALID_COMPACT_FORMAT?;

    CompactNodeIPv4 result;

    // Extract node ID (20 bytes)
    for (usz i = 0; i < SHA1_HASH_SIZE; i++)
    {
        result.node_id[i] = bytes[i];
    }

    // Extract IPv4 address (4 bytes)
    result.addr.addr.is_ipv6 = false;
    result.addr.addr.ipv4.a = bytes[20];
    result.addr.addr.ipv4.b = bytes[21];
    result.addr.addr.ipv4.c = bytes[22];
    result.addr.addr.ipv4.d = bytes[23];

    // Extract port (2 bytes, big-endian)
    result.addr.port = ((ushort)bytes[24] << 8) | (ushort)bytes[25];

    return result;
}

<*
 Decode a DHT node from compact IPv6 format (BEP 32).
 Compact node format: 20 bytes (node ID) + 16 bytes (IP) + 2 bytes (port)

 @param bytes : "38-byte compact node format"
 @return "Tuple of (node_id, socket_address), or fault if invalid"
*>
fn CompactNodeIPv6? decode_compact_node_ipv6(char[] bytes) @public
{
    if (bytes.len != COMPACT_NODE_IPV6_SIZE) return INVALID_COMPACT_FORMAT?;

    CompactNodeIPv6 result;

    // Extract node ID (20 bytes)
    for (usz i = 0; i < SHA1_HASH_SIZE; i++)
    {
        result.node_id[i] = bytes[i];
    }

    // Extract IPv6 address (16 bytes)
    result.addr.addr.is_ipv6 = true;
    char* ipv6_bytes = (char*)&result.addr.addr.ipv6;
    for (usz i = 0; i < IPV6_ADDR_SIZE; i++)
    {
        ipv6_bytes[i] = bytes[20 + i];
    }

    // Extract port (2 bytes, big-endian)
    result.addr.port = ((ushort)bytes[36] << 8) | (ushort)bytes[37];

    return result;
}
