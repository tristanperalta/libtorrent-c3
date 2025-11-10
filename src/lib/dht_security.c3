module libtorrent::dht_security;

import std::io;
import libtorrent::common;

/**
 * BEP 42: DHT Security Extension
 * ===============================
 *
 * Prevents Sybil attacks by requiring node IDs to be derived from IP addresses.
 * Node IDs must match a CRC32C hash of the masked IP address.
 *
 * Specification: http://www.bittorrent.org/beps/bep_0042.html
 *
 * Algorithm (IPv4):
 *   1. Mask IP with 0x030f3fff
 *   2. Combine with random value r (0-7): masked_ip | (r << 29)
 *   3. Compute CRC32C hash of result
 *   4. Node ID must match:
 *      - First 21 bits = first 21 bits of CRC32C
 *      - Bits 21-23 = r value
 *
 * Implementation based on C3 stdlib CRC32 pattern (std::hash::crc32)
 * but using CRC32C (Castagnoli) polynomial 0x1EDC6F41 instead of IEEE 0x04C11DB7.
 */

// ============================================================================
// CRC32C (Castagnoli) Implementation
// ============================================================================

/**
 * CRC32C lookup table (Castagnoli polynomial: 0x1EDC6F41)
 *
 * Generated using:
 *   for i in 0..255:
 *     crc = i
 *     for j in 0..7:
 *       if crc & 1:
 *         crc = (crc >> 1) ^ 0x82F63B78  (reversed polynomial)
 *       else:
 *         crc = crc >> 1
 *     table[i] = crc
 */
