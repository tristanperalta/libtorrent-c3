# libtorrent-c3

A BitTorrent implementation written in C3.

## Project Structure

```
libtorrent-c3/
├── src/
│   ├── lib/           # Library implementation
│   │   └── torrent.c3
│   └── main.c3        # Executable entry point
├── test/
│   ├── lib/           # Library tests
│   │   └── test_torrent.c3
│   └── test_main.c3   # Executable tests
└── project.json       # Project configuration
```

## Targets

This project has two build targets:

1. **libtorrent** - Dynamic library (`libtorrent.so`)
   - Core torrent functionality
   - Built with PIC (Position Independent Code)

2. **torrent-client** - Executable application
   - Command-line torrent client
   - Links to the libtorrent dynamic library

## Building

### Prerequisites

- [C3 compiler](https://c3-lang.org/) (c3c)

### Build all targets

```bash
c3c build
```

This will generate:
- `libtorrent.so` - The dynamic library
- `torrent-client` - The executable

### Build specific target

```bash
c3c build libtorrent
c3c build torrent-client
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
c3c test libtorrent
c3c test torrent-client
```

### Run specific tests (filter by name)

```bash
c3c test --test-filter "greet"
```

### Additional test options

- `--test-quiet` - Only show output on failure
- `--test-nocapture` - Allow tests to print during execution
- `--test-breakpoint` - Trigger breakpoint on failure (for debugging)

## Development

### Project Configuration

The project is configured via `project.json`, which defines:
- Build targets and their types
- Source and test file locations
- Compiler and linker settings
- Dependencies

### Writing Tests

Tests are written using the `@test` attribute:

```c3
fn void my_test() @test
{
  int result = my_function();
  assert(result == expected, "Error message if assertion fails");
}
```

## License

Version 0.1.0
