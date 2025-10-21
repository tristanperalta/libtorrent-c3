module libtorrent::common;

<*
 BitTorrent Protocol Common Types and Constants
 ==============================================
 Shared constants and type aliases used across the libtorrent modules.

 This module provides common protocol-level definitions to ensure
 consistency and avoid duplication across tracker, peer, and network code.
*>

// Protocol size constants (BEP 3 standard)
const usz IPV4_ADDR_SIZE = 4;     // IPv4 address size in bytes
const usz PEER_ID_SIZE = 20;      // Peer ID size in bytes (BEP 3)
const usz SHA1_HASH_SIZE = 20;    // SHA1 info hash size in bytes (BEP 3)

// BitTorrent handshake constants (BEP 3)
const usz HANDSHAKE_SIZE = 68;            // Total handshake message size
const usz HANDSHAKE_RESERVED_SIZE = 8;    // Reserved bytes in handshake
const String PROTOCOL_STRING = "BitTorrent protocol";  // Protocol identifier
const usz PROTOCOL_STRING_LEN = 19;       // Length of protocol string

// Block and piece constants (BEP 3)
const usz STANDARD_BLOCK_SIZE = 16384;    // Standard 16KB block size

// Compact peer format constants (BEP 3)
const usz COMPACT_PEER_SIZE = 6;          // IPv4 (4) + port (2)
const usz COMPACT_PEER_PORT_SIZE = 2;     // Port size in compact format

// Type aliases for common protocol types
alias InfoHash = char[SHA1_HASH_SIZE];     // Torrent info hash
alias PeerId = char[PEER_ID_SIZE];         // BitTorrent peer ID
alias Ipv4Addr = char[IPV4_ADDR_SIZE];     // IPv4 address in network byte order

// Type aliases for block/piece indexing (used across multiple modules)
typedef PieceIndex = uint;
typedef BlockOffset = uint;
