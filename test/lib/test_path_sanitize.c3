module libtorrent::test;

import libtorrent::path_sanitize;
import std::io::path;

/**
 * Test UTF-8 validation for valid sequences
 */
fn void test_utf8_validation_valid() @test
{
    // ASCII
    assert(path_sanitize::is_valid_utf8("hello"), "ASCII should be valid");

    // Valid 2-byte sequence: ¡
    assert(path_sanitize::is_valid_utf8("\xc2\xa1"), "Valid 2-byte UTF-8 should be valid");

    // Valid 3-byte sequence: €
    assert(path_sanitize::is_valid_utf8("\xe2\x82\xac"), "Valid 3-byte UTF-8 should be valid");

    // Valid 4-byte sequence: 𝄞
    assert(path_sanitize::is_valid_utf8("\xf0\x9d\x84\x9e"), "Valid 4-byte UTF-8 should be valid");

    // Mixed valid sequences
    assert(path_sanitize::is_valid_utf8("hello\xc2\xa1world"), "Mixed ASCII and UTF-8 should be valid");
}

/**
 * Test UTF-8 validation for invalid sequences
 */
fn void test_utf8_validation_invalid() @test
{
    // Truncated 2-byte sequence - build it manually to ensure correct bytes
    char[] truncated2 = {0xc2};
    assert(!path_sanitize::is_valid_utf8((String)truncated2), "Truncated 2-byte should be invalid");

    // Truncated 3-byte sequence
    char[] truncated3 = {0xe2, 0x82};
    assert(!path_sanitize::is_valid_utf8((String)truncated3), "Truncated 3-byte should be invalid");

    // Invalid continuation byte
    char[] invalid_cont = {0xc2, 0x00};
    assert(!path_sanitize::is_valid_utf8((String)invalid_cont), "Invalid continuation byte should be invalid");

    // Overlong encoding (2-byte form of ASCII)
    char[] overlong2 = {0xc0, 0x80};
    assert(!path_sanitize::is_valid_utf8((String)overlong2), "Overlong encoding should be invalid");

    // Overlong encoding (3-byte)
    char[] overlong3 = {0xe0, 0x80, 0x80};
    assert(!path_sanitize::is_valid_utf8((String)overlong3), "Overlong 3-byte should be invalid");

    // Invalid 5-byte sequence
    char[] invalid5 = {0xf8, 0xa1, 0xa1, 0xa1, 0xa1};
    assert(!path_sanitize::is_valid_utf8((String)invalid5), "5-byte sequence should be invalid");

    // Surrogate pair (not allowed in UTF-8)
    char[] surrogate = {0xed, 0xa0, 0x80};
    assert(!path_sanitize::is_valid_utf8((String)surrogate), "Surrogate pair should be invalid");
}

/**
 * Test UTF-8 repair function
 */
fn void test_utf8_repair() @test
{
    // Valid UTF-8 should not be modified
    String valid = "hello\xc2\xa1".copy(mem);
    defer free(valid);
    bool was_valid = path_sanitize::repair_utf8(&valid);
    assert(was_valid, "Valid UTF-8 should return true");
    assert(valid == "hello\xc2\xa1", "Valid UTF-8 should not be modified");

    // Invalid UTF-8 should be repaired - build manually
    char[] invalid_bytes = {0xc2};
    String invalid = ((String)invalid_bytes).copy(mem);
    defer free(invalid);
    bool was_invalid = path_sanitize::repair_utf8(&invalid);
    assert(!was_invalid, "Invalid UTF-8 should return false");
    assert(invalid == "_", "Invalid byte should be replaced with underscore");
}

/**
 * Test null byte removal
 */
fn void test_null_byte_removal() @test
{
    // No null bytes - should return same string
    String no_nulls = "hello";
    String result1 = path_sanitize::remove_null_bytes(no_nulls);
    assert(result1 == no_nulls, "String without null bytes should be unchanged");

    // Null bytes present - should be replaced
    String with_nulls = "hello\x00world";
    String result2 = path_sanitize::remove_null_bytes(with_nulls);
    defer free(result2);
    assert(result2 == "hello_world", "Null bytes should be replaced with underscore");

    // Multiple null bytes
    String multi_nulls = "\x00\x00\x00";
    String result3 = path_sanitize::remove_null_bytes(multi_nulls);
    defer free(result3);
    assert(result3 == "___", "All null bytes should be replaced");
}

/**
 * Test Unicode directional character removal
 */
