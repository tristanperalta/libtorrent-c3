module libtorrent::bencode;

import std::io;
import std::core::mem;
import std::core::dstring;
import std::collections::list;
import libtorrent::logger;

/**
 * Bencode Format Specification
 * =============================
 * Bencode is the encoding used by BitTorrent for storing and transmitting data.
 *
 * Data Types:
 *
 * 1. Integers: i<number>e
 *    - Example: i42e = 42, i-3e = -3, i0e = 0
 *    - No leading zeros except for zero itself
 *
 * 2. Byte Strings: <length>:<content>
 *    - Example: 4:spam = "spam", 0: = empty string
 *    - Length is in decimal, content is raw bytes
 *
 * 3. Lists: l<elements>e
 *    - Example: l4:spami42ee = ["spam", 42]
 *    - Elements are bencoded values, no delimiters
 *
 * 4. Dictionaries: d<key><value>...e
 *    - Example: d3:cow3:moo4:spam4:eggse = {"cow": "moo", "spam": "eggs"}
 *    - Keys must be byte strings, sorted lexicographically
 *    - Values can be any bencoded type
 */

/**
 * Maximum nesting depth for bencode structures.
 * Prevents stack overflow from maliciously crafted deeply nested data.
 */
const int MAX_BENCODE_DEPTH = 100;

/**
 * Type aliases for the collections used in bencode structures.
 */
alias BencodeValueList = List{BencodeValue*};
alias ByteStringList = List{char[]};

/**
 * BencodeValue represents any bencode data type.
 * This is a tagged union that can hold integers, strings, lists, or dictionaries.
 */
enum BencodeType : char
{
    INTEGER,
    STRING,
    LIST,
    DICT
}

/**
 * BencodeDict represents a bencode dictionary.
 * Keys are byte strings and must be sorted lexicographically.
 * Values can be any bencode type.
 */
struct BencodeDict
{
    ByteStringList keys;      // List of string keys (sorted)
    BencodeValueList values;  // Corresponding values
}

/**
 * BencodeDictEntry represents a single key-value pair from a dictionary.
 * Used for iterating over bencode dictionaries.
 *
 * Usage:
 *   foreach (entry : dict.dict_entries())
 *   {
 *       io::printfn("%s: %s", entry.key, entry.value);
 *   }
 */
struct BencodeDictEntry
{
    String key;
    BencodeValue* value;
}

/**
 * BencodeValue is a tagged union representing any bencode value.
 *
 * SAFETY: Always check the 'type' field before accessing union members!
 *
 * NOTE: Bencode "strings" use char[] instead of String because they are
 * raw byte buffers that may contain non-UTF-8 data (e.g., SHA1 hashes in
 * .torrent files). See BEP 3 for details.
 *
 * Usage:
 *   BencodeValue* val = make_integer(42);
 *   if (val.type == BencodeType.INTEGER) {
 *       io::printfn("Integer: %d", val.integer);
 *   }
 */
struct BencodeValue
{
    BencodeType type;
    union {
        long integer;           // For INTEGER: the integer value
        char[] string;          // For STRING: raw byte data (not necessarily UTF-8!)
        BencodeValueList list;  // For LIST: list of BencodeValue pointers
        BencodeDict dict;       // For DICT: dictionary structure
    }
}

/**
 * Faults for bencode operations that can fail
 */
faultdef BENCODE_INVALID_FORMAT;
faultdef BENCODE_UNEXPECTED_END;
faultdef BENCODE_INVALID_INTEGER;
faultdef BENCODE_INVALID_STRING_LENGTH;
faultdef BENCODE_INVALID_DICT_KEY;

/**
 * Write an integer to a DString buffer in decimal format.
 */
fn void write_integer(DString* buf, long value)
{
    buf.appendf("%d", value);
}

/**
 * Recursively encode a BencodeValue into a DString buffer.
 */
