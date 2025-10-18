# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a BitTorrent implementation written in C3, a C-like systems programming language. The project uses a **multi-target build system** with two separate targets:

1. **libtorrent** (dynamic library) - Core BitTorrent functionality
2. **torrent-client** (executable) - Command-line client that links to the library

The key architectural decision is the separation between library and executable, where:
- The library (`src/lib/**`) contains the module `libtorrent` with reusable BitTorrent functionality
- The executable (`src/main.c3`) contains the module `torrent_client` and imports `libtorrent`
- Both targets are built independently but the executable depends on the library at runtime

## Build System

This project uses C3's native build system configured via `project.json`:

**Build all targets:**
```bash
c3c build
```

**Build specific target:**
```bash
c3c build libtorrent       # Build only the dynamic library
c3c build torrent-client   # Build only the executable
```

**Clean build artifacts:**
```bash
c3c clean
```

**Run the executable:**
```bash
LD_LIBRARY_PATH=. ./torrent-client
```
Note: The `LD_LIBRARY_PATH=.` is required because the dynamic library is not in a system path.

## Testing

Tests are located in `test/` directory with the same structure as `src/`:
- `test/lib/` - Library unit tests
- `test/` - Executable/integration tests

**Run all tests:**
```bash
c3c test
```

**Run tests for specific target:**
```bash
c3c test libtorrent
c3c test torrent-client
```

**Run specific test by name:**
```bash
c3c test --test-filter "test_name"
```

**Additional test flags:**
- `--test-quiet` - Only show failures
- `--test-nocapture` - Show test stdout in real-time
- `--test-breakpoint` - Trigger debugger on test failure

## C3-Specific Patterns

### Public Functions in Libraries
Functions in the library that need to be exported must use the `@public` attribute:
```c3
fn void my_function() @public
{
  // Implementation
}
```

### Module Organization
- Library code uses `module libtorrent;`
- Executable code uses `module torrent_client;`
- The executable imports the library with `import libtorrent;`

### Test Functions
Tests use the `@test` attribute and `assert()` for validation:
```c3
fn void test_something() @test
{
  assert(condition, "Error message");
}
```

## Multi-Target Configuration Notes

The `project.json` configuration has important target-specific settings:

- **libtorrent target**: Uses `"reloc": "pic"` (Position Independent Code) which is **required** for dynamic libraries on Linux. The global `"reloc": "none"` is overridden for this target.
- **torrent-client target**: Uses the global relocation model (none) which is appropriate for executables.
- Both targets have their own `sources` arrays that override the global `"sources": ["src/**"]` for precise control over what goes into each build.

The test sources (`test/**`) are globally configured and automatically associated with their respective targets based on module namespaces.
