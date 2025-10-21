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

// Type aliases for common protocol types
alias InfoHash = char[SHA1_HASH_SIZE];     // Torrent info hash
alias PeerId = char[PEER_ID_SIZE];         // BitTorrent peer ID
alias Ipv4Addr = char[IPV4_ADDR_SIZE];     // IPv4 address in network byte order