fn void encode_recursive(DString* buf, BencodeValue* value)
{
    switch (value.type)
    {
        case INTEGER:
            buf.append('i');
            write_integer(buf, value.integer);
            buf.append('e');
        case STRING:
            write_integer(buf, (long)value.string.len);
            buf.append(':');
            buf.append(value.string);
        case LIST:
            buf.append('l');
            foreach (item : value.list.array_view())
            {
                encode_recursive(buf, item);
            }
            buf.append('e');
        case DICT:
            buf.append('d');
            foreach (entry : value.dict.entries())
            {
                // Encode key (as a string)
                write_integer(buf, (long)entry.key.len);
                buf.append(':');
                buf.append(entry.key);
                // Encode value (recursive)
                encode_recursive(buf, entry.value);
            }
            buf.append('e');
    }
}

/**
 * Encode a BencodeValue into its byte representation.
 *
 * @param value The value to encode
 * @return The bencoded byte string (caller must free)
 *
 * Example:
 *   BencodeValue* val = make_integer(42);
 *   defer free_bencode_value(val);
 *   String encoded = encode(val);
 *   defer free(encoded);
 */
fn String encode(BencodeValue* value) @public
{
    DString buf;
    encode_recursive(&buf, value);
    // Copy to mem allocator so it persists (C3 0.7.4+: use 'mem' not 'allocator::heap()')
    return buf.copy_str(mem);
}

/**
 * Parser state for decoding bencode data.
 */
struct DecodeState
{
    io::ByteReader reader;  // Input stream
    int depth;               // Current nesting depth
}

/**
 * Peek at the current character without advancing.
 * Returns fault if at end of input.
 */
fn char? peek(DecodeState* state)
{
    if (state.reader.index >= state.reader.bytes.len)
    {
        return BENCODE_UNEXPECTED_END?;
    }
    return state.reader.bytes[state.reader.index];
}

/**
 * Consume and return the current character.
 * Returns fault if at end of input.
 */
fn char? consume(DecodeState* state)
{
    return state.reader.read_byte();
}

/**
 * Read characters until delimiter is found and return as a byte array.
 * The delimiter is consumed but not included in the result.
 * Returns fault if delimiter not found.
 * Note: Uses temp allocator for temporary buffer.
 */
fn String? read_until(DecodeState* state, char delimiter)
{
    DString buf;  // Uses temp allocator by default

    while (true)
    {
        char c = peek(state)!;  // Fault propagates if at end
        if (c == delimiter)
        {
            consume(state)!;  // consume delimiter
            break;
        }
        consume(state)!;
        buf.append_char(c);
    }

    // Copy to persistent memory
    return buf.copy_str(mem);
}

/**
 * Read exactly 'length' bytes from the input and return as a byte array.
 * Returns fault if not enough bytes available.
 * Note: Allocates with mem allocator.
 */
fn String? read_bytes(DecodeState* state, usz length)
{
    char[] result = mem::new_array(char, length);

    for (usz i = 0; i < length; i++)
    {
        char? byte_result = consume(state);
        if (catch err = byte_result)
        {
            // Fault occurred - clean up and propagate
            free(result);
            return err?;
        }
        result[i] = byte_result;  // Safe to use after check
    }

    return (String)result;
}

/**
 * Check if a character is a digit.
 */
fn bool is_digit(char c)
{
    return c >= '0' && c <= '9';
}

/**
 * Recursively decode a bencode value.
 */
