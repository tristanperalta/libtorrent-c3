module libtorrent::path_sanitize;

import std::io::path;

/**
 * Path sanitization utilities for BitTorrent file paths.
 *
 * This module provides security-hardened path sanitization that extends
 * C3's standard library path handling with BitTorrent-specific requirements:
 * - UTF-8 validation and repair
 * - Null byte removal
 * - Unicode directional character removal (security)
 * - Path truncation with extension preservation
 * - Platform-specific trailing character handling
 */

/**
 * Check if a byte is a valid UTF-8 continuation byte (10xxxxxx).
 */
fn bool is_utf8_continuation(char byte) @inline
{
    // Convert to unsigned byte value
    usz b = ((usz)byte) & 0xFF;
    return (b & 0xC0) == 0x80;
}

/**
 * Validate UTF-8 encoding and count expected continuation bytes.
 *
 * UTF-8 structure:
 * - 1-byte: 0xxxxxxx
 * - 2-byte: 110xxxxx 10xxxxxx
 * - 3-byte: 1110xxxx 10xxxxxx 10xxxxxx
 * - 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
 *
 * @param first_byte The first byte of the sequence
 * @return Number of continuation bytes expected (1-3), or -1 if invalid
 */
fn int utf8_continuation_bytes(char first_byte)
{
    // Convert signed char to unsigned byte value (0-255)
    // Cast to usz first to avoid sign extension, then mask
    usz byte = ((usz)first_byte) & 0xFF;

    // 1-byte sequence (ASCII): 0xxxxxxx
    if (byte < 0x80) return 0;

    // 2-byte sequence: 110xxxxx
    if ((byte & 0xE0) == 0xC0)
    {
        // Check for overlong encoding (must encode value >= 0x80)
        if (byte < 0xC2) return -1;  // Overlong
        return 1;
    }

    // 3-byte sequence: 1110xxxx
    if ((byte & 0xF0) == 0xE0) return 2;

    // 4-byte sequence: 11110xxx
    if ((byte & 0xF8) == 0xF0)
    {
        // Check for invalid sequences (UTF-8 only goes up to U+10FFFF)
        if (byte > 0xF4) return -1;  // Out of range
        return 3;
    }

    // Invalid start byte (continuation byte or 5/6-byte sequence)
    return -1;
}

/**
 * Check if a string contains valid UTF-8 encoding.
 *
 * @param str The string to validate
 * @return true if the string is valid UTF-8, false otherwise
 */
fn bool is_valid_utf8(String str) @public
{
    usz i = 0;
    while (i < str.len)
    {
        char byte = str[i];
        int continuation_bytes = utf8_continuation_bytes(byte);

        // Invalid start byte
        if (continuation_bytes < 0) return false;

        // ASCII character - valid
        if (continuation_bytes == 0)
        {
            i++;
            continue;
        }

        // Check if we have enough bytes left
        if (i + continuation_bytes >= str.len) return false;

        // Validate continuation bytes
        for (int j = 1; j <= continuation_bytes; j++)
        {
            if (!is_utf8_continuation(str[i + j])) return false;
        }

        // Check for overlong encodings and surrogates in 3-byte sequences
        if (continuation_bytes == 2)
        {
            usz first = ((usz)str[i]) & 0xFF;
            usz second = ((usz)str[i + 1]) & 0xFF;
            // U+0000 to U+07FF must use 2-byte encoding
            if (first == 0xE0 && second < 0xA0) return false;
            // Surrogates (U+D800-U+DFFF) are invalid
            if (first == 0xED && second >= 0xA0) return false;
        }

        // Check for overlong encodings and invalid ranges in 4-byte sequences
        if (continuation_bytes == 3)
        {
            usz first = ((usz)str[i]) & 0xFF;
            usz second = ((usz)str[i + 1]) & 0xFF;
            // U+0000 to U+FFFF must use 1-3 byte encoding
            if (first == 0xF0 && second < 0x90) return false;
            // U+10FFFF is the maximum valid code point
            if (first == 0xF4 && second > 0x8F) return false;
        }

        i += (usz)(continuation_bytes + 1);
    }

    return true;
}