const uint[256] CRC32C_TABLE @private = {
    0x00000000, 0xf26b8303, 0xe13b70f7, 0x1350f3f4,
    0xc79a971f, 0x35f1141c, 0x26a1e7e8, 0xd4ca64eb,
    0x8ad958cf, 0x78b2dbcc, 0x6be22838, 0x9989ab3b,
    0x4d43cfd0, 0xbf284cd3, 0xac78bf27, 0x5e133c24,
    0x105ec76f, 0xe235446c, 0xf165b798, 0x030e349b,
    0xd7c45070, 0x25afd373, 0x36ff2087, 0xc494a384,
    0x9a879fa0, 0x68ec1ca3, 0x7bbcef57, 0x89d76c54,
    0x5d1d08bf, 0xaf768bbc, 0xbc267848, 0x4e4dfb4b,
    0x20bd8ede, 0xd2d60ddd, 0xc186fe29, 0x33ed7d2a,
    0xe72719c1, 0x154c9ac2, 0x061c6936, 0xf477ea35,
    0xaa64d611, 0x580f5512, 0x4b5fa6e6, 0xb93425e5,
    0x6dfe410e, 0x9f95c20d, 0x8cc531f9, 0x7eaeb2fa,
    0x30e349b1, 0xc288cab2, 0xd1d83946, 0x23b3ba45,
    0xf779deae, 0x05125dad, 0x1642ae59, 0xe4292d5a,
    0xba3a117e, 0x4851927d, 0x5b016189, 0xa96ae28a,
    0x7da08661, 0x8fcb0562, 0x9c9bf696, 0x6ef07595,
    0x417b1dbc, 0xb3109ebf, 0xa0406d4b, 0x522bee48,
    0x86e18aa3, 0x748a09a0, 0x67dafa54, 0x95b17957,
    0xcba24573, 0x39c9c670, 0x2a993584, 0xd8f2b687,
    0x0c38d26c, 0xfe53516f, 0xed03a29b, 0x1f682198,
    0x5125dad3, 0xa34e59d0, 0xb01eaa24, 0x42752927,
    0x96bf4dcc, 0x64d4cecf, 0x77843d3b, 0x85efbe38,
    0xdbfc821c, 0x2997011f, 0x3ac7f2eb, 0xc8ac71e8,
    0x1c661503, 0xee0d9600, 0xfd5d65f4, 0x0f36e6f7,
    0x61c69362, 0x93ad1061, 0x80fde395, 0x72966096,
    0xa65c047d, 0x5437877e, 0x4767748a, 0xb50cf789,
    0xeb1fcbad, 0x197448ae, 0x0a24bb5a, 0xf84f3859,
    0x2c855cb2, 0xdeeedfb1, 0xcdbe2c45, 0x3fd5af46,
    0x7198540d, 0x83f3d70e, 0x90a324fa, 0x62c8a7f9,
    0xb602c312, 0x44694011, 0x5739b3e5, 0xa55230e6,
    0xfb410cc2, 0x092a8fc1, 0x1a7a7c35, 0xe811ff36,
    0x3cdb9bdd, 0xceb018de, 0xdde0eb2a, 0x2f8b6829,
    0x82f63b78, 0x709db87b, 0x63cd4b8f, 0x91a6c88c,
    0x456cac67, 0xb7072f64, 0xa457dc90, 0x563c5f93,
    0x082f63b7, 0xfa44e0b4, 0xe9141340, 0x1b7f9043,
    0xcfb5f4a8, 0x3dde77ab, 0x2e8e845f, 0xdce5075c,
    0x92a8fc17, 0x60c37f14, 0x73938ce0, 0x81f80fe3,
    0x55326b08, 0xa759e80b, 0xb4091bff, 0x466298fc,
    0x1871a4d8, 0xea1a27db, 0xf94ad42f, 0x0b21572c,
    0xdfeb33c7, 0x2d80b0c4, 0x3ed04330, 0xccbbc033,
    0xa24bb5a6, 0x502036a5, 0x4370c551, 0xb11b4652,
    0x65d122b9, 0x97baa1ba, 0x84ea524e, 0x7681d14d,
    0x2892ed69, 0xdaf96e6a, 0xc9a99d9e, 0x3bc21e9d,
    0xef087a76, 0x1d63f975, 0x0e330a81, 0xfc588982,
    0xb21572c9, 0x407ef1ca, 0x532e023e, 0xa145813d,
    0x758fe5d6, 0x87e466d5, 0x94b49521, 0x66df1622,
    0x38cc2a06, 0xcaa7a905, 0xd9f75af1, 0x2b9cd9f2,
    0xff56bd19, 0x0d3d3e1a, 0x1e6dcdee, 0xec064eed,
    0xc38d26c4, 0x31e6a5c7, 0x22b65633, 0xd0ddd530,
    0x0417b1db, 0xf67c32d8, 0xe52cc12c, 0x1747422f,
    0x49547e0b, 0xbb3ffd08, 0xa86f0efc, 0x5a048dff,
    0x8ecee914, 0x7ca56a17, 0x6ff599e3, 0x9d9e1ae0,
    0xd3d3e1ab, 0x21b862a8, 0x32e8915c, 0xc083125f,
    0x144976b4, 0xe622f5b7, 0xf5720643, 0x07198540,
    0x590ab964, 0xab613a67, 0xb831c993, 0x4a5a4a90,
    0x9e902e7b, 0x6cfbad78, 0x7fab5e8c, 0x8dc0dd8f,
    0xe330a81a, 0x115b2b19, 0x020bd8ed, 0xf0605bee,
    0x24aa3f05, 0xd6c1bc06, 0xc5914ff2, 0x37faccf1,
    0x69e9f0d5, 0x9b8273d6, 0x88d28022, 0x7ab90321,
    0xae7367ca, 0x5c18e4c9, 0x4f48173d, 0xbd23943e,
    0xf36e6f75, 0x0105ec76, 0x12551f82, 0xe03e9c81,
    0x34f4f86a, 0xc69f7b69, 0xd5cf889d, 0x27a40b9e,
    0x79b737ba, 0x8bdcb4b9, 0x988c474d, 0x6ae7c44e,
    0xbe2da0a5, 0x4c4623a6, 0x5f16d052, 0xad7d5351,
};

/**
 * Compute CRC32C (Castagnoli) hash of data.
 *
 * @param data : "Data to hash"
 * @return "32-bit CRC32C hash"
 */
fn uint crc32c(char[] data) @public
{
    uint result = ~(uint)(0);  // Initial value: 0xFFFFFFFF
    foreach (char x : data)
    {
        result = (result >> 8) ^ CRC32C_TABLE[(result ^ x) & 0xFF];
    }
    return ~result;  // Final XOR
}

// ============================================================================
// BEP 42 Node ID Generation & Verification
// ============================================================================

/**
 * Mask IPv4 address per BEP 42 specification.
 *
 * Mask: 0x030f3fff (binary: 00000011 00001111 00111111 11111111)
 * This preserves ~21 bits of IP information while allowing flexibility.
 *
 * @param ip : "IPv4 address (4 bytes)"
 * @param random : "Random value (0-7)"
 * @return "Masked IP with random value shifted to bit 29"
 */