fn BencodeValue*? decode_value(DecodeState* state)
{
    char c = peek(state)!;  // Fault propagates if at end

    // Decode integer: i<number>e
    if (c == 'i')
    {
        consume(state)!; // consume 'i'

        // Read until 'e'
        String num_str = read_until(state, 'e')!;
        defer mem::free(num_str);

        // Validate: no leading zeros except for "0" itself
        if (num_str.len > 1 && num_str[0] == '0')
        {
            return BENCODE_INVALID_INTEGER?;
        }

        // Validate: "-0" is not allowed
        if (num_str.len > 1 && num_str[0] == '-' && num_str[1] == '0')
        {
            return BENCODE_INVALID_INTEGER?;
        }

        // Parse the integer - create properly formatted string
        DString buf;  // Uses temp allocator
        buf.append(num_str);
        long value = buf.str_view().to_long()!;

        return make_integer(value);
    }

    // Decode string: <length>:<content>
    if (is_digit(c))
    {
        // Read length until ':'
        String len_str = read_until(state, ':')!;
        defer mem::free(len_str);

        // Parse the length - create properly formatted string
        DString len_buf;  // Uses temp allocator
        len_buf.append(len_str);
        long len_val = len_buf.str_view().to_long()!;

        if (len_val < 0)
        {
            return BENCODE_INVALID_STRING_LENGTH?;
        }

        usz length = (usz)len_val;

        // Read the string content
        String content = read_bytes(state, length)!;
        defer mem::free(content);

        return make_string(content);
    }

    // Decode list: l<elements>e
    if (c == 'l')
    {
        consume(state)!; // consume 'l'

        // Check depth
        state.depth++;
        if (state.depth > MAX_BENCODE_DEPTH)
        {
            return BENCODE_INVALID_FORMAT?;
        }

        BencodeValue* list = make_list();

        while (true)
        {
            char next = peek(state)!;
            if (next == 'e') break;

            BencodeValue* item = decode_value(state)!;
            list_append(list, item);
        }

        consume(state)!; // consume 'e'
        state.depth--;

        return list;
    }

    // Decode dictionary: d<key><value>...e
    if (c == 'd')
    {
        consume(state)!; // consume 'd'

        // Check depth
        state.depth++;
        if (state.depth > MAX_BENCODE_DEPTH)
        {
            return BENCODE_INVALID_FORMAT?;
        }

        BencodeValue* dict = make_dict();

        while (true)
        {
            char next = peek(state)!;
            if (next == 'e') break;

            // Decode key (must be a string)
            BencodeValue* key_val = decode_value(state)!;

            if (key_val.type != BencodeType.STRING)
            {
                free_bencode_value(key_val);
                free_bencode_value(dict);
                return BENCODE_INVALID_DICT_KEY?;
            }

            // Convert key char[] to String
            String key = (String)key_val.string;

            // Decode value
            BencodeValue* value = decode_value(state)!;

            // Add to dictionary
            dict_set(dict, key, value);

            // Free the key BencodeValue (we copied the string)
            free_bencode_value(key_val);
        }

        consume(state)!; // consume 'e'
        state.depth--;

        return dict;
    }

    return BENCODE_INVALID_FORMAT?;
}

/**
 * Decode a bencoded byte string into a BencodeValue.
 *
 * @param data The bencoded data to decode
 * @return The decoded value or a fault if parsing fails
 *
 * Note: Uses temp allocator for intermediate buffers during parsing.
 * The returned BencodeValue is allocated with mem allocator and must be freed.
 */
fn BencodeValue*? decode(String data) @public => @pool()
{
    io::ByteReader reader;
    reader.init(data);
    DecodeState state = { reader, 0 };

    return decode_value(&state);
}

/**
 * Get a value from a dictionary by key.
 *
 * @param dict The dictionary BencodeValue
 * @param key The key to look up
 * @return The value if found, or null if not found
 */
fn BencodeValue* dict_get(BencodeValue* dict, String key) @public
{
    if (dict.type != BencodeType.DICT) return null;

    foreach (entry : dict.dict.entries())
    {
        if (entry.key == key)
        {
            return entry.value;
        }
    }

    return null;
}

/**
 * Get a required key from a bencode dictionary with type checking.
 * Returns the value if found and of the correct type, otherwise returns fault.
 *
 * @param $Type The expected BencodeType (e.g., STRING, INTEGER, LIST, DICT)
 * @param dict The dictionary to search
 * @param key The key to look up
 * @param fault_type The fault to return if key is missing or wrong type
 */
macro dict_get_required(btype, dict, key, fault_type)
{
    BencodeValue* val = dict_get(dict, key);
    if (!val || val.type != btype)
    {
        return fault_type?;
    }
    return val;
}

/**
 * Free a BencodeValue and all its nested data.
 * Use with defer for automatic cleanup.
 *
 * @param value The value to free (can be null)
 */
