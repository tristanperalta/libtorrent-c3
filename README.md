# libtorrent-c3

A BitTorrent client and library written in C3. Downloads torrents, exchanges peers automatically, and validates paths to prevent security attacks. Supports symlinks, file attributes, and peer exchange (PEX). 492+ tests ensure reliability.

## Features

- **Parse .torrent files** including symlinks and file attributes (BEP 47)
- **Exchange peers automatically** without trackers using PEX (BEP 11)
- **Download with GUI or CLI** - optional raylib interface with real-time progress
- **Validates paths** to prevent directory traversal and symlink escapes
- **Extension protocol** (BEP 10) for capability negotiation
- **Async I/O** with libuv via c3io library
- **Web seeds** for HTTP/FTP fallback (BEP 19)
- **Async logging** that doesn't block downloads
- **Memory safe** using C3's temp allocator and `defer`

## Quick Start

```bash
# Download a torrent
./torrent-client example.torrent

# With GUI
./torrent-client --gui example.torrent

# With logging
./torrent-client --log-file download.log --debug example.torrent
```

## Targets

1. **libtorrent** - Dynamic library (`libtorrent.so`)
   - Core torrent parsing and protocol implementation
   - Built with PIC (Position Independent Code)
   - Exports public API for applications

2. **torrent-client** - Executable application
   - Command-line and GUI torrent client
   - Links to the libtorrent dynamic library

## Building

### Prerequisites

- [C3 compiler](https://c3-lang.org/) version 0.7.6 or later
- **libuv** - Cross-platform async I/O library
  - Arch Linux: `sudo pacman -S libuv`
  - Ubuntu/Debian: `sudo apt install libuv1-dev`
  - macOS: `brew install libuv`
- **libcurl** - HTTP/HTTPS client library
  - Arch Linux: `sudo pacman -S curl`
  - Ubuntu/Debian: `sudo apt install libcurl4-openssl-dev`
  - macOS: `brew install curl`
- **Optional: raylib55, raygui** - For GUI mode
  - Arch Linux: `sudo pacman -S raylib`

### Build all targets

```bash
c3c build
```

This generates:
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

Run the executable:

```bash
LD_LIBRARY_PATH=. ./torrent-client
```

Or install `libtorrent.so` to a system library path.

## Security

### Path Validation
Blocks torrents trying to write outside the download folder:
- Rejects paths with `..` or `.` components
- Rejects absolute paths (`/etc/passwd`)
- Validates symlinks can't escape torrent directory
- Removes null bytes and Unicode directional overrides

### Peer Exchange Security
- Filters private IP addresses (10.x, 192.168.x, 127.x)
- Validates port numbers (rejects port 0)
- Rate limits to 1 PEX message per minute per peer
- Maximum 50 peers per message

## Testing

### Run all tests

```bash
c3c test
```

### Run tests for specific target

```bash
c3c test libtorrent
c3c test torrent-client
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
import libtorrent::metainfo;
import std::io::file;

fn void parse_example()
{
    String data = file::load_buffer("example.torrent")!!;
    defer free(data);

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

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

### Peer Wire Protocol

```c3
import libtorrent::peer_connection;
import libtorrent::peer_wire;
import async::event_loop;  // From c3io library

fn void on_message(peer_connection::PeerConnection* peer, peer_wire::Message* msg, void* user_data)
{
    switch (msg.type)
    {
        case peer_wire::MessageType.CHOKE:
            io::printfn("Peer choked us");
        case peer_wire::MessageType.UNCHOKE:
            io::printfn("Peer unchoked us");
            // Now we can request pieces
            peer.send_request(piece_index: 0, begin: 0, length: 16384)!;
        case peer_wire::MessageType.HAVE:
            uint? piece_opt = peer_wire::decode_have(msg.payload);
            if (piece_opt)
            {
                io::printfn("Peer has piece %d", piece_opt!!);
            }
        case peer_wire::MessageType.PIECE:
            peer_wire::PieceMsg? piece = peer_wire::decode_piece(msg.payload);
            if (piece)
            {
                io::printfn("Received block from piece %d", piece!!.index);
                // Save the block data
                defer free(piece!!.block);
            }
        default:
            // Handle other message types
    }
}

fn void on_state_change(peer_connection::PeerConnection* peer, peer_connection::PeerState state, void* user_data)
{
    switch (state)
    {
        case peer_connection::PeerState.CONNECTING:
            io::printfn("Connecting to peer...");
        case peer_connection::PeerState.HANDSHAKING:
            io::printfn("Performing handshake...");
        case peer_connection::PeerState.READY:
            io::printfn("Connection ready!");
            // Send interested message
            peer.send_interested()!;
        case peer_connection::PeerState.CLOSED:
            io::printfn("Connection closed");
    }
}

fn void peer_example()
{
    // Create event loop
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // Prepare info hash and peer ID
    InfoHash info_hash;
    PeerId peer_id;
    // ... fill with actual values

    // Connect to peer
    peer_connection::PeerConnection* peer = peer_connection::connect(
        &loop,
        "192.168.1.100",  // Peer IP
        6881,              // Peer port
        info_hash,
        peer_id,
        &on_message,
        &on_state_change,
        null              // user_data
    )!!;
    defer peer_connection::close(peer);

    // Run event loop to handle connection
    loop.run()!;
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

    TorrentFile* torrent = metainfo::parse(data)!!;
    defer metainfo::free_torrent_file(torrent);

    assert(torrent.info.name.len > 0, "Expected valid torrent name");
}
```