fn ulong mask_ipv4(common::Ipv4Addr ip, char random)
{
    // Convert IP to big-endian 32-bit integer
    ulong ip_int = ((ulong)ip[0] << 24) | ((ulong)ip[1] << 16) |
                   ((ulong)ip[2] << 8) | ((ulong)ip[3]);

    // Apply BEP 42 mask
    ulong masked = ip_int & 0x030f3fff;

    // Add random value in bits 29-31
    masked |= ((ulong)(random & 0x07) << 29);

    return masked;
}

/**
 * Generate a BEP 42 compliant node ID for given IP and random value.
 *
 * INTERNAL/DEPRECATED: Prefer generate_node_id_for_address() (SocketAddress API).
 * This function is public only for testing purposes.
 *
 * Node ID format:
 *   - Bits 0-20: First 21 bits of CRC32C(masked_ip)
 *   - Bits 21-23: Random value (0-7)
 *   - Bits 24-159: Random data (can be anything)
 *
 * @param ip : "IPv4 address"
 * @param random : "Random value (0-7)"
 * @return "20-byte node ID"
 */
fn common::NodeId generate_node_id(common::Ipv4Addr ip, char random) @public
{
    // Mask IP with random value
    ulong masked_ip = mask_ipv4(ip, random);

    // Convert to bytes (big-endian)
    char[4] ip_bytes;
    ip_bytes[0] = (char)((masked_ip >> 24) & 0xFF);
    ip_bytes[1] = (char)((masked_ip >> 16) & 0xFF);
    ip_bytes[2] = (char)((masked_ip >> 8) & 0xFF);
    ip_bytes[3] = (char)(masked_ip & 0xFF);

    // Compute CRC32C
    uint crc = crc32c(ip_bytes[..]);

    // Build node ID
    common::NodeId node_id;

    // First 21 bits from CRC32C (bits 0-20 of node ID)
    // Plus 3 bits for random (bits 21-23 of node ID)
    node_id[0] = (char)((crc >> 24) & 0xFF);              // Bits 0-7
    node_id[1] = (char)((crc >> 16) & 0xFF);              // Bits 8-15
    node_id[2] = (char)(((crc >> 8) & 0xF8) | (random & 0x07));  // Bits 16-23 (21 bits CRC + 3 bits random)

    // Remaining 17 bytes can be random (not specified by BEP 42)
    // For now, set to zero (could be random in production)
    for (usz i = 3; i < 20; i++)
    {
        node_id[i] = 0;
    }

    return node_id;
}

/**
 * Extract random value (r) from node ID.
 *
 * Random value is stored in bits 21-23 of node ID.
 *
 * @param id : "Node ID"
 * @return "Random value (0-7)"
 */
fn char extract_random_from_node_id(common::NodeId id)
{
    // Bits 21-23 are in the lower 3 bits of byte 2
    return id[2] & 0x07;
}

/**
 * Check if IP address is exempt from BEP 42 verification.
 *
 * INTERNAL/DEPRECATED: Public only for testing. Prefer SocketAddress API.
 *
 * Private/local networks are exempt:
 *   - 10.0.0.0/8
 *   - 172.16.0.0/12
 *   - 192.168.0.0/16
 *   - 169.254.0.0/16 (link-local)
 *   - 127.0.0.0/8 (loopback)
 *
 * @param ip : "IPv4 address"
 * @return "True if exempt from verification"
 */
fn bool is_ip_exempt_from_verification(common::Ipv4Addr ip) @public
{
    // 10.0.0.0/8
    if (ip[0] == 10)
    {
        return true;
    }

    // 172.16.0.0/12
    if (ip[0] == 172 && (ip[1] >= 16 && ip[1] <= 31))
    {
        return true;
    }

    // 192.168.0.0/16
    if (ip[0] == 192 && ip[1] == 168)
    {
        return true;
    }

    // 169.254.0.0/16 (link-local)
    if (ip[0] == 169 && ip[1] == 254)
    {
        return true;
    }

    // 127.0.0.0/8 (loopback)
    if (ip[0] == 127)
    {
        return true;
    }

    return false;
}

/**
 * Verify that node ID matches source IP per BEP 42.
 *
 * INTERNAL/DEPRECATED: Prefer verify_node_id_for_address() (SocketAddress API).
 * This function is public only for testing purposes.
 *
 * Verification steps:
 *   1. Check if IP is exempt (private/local) → always valid
 *   2. Extract random value from node ID (bits 21-23)
 *   3. Compute expected CRC32C(masked_ip | r)
 *   4. Compare first 21 bits of node ID with first 21 bits of CRC32C
 *
 * @param id : "Node ID to verify"
 * @param ip : "Source IPv4 address"
 * @return "True if node ID is valid for this IP"
 */