fn void free_bencode_value(BencodeValue* value) @public
{
    if (!value) return;

    switch (value.type)
    {
        case STRING:
            free(value.string);
        case LIST:
            foreach (item : value.list.array_view())
            {
                free_bencode_value(item);
            }
            value.list.free();
        case DICT:
            foreach (key : value.dict.keys.array_view())
            {
                free(key);
            }
            value.dict.keys.free();
            foreach (val : value.dict.values.array_view())
            {
                free_bencode_value(val);
            }
            value.dict.values.free();
        case INTEGER:
            // No nested allocation
    }
    free(value);
}

/**
 * Create a bencode integer value.
 * Caller is responsible for freeing with free_bencode_value().
 *
 * Usage:
 *   BencodeValue* val = make_integer(42);
 *   defer free_bencode_value(val);
 *
 * @param value The integer value
 * @return A BencodeValue representing the integer
 */
fn BencodeValue* make_integer(long value) @public
{
    BencodeValue* val = mem::new(BencodeValue);
    val.type = BencodeType.INTEGER;
    val.integer = value;
    return val;
}

/**
 * Create a bencode string value.
 * Caller is responsible for freeing with free_bencode_value().
 *
 * Usage:
 *   BencodeValue* val = make_string("hello");
 *   defer free_bencode_value(val);
 *
 * @param value The string value (will be copied)
 * @return A BencodeValue representing the string
 */
fn BencodeValue* make_string(String value) @public
{
    BencodeValue* val = mem::new(BencodeValue);
    val.type = BencodeType.STRING;
    // Copy the string data
    val.string = mem::new_array(char, value.len);
    foreach (i, c : value)
    {
        val.string[i] = c;
    }
    return val;
}

/**
 * Create a bencode list value.
 * Caller is responsible for freeing with free_bencode_value().
 *
 * Usage:
 *   BencodeValue* val = make_list();
 *   defer free_bencode_value(val);
 *
 * @return An empty BencodeValue list
 */
fn BencodeValue* make_list() @public
{
    BencodeValue* val = mem::new(BencodeValue);
    val.type = BencodeType.LIST;
    val.list.init(mem);
    return val;
}

/**
 * Create a bencode dictionary value.
 * Caller is responsible for freeing with free_bencode_value().
 *
 * Usage:
 *   BencodeValue* val = make_dict();
 *   defer free_bencode_value(val);
 *
 * @return An empty BencodeValue dictionary
 */
fn BencodeValue* make_dict() @public
{
    BencodeValue* val = mem::new(BencodeValue);
    val.type = BencodeType.DICT;
    val.dict.keys.init(mem);
    val.dict.values.init(mem);
    return val;
}

/**
 * Append a value to a bencode list.
 *
 * @param list The list to append to (must be a LIST type)
 * @param value The value to append
 */
fn void list_append(BencodeValue* list, BencodeValue* value) @public
{
    list.list.push(value);
}

/**
 * Compare two strings lexicographically (byte by byte).
 * Returns: -1 if a < b, 0 if a == b, 1 if a > b
 */
