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

## General Guidelines

### Test Count References

**IMPORTANT: Never include test count references** in the following places:
- **Git commit messages** - Don't add phrases like "(there are 700+ passing tests)" or "All 705 tests pass"
- **Code comments** - Don't add test count comments in source code
- **README.md** - Don't include test count statistics in the description or features list

Test counts change frequently as the codebase evolves and become stale/inaccurate quickly. The test suite itself is the source of truth for test counts.

**Acceptable places for test counts:**
- Test output/logs during CI/CD runs
- Temporary debugging or development notes (not committed)
- Documentation specifically about testing methodology (if kept up to date)

## Architecture Principle: Non-Blocking Async I/O

**This is a non-blocking torrent client.** All I/O operations must be asynchronous to prevent blocking the event loop.

### Critical Requirements

1. **Never block the event loop** - All I/O (network, disk, DNS) must use async APIs from c3io library
2. **Use async APIs**:
   - Network: `async::tcp`, `async::udp` (not blocking sockets)
   - DNS: `async::dns` (not blocking `getaddrinfo`)
   - Disk I/O: `async::file` (not blocking `fread`/`fwrite`)
   - Timers: `async::timer` (not `sleep()`)
3. **Logging**: Use the async logger (`logger.c3`) which queues messages to prevent I/O blocking
4. **Event-driven**: All operations driven by event loop callbacks, not polling loops

### Why This Matters

A single blocking call (e.g., `fwrite()`, `getaddrinfo()`, `sleep()`) freezes the entire client:
- No peer communication while blocked
- Tracker announces delayed
- GUI becomes unresponsive
- Downloads stall across all torrents

### Examples

❌ **Wrong** - Blocks event loop:
```c3
// Blocking disk write - freezes client during I/O
file::write(path, data);

// Blocking DNS lookup - freezes client
String ip = dns_lookup_blocking(hostname);

// Blocking sleep - freezes client
thread::sleep(1000);
```

✅ **Correct** - Non-blocking async I/O:
```c3
// Async disk write - client continues during I/O
async::file::write(&loop, path, data, &on_write_complete);

// Async DNS lookup - client continues during lookup
async::dns::resolve(&loop, hostname, &on_dns_resolved);

// Async timer - client continues during delay
async::timer::create(&loop, 1000, &on_timer_fired);
```

### When Working on This Codebase

- Always ask: "Does this block the event loop?"
- Use c3io async APIs for all I/O
- If adding new I/O, ensure it's async
- Test that GUI remains responsive during operations

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

## Memory Debugging with Valgrind

Valgrind is a powerful memory debugging tool that detects memory leaks, use-after-free, and other memory errors.

**Install Valgrind (Arch Linux):**
```bash
sudo pacman -S valgrind
```

**Run tests with memory checking:**
```bash
# Basic leak check
valgrind ./testrun

# Full leak check with details
valgrind --leak-check=full ./testrun

# Detailed report with origins
valgrind --leak-check=full --show-leak-kinds=all --track-origins=yes ./testrun
```

**Expected output for clean code:**
```
==12345== HEAP SUMMARY:
==12345==     in use at exit: 0 bytes in 0 blocks
==12345==   total heap usage: 347 allocs, 347 frees, 308,678 bytes allocated
==12345==
==12345== All heap blocks were freed -- no leaks are possible
==12345==
==12345== ERROR SUMMARY: 0 errors from 0 contexts
```

**What Valgrind catches:**
- Memory leaks (allocated but not freed)
- Use-after-free (accessing freed memory)
- Invalid reads/writes (buffer overflows)
- Uninitialized memory usage
- Double frees

**Note:** Programs run 10-50x slower under Valgrind, so only use during development/testing.

## C3 Version: 0.7.6

**This project uses C3 0.7.6.** Claude's training data only covered C3 0.6.x, so there are significant breaking changes to be aware of:

### Critical Breaking Changes from 0.6.x to 0.7.x

**1. Fault System (0.7.0)**
```c3
// 0.6.x (OLD - no longer works):
fault MyError { FOO, BAR }
fn int! my_function() { ... }

// 0.7.x (NEW - current syntax):
fault my_error, another_error;
fn int? my_function() { ... }
```

**2. Type Aliases and Typedefs (0.7.0)**
```c3
// 0.6.x: def, distinct
// 0.7.x: alias, typedef
alias MyInt = int;
typedef MyDistinct = int;
```

**3. Generic Syntax (0.7.0)**
```c3
// 0.6.x: Foo(<int>)
// 0.7.x: Foo{int}
List{int} my_list;
```