fn bool verify_node_id(common::NodeId id, common::Ipv4Addr ip) @public
{
    // Exempt IPs always verify
    if (is_ip_exempt_from_verification(ip))
    {
        return true;
    }

    // Extract random value from node ID
    char random = extract_random_from_node_id(id);

    // Mask IP with extracted random value
    ulong masked_ip = mask_ipv4(ip, random);

    // Convert to bytes (big-endian)
    char[4] ip_bytes;
    ip_bytes[0] = (char)((masked_ip >> 24) & 0xFF);
    ip_bytes[1] = (char)((masked_ip >> 16) & 0xFF);
    ip_bytes[2] = (char)((masked_ip >> 8) & 0xFF);
    ip_bytes[3] = (char)(masked_ip & 0xFF);

    // Compute expected CRC32C
    uint expected_crc = crc32c(ip_bytes[..]);

    // Extract first 21 bits from node ID
    uint node_bits = ((uint)id[0] << 24) | ((uint)id[1] << 16) | ((uint)(id[2] & 0xF8) << 8);

    // Extract first 21 bits from CRC32C
    uint crc_bits = expected_crc & 0xFFFFF800;  // Mask to keep only bits 0-20

    // Compare
    return node_bits == crc_bits;
}

// ============================================================================
// BEP 42 IPv6 Support
// ============================================================================

/**
 * Check if IPv6 address is exempt from BEP 42 verification.
 *
 * INTERNAL/DEPRECATED: Public only for testing. Prefer SocketAddress API.
 *
 * Private/local networks are exempt:
 *   - fc00::/7  (Unique Local Addresses - ULA)
 *   - fe80::/10 (Link-Local)
 *   - ::1/128   (Loopback)
 *
 * @param ipv6 : "IPv6 address (16 bytes)"
 * @return "True if exempt from verification"
 */
fn bool is_ipv6_exempt_from_verification(common::Ipv6Addr ipv6) @public
{
    // fc00::/7 (Unique Local Addresses)
    if ((ipv6[0] & 0xFE) == 0xFC)
    {
        return true;
    }

    // fe80::/10 (Link-Local)
    if (ipv6[0] == 0xFE && (ipv6[1] & 0xC0) == 0x80)
    {
        return true;
    }

    // ::1/128 (Loopback)
    bool is_loopback = true;
    for (usz i = 0; i < 15; i++)
    {
        if (ipv6[i] != 0)
        {
            is_loopback = false;
            break;
        }
    }
    if (is_loopback && ipv6[15] == 1)
    {
        return true;
    }

    return false;
}

/**
 * Mask IPv6 address per BEP 42 specification.
 *
 * Mask (first 64 bits): 0x0103070f1f3f7fff
 * This preserves ~21 bits of IPv6 information while allowing flexibility.
 *
 * @param ipv6 : "IPv6 address (16 bytes)"
 * @param random : "Random value (0-7)"
 * @param result : "Output buffer for masked address (8 bytes)"
 */
fn void mask_ipv6(common::Ipv6Addr ipv6, char random, char* result)
{
    // BEP 42 IPv6 mask for first 64 bits: 0x0103070f1f3f7fff
    char[8] mask = {
        0x01, 0x03, 0x07, 0x0f,
        0x1f, 0x3f, 0x7f, 0xff
    };

    // Apply mask to first 8 bytes of IPv6 address
    for (usz i = 0; i < 8; i++)
    {
        result[i] = ipv6[i] & mask[i];
    }

    // Add random value in bits 61-63 (byte 7, bits 5-7)
    result[7] = (result[7] & 0x1F) | ((random & 0x07) << 5);
}

/**
 * Generate a BEP 42 compliant node ID for given IPv6 address and random value.
 *
 * INTERNAL/DEPRECATED: Prefer generate_node_id_for_address() (SocketAddress API).
 * This function is public only for testing purposes.
 *
 * Node ID format (same as IPv4):
 *   - Bits 0-20: First 21 bits of CRC32C(masked_ipv6)
 *   - Bits 21-23: Random value (0-7)
 *   - Bits 24-159: Random data (can be anything)
 *
 * @param ipv6 : "IPv6 address (16 bytes)"
 * @param random : "Random value (0-7)"
 * @return "20-byte node ID"
 */