/**
 * Repair invalid UTF-8 sequences by replacing invalid bytes with underscore.
 *
 * @param str The string to repair (will be modified in-place if invalid)
 * @return true if the string was valid, false if it was repaired
 */
fn bool repair_utf8(String* str) @public
{
    if (is_valid_utf8(*str)) return true;

    // Create a new buffer for the repaired string
    char[] repaired = mem::new_array(char, str.len);
    usz write_pos = 0;
    usz i = 0;

    while (i < str.len)
    {
        char byte = (*str)[i];
        int continuation_bytes = utf8_continuation_bytes(byte);

        // Invalid start byte - replace with underscore
        if (continuation_bytes < 0)
        {
            repaired[write_pos++] = '_';
            i++;
            continue;
        }

        // ASCII character - copy as-is
        if (continuation_bytes == 0)
        {
            repaired[write_pos++] = byte;
            i++;
            continue;
        }

        // Check if we have enough bytes for the sequence
        if (i + continuation_bytes >= str.len)
        {
            // Truncated sequence - replace with underscore
            repaired[write_pos++] = '_';
            i++;
            continue;
        }

        // Validate continuation bytes
        bool valid = true;
        for (int j = 1; j <= continuation_bytes; j++)
        {
            if (!is_utf8_continuation((*str)[i + j]))
            {
                valid = false;
                break;
            }
        }

        if (!valid)
        {
            // Invalid continuation - replace with underscore
            repaired[write_pos++] = '_';
            i++;
            continue;
        }

        // Check for overlong encodings and surrogates
        bool overlong = false;
        if (continuation_bytes == 2)
        {
            usz first = ((usz)(*str)[i]) & 0xFF;
            usz second = ((usz)(*str)[i + 1]) & 0xFF;
            if (first == 0xE0 && second < 0xA0) overlong = true;
            // Surrogates (U+D800-U+DFFF) are invalid
            if (first == 0xED && second >= 0xA0) overlong = true;
        }
        else if (continuation_bytes == 3)
        {
            usz first = ((usz)(*str)[i]) & 0xFF;
            usz second = ((usz)(*str)[i + 1]) & 0xFF;
            if (first == 0xF0 && second < 0x90) overlong = true;
            if (first == 0xF4 && second > 0x8F) overlong = true;
        }

        if (overlong)
        {
            // Overlong encoding - security issue, replace
            repaired[write_pos++] = '_';
            i += (usz)(continuation_bytes + 1);
            continue;
        }

        // Valid sequence - copy all bytes
        for (int j = 0; j <= continuation_bytes; j++)
        {
            repaired[write_pos++] = (*str)[i + j];
        }
        i += (usz)(continuation_bytes + 1);
    }

    // Free old string and replace with repaired version
    free(*str);
    *str = (String)repaired[:write_pos];
    return false;
}

/**
 * Remove null bytes from a string by replacing them with underscore.
 *
 * @param str The string to process
 * @return Sanitized string (caller must free if different from input)
 */
fn String remove_null_bytes(String str) @public
{
    // Quick check: does it contain null bytes?
    bool has_null = false;
    foreach (c : str)
    {
        if (c == 0)
        {
            has_null = true;
            break;
        }
    }

    // No null bytes - return as-is
    if (!has_null) return str;

    // Replace null bytes with underscore
    char[] result = str.copy(mem);
    foreach (i, c : result)
    {
        if (c == 0) result[i] = '_';
    }

    return (String)result;
}

/**
 * Remove Unicode directional override characters that can hide file extensions.
 *
 * Removes:
 * - U+200E (LEFT-TO-RIGHT MARK):      \xe2\x80\x8e
 * - U+202B (RIGHT-TO-LEFT EMBEDDING): \xe2\x80\xab
 * - U+202E (RIGHT-TO-LEFT OVERRIDE):  \xe2\x80\xae
 *
 * These characters can make "evil.exe⮞txt." appear as "evil.txt" in displays.
 *
 * @param str The string to process
 * @return Sanitized string (caller must free if different from input)
 */
