# libtorrent-c3

A BitTorrent library implementation written in C3, providing torrent file parsing, bencode encoding/decoding, and secure path handling.

## Features

- **Bencode Support**: Full bencode encoding and decoding with ergonomic macros
  - `@blist()` and `@bdict()` macros for concise inline creation
  - Dictionary iteration with `dict.entries()`
  - Automatic memory management with temp allocator
- **Torrent Parsing**: Complete .torrent file parser supporting BEP 3
  - Single-file and multi-file torrents
  - Announce lists with multi-tracker support
  - Web seed URLs (BEP 19)
  - DHT nodes and extended metadata
- **Path Sanitization**: Security-focused path handling
  - Path traversal prevention (removes `../`)
  - Invalid UTF-8 repair
  - Unicode directional override removal
  - Null byte filtering
  - Path length limits (240 chars)
- **Memory Safe**: Leverages C3's temp allocator and `defer` for automatic cleanup
- **Well Tested**: 129 passing tests with full coverage

## Targets

This project has two build targets:

1. **libtorrent** - Dynamic library (`libtorrent.so`)
   - Core torrent parsing and bencode functionality
   - Built with PIC (Position Independent Code)
   - Exports public API for use in applications

2. **torrent-client** - Executable application
   - Command-line torrent client
   - Links to the libtorrent dynamic library

## Building

### Prerequisites

- [C3 compiler](https://c3-lang.org/) version 0.7.6 or later

### Build all targets

```bash
c3c build
```

This will generate:
- `libtorrent.so` - The dynamic library
- `torrent-client` - The executable

### Build specific target

```bash
c3c build libtorrent       # Build only the library
c3c build torrent-client   # Build only the executable
```

### Clean build artifacts

```bash
c3c clean
```

## Running

To run the executable with the dynamic library:

```bash
LD_LIBRARY_PATH=. ./torrent-client
```

Or install `libtorrent.so` to a system library path.

## Testing

### Run all tests

```bash
c3c test
```

### Run tests for specific target

```bash
c3c test libtorrent       # Run library tests (129 tests)
c3c test torrent-client   # Run executable tests
```

### Run specific tests (filter by name)

```bash
c3c test --test-filter "bencode"
c3c test --test-filter "test_parse_multifile"
```

### Additional test options

- `--test-quiet` - Only show output on failure
- `--test-nocapture` - Allow tests to print during execution
- `--test-breakpoint` - Trigger breakpoint on failure (for debugging)

## Usage Examples

### Parsing a Torrent File

```c3
import libtorrent;

fn void parse_example()
{
    String data = file::load_buffer("example.torrent")!!;
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    io::printfn("Name: %s", torrent.info.name);
    io::printfn("Size: %d bytes", torrent.info.length);
}
```

### Using Bencode Macros

```c3
import libtorrent::bencode;

fn void bencode_example()
{
    // Create a bencode dictionary using macros
    BencodeValue* info = bencode::@bdict(
        "name", bencode::make_string("example"),
        "size", bencode::make_integer(1024),
        "files", bencode::@blist(
            bencode::make_string("file1.txt"),
            bencode::make_string("file2.txt")
        )
    );
    defer bencode::free_bencode_value(info);

    // Iterate over dictionary entries
    foreach (entry : info.dict_entries())
    {
        io::printfn("%s: ...", entry.key);
    }

    // Encode to bencode format
    String encoded = bencode::encode(info);
    defer free(encoded);
}
```

### Path Sanitization

```c3
import libtorrent::path_sanitize;

fn void sanitize_example()
{
    // Sanitize a potentially malicious path
    String? safe_path = path_sanitize::sanitize_torrent_path("../../../etc/passwd");

    if (safe_path)
    {
        io::printfn("Sanitized: %s", safe_path);  // Output: "etc/passwd"
    }
}
```

## Development

### Project Configuration

The project is configured via `project.json`, which defines:
- Build targets and their types (dynamic library vs executable)
- Source and test file locations
- Compiler and linker settings (PIC for shared library)

### Writing Tests

Tests are written using the `@test` attribute:

```c3
fn void test_parse_valid_torrent() @test
{
    String data = create_test_torrent();
    defer free(data);

    TorrentFile* torrent = torrent::parse(data)!!;
    defer torrent::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected valid torrent name");
}
```

### Memory Management

This project leverages C3's memory management features:
- **Temp allocator** (`@pool()`): Automatic cleanup for short-lived allocations
- **`defer`**: Ensures cleanup happens even on early returns
- **Explicit `free()`**: For long-lived heap allocations