fn common::NodeId generate_node_id_ipv6(common::Ipv6Addr ipv6, char random) @public
{
    // Mask IPv6 address with random value (first 64 bits)
    char[8] masked;
    mask_ipv6(ipv6, random, &masked[0]);

    // Compute CRC32C of masked address
    uint crc = crc32c(masked[..]);

    // Build node ID (same format as IPv4)
    common::NodeId node_id;

    // First 21 bits from CRC32C + 3 bits for random
    node_id[0] = (char)((crc >> 24) & 0xFF);              // Bits 0-7
    node_id[1] = (char)((crc >> 16) & 0xFF);              // Bits 8-15
    node_id[2] = (char)(((crc >> 8) & 0xF8) | (random & 0x07));  // Bits 16-23

    // Remaining 17 bytes can be random (set to zero for now)
    for (usz i = 3; i < 20; i++)
    {
        node_id[i] = 0;
    }

    return node_id;
}

/**
 * Verify that node ID matches source IPv6 address per BEP 42.
 *
 * INTERNAL/DEPRECATED: Prefer verify_node_id_for_address() (SocketAddress API).
 * This function is public only for testing purposes.
 *
 * Verification steps:
 *   1. Check if IPv6 is exempt (local/private) → always valid
 *   2. Extract random value from node ID (bits 21-23)
 *   3. Compute expected CRC32C(masked_ipv6 | r)
 *   4. Compare first 21 bits of node ID with first 21 bits of CRC32C
 *
 * @param id : "Node ID to verify"
 * @param ipv6 : "Source IPv6 address"
 * @return "True if node ID is valid for this IPv6"
 */
fn bool verify_node_id_ipv6(common::NodeId id, common::Ipv6Addr ipv6) @public
{
    // Exempt IPv6 addresses always verify
    if (is_ipv6_exempt_from_verification(ipv6))
    {
        return true;
    }

    // Extract random value from node ID
    char random = id[2] & 0x07;

    // Mask IPv6 with extracted random value
    char[8] masked;
    mask_ipv6(ipv6, random, &masked[0]);

    // Compute expected CRC32C
    uint expected_crc = crc32c(masked[..]);

    // Extract first 21 bits from node ID
    uint node_bits = ((uint)id[0] << 24) | ((uint)id[1] << 16) | ((uint)(id[2] & 0xF8) << 8);

    // Extract first 21 bits from CRC32C
    uint crc_bits = expected_crc & 0xFFFFF800;

    // Compare
    return node_bits == crc_bits;
}

// ============================================================================
// Unified BEP 42 Functions (IPv4 + IPv6)
// ============================================================================

/**
 * Generate a BEP 42 compliant node ID for a given socket address.
 *
 * Automatically dispatches to IPv4 or IPv6 implementation based on address type.
 *
 * @param addr : "Socket address (IPv4 or IPv6)"
 * @param random : "Random value (0-7)"
 * @return "20-byte node ID"
 */
fn common::NodeId generate_node_id_for_address(common::SocketAddress addr, char random) @public
{
    if (addr.addr.is_ipv6)
    {
        // Extract IPv6 bytes directly from InetAddress
        common::Ipv6Addr ipv6_bytes;
        char* ipv6_ptr = (char*)&addr.addr.ipv6;
        for (usz i = 0; i < 16; i++)
        {
            ipv6_bytes[i] = ipv6_ptr[i];
        }
        return generate_node_id_ipv6(ipv6_bytes, random);
    }
    else
    {
        common::Ipv4Addr ipv4_bytes = addr.to_ipv4_bytes();
        return generate_node_id(ipv4_bytes, random);
    }
}

/**
 * Verify that node ID matches source socket address per BEP 42.
 *
 * Automatically dispatches to IPv4 or IPv6 implementation based on address type.
 *
 * @param id : "Node ID to verify"
 * @param addr : "Source socket address (IPv4 or IPv6)"
 * @return "True if node ID is valid for this address"
 */
fn bool verify_node_id_for_address(common::NodeId id, common::SocketAddress addr) @public
{
    if (addr.addr.is_ipv6)
    {
        // Extract IPv6 bytes directly from InetAddress
        common::Ipv6Addr ipv6_bytes;
        char* ipv6_ptr = (char*)&addr.addr.ipv6;
        for (usz i = 0; i < 16; i++)
        {
            ipv6_bytes[i] = ipv6_ptr[i];
        }
        return verify_node_id_ipv6(id, ipv6_bytes);
    }
    else
    {
        common::Ipv4Addr ipv4_bytes = addr.to_ipv4_bytes();
        return verify_node_id(id, ipv4_bytes);
    }
}