fn int compare_strings_lexicographic(String a, String b)
{
    usz min_len = a.len < b.len ? a.len : b.len;
    for (usz i = 0; i < min_len; i++)
    {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    // All bytes equal up to min_len, shorter string comes first
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

/**
 * Set a key-value pair in a bencode dictionary.
 * Keys must be added in lexicographically sorted order.
 * This function validates that keys are inserted in sorted order.
 *
 * @param dict The dictionary to add to (must be a DICT type)
 * @param key The key (will be copied)
 * @param value The value
 */
fn void dict_set(BencodeValue* dict, String key, BencodeValue* value) @public
{
    // Validate that key is lexicographically greater than last key
    if (dict.dict.keys.size > 0)
    {
        char[] last_key = dict.dict.keys.array_view()[dict.dict.keys.size - 1];
        int cmp = compare_strings_lexicographic((String)last_key, key);
        if (cmp >= 0)
        {
            // Keys not in sorted order - this violates BitTorrent spec
            logger::log(logger::LogLevel.WARN, "Dictionary keys must be in lexicographically sorted order!");
            logger::logf(logger::LogLevel.WARN, "  Last key: %s", (String)last_key);
            logger::logf(logger::LogLevel.WARN, "  New key: %s", key);
        }
    }

    // Copy the key
    char[] key_copy = mem::new_array(char, key.len);
    foreach (i, c : key)
    {
        key_copy[i] = c;
    }

    // Add key and value to lists
    dict.dict.keys.push(key_copy);
    dict.dict.values.push(value);
}

/**
 * Recursively convert a BencodeValue to a human-readable string.
 */
fn void to_string_recursive(DString* buf, BencodeValue* value, int indent_level)
{
    // Create indent string manually
    for (int i = 0; i < indent_level; i++)
    {
        buf.append("  ");
    }

    switch (value.type)
    {
        case INTEGER:
            buf.appendf("%d", value.integer);
        case STRING:
            // Try to print as UTF-8 string if valid, otherwise show hex
            if (value.string.len < 64)
            {
                buf.appendf("\"%s\"", (String)value.string);
            }
            else
            {
                buf.appendf("<bytes[%d]>", value.string.len);
            }
        case LIST:
            buf.append("[\n");
            foreach (i, item : value.list.array_view())
            {
                for (int j = 0; j < indent_level + 1; j++) buf.append("  ");
                to_string_recursive(buf, item, 0);
                if (i < value.list.size - 1)
                {
                    buf.append(",");
                }
                buf.append("\n");
            }
            for (int i = 0; i < indent_level; i++) buf.append("  ");
            buf.append("]");
        case DICT:
            buf.append("{\n");
            foreach (i, entry : value.dict.entries())
            {
                for (int j = 0; j < indent_level + 1; j++) buf.append("  ");
                buf.appendf("\"%s\": ", entry.key);
                to_string_recursive(buf, entry.value, 0);
                if (i < value.dict.keys.size - 1)
                {
                    buf.append(",");
                }
                buf.append("\n");
            }
            for (int i = 0; i < indent_level; i++) buf.append("  ");
            buf.append("}");
    }
}

/**
 * Convert a BencodeValue to a human-readable string for debugging.
 *
 * @param value The value to print
 * @return A formatted string representation (caller must free)
 */
fn String to_string(BencodeValue* value) @public
{
    DString buf;
    to_string_recursive(&buf, value, 0);
    return buf.copy_str(mem);
}

/**
 * Get an array of key-value pairs for iterating over a dictionary.
 *
 * This method creates an array of BencodeDictEntry structs containing
 * all key-value pairs from the dictionary, enabling easy iteration.
 *
 * Usage:
 *   foreach (entry : dict.entries())
 *   {
 *       io::printfn("Key: %s", entry.key);
 *   }
 *
 * @param self The BencodeDict to iterate over
 * @return Array of BencodeDictEntry structs (uses temp allocator)
 */
fn BencodeDictEntry[] BencodeDict.entries(&self) @public
{
    BencodeDictEntry[] result = mem::temp_array(BencodeDictEntry, self.keys.size);
    foreach (i, key : self.keys.array_view())
    {
        result[i] = { .key = (String)key, .value = self.values.array_view()[i] };
    }
    return result;
}

/**
 * Convenience method to get dict entries from a BencodeValue.
 *
 * This is a convenience wrapper that asserts the value is a dictionary
 * and returns its entries for iteration.
 *
 * Usage:
 *   BencodeValue* root = decode(data)!!;
 *   foreach (entry : root.dict_entries())
 *   {
 *       io::printfn("%s: %s", entry.key, entry.value);
 *   }
 *
 * @param self The BencodeValue (must be type DICT)
 * @return Array of BencodeDictEntry structs (caller must free)
 */
fn BencodeDictEntry[] BencodeValue.dict_entries(&self) @public @inline
{
    assert(self.type == BencodeType.DICT, "Value must be a DICT");
    return self.dict.entries();
}

/**
 * Macro: Create a bencode list from variable arguments.
 *
 * This macro provides a concise way to create bencode lists inline.
 *
 * Usage:
 *   BencodeValue* list = @blist(item1, item2, item3);
 *   // Equivalent to:
 *   BencodeValue* list = make_list();
 *   list_append(list, item1);
 *   list_append(list, item2);
 *   list_append(list, item3);
 *
 * @param ... Variable number of BencodeValue* items to add to the list
 * @return A BencodeValue* containing the list
 */
macro BencodeValue* @blist(...)
{
    BencodeValue* list = make_list();
    $for var $i = 0; $i < $vacount; $i++:
        list_append(list, $vaarg[$i]);
    $endfor
    return list;
}

/**
 * Macro: Create a bencode dictionary from key-value pairs.
 *
 * This macro provides a concise way to create bencode dictionaries inline.
 * Arguments must be provided in key-value pairs (even number of arguments).
 *
 * Usage:
 *   BencodeValue* dict = @bdict(
 *       "name", make_string("example"),
 *       "size", make_integer(1024)
 *   );
 *   // Equivalent to:
 *   BencodeValue* dict = make_dict();
 *   dict_set(dict, "name", make_string("example"));
 *   dict_set(dict, "size", make_integer(1024));
 *
 * @param ... Variable number of arguments as key-value pairs (must be even)
 * @return A BencodeValue* containing the dictionary
 */
macro BencodeValue* @bdict(...)
{
    $assert $vacount % 2 == 0;
    BencodeValue* dict = make_dict();
    $for var $i = 0; $i < $vacount; $i += 2:
        dict_set(dict, $vaarg[$i], $vaarg[$i + 1]);
    $endfor
    return dict;
}

/**
 * Macro: Auto-wrap a value based on its type.
 *
 * This helper macro automatically wraps primitive values in their
 * corresponding bencode types based on compile-time type introspection.
 *
 * Supported types:
 * - String → make_string()
 * - int, long, ichar, isz → make_integer()
 * - BencodeValue* → pass through (already wrapped)
 *
 * @param value The value to wrap
 * @return A BencodeValue* containing the wrapped value
 */
macro BencodeValue* @wrap_value(value)
{
    var $type_name = $typeof(value).nameof;
    $switch $type_name:
        $case "String":
            return make_string(value);
        $case "int":
        $case "long":
        $case "ichar":
        $case "isz":
            return make_integer((long)value);
        $case "BencodeValue*":
            return value;
        $default:
            $error "Unsupported type for bencode auto-wrap: use make_string(), make_integer(), or pass BencodeValue*";
    $endswitch
}

/**
 * Macro: Create a bencode list with automatic type wrapping.
 *
 * This macro automatically wraps primitive values (String, int, long)
 * in their corresponding bencode types, eliminating manual make_string()
 * and make_integer() calls.
 *
 * Usage:
 *   BencodeValue* list = @blist_wrap("hello", 42, "world");
 *   // Equivalent to:
 *   BencodeValue* list = @blist(
 *       make_string("hello"),
 *       make_integer(42),
 *       make_string("world")
 *   );
 *
 * @param ... Variable number of values to add to the list
 * @return A BencodeValue* containing the list
 */
macro BencodeValue* @blist_wrap(...)
{
    BencodeValue* list = make_list();
    $for var $i = 0; $i < $vacount; $i++:
        list_append(list, @wrap_value($vaarg[$i]));
    $endfor
    return list;
}

/**
 * Macro: Create a bencode dictionary with automatic value wrapping.
 *
 * This macro automatically wraps primitive values in their corresponding
 * bencode types. Keys must still be String type.
 *
 * Usage:
 *   BencodeValue* dict = @bdict_wrap(
 *       "name", "example",
 *       "size", 1024
 *   );
 *   // Equivalent to:
 *   BencodeValue* dict = @bdict(
 *       "name", make_string("example"),
 *       "size", make_integer(1024)
 *   );
 *
 * @param ... Variable number of key-value pairs (must be even)
 * @return A BencodeValue* containing the dictionary
 */
macro BencodeValue* @bdict_wrap(...)
{
    $assert $vacount % 2 == 0;
    BencodeValue* dict = make_dict();
    $for var $i = 0; $i < $vacount; $i += 2:
        dict_set(dict, $vaarg[$i], @wrap_value($vaarg[$i + 1]));
    $endfor
    return dict;
}
