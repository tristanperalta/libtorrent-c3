# c3io - Async I/O Library for C3

An async I/O library for C3 providing ergonomic wrappers around libuv for non-blocking network and file operations.

## Overview

c3io is a standalone library that provides high-level async I/O primitives built on top of libuv. It includes C3 bindings for libuv and offers an event-driven programming model with support for TCP, UDP, timers, DNS resolution, file operations, and work queue management.

## Features

### High-Level Async Modules

- **Event Loop** (`async::event_loop`) - Core event loop management
- **TCP** (`async::tcp`) - Async TCP client and server operations
- **UDP** (`async::udp`) - Async UDP socket operations
- **Timer** (`async::timer`) - One-shot and periodic timers
- **DNS** (`async::dns`) - Async DNS resolution
- **File** (`async::file`) - Async file I/O operations
- **Work Queue** (`async::work`) - Thread pool for CPU-intensive tasks

### Low-Level Bindings

- **libuv Bindings** (`uv`) - Complete C3 bindings for libuv API

## Dependencies

- libuv - Cross-platform async I/O library

## Usage

Add c3io to your `dependency-search-paths` in `project.json`:

```json
{
  "dependency-search-paths": ["lib"]
}
```

Import the modules you need:

```c3
import async::event_loop;
import async::tcp;
import async::timer;

fn void main()
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // Use async operations...

    loop.run()!!;
}
```

## License

See parent project license.

## Authors

- Tristan Peralta <tristan@peralta.ph>
- Claude Code <noreply@anthropic.com>
