module libtorrent::utp::common;

import libtorrent::common;  // Import SocketAddress from main common module

<*
 μTP (Micro Transport Protocol) Common Types and Constants
 ==========================================================

 Shared constants and types used across the μTP implementation.
 Based on BEP 29: http://www.bittorrent.org/beps/bep_0029.html

 NOTE: We import SocketAddress from libtorrent::common to reuse the robust
 IPv4/IPv6 implementation instead of creating our own.
*>

// ============================================================================
// Packet Types (BEP 29)
// ============================================================================

const char ST_DATA  = 0;  // Regular data packet with payload
const char ST_FIN   = 1;  // Connection finalization (graceful close)
const char ST_STATE = 2;  // ACK-only packet (no payload)
const char ST_RESET = 3;  // Force terminate connection
const char ST_SYN   = 4;  // Connection initiation (handshake)

// ============================================================================
// Protocol Constants
// ============================================================================

const char UTP_VERSION = 1;  // Current μTP protocol version

const usz UTP_HEADER_SIZE = 20;  // Header size in bytes

// Maximum packet size (Ethernet MTU - IP header - UDP header)
// 1500 (Ethernet) - 20 (IP) - 8 (UDP) = 1472 bytes
// Use 1400 for safety margin (some networks have lower MTU)
const usz MAX_PACKET_SIZE = 1400;

// ============================================================================
// Faults (Error Codes)
// ============================================================================

faultdef UTP_INVALID_PACKET;     // Malformed packet
faultdef UTP_PACKET_TOO_SHORT;   // Packet smaller than header size
faultdef UTP_INVALID_VERSION;    // Unsupported protocol version
faultdef UTP_PACKET_NOT_FOUND;   // Packet not found in send buffer (Week 2)

// NOTE: For socket addresses, use common::SocketAddress directly.
// This provides robust IPv4/IPv6 support with std::net::InetAddress integration.