fn void test_directional_char_removal() @test
{
    // No directional chars
    String no_dir = "hello.txt";
    String result1 = path_sanitize::remove_directional_chars(no_dir);
    assert(result1 == no_dir, "String without directional chars should be unchanged");

    // U+200E (LEFT-TO-RIGHT MARK): 0xe2 0x80 0x8e
    char[] ltr_bytes = {'h','e','l','l','o', 0xe2, 0x80, 0x8e, '.','t','x','t'};
    String result2 = path_sanitize::remove_directional_chars((String)ltr_bytes);
    defer if (result2 != (String)ltr_bytes) free(result2);
    assert(result2 == "hello.txt", "U+200E should be removed");

    // U+202B (RIGHT-TO-LEFT EMBEDDING): 0xe2 0x80 0xab
    char[] rle_bytes = {'e','v','i','l', 0xe2, 0x80, 0xab, 'e','x','e','.','t','x','t'};
    String result3 = path_sanitize::remove_directional_chars((String)rle_bytes);
    defer if (result3 != (String)rle_bytes) free(result3);
    assert(result3 == "evilexe.txt", "U+202B should be removed");

    // U+202E (RIGHT-TO-LEFT OVERRIDE): 0xe2 0x80 0xae
    char[] rlo_bytes = {'f','i','l','e', 0xe2, 0x80, 0xae, '.','d','o','c'};
    String result4 = path_sanitize::remove_directional_chars((String)rlo_bytes);
    defer if (result4 != (String)rlo_bytes) free(result4);
    assert(result4 == "file.doc", "U+202E should be removed");
}

/**
 * Test path truncation without extension
 */
fn void test_truncate_path_basic() @test
{
    // Short path - no truncation needed
    String short_path = "hello.txt";
    String result1 = path_sanitize::truncate_path(short_path, 240);
    assert(result1 == short_path, "Short path should not be truncated");

    // Long path - should truncate
    char[] long_base = mem::new_array(char, 300);
    defer free(long_base);
    for (usz i = 0; i < 300; i++) long_base[i] = 'a';

    @pool()
    {
        DString long_path = dstring::temp_with_capacity(310);
        long_path.append((String)long_base);
        long_path.append(".txt");

        String result2 = path_sanitize::truncate_path(long_path.str_view(), 240);
        defer free(result2);

        assert(result2.len == 240, "Long path should be truncated to 240 chars");
        assert(result2.ends_with(".txt"), "Extension should be preserved");
    };
}

/**
 * Test path truncation with UTF-8
 */
fn void test_truncate_path_utf8() @test
{
    // Create path with UTF-8 near truncation point
    @pool()
    {
        DString path = dstring::temp_with_capacity(250);
        // Add 237 ASCII chars
        for (usz i = 0; i < 237; i++) path.append("a");
        // Add 2-byte UTF-8: ¡ (\xc2\xa1)
        path.append("\xc2\xa1");
        // Add extension
        path.append(".txt");

        String result = path_sanitize::truncate_path(path.str_view(), 240);
        defer free(result);

        assert(result.len <= 240, "Path should not exceed max length");
        assert(path_sanitize::is_valid_utf8(result), "Truncated path should have valid UTF-8");
        assert(result.ends_with(".txt"), "Extension should be preserved");
    };
}

/**
 * Test trailing dot/space handling on Windows
 */
fn void test_trailing_chars_windows() @test
{
    // Test with Windows path environment
    String with_dots = "filename...";
    String result1 = path_sanitize::handle_trailing_chars(with_dots, path::PathEnv.WIN32);
    defer if (result1 != with_dots) free(result1);
    assert(result1 == "filename", "Trailing dots should be removed on Windows");

    String with_spaces = "filename   ";
    String result2 = path_sanitize::handle_trailing_chars(with_spaces, path::PathEnv.WIN32);
    defer if (result2 != with_spaces) free(result2);
    assert(result2 == "filename", "Trailing spaces should be removed on Windows");

    String mixed = "filename. . ";
    String result3 = path_sanitize::handle_trailing_chars(mixed, path::PathEnv.WIN32);
    defer if (result3 != mixed) free(result3);
    assert(result3 == "filename", "Mixed trailing chars should be removed on Windows");
}

/**
 * Test trailing dot/space handling on POSIX
 */
fn void test_trailing_chars_posix() @test
{
    // Test with POSIX path environment
    String with_dots = "filename...";
    String result1 = path_sanitize::handle_trailing_chars(with_dots, path::PathEnv.POSIX);
    assert(result1 == with_dots, "Trailing dots should be preserved on POSIX");

    String with_spaces = "filename   ";
    String result2 = path_sanitize::handle_trailing_chars(with_spaces, path::PathEnv.POSIX);
    assert(result2 == with_spaces, "Trailing spaces should be preserved on POSIX");
}

/**
 * Test full path sanitization with simple cases
 */