**4. Allocators (0.7.4)**
```c3
// 0.6.x: allocator::heap(), allocator::temp()
// 0.7.x: Use 'mem' instead (allocator functions are deprecated)
String s = buf.copy_str(mem);  // Correct
```

**5. Enum Changes (0.7.0, 0.7.4)**
```c3
// Enums no longer cast to/from int automatically
// Use .ordinal and .from_ordinal, or cast explicitly (0.7.4+)
MyEnum val = (MyEnum)5;  // Explicit cast (0.7.4+)
int num = (int)val;      // Explicit cast (0.7.4+)
```

**6. Main/Test Functions (0.7.0)**
```c3
// 0.6.x: fn void! main()
// 0.7.x: fn void main() or fn int main()
fn void main() { ... }
fn void my_test() @test { ... }
```

**7. Compile-Time Operators (0.7.0, 0.7.2)**
```c3
// Deprecated: $or, $and, $concat
// Use instead: |||, &&&, +++
// Also: $foreach/$for/$switch now use ':' instead of '()'
$foreach item : items:
    // ...
```

**8. Stdlib Naming (0.7.0)**
```c3
// Many "new_*" functions renamed
// 0.6.x: string::new_from_*, mem::temp_new
// 0.7.x: string::from_*, mem::tnew
// anyfault -> fault
```

**9. Expression Blocks Removed (0.7.0)**
```c3
// 0.6.x: {| ... |} expression blocks
// 0.7.x: Removed, use regular blocks or other constructs
```

**10. Named Arguments (0.6.3)**
```c3
// 0.6.x: func(.arg = value)
// 0.7.x: func(arg: value)  (old style deprecated)
```

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

### Method-Based Syntax (Preferred Style)

**This codebase uses method-based syntax for struct operations.** C3 supports defining functions as methods on structs using the `&self` parameter.

**Declaring Methods:**
```c3
// Method declaration - use &self as first parameter
fn void MyStruct.my_method(&self, int arg)
{
    // Access fields with self.field
    self.field = arg;
}

// Free method - common pattern for cleanup
fn void MyStruct.free(&self)
{
    // Clean up resources
    if (self.data.len > 0) free(self.data);
    free(self);
}
```

**Calling Methods:**
```c3
MyStruct* instance = create_instance();

// Method-based syntax (preferred)
instance.my_method(42);
instance.free();

// Module-based syntax (avoid for struct methods)
// my_module::my_method(instance, 42);  // Don't do this
```

**Why Method-Based Syntax:**
- **More readable**: `torrent.get_num_pieces()` is clearer than `metainfo::get_num_pieces(torrent)`
- **Better IDE support**: Methods show up in autocomplete for the struct type
- **Cleaner call sites**: Reduces visual clutter, especially with multiple chained operations
- **Safer**: Method syntax guarantees non-null `&self`, no null checks needed

**Migration Pattern:**
```c3
// Old module-based function:
fn int get_count(MyStruct* obj) @public
{
    if (obj == null) return 0;  // Null check needed
    return obj.count;
}

// New method-based:
fn int MyStruct.get_count(&self) @public
{
    // No null check needed - &self is always valid
    return self.count;
}

// Call site improvement:
// Before: int count = my_module::get_count(&obj);
// After:  int count = obj.get_count();
```

**Guidelines:**
- Use methods for operations that logically belong to a struct
- Keep factory functions (constructors) as module functions: `create_foo()`, `parse()`, etc.
- Use methods for: accessors, mutators, operations, and cleanup (`free`)
- Internal helper functions that don't operate on a primary struct can remain module functions

### Error Handling with Faults (C3 0.7+)

**IMPORTANT:** This project uses C3 0.7.6. The fault syntax changed significantly from 0.6.x to 0.7.x.

**Declaring Faults:**
```c3
// IMPORTANT: Use 'faultdef' for proper pointer optional support (C3 0.7.6)
// Using 'fault' (lowercase) has a known bug with pointer optionals (Foo*?)
faultdef BENCODE_INVALID_FORMAT;
faultdef BENCODE_UNEXPECTED_END;
faultdef BENCODE_INVALID_INTEGER;

// Alternative (older style, may have issues with pointer optionals):
// fault bencode_invalid_format, bencode_unexpected_end;
```

**Optional Return Types:**
```c3
// Use `?` after the type for optional returns (NOT `!`)
fn BencodeValue*? decode(String data) @public
{
    // Return a fault with `?` suffix
    return bencode_invalid_format?;

    // Or return success value
    return value;
}
```

