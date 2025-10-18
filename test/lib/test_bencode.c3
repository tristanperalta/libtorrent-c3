module libtorrent::bencode::test;

import std::io;
import libtorrent::bencode;

/**
 * Bencode Test Suite
 * ==================
 * Tests for encoding and decoding bencode values according to the BitTorrent specification.
 */

// ============================================================================
// Integer Tests
// ============================================================================

fn void test_encode_integer_positive() @test
{
    BencodeValue* val = bencode::make_integer(42);
    defer bencode::free_bencode_value(val);

    String encoded = bencode::encode(val);
    defer free(encoded);
    io::printfn("Encoded: '%s'", encoded);
    io::printfn("Length: %d", encoded.len);
    assert(encoded == "i42e", "Expected 'i42e'");
}

fn void test_encode_integer_negative() @test
{
    BencodeValue* val = bencode::make_integer(-3);
    defer bencode::free_bencode_value(val);

    String encoded = bencode::encode(val);
    defer free(encoded);
    assert(encoded == "i-3e", "Expected 'i-3e'");
}

fn void test_encode_integer_zero() @test
{
    BencodeValue* val = bencode::make_integer(0);
    defer bencode::free_bencode_value(val);

    String encoded = bencode::encode(val);
    defer free(encoded);
    assert(encoded == "i0e", "Expected 'i0e'");
}

fn void test_decode_integer_positive() @test
{
    BencodeValue* val = bencode::decode("i42e")!!;
    defer bencode::free_bencode_value(val);

    io::printfn("DEBUG: val.type = %d, expected INTEGER = %d", val.type.ordinal, bencode::BencodeType.INTEGER.ordinal);
    assert(val.type == bencode::BencodeType.INTEGER, "Expected INTEGER type");
    assert(val.integer == 42, "Expected value 42");
}

fn void test_decode_integer_negative() @test
{
    BencodeValue* val = bencode::decode("i-3e")!!;
    defer bencode::free_bencode_value(val);

    assert(val.type == bencode::BencodeType.INTEGER, "Expected INTEGER type");
    assert(val.integer == -3, "Expected value -3");
}

fn void test_decode_integer_zero() @test
{
    BencodeValue* val = bencode::decode("i0e")!!;
    defer bencode::free_bencode_value(val);

    assert(val.type == bencode::BencodeType.INTEGER, "Expected INTEGER type");
    assert(val.integer == 0, "Expected value 0");
}

fn void test_decode_integer_invalid_leading_zero() @test
{
    if (catch err = bencode::decode("i03e"))
    {
        // Expected to fail - test passes
    }
    else
    {
        assert(false, "Expected decode to fail for leading zero");
    }
}

// ============================================================================
// String Tests
// ============================================================================

fn void test_encode_string_simple() @test
{
    BencodeValue* val = bencode::make_string("spam");
    defer bencode::free_bencode_value(val);

    String encoded = bencode::encode(val);
    defer free(encoded);
    assert(encoded == "4:spam", "Expected '4:spam'");
}

fn void test_encode_string_empty() @test
{
    BencodeValue* val = bencode::make_string("");
    defer bencode::free_bencode_value(val);

    String encoded = bencode::encode(val);
    defer free(encoded);
    assert(encoded == "0:", "Expected '0:'");
}

fn void test_decode_string_simple() @test
{
    BencodeValue* val = bencode::decode("4:spam")!!;
    defer bencode::free_bencode_value(val);

    assert(val.type == bencode::BencodeType.STRING, "Expected STRING type");
    assert((String)val.string == "spam", "Expected 'spam'");
}

fn void test_decode_string_empty() @test
{
    BencodeValue* val = bencode::decode("0:")!!;
    defer bencode::free_bencode_value(val);

    assert(val.type == bencode::BencodeType.STRING, "Expected STRING type");
    assert((String)val.string == "", "Expected empty string");
}

fn void test_decode_string_with_special_chars() @test
{
    BencodeValue* val = bencode::decode("5:hi\x00\x01\x02")!!;
    defer bencode::free_bencode_value(val);

    assert(val.type == bencode::BencodeType.STRING, "Expected STRING type");
    assert(val.string.len == 5, "Expected length 5");
}

fn void test_decode_string_invalid_length() @test
{
    if (catch err = bencode::decode("5:spam"))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Expected decode to fail for length mismatch");
    }
}

// ============================================================================
// List Tests
// ============================================================================

fn void test_encode_list_empty() @test
{
    BencodeValue* val = bencode::make_list();
    defer bencode::free_bencode_value(val);

    String encoded = bencode::encode(val);
    defer free(encoded);
    assert(encoded == "le", "Expected 'le'");
}

fn void test_encode_list_simple() @test
{
    BencodeValue* list = bencode::make_list();
    defer bencode::free_bencode_value(list);

    BencodeValue* str = bencode::make_string("spam");
    BencodeValue* num = bencode::make_integer(42);

    bencode::list_append(list, str);
    bencode::list_append(list, num);

    String encoded = bencode::encode(list);
    defer free(encoded);
    assert(encoded == "l4:spami42ee", "Expected 'l4:spami42ee'");
}

fn void test_encode_list_nested() @test
{
    // TODO: Test encoding nested lists like [["a"], [["b"]]]
}

fn void test_decode_list_empty() @test
{
    BencodeValue* val = bencode::decode("le")!!;
    defer bencode::free_bencode_value(val);

    assert(val.type == bencode::BencodeType.LIST, "Expected LIST type");
    assert(val.list.len == 0, "Expected empty list");
}

