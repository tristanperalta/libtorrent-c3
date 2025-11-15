module test_bencode_debug;

import std::io;
import libtorrent::bencode;

fn void main()
{
    // Test 1: 32-byte binary string
    char[32] merkle_root;
    for (uint i = 0; i < 32; i++) {
        merkle_root[i] = (char)i;
    }

    BencodeValue* val = bencode::make_string((String)merkle_root[..]);
    defer val.free();

    String encoded = val.encode();
    defer free(encoded);

    io::printfn("Encoded length: %d", encoded.len);
    io::printfn("First 10 chars: '%s'", encoded[0..10]);
    io::printfn("Expected: '32:'");

    // Test 2: Simple string
    BencodeValue* val2 = bencode::make_string("test");
    defer val2.free();

    String encoded2 = val2.encode();
    defer free(encoded2);

    io::printfn("\nSimple string encoded: '%s'", encoded2);
    io::printfn("Expected: '4:test'");
}