**Using the Rethrow Operator `!`:**
```c3
// The `!` operator unwraps or auto-returns the fault
int value = might_fail()!;
```

**Handling Optionals:**
```c3
// Check if optional is empty and get the fault
if (catch excuse = decode(data))
{
    io::printfn("Error: %s", excuse);
    return excuse?;  // Rethrow the fault
}

// Auto-unwrap after handling empty case
value = decode(data);  // No longer optional here
```

**Key Changes from C3 0.6.x:**
- 0.6.x used `fault MyError { FOO, BAR }` - **This no longer works in 0.7**
- 0.7.x uses `fault foo_error, bar_error;` (lowercase names)
- Optional type syntax: Use `Type?` not `Type!`
- The `!` is the rethrow operator, not part of type declarations

### Memory Management and Allocators (C3 0.7+)

**IMPORTANT ALLOCATOR CHANGES (0.7.4):**
- `allocator::heap()` and `allocator::temp()` are **deprecated**
- Use `mem` as the allocator instead

**The Temp Allocator and @pool():**

C3's temp allocator is a region-based allocator that automatically frees memory when leaving scope, preventing memory leaks without garbage collection overhead.

```c3
// Use @pool() to create a temp allocator scope
fn int example(int input) => @pool()
{
    // Allocate with temp allocator - auto-freed when function exits
    int* temp_variable = mem::tnew(int);
    *temp_variable = 56;
    return input + *temp_variable;
}  // temp_variable automatically freed here!

// Or use @pool() as a block
fn void process_data()
{
    @pool()
    {
        // All temp allocations here are freed when leaving this block
        String* temp = allocator::new(tmem, String);
        // ...
    }  // temp automatically freed
}
```

**Key benefits:**
- No manual `free()` needed for temp allocations
- Better performance than individual `malloc`/`free` calls
- Good memory locality (all allocations in one region)
- Automatic cleanup even on early returns or faults
- The compiler auto-adds `@pool()` to `main()` if temp allocations are detected

**Working with DString:**
```c3
// DString can be declared without initialization (uses temp allocator by default)
DString buf;
buf.append("Hello");
buf.appendf("%d", 42);

// To return a string that persists, copy to the mem allocator
String result = buf.copy_str(mem);  // Caller must free()
defer free(result);
```

**When to use temp vs persistent allocation:**
- **Temp allocator (`mem::tnew()`)**: For intermediate/temporary data that doesn't outlive the function
- **Persistent allocator (`mem::new()`)**: For data that needs to be returned or stored long-term

**Memory Allocation:**
```c3
// Heap allocation
BencodeValue* val = mem::new(BencodeValue);
defer free(val);  // Auto-cleanup when scope exits

char[] buffer = mem::new_array(char, 100);
defer free(buffer);  // Defers execute in reverse order (LIFO)

// Use val and buffer...
// They are automatically freed when function exits
```

**Important DString Notes:**
- DString without initialization uses temp allocator (auto-freed at scope exit)
- `str_view()` returns a view (no copy, valid only within current scope)
- `copy_str(mem)` creates a heap copy that persists (caller must free)
- **Format specifiers**: Use `%d` for integers (not `%lld`)

**The `defer` Statement:**
```c3
fn void example()
{
    File f = file::open("file.txt", "r")!;
    defer (void)f.close();  // Auto-close on any exit

    BencodeValue* val = mem::new(BencodeValue);
    defer free(val);  // Auto-free on any exit

    if (error) return;  // Defers execute here!

    // ... use f and val ...

}  // Defers execute here too (in reverse order: free, close)
```

- `defer` executes when leaving scope (return, break, continue, scope end)
- Multiple defers execute in **reverse order** (LIFO)
- Use `defer` instead of manual cleanup for better safety

### String Types in C3

**C3 has multiple string types for different use cases:**

1. **`String`** (typedef for `char[]`) - UTF-8 text, immutable slice
2. **`char[]`** - Raw byte array (slice), may contain non-UTF-8 data
3. **`ZString`** (typedef for `char*`) - C-style null-terminated string
4. **`DString`** - Dynamic string builder

**When to use `char[]` vs `String`:**
- Use `String` for UTF-8 text
- Use `char[]` for raw bytes that may not be valid UTF-8 (e.g., binary data, hashes)
- In this project, bencode strings use `char[]` because they can contain binary data

### Tagged Unions