fn String remove_directional_chars(String str) @public
{
    if (str.len < 3) return str;  // Shortest sequence is 3 bytes

    // Quick scan: check if it contains any directional marks
    bool has_directional = false;
    for (usz i = 0; i + 2 < str.len; i++)
    {
        usz b1 = ((usz)str[i]) & 0xFF;
        usz b2 = ((usz)str[i + 1]) & 0xFF;
        if (b1 == 0xe2 && b2 == 0x80)
        {
            usz third = ((usz)str[i + 2]) & 0xFF;
            if (third == 0x8e || third == 0xab || third == 0xae)
            {
                has_directional = true;
                break;
            }
        }
    }

    // No directional characters - return as-is
    if (!has_directional) return str;

    // Remove directional characters
    char[] result = mem::new_array(char, str.len);
    usz write_pos = 0;

    for (usz i = 0; i < str.len; i++)
    {
        // Check for start of directional sequence
        if (i + 2 < str.len)
        {
            usz b1 = ((usz)str[i]) & 0xFF;
            usz b2 = ((usz)str[i + 1]) & 0xFF;
            if (b1 == 0xe2 && b2 == 0x80)
            {
                usz third = ((usz)str[i + 2]) & 0xFF;
                if (third == 0x8e || third == 0xab || third == 0xae)
                {
                    // Skip this 3-byte sequence
                    i += 2;
                    continue;
                }
            }
        }

        // Copy normal character
        result[write_pos++] = str[i];
    }

    return (String)result[:write_pos];
}

/**
 * Handle platform-specific trailing dots and spaces.
 *
 * Windows: Remove trailing dots and spaces
 * POSIX: Preserve trailing dots and spaces
 *
 * @param str The string to process
 * @param path_env The path environment (WIN32 or POSIX)
 * @return Sanitized string (may be same as input on POSIX)
 */
fn String handle_trailing_chars(String str, path::PathEnv path_env) @public
{
    // POSIX: preserve trailing characters
    if (path_env != path::PathEnv.WIN32) return str;

    // Windows: remove trailing dots and spaces
    usz end = str.len;
    while (end > 0 && (str[end - 1] == '.' || str[end - 1] == ' '))
    {
        end--;
    }

    // No change needed
    if (end == str.len) return str;

    // Return trimmed string
    return str[:end].copy(mem);
}

/**
 * Truncate a path to maximum length while preserving file extension.
 *
 * @param str The path to truncate
 * @param max_len Maximum length (default 240)
 * @return Truncated path (caller must free if different from input)
 */
fn String truncate_path(String str, usz max_len = 240) @public
{
    if (str.len <= max_len) return str;

    // Find extension (last dot)
    usz? ext_index = str.rindex_of(".");
    String ext = "";
    if (try index = ext_index)
    {
        ext = str[index..];
    }

    // Calculate available space for base name
    usz base_max = max_len - ext.len;
    if (base_max == 0)
    {
        // Extension is longer than max_len - just truncate
        return str[:max_len].copy(mem);
    }

    // Try to find a word boundary (space) near the truncation point
    usz truncate_at = base_max;

    // Look back up to 20 characters for a space
    usz search_start = truncate_at > 20 ? truncate_at - 20 : 0;
    for (usz i = truncate_at; i > search_start; i--)
    {
        if (str[i - 1] == ' ')
        {
            truncate_at = i - 1;  // Truncate before the space
            break;
        }
    }

    // Ensure we don't split a UTF-8 character
    // Step back if we're in the middle of a multi-byte sequence
    while (truncate_at > 0 && is_utf8_continuation(str[truncate_at]))
    {
        truncate_at--;
    }

    // Combine base + extension
    @pool()
    {
        DString result = dstring::temp_with_capacity(max_len);
        result.append(str[:truncate_at]);
        result.append(ext);
        return result.copy_str(mem);
    };
}