fn void test_decode_list_simple() @test
{
    BencodeValue* val = bencode::decode("l4:spami42ee")!!;
    defer bencode::free_bencode_value(val);

    assert(val.type == bencode::BencodeType.LIST, "Expected LIST type");
    assert(val.list.len == 2, "Expected 2 items");

    BencodeValue* item0 = val.list[0];
    assert(item0.type == bencode::BencodeType.STRING, "Expected STRING at index 0");
    assert((String)item0.string == "spam", "Expected 'spam'");

    BencodeValue* item1 = val.list[1];
    assert(item1.type == bencode::BencodeType.INTEGER, "Expected INTEGER at index 1");
    assert(item1.integer == 42, "Expected 42");
}

fn void test_decode_list_mixed_types() @test
{
    // Test: [1, [2], 3] = li1eli2eei3ee
    BencodeValue* val = bencode::decode("li1eli2eei3ee")!!;
    defer bencode::free_bencode_value(val);

    assert(val.type == bencode::BencodeType.LIST, "Expected LIST type");
    assert(val.list.len == 3, "Expected 3 items");

    BencodeValue* item0 = val.list[0];
    assert(item0.type == bencode::BencodeType.INTEGER, "Expected INTEGER at index 0");
    assert(item0.integer == 1, "Expected 1");

    BencodeValue* item1 = val.list[1];
    assert(item1.type == bencode::BencodeType.LIST, "Expected LIST at index 1");
    assert(item1.list.len == 1, "Expected nested list with 1 item");

    BencodeValue* item2 = val.list[2];
    assert(item2.type == bencode::BencodeType.INTEGER, "Expected INTEGER at index 2");
    assert(item2.integer == 3, "Expected 3");
}

// ============================================================================
// Dictionary Tests
// ============================================================================

fn void test_encode_dict_empty() @test
{
    BencodeValue* dict = bencode::make_dict();
    defer bencode::free_bencode_value(dict);

    String encoded = bencode::encode(dict);
    defer free(encoded);
    assert(encoded == "de", "Expected 'de'");
}

fn void test_encode_dict_simple() @test
{
    BencodeValue* dict = bencode::make_dict();
    defer bencode::free_bencode_value(dict);

    BencodeValue* cow_val = bencode::make_string("moo");
    BencodeValue* spam_val = bencode::make_string("eggs");

    // Note: Keys must be in lexicographical order (cow < spam)
    bencode::dict_set(dict, "cow", cow_val);
    bencode::dict_set(dict, "spam", spam_val);

    String encoded = bencode::encode(dict);
    defer free(encoded);
    assert(encoded == "d3:cow3:moo4:spam4:eggse", "Expected 'd3:cow3:moo4:spam4:eggse'");
}

fn void test_encode_dict_sorted_keys() @test
{
    // TODO: Verify that keys are sorted lexicographically when encoding
}

fn void test_encode_dict_nested() @test
{
    // TODO: Test encoding dictionaries with nested values
}

fn void test_decode_dict_empty() @test
{
    BencodeValue* val = bencode::decode("de")!!;
    defer bencode::free_bencode_value(val);

    assert(val.type == bencode::BencodeType.DICT, "Expected DICT type");
    assert(val.dict.len == 0, "Expected empty dict");
}

fn void test_decode_dict_simple() @test
{
    BencodeValue* val = bencode::decode("d3:cow3:moo4:spam4:eggse")!!;
    defer bencode::free_bencode_value(val);

    assert(val.type == bencode::BencodeType.DICT, "Expected DICT type");
    assert(val.dict.len == 2, "Expected 2 entries");

    BencodeValue* cow_val = bencode::dict_get(val, "cow");
    assert(cow_val != null, "Expected 'cow' key to exist");
    assert(cow_val.type == bencode::BencodeType.STRING, "Expected STRING value for 'cow'");
    assert((String)cow_val.string == "moo", "Expected 'moo'");

    BencodeValue* spam_val = bencode::dict_get(val, "spam");
    assert(spam_val != null, "Expected 'spam' key to exist");
    assert(spam_val.type == bencode::BencodeType.STRING, "Expected STRING value for 'spam'");
    assert((String)spam_val.string == "eggs", "Expected 'eggs'");
}

fn void test_decode_dict_unsorted_keys() @test
{
    // TODO: Test that unsorted dictionary keys cause an error
    // Note: This requires additional validation logic in the decoder
}

fn void test_decode_dict_non_string_key() @test
{
    if (catch err = bencode::decode("di42e3:bare"))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Expected decode to fail for non-string key");
    }
}

// ============================================================================
// Real-World BitTorrent Examples
// ============================================================================

fn void test_decode_torrent_info_dict() @test
{
    // TODO: Test decoding a real .torrent file info dictionary structure
    // Example structure:
    // {
    //   "name": "example.txt",
    //   "length": 12345,
    //   "piece length": 262144,
    //   "pieces": "<20-byte SHA1 hash>"
    // }
}

fn void test_roundtrip_encoding() @test
{
    String[] test_cases = {
        "i42e",
        "4:spam",
        "le",
        "l4:spami42ee",
        "de",
        "d3:cow3:moo4:spam4:eggse"
    };

    foreach (test_case : test_cases)
    {
        BencodeValue* decoded = bencode::decode(test_case)!!;
        defer bencode::free_bencode_value(decoded);

        String encoded = bencode::encode(decoded);
        defer free(encoded);

        assert(encoded == test_case, "Roundtrip failed");
    }
}

// ============================================================================
// Error Handling Tests
// ============================================================================

fn void test_decode_invalid_format() @test
{
    if (catch err = bencode::decode("xyz"))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Expected decode to fail for invalid format");
    }
}

fn void test_decode_unexpected_end() @test
{
    if (catch err = bencode::decode("i42"))
    {
        // Expected to fail
    }
    else
    {
        assert(false, "Expected decode to fail for incomplete integer");
    }
}