C3 supports C-style unions with manual tagging:
```c3
enum ValueType { INTEGER, STRING }

struct Value {
    ValueType type;  // Tag
    union {
        long integer;
        char[] string;
    }
}

// Usage: Always check type before accessing union
if (value.type == ValueType.INTEGER) {
    io::printfn("%d", value.integer);
}
```

### HashMap Iteration with @each

**CRITICAL: `return` inside `@each` exits the entire enclosing function, not just the loop!**

```c3
// ❌ WRONG - Code after @each never executes!
Item* found = null;
pool.items.@each(; Key key, Item* item)
{
    if (item.connection == conn)
    {
        found = item;
        return; // ❌ Exits entire function!
    }
};
// This code never runs if item was found
if (found) found.state = State.READY;

// ✅ CORRECT - Remove the return
Item* found = null;
pool.items.@each(; Key key, Item* item)
{
    if (item.connection == conn)
    {
        found = item;
        // Note: Don't use 'return' - it exits the entire callback, not just @each!
    }
};
// This code now executes correctly
if (found) found.state = State.READY;
```

**Why:** The `@each` macro uses a lambda, and `return` in a lambda exits the enclosing function, not the lambda itself.

**Real bugs this caused:**
- `peer_pool.c3`: Peers stuck in CONNECTING state (state transitions never executed)
- `peer_pool.c3`: Messages not forwarded (callbacks never invoked)

**Guideline:** Never use `return` inside `@each` unless you intend to exit the entire function.

## Memory Management in Async Systems

This project uses async I/O with libuv, which requires special attention to memory management. Here are critical patterns learned from fixing memory leaks (documented in SHUTDOWN_LEAKS.md).

### 1. C3 Optional Pattern - Don't Call Twice!

```c3
// ❌ WRONG - Allocates TWICE, leaks first allocation!
if (catch err = foo()) {
    // Handle error
} else {
    result = foo()!!;  // ❌ Calls foo() again, leaks first allocation
}

// ✅ CORRECT - Allocate once, reuse result
Type? result = foo();
if (catch err = result) {
    // Handle error
} else {
    // Use result - already allocated, no leak
}
```

**Why**: `if (catch err = foo())` only captures the fault on failure. On success, the return value is **discarded** (not captured). Calling `foo()` again in the else branch creates a second allocation while the first one leaks.

### 2. Async Resource Cleanup is Two-Phase

```c3
// ❌ WRONG - Timer* leaks because callback never runs
timer.stop();
free(timer);  // Wrapper freed, but libuv handle still active

// ✅ CORRECT - Close registers cleanup callback
timer.close();           // Queues close, registers cleanup callback
loop.run_once();         // Drains event loop, callbacks execute
// timer.free() not needed - callback already freed it
```

**Pattern**: `.close()` ≠ `.free()`
- `.close()` is **async** - queues cleanup, registers callback
- `.free()` is **sync** - frees memory immediately
- For async resources: close → drain callbacks → callback frees

**Applies to**: Timers, TCP/UDP sockets, DNS resolvers, all libuv handles

### 3. Memory Ownership in Callback Chains

```
Caller:    allocate → invoke callback(data) → callback returns → free(data)
Callback:  ❌ Don't free data!  ✅ Just use it
```

**Example**: TrackerResponse.peers
```c3
// udp_tracker.c3 (caller - owns memory):
peers = parse_compact_peers(data);           // Allocate
callback(&response, 0, user_data);           // Invoke with data
// Callback returns
free(response.peers);                        // Caller frees

// session_tracker_coordinator.c3 (callback - doesn't own):
fn void on_peers_received(TrackerResponse* response, ...) {
    // Use response.peers
    peer_pool.add_peers(response.peers);
    // ❌ DON'T free(response.peers) - causes double-free!
}
```

**Why**: Freeing in the wrong layer causes double-free crashes!

### 4. Composite Structs Need .close() Before free()

```c3
struct PeerConnection {
    TcpConnection* tcp;
    List{int} allowed_fast_set;  // Internal resources
    List{int} peer_allowed_fast;
    // ... more Lists
}

// ❌ WRONG - Lists leak
free(connection);

// ✅ CORRECT - Free internals, then container
connection.close();    // Frees Lists, buffers, internal state
free(connection);      // Frees the struct itself
```

**Pattern**: `.close()` frees contained resources, `free()` frees the container.

**Warning**: `.close()` is often NOT idempotent - check `is_closed` flag before calling.

### 5. Shutdown vs Runtime Cleanup