fn void test_sanitize_path_basic() @test
{
    // Valid path - should pass through with normalization
    String? result1 = path_sanitize::sanitize_torrent_path("hello/world.txt");
    if (catch excuse = result1)
    {
        assert(false, "Valid path should succeed");
        return;
    }
    defer free(result1);

    // Path with null bytes - use explicit byte array
    char[] null_bytes_path = {'h','e','l','l','o', 0x00, 'w','o','r','l','d','.','t','x','t'};
    String? result2 = path_sanitize::sanitize_torrent_path((String)null_bytes_path);
    if (catch excuse = result2)
    {
        assert(false, "Path with null bytes should succeed");
        return;
    }
    defer free(result2);
    assert(!result2.contains("\x00"), "Null bytes should be removed");

    // Path with directional characters - use explicit byte array
    // U+202B (RIGHT-TO-LEFT EMBEDDING): 0xe2 0x80 0xab
    char[] dir_char_path = {'e','v','i','l', 0xe2, 0x80, 0xab, 'e','x','e','.','t','x','t'};
    String? result3 = path_sanitize::sanitize_torrent_path((String)dir_char_path);
    if (catch excuse = result3)
    {
        assert(false, "Path with directional chars should succeed");
        return;
    }
    defer free(result3);
    // Check that the 3-byte sequence is not present
    char[] dir_sequence = {0xe2, 0x80, 0xab};
    assert(!result3.contains((String)dir_sequence), "Directional chars should be removed");
}

/**
 * Test path sanitization with path traversal
 */
fn void test_sanitize_path_traversal() @test
{
    // Parent directory traversal
    String? result1 = path_sanitize::sanitize_torrent_path("../../../etc/passwd");
    if (catch excuse = result1)
    {
        assert(false, "Path traversal should be sanitized");
        return;
    }
    defer free(result1);
    assert(!result1.contains(".."), "Parent directory markers should be removed");

    // Current directory markers
    String? result2 = path_sanitize::sanitize_torrent_path("./foo/./bar");
    if (catch excuse = result2)
    {
        assert(false, "Current directory markers should be normalized");
        return;
    }
    defer free(result2);
}

/**
 * Test path sanitization with invalid UTF-8
 */
fn void test_sanitize_path_invalid_utf8() @test
{
    // Truncated UTF-8 sequence - use explicit byte array
    char[] truncated_utf8 = {'f','i','l','e', 0xc2, '.','t','x','t'};
    String? result1 = path_sanitize::sanitize_torrent_path((String)truncated_utf8);
    if (catch excuse = result1)
    {
        assert(false, "Path with invalid UTF-8 should succeed");
        return;
    }
    defer free(result1);
    assert(path_sanitize::is_valid_utf8(result1), "Result should have valid UTF-8");
    assert(result1.contains("_"), "Invalid UTF-8 should be replaced with underscore");

    // Overlong encoding - use explicit byte array
    char[] overlong = {'f','i','l','e', 0xc0, 0x80, '.','t','x','t'};
    String? result2 = path_sanitize::sanitize_torrent_path((String)overlong);
    if (catch excuse = result2)
    {
        assert(false, "Path with overlong encoding should succeed");
        return;
    }
    defer free(result2);
    assert(path_sanitize::is_valid_utf8(result2), "Result should have valid UTF-8");
}

/**
 * Test path sanitization with long paths
 */
fn void test_sanitize_path_truncation() @test
{
    // Create very long path
    char[] long_name = mem::new_array(char, 300);
    defer free(long_name);
    for (usz i = 0; i < 300; i++) long_name[i] = 'x';

    @pool()
    {
        DString path = dstring::temp_with_capacity(310);
        path.append((String)long_name);
        path.append(".txt");

        String? result = path_sanitize::sanitize_torrent_path(path.str_view());
        if (catch excuse = result)
        {
            assert(false, "Long path should succeed");
            return;
        }
        defer free(result);

        assert(result.len <= 240, "Path should be truncated to 240 chars");
        assert(result.ends_with(".txt"), "Extension should be preserved after truncation");
    };
}

/**
 * Test comprehensive sanitization
 */
fn void test_sanitize_comprehensive() @test
{
    // Combination: invalid UTF-8, null bytes, directional chars, long path
    // Build the path with explicit bytes
    char[] invalid_utf8 = {'f','i','l','e', 0xc2};  // Invalid UTF-8
    char[] null_byte = {0x00};  // Null byte
    char[] dir_char = {0xe2, 0x80, 0xae};  // U+202E (RIGHT-TO-LEFT OVERRIDE)

    @pool()
    {
        DString complex = dstring::temp_with_capacity(300);
        complex.append((String)invalid_utf8);
        complex.append((String)null_byte);
        complex.append((String)dir_char);
        // Add padding to test truncation
        for (usz i = 0; i < 250; i++) complex.append("a");
        complex.append(".txt");

        String? result = path_sanitize::sanitize_torrent_path(complex.str_view());
        if (catch excuse = result)
        {
            assert(false, "Complex path should succeed");
            return;
        }
        defer free(result);

        assert(path_sanitize::is_valid_utf8(result), "Result should have valid UTF-8");
        assert(!result.contains("\x00"), "Null bytes should be removed");
        assert(!result.contains((String)dir_char), "Directional chars should be removed");
        assert(result.len <= 240, "Long path should be truncated");
        assert(result.ends_with(".txt"), "Extension should be preserved");
    };
}