/**
 * Sanitize a file path for safe BitTorrent operations.
 *
 * This is the main entry point that combines all sanitization steps:
 * 1. UTF-8 validation and repair
 * 2. Null byte removal
 * 3. Unicode directional character removal (security)
 * 4. Path normalization (using C3 stdlib)
 * 5. Platform-specific trailing character handling
 * 6. Path truncation to 240 characters
 *
 * @param file_path The file path to sanitize
 * @param path_env The target path environment (default: auto-detect)
 * @return Sanitized path (caller must free)
 */
fn String? sanitize_torrent_path(String file_path, path::PathEnv path_env = path::DEFAULT_ENV) @public
{
    // Step 1: UTF-8 validation and repair
    String utf8_str = file_path.copy(mem);
    repair_utf8(&utf8_str);

    // Step 2: Remove null bytes
    String no_nulls = remove_null_bytes(utf8_str);
    if (no_nulls != utf8_str) free(utf8_str);

    // Step 3: Remove Unicode directional characters (security)
    String no_directional = remove_directional_chars(no_nulls);
    if (no_directional != no_nulls) free(no_nulls);

    // Step 4: Use C3's stdlib path normalization
    // This handles path traversal, reserved characters, separator folding
    // If normalization fails (e.g., path tries to escape root with../..),
    // strip leading ../ sequences and try again
    String normalized;

    // Try to normalize - use a temporary to avoid the double-call pattern
    String? norm_result = path::normalize(no_directional, path_env);
    if (catch excuse = norm_result)
    {

        // Path normalization failed - likely due to path traversal or other issues
        // Clean up the path by removing problematic sequences
        String safe = no_directional;

        // Strip leading ../ and ../
        while (safe.starts_with("../") || safe.starts_with("..\\"))
        {
            safe = safe[3..];
        }

        // Strip leading ./ and .\
        while (safe.starts_with("./") || safe.starts_with(".\\"))
        {
            safe = safe[2..];
        }

        // Replace internal "./" and ".\" with just the separator
        // This preserves path structure: "foo/./bar" -> "foo//bar"
        String temp1 = safe.replace(mem, "/./", "/");
        String temp2 = temp1.replace(mem, "\\.\\", "\\");
        if (temp2 != temp1) free(temp1);
        safe = temp2;

        // Strip leading slashes
        while (safe.starts_with("/") || safe.starts_with("\\"))
        {
            safe = safe[1..];
        }

        // Handle special cases
        if (safe == ".." || safe == "." || safe.len == 0)
        {
            free(safe);
            safe = "_";
        }

        // Try to normalize the cleaned path
        String? norm_result2 = path::normalize(safe, path_env);
        if (catch excuse2 = norm_result2)
        {
            // Still failed, just use the safe path as-is
            normalized = safe.copy(mem);
        }
        else
        {
            normalized = norm_result2;
        }
        free(no_directional);
    }
    else
    {
        // path::normalize succeeded - use the result we already have
        // Make a defensive copy to avoid memory corruption issues
        if (norm_result == no_directional)
        {
            // Same string - keep it as-is
            normalized = norm_result;
        }
        else
        {
            // Different string - make a copy and free the old one
            normalized = norm_result.copy(mem);
            free(no_directional);
        }
    }

    // Step 4b: Final cleanup - remove any remaining ".." for security
    // Even if normalize succeeded, ensure no path traversal remains
    String final_normalized = normalized;
    if (normalized.contains(".."))
    {
        // Replace all occurrences of ".." with "_"
        final_normalized = normalized.replace(mem, "..", "_");
        free(normalized);
    }

    // Step 5: Handle platform-specific trailing dots and spaces
    String no_trailing = handle_trailing_chars(final_normalized, path_env);
    if (no_trailing != final_normalized) free(final_normalized);

    // Step 6: Truncate to 240 characters with extension preservation
    String truncated = truncate_path(no_trailing, 240);
    if (truncated != no_trailing) free(no_trailing);

    return truncated;
}