```c3
if (peer.connection) {
    peer.connection.close();

    if (!pool.shutting_down) {
        free(peer.connection);  // ✅ Free immediately during runtime
    }
    // ❌ Don't free during shutdown - centralized cleanup handles it
}
```

**Why**:
- **Runtime**: Free immediately to prevent leaks on reconnections
- **Shutdown**: Keep pointers valid for centralized cleanup in `.free()` methods

Use a `shutting_down` flag to coordinate cleanup phases.

### 6. Layer Separation - Who Frees What?

```
TCP Layer (libuv):     Frees TcpConnection* (wrapper struct)
                       ❌ Doesn't know about PeerConnection!

Application Layer:     PeerConnection.close() frees Lists/buffers
                       peer_pool.free() frees PeerConnection* structs
```

**Principle**: Lower layers don't clean up higher-level abstractions. Application code must free application structs.

### 7. Test Code Needs Same Discipline

Tests must explicitly close async resources before freeing:

```c3
// Test cleanup pattern:
defer {
    if (bus.dispatch_timer) bus.dispatch_timer.close();  // ✅ Close async resources
    bus.free();                                            // Free wrapper
    loop.run_once();                                       // Drain callbacks
}
```

Don't assume `.free()` handles cleanup - it often just nulls pointers.

### Common Pitfalls

1. **Code duplication**: Fix in one place (UDP tracker), forget identical code elsewhere (HTTP tracker)
2. **Early returns in @each**: Code after loop never executes if you use `return` inside
3. **Nulling pointers too early**: Loses reference needed for cleanup later
4. **Forgetting to close before close_all_handles()**: Generic callback won't clean up properly

See SHUTDOWN_LEAKS.md for detailed analysis of 12 bugs and lessons learned.

## Multi-Target Configuration Notes

The `project.json` configuration has important target-specific settings:

- **libtorrent target**: Uses `"reloc": "pic"` (Position Independent Code) which is **required** for dynamic libraries on Linux. The global `"reloc": "none"` is overridden for this target.
- **torrent-client target**: Uses the global relocation model (none) which is appropriate for executables.
- Both targets have their own `sources` arrays that override the global `"sources": ["src/**"]` for precise control over what goes into each build.

The test sources (`test/**`) are globally configured and automatically associated with their respective targets based on module namespaces.

## Useful New Features in C3 0.7.x

### Operator Overloading (0.7.1)
```c3
// Arithmetic: + - * / % & | ^ << >>
// Comparison: == !=
// Assignment: += -= *= /= %= &= |= ^= <<= >>=
fn MyType MyType.@operator(+)(MyType other) { ... }
fn bool MyType.@operator(==)(MyType other) { ... }
```

### Const Enums (0.7.4)
```c3
// Behaves like C enums but may be any type
enum Status : const { OK, ERROR, PENDING }
```

### defer (catch err) (0.7.0)
```c3
fn void example()
{
    File f = file::open("file.txt")!;
    defer (catch err) {
        io::printfn("Cleanup error: %s", err);
    }
    defer (void)f.close();
    // ...
}
```

### Compile-Time Format Validation (0.7.0)
```c3
fn void my_printf(String fmt, args...) @format
{
    // Format string is validated at compile time
}
```

### Array Macros (0.7.5)
```c3
// New array manipulation macros
int[] arr = { 1, 2, 3, 4, 5 };
int sum = arr.@sum();      // Sum all elements
int max = arr.@max();      // Find maximum
bool any = arr.@any(&is_even);  // Check if any match predicate
```

### Module Aliasing (0.7.5)
```c3
alias io = module std::io;
io::printfn("Hello!");
```

### Compile-Time Ternary (0.7.5)
```c3
// Use ??? for compile-time ternary (replaces deprecated @select)
$Type MyType = $IS_DEBUG ??? DebugImpl : ReleaseImpl;
```

### String Methods (0.7.2, 0.7.3)
```c3
String s = "hello world";
int count = s.count("l");           // Count occurrences
String replaced = s.replace(mem, "world", "C3");
String escaped = s.escape();         // Escape special chars
```

### Additional Useful Features
- **@tag and tagof** (0.6.2) - User-defined type and member tags
- **defer (catch err)** - Catch errors during defer cleanup
- **Operator overloading** - Full arithmetic and comparison operators
- **Named arguments** - `func(param: value)` syntax
- **Const enums** - C-like enums with any type
- **Virtual memory library** (0.7.4) - Low-level VM operations
- **Cryptographic functions** - AES, Ed25519, SHA256, SHA512, HMAC, PBKDF2
- **Better error messages** - Significantly improved throughout 0.7.x
