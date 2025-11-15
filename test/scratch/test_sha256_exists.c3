module test_sha256;

import std::hash::sha256;
import std::io;

fn void main() {
    char[16] test_data = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    char[32] hash = sha256::hash(test_data[..]);

    io::printfn("SHA-256 module exists!");
    io::printfn("Hash length: %d bytes", hash.len);
}
