# Session Refactoring Plan

## Overview

This document outlines the plan to refactor the current single-torrent `DownloadContext` into a more flexible architecture that supports both single-torrent and multi-torrent use cases with shared resources.

## Goals

1. **Better naming**: Align with libtorrent-rasterbar conventions (`Session` instead of `DownloadContext`)
2. **Resource efficiency**: Share expensive resources (DHT, event loop) across multiple torrents
3. **Flexibility**: Support both standalone sessions and managed multi-torrent scenarios
4. **Simplicity**: Unified resource model - always use SharedResources
5. **Library-ready**: Make the codebase easy to embed in GUI applications

## Architecture Design

### Current Architecture (Single-Torrent)

```
┌────────────────────────────────┐
│      DownloadContext           │
│  - TorrentFile                 │
│  - DownloadManager             │
│  - StorageManager              │
│  - PeerPool                    │
│  - TrackerCoordinator          │
│  - EventLoop (owns)            │
│  - DHTClient (owns)            │
│  - PeerDiscovery (owns)        │
└────────────────────────────────┘
```

**Issues:**
- Each torrent creates its own DHT node (wasteful)
- Each torrent has separate event loop thread
- Can't download multiple torrents efficiently
- Resources not shared

### Target Architecture (Unified Resource Model)

```
┌─────────────────────────────────────────────────────────┐
│              TorrentManager (Optional)                   │
│  - Manages multiple Session instances                    │
│  - Creates ONE SharedResources for all                   │
└─────────────────────────────────────────────────────────┘
                          │
        ┌─────────────────┼─────────────────┐
        ▼                 ▼                 ▼
  ┌──────────┐      ┌──────────┐      ┌──────────┐
  │ Session  │      │ Session  │      │ Session  │
  │    #1    │      │    #2    │      │    #3    │
  └──────────┘      └──────────┘      └──────────┘
        │                 │                 │
        └─────────────────┼─────────────────┘
                          ▼
              ┌───────────────────────┐
              │   SharedResources     │
              │  (ALWAYS PRESENT)     │
              ├───────────────────────┤
              │ • EventLoop           │
              │ • DHT Client          │
              │ • Peer Discovery      │
              │ • Port Mapping (UPnP) │
              │ • Bandwidth Manager   │
              └───────────────────────┘

Single-Torrent Mode:
  Session → SharedResources (1:1, Session owns it)

Multi-Torrent Mode:
  Session 1 ┐
  Session 2 ├→ SharedResources (N:1, TorrentManager owns it)
  Session 3 ┘
```

**Benefits:**
- ✅ **Uniform design**: Always use SharedResources (no ownership confusion)
- ✅ **Simpler API**: No `create_standalone()` vs `create_managed()` distinction
- ✅ **Single DHT node** serves all torrents (or just one)
- ✅ **Shared event loop** (no thread overhead)
- ✅ **Efficient resource usage**
- ✅ **Clean separation of concerns**

---

## Phase 1: Rename DownloadContext → Session

### Goal
Pure renaming operation to align with industry standards and prepare for future phases.

### Changes

#### 1. File Rename
```bash
src/download_session.c3 → src/session.c3
```

#### 2. Module Names (6 locations)
```c3
// Before
module torrent_client::download_session;
import torrent_client::download_session;

// After
module torrent_client::session;
import torrent_client::session;
```

**Files to update:**
- `src/session.c3` (renamed from download_session.c3)
- `src/main.c3`
- `src/session_message_handler.c3`
- `src/session_tracker_coordinator.c3`
- `src/magnet_download_session.c3`
- `src/ui/raylib_ui.c3`

#### 3. Struct Names
```c3
// Before
struct DownloadContext { ... }
DownloadContext* ctx;
download_session::DownloadContext* ctx;

// After
struct Session { ... }
Session* session;
session::Session* session;
```

#### 4. Helper Struct Members
```c3
// Before
struct PieceWriteContext {
    DownloadContext* download_ctx;
}

// After
struct PieceWriteContext {
    Session* session;
}
```

Same for:
- `WebSeedVerifyContext.download_ctx` → `WebSeedVerifyContext.session`
- `HttpSeedVerifyContext.download_ctx` → `HttpSeedVerifyContext.session`

#### 5. Module-Qualified References (~50+ occurrences)
```c3
// Before
download_session::format_size()
download_session::tracker_error_string()
download_session::VERIFICATION_BATCH_SIZE

// After
session::format_size()
session::tracker_error_string()
session::VERIFICATION_BATCH_SIZE
```

#### 6. Documentation Updates
Update references in:
- `ARCHITECTURE.md`
- `BEP38.md`
- `BEP_SUPPORT.md`
- `SHUTDOWN_LEAKS.md`
- `UPLOADING_SEEDING.md`
- Code comments in `session_message_handler.c3` and `session_tracker_coordinator.c3`

### What's NOT Changing
- Function names like `on_download_peer_connected()` (semantic change - Phase 2)
- `magnet_download_session` module (different purpose)
- Any logic or behavior

### Files Affected
**Source code (7 files):**
1. `src/download_session.c3` → `src/session.c3` (~80 changes)
2. `src/main.c3` (~35 changes)
3. `src/session_message_handler.c3` (~4 changes)
4. `src/session_tracker_coordinator.c3` (~2 changes)
5. `src/magnet_download_session.c3` (~8 changes)
6. `src/ui/raylib_ui.c3` (if present)
7. Test files that reference DownloadContext

**Documentation (5 files):**
1. `ARCHITECTURE.md`
2. `BEP38.md`
3. `BEP_SUPPORT.md`
4. `SHUTDOWN_LEAKS.md`
5. `UPLOADING_SEEDING.md`

### Testing
```bash
c3c build
c3c test libtorrent
```

**Expected result:** All 902 tests pass

### Risk Assessment
**LOW RISK** ✅
- Pure renaming operation
- No logic changes
- Compiler will catch missed renames
- No naming conflicts
- Reversible with git

### Time Estimate
- Implementation: 30-45 minutes
- Testing: 5-10 minutes
- **Total: ~1 hour**

---

## Phase 1.5: Integrate EventBus for Session Events

### Goal
Add EventBus to Session to provide event-driven callbacks for session state changes and progress updates. This enables GUI applications and library users to react to session events without polling.

### Why EventBus?
The codebase already has a fully functional EventBus (`src/lib/event_bus.c3`) that provides:
- ✅ **Async dispatch** - Events published on next event loop tick (non-blocking)
- ✅ **Pub/Sub pattern** - Decouples event publishers from subscribers
- ✅ **Wildcard subscriptions** - Listen to all events with `"*"`
- ✅ **Type-safe event data** - Events carry typed data structures
- ✅ **Already tested** - Existing infrastructure, no new code needed

### Changes

#### 1. Add EventBus to Session struct
```c3
// In src/session.c3
struct Session {
    // ... existing fields ...

    EventBus* event_bus;  // Event bus for session events
}
```

#### 2. Define Event Types (Session Constants)
```c3
// Event type constants
const String SESSION_STARTED = "session.started";
const String SESSION_PAUSED = "session.paused";
const String SESSION_RESUMED = "session.resumed";
const String SESSION_COMPLETED = "session.completed";
const String SESSION_STOPPED = "session.stopped";
const String SESSION_ERROR = "session.error";

const String PIECE_COMPLETED = "piece.completed";
const String PIECE_HASH_FAILED = "piece.hash_failed";

const String PEER_CONNECTED = "peer.connected";
const String PEER_DISCONNECTED = "peer.disconnected";

const String TRACKER_ANNOUNCE_SUCCESS = "tracker.success";
const String TRACKER_ANNOUNCE_FAILED = "tracker.failed";

const String STATS_UPDATE = "stats.update";
```

#### 3. Define Event Data Structures
```c3
// Event data structures
struct SessionStateEvent {
    InfoHash info_hash;
    SessionState state;
    String message;  // Optional description
}

struct PieceCompletedEvent {
    uint piece_index;
    usz piece_size;
    uint pieces_complete;
    uint total_pieces;
}

struct PeerEvent {
    SocketAddress peer_addr;
    String peer_id;  // If available
}

struct TrackerEvent {
    String tracker_url;
    int peer_count;      // For success
    String error_message;  // For failure
}

struct StatsUpdateEvent {
    long downloaded;
    long uploaded;
    int download_rate;
    int upload_rate;
    int connected_peers;
    float progress;
}

struct SessionErrorEvent {
    String error_message;
    int error_code;
}
```

#### 4. Publish Events from Session

**In session state transitions:**
```c3
fn void Session.start(&self) {
    // ... existing start logic ...

    SessionStateEvent evt = {
        .info_hash = self.info_hash,
        .state = SessionState.DOWNLOADING,
        .message = "Session started"
    };
    self.event_bus.publish(SESSION_STARTED, &evt, SessionStateEvent.sizeof);
}

fn void Session.pause(&self) {
    // ... existing pause logic ...

    SessionStateEvent evt = {
        .info_hash = self.info_hash,
        .state = SessionState.PAUSED,
        .message = "Session paused"
    };
    self.event_bus.publish(SESSION_PAUSED, &evt, SessionStateEvent.sizeof);
}
```

**In download_manager when piece completes:**
```c3
// In on_piece_verified callback (download_manager.c3)
PieceCompletedEvent evt = {
    .piece_index = piece_index,
    .piece_size = piece_size,
    .pieces_complete = ctx.download_mgr.get_completed_piece_count(),
    .total_pieces = ctx.torrent.info.get_num_pieces()
};
ctx.event_bus.publish(PIECE_COMPLETED, &evt, PieceCompletedEvent.sizeof);
```

**In peer_pool callbacks:**
```c3
// In on_download_peer_connected
PeerEvent evt = {
    .peer_addr = peer_addr,
    .peer_id = ""  // Can add if available
};
ctx.event_bus.publish(PEER_CONNECTED, &evt, PeerEvent.sizeof);
```

**In tracker_coordinator:**
```c3
// In on_announce_complete_parallel (success case)
TrackerEvent evt = {
    .tracker_url = tracker_url,
    .peer_count = response.peers.len,
    .error_message = ""
};
coord.session.event_bus.publish(TRACKER_ANNOUNCE_SUCCESS, &evt, TrackerEvent.sizeof);
```

**Periodic stats updates:**
```c3
// Add stats timer (1 second interval)
fn void on_stats_timer(async::timer::Timer* timer, void* user_data) {
    Session* session = (Session*)user_data;

    StatsUpdateEvent evt = {
        .downloaded = session.storage_mgr.get_downloaded(),
        .uploaded = session.upload_mgr.get_uploaded(),
        .download_rate = session.download_mgr.get_download_rate(),
        .upload_rate = session.upload_mgr.get_upload_rate(),
        .connected_peers = session.peer_pool.get_connected_count(),
        .progress = session.download_mgr.get_progress()
    };
    session.event_bus.publish(STATS_UPDATE, &evt, StatsUpdateEvent.sizeof);
}
```

#### 5. Usage Example (Application Side)

```c3
// In main.c3 or GUI application
fn void on_piece_completed(String event_type, void* event_data, void* user_data) {
    PieceCompletedEvent* evt = (PieceCompletedEvent*)event_data;
    io::printfn("✓ Piece %d completed (%d/%d pieces, %.1f%%)",
                evt.piece_index,
                evt.pieces_complete,
                evt.total_pieces,
                (float)evt.pieces_complete / evt.total_pieces * 100.0);
}

fn void on_tracker_success(String event_type, void* event_data, void* user_data) {
    TrackerEvent* evt = (TrackerEvent*)event_data;
    io::printfn("✓ Tracker %s: Got %d peers", evt.tracker_url, evt.peer_count);
}

// Subscribe to events
session.event_bus.subscribe(PIECE_COMPLETED, &on_piece_completed, null);
session.event_bus.subscribe(TRACKER_ANNOUNCE_SUCCESS, &on_tracker_success, null);

// Or subscribe to ALL events:
session.event_bus.subscribe("*", &on_any_event, user_data);
```

#### 6. Integration Points

**Files to modify:**
1. `src/session.c3` - Add EventBus field, publish state change events
2. `src/download_manager.c3` - Publish piece completion events
3. `src/session_message_handler.c3` - Publish peer events
4. `src/session_tracker_coordinator.c3` - Publish tracker events
5. `src/upload_manager.c3` - Publish upload events (future)
6. `src/main.c3` - Subscribe to events and display to user

### EventBus Ownership Decision

**Per-Session EventBus (Recommended):**
```c3
struct Session {
    EventBus* event_bus;  // Each session has own event bus
}

// Pros:
// - Isolated events per torrent
// - Simple subscription (one torrent = one bus)
// - No info_hash filtering needed
// - Clean separation

// Cons:
// - Must subscribe to each session individually in multi-torrent
```

**Why per-session?**
- In single-torrent mode: One session, one bus (simple)
- In multi-torrent mode: TorrentManager can aggregate events if needed

**TorrentManager can provide convenience methods:**
```c3
fn void TorrentManager.subscribe_all(&self, String event_type, EventCallback callback, void* user_data) {
    // Subscribe to all session event buses
    self.sessions.@each(; InfoHash hash, Session* session) {
        session.event_bus.subscribe(event_type, callback, user_data);
    };
}
```

### Testing

```bash
c3c build
c3c test libtorrent

# Test event firing in CLI
./torrent-client test.torrent
# Should see events logged: session started, tracker success, piece completed, etc.
```

**Expected result:**
- All 902 tests pass
- Events fire at appropriate times
- No performance degradation (async dispatch)

### Risk Assessment
**LOW RISK** ✅
- EventBus already exists and is tested
- Pure additive change (no breaking changes)
- Events are optional (subscribers can ignore)
- Async dispatch prevents blocking

### Time Estimate
- Implementation: 1-2 hours
- Testing: 30 minutes
- **Total: ~2 hours**

### Benefits
✅ **GUI-ready** - Applications can react to events without polling
✅ **Non-blocking** - Events dispatched asynchronously on event loop
✅ **Flexible** - Subscribe to specific events or all events
✅ **Decoupled** - Session doesn't know who's listening
✅ **Already implemented** - Reuse existing EventBus infrastructure

---

## Phase 2: Extract SharedResources Module

### Goal
Create a `SharedResources` module that **always** manages shared resources, whether for single-torrent or multi-torrent scenarios. This eliminates ownership complexity.

### New File: `src/lib/shared_resources.c3`

```c3
module libtorrent::shared_resources;

/**
 * Resources shared across torrent sessions (or used by a single session).
 * ALWAYS present - Session always borrows from SharedResources.
 */
struct SharedResources
{
    EventLoop* loop;                    // Event loop (owned)
    DHTClient* dht;                     // DHT node (owned)
    PeerDiscovery* peer_discovery;      // Composite discovery (owned)

    // Optional shared resources
    UPnPClient* upnp;                   // Port mapping
    BandwidthManager* bandwidth;        // Global rate limits (future)

    // Reference counting
    uint ref_count;                     // Number of sessions using this

    // Statistics
    uint active_torrents;
    ulong total_download_rate;
    ulong total_upload_rate;
}

/**
 * Create shared resources.
 * Can be used by one session (single-torrent) or many (multi-torrent).
 */
fn SharedResources* create(EventLoop* loop) @public;

/**
 * Add a reference (session using these resources).
 */
fn void SharedResources.add_ref(&self) @public;

/**
 * Remove a reference (session done with resources).
 * Auto-frees when ref_count reaches 0.
 */
fn void SharedResources.release(&self) @public;

/**
 * Force free (for cleanup, ignores ref count).
 */
fn void SharedResources.free(&self) @public;
```

### Modified: `src/lib/session.c3`

```c3
struct Session
{
    // Torrent-specific (NOT shared)
    TorrentFile* torrent;
    DownloadManager* download_mgr;
    StorageManager* storage_mgr;
    PeerPool* peer_pool;
    UploadManager* upload_mgr;
    TrackerCoordinator* tracker_coord;

    // Shared resources (ALWAYS borrowed from SharedResources)
    SharedResources* shared;            // ALWAYS present, never null

    // Session state
    InfoHash info_hash;
    SessionState state;  // STOPPED, DOWNLOADING, SEEDING, PAUSED
}

/**
 * Create session with SharedResources.
 * Note: Session borrows SharedResources, does NOT own it.
 */
fn Session* create(TorrentFile* torrent, SharedResources* shared) @public;

fn void Session.start(&self) @public;
fn void Session.pause(&self) @public;
fn void Session.resume(&self) @public;
fn void Session.stop(&self) @public;

/**
 * Free session and release SharedResources reference.
 * If this was the last session, SharedResources will auto-free.
 */
fn void Session.free(&self) @public;
```

### Key Design Decision: Unified Resource Model

**OLD approach (complex):**
```c3
// Two modes, ownership confusion
Session* s1 = create_standalone(loop, torrent);  // Owns loop, DHT
Session* s2 = create_managed(torrent, shared);   // Borrows from shared
// Who owns what? Hard to track!
```

**NEW approach (simple):**
```c3
// ALWAYS use SharedResources
SharedResources* shared = shared_resources::create(loop);
Session* session = session::create(torrent, shared);
// Crystal clear: Session borrows, SharedResources owns
```

### What Gets Shared vs Not Shared

| Resource | Location | Shared? | Reason |
|----------|----------|---------|--------|
| **Event Loop** | SharedResources | ✅ YES | Single thread model |
| **DHT Client** | SharedResources | ✅ YES | One node, many torrents |
| **Peer Discovery** | SharedResources | ✅ YES | DHT/LSD broadcast once |
| **UPnP/NAT-PMP** | SharedResources | ✅ YES | Port mapping |
| **Bandwidth Manager** | SharedResources | ✅ YES | Global rate limits |
| **Peer Pool** | Session | ❌ NO | Torrent-specific peers |
| **Download Manager** | Session | ❌ NO | Torrent-specific pieces |
| **Storage Manager** | Session | ❌ NO | Torrent-specific files |
| **Tracker Coordinator** | Session | ❌ NO | Torrent-specific trackers |
| **Upload Manager** | Session | ❌ NO | Torrent-specific data |

### Changes Required

1. **Create SharedResources module** with event loop, DHT, peer discovery
2. **Add reference counting** to SharedResources (add_ref/release)
3. **Simplify Session constructor** - single `create()` that always takes SharedResources
4. **Update Session.free()** to call `shared.release()`
5. **Remove ownership tracking** - SharedResources always owns, Session always borrows

### Testing
```bash
c3c build
c3c test libtorrent
```

**Expected result:** All tests pass, CLI still works

### Risk Assessment
**MEDIUM RISK** ⚠️
- Refactoring resource ownership
- Need reference counting logic
- Must ensure no double-free or leaks
- Simpler than dual-mode approach

### Time Estimate
- Implementation: 2-3 hours
- Testing: 30 minutes
- **Total: ~3 hours**

---

## Phase 3: Implement TorrentManager

### Goal
Create a multi-torrent manager that coordinates multiple sessions with shared resources.

### New File: `src/lib/torrent_manager.c3`

```c3
module libtorrent::torrent_manager;

/**
 * Manages multiple torrent sessions with shared resources.
 */
struct TorrentManager
{
    SharedResources* shared;            // One SharedResources for all torrents
    HashMap{InfoHash, Session*} sessions;

    // Configuration
    int max_torrents;
    int max_connections;
    int global_upload_limit;
    int global_download_limit;
}

fn TorrentManager* create(EventLoop* loop) @public;

/**
 * Add torrent from file path (manager parses internally).
 */
fn Session* TorrentManager.add_torrent(&self, String torrent_path) @public;

/**
 * Add torrent from parsed TorrentFile*.
 */
fn Session* TorrentManager.add_torrent_file(&self, TorrentFile* torrent) @public;

/**
 * Remove torrent from manager.
 */
fn void TorrentManager.remove_torrent(&self, InfoHash* hash) @public;

/**
 * Get session by info hash.
 */
fn Session* TorrentManager.get_session(&self, InfoHash* hash) @public;

/**
 * Get all sessions.
 */
fn Session*[] TorrentManager.get_all_sessions(&self) @public;

/**
 * Pause all torrents.
 */
fn void TorrentManager.pause_all(&self) @public;

/**
 * Resume all torrents.
 */
fn void TorrentManager.resume_all(&self) @public;

fn void TorrentManager.free(&self) @public;
```

### Usage Patterns

#### Pattern 1: Single Torrent (Simple)
```c3
// Single torrent with its own SharedResources
fn void main() {
    EventLoop* loop = event_loop::create();
    TorrentFile* torrent = metainfo::parse(file_data)!!;

    // Create SharedResources for this one torrent
    SharedResources* shared = shared_resources::create(loop);

    // Create session (borrows shared)
    Session* session = session::create(torrent, shared);
    session.start();

    // Run until complete
    while (!session.is_complete()) {
        loop.run_once();
    }

    session.free();    // Releases ref to shared
    shared.free();     // Frees resources (ref_count = 0)
    loop.free();
}
```

#### Pattern 2: Multiple Torrents (TorrentManager)
```c3
// GUI application downloading multiple torrents
fn void main() {
    EventLoop* loop = event_loop::create();

    // Create manager (creates ONE SharedResources internally)
    TorrentManager* mgr = torrent_manager::create(loop);

    // Add multiple torrents (all share resources)
    Session* s1 = mgr.add_torrent("file1.torrent");
    Session* s2 = mgr.add_torrent("file2.torrent");
    Session* s3 = mgr.add_torrent("file3.torrent");

    // All sessions share: DHT, event loop, port mapping
    // Each has: own peer pool, download manager, storage

    s1.start();
    s2.start();
    s3.start();

    // Single event loop serves all torrents
    loop.run();

    mgr.free();  // Frees all sessions and SharedResources
}
```

#### Pattern 3: Manual Resource Management (Advanced)
```c3
// Advanced: Multiple sessions, manual SharedResources
EventLoop* loop = event_loop::create();
SharedResources* shared = shared_resources::create(loop);

// Create multiple sessions manually
Session* s1 = session::create(torrent1, shared);
Session* s2 = session::create(torrent2, shared);
Session* s3 = session::create(torrent3, shared);

s1.start();
s2.start();
s3.start();

loop.run();

// Free sessions (each calls shared.release())
s1.free();
s2.free();
s3.free();  // Last one auto-frees SharedResources (ref_count = 0)

loop.free();
```

### TorrentManager Implementation Details

```c3
fn TorrentManager* create(EventLoop* loop) @public
{
    TorrentManager* mgr = mem::new(TorrentManager);

    // Create ONE SharedResources for all torrents
    mgr.shared = shared_resources::create(loop);

    mgr.sessions.init(mem);
    mgr.max_torrents = 100;
    mgr.max_connections = 200;

    return mgr;
}

fn Session* TorrentManager.add_torrent_file(&self, TorrentFile* torrent) @public
{
    // Check if already added
    if (Session**? existing = self.sessions.get_ref(torrent.info_hash))
    {
        return *existing;  // Already exists
    }

    // Create session (borrows shared resources)
    Session* session = session::create(torrent, self.shared);

    // Track session
    self.sessions.set(torrent.info_hash, session);

    return session;
}

fn void TorrentManager.remove_torrent(&self, InfoHash* hash) @public
{
    Session**? session_opt = self.sessions.get_ref(*hash);
    if (catch err = session_opt) return;  // Not found

    Session* session = *session_opt;
    session.stop();
    session.free();  // Releases ref to shared

    self.sessions.remove(*hash);
}

fn void TorrentManager.free(&self) @public
{
    // Free all sessions
    self.sessions.@each(; InfoHash hash, Session* session)
    {
        session.stop();
        session.free();  // Each releases ref to shared
    };
    self.sessions.free();

    // Free SharedResources (ref_count should be 0 now)
    self.shared.free();

    free(self);
}
```

### API Design

**Two overloaded `add_torrent` methods:**

1. **From file path** (convenience):
   ```c3
   fn Session* add_torrent(&self, String path)
   {
       TorrentFile? torrent_opt = metainfo::parse_file(path);
       if (catch err = torrent_opt)
       {
           io::eprintfn("Failed to parse torrent: %s", err);
           return null;
       }
       return self.add_torrent_file(torrent_opt);
   }
   ```

2. **From parsed TorrentFile*** (flexibility):
   ```c3
   fn Session* add_torrent_file(&self, TorrentFile* torrent)
   {
       // (implementation shown above)
   }
   ```

### Changes Required

1. **Create TorrentManager module** with HashMap of sessions
2. **Implement add_torrent()** with both overloads
3. **Implement remove_torrent()** with proper cleanup
4. **Add session lookup** by InfoHash
5. **Add global pause/resume** operations
6. **Update CLI** to optionally use TorrentManager
7. **Add GUI examples** demonstrating multi-torrent usage

### Testing
```bash
c3c build
c3c test libtorrent

# Test multi-torrent scenario
./torrent-client --multi file1.torrent file2.torrent file3.torrent
```

**Expected result:** Can download multiple torrents simultaneously with shared DHT

### Risk Assessment
**MEDIUM RISK** ⚠️
- Complex state management (multiple torrents)
- Need proper session lifecycle management
- HashMap operations must be safe
- Resource cleanup order critical
- Need thorough testing with multiple torrents

### Time Estimate
- Implementation: 4-6 hours
- Testing: 1-2 hours
- **Total: ~6-8 hours**

---

## File Structure After All Phases

```
src/lib/
├── session.c3                   # Renamed from download_session.c3
├── shared_resources.c3          # NEW: Unified resource management
├── torrent_manager.c3           # NEW: Multi-torrent coordinator
├── session_message_handler.c3   # Keep as-is
├── session_tracker_coordinator.c3  # Keep as-is
├── magnet_download_session.c3   # Keep as-is (different purpose)
├── peer_discovery.c3            # Already exists (owned by SharedResources)
├── dht_client.c3                # Already exists (owned by SharedResources)
├── peer_pool.c3                 # Per-session
├── download_manager.c3          # Per-session
├── storage_manager.c3           # Per-session
├── tracker_coordinator.c3       # Per-session
└── upload_manager.c3            # Per-session
```

---

## Benefits Summary

### After Phase 1
✅ Better naming aligned with industry standards
✅ Foundation for future phases
✅ No behavior changes, low risk

### After Phase 1.5
✅ **Event-driven architecture** - No polling required
✅ **GUI-ready callbacks** - React to state changes, piece completion, tracker events
✅ **Async event dispatch** - Non-blocking, fits existing architecture
✅ **Reuses existing EventBus** - Zero new infrastructure needed
✅ **Flexible subscriptions** - Per-event or wildcard listeners

### After Phase 2
✅ **Unified resource model** - always use SharedResources
✅ **No ownership confusion** - SharedResources owns, Session borrows
✅ **Reference counting** - auto-cleanup when last session closes
✅ **Simpler API** - single `create()` method

### After Phase 3
✅ Full multi-torrent support
✅ Efficient resource sharing (one DHT for all torrents)
✅ Library-ready API for embedding
✅ CLI can still work with single torrent
✅ GUI can manage multiple downloads
✅ Scalable architecture

---

## Key Design Insight: Why This is Better

### OLD Design (Dual-Mode, Complex):
```c3
struct Session {
    EventLoop* loop;           // Owned OR borrowed? Who knows!
    PeerDiscovery* discovery;  // Owned OR borrowed? Confusing!
    SharedResources* shared;   // Optional, adds complexity
    bool owns_resources;       // Need to track ownership
}

// Two constructors, ownership confusion
Session* s1 = create_standalone(loop, torrent);  // Owns resources
Session* s2 = create_managed(torrent, shared);   // Borrows resources
// How to free? Check owns_resources flag...
```

### NEW Design (Unified, Simple):
```c3
struct Session {
    SharedResources* shared;   // ALWAYS present, ALWAYS borrowed
    // No ownership ambiguity!
}

// One constructor, crystal clear
SharedResources* shared = shared_resources::create(loop);
Session* session = session::create(torrent, shared);
// How to free? session.free() releases ref, shared auto-frees when ref=0
```

**Benefits:**
- ✅ No ownership tracking needed
- ✅ Single code path (no mode switching)
- ✅ Reference counting handles cleanup
- ✅ Same pattern for single or multi-torrent
- ✅ Simpler to understand and maintain

---

## Implementation Priority

1. **Phase 1 (Easy)**: Rename `DownloadContext` → `Session`
   - Pure mechanical refactoring
   - Low risk, immediate benefit
   - **Recommended: Do this first**

2. **Phase 1.5 (Easy)**: Integrate EventBus for Session Events
   - Add event-driven callbacks
   - Low risk, pure additive
   - **Makes library GUI-ready**

3. **Phase 2 (Medium)**: Extract `SharedResources` module
   - Unified resource model
   - Medium risk, enables Phase 3
   - **Do when ready for multi-torrent**

4. **Phase 3 (Advanced)**: Implement `TorrentManager`
   - Full multi-torrent support
   - Medium risk, requires testing
   - **Do when needed for GUI or library usage**

---

## Rollback Strategy

Each phase is independently reversible:

**Phase 1:** Simple git revert (pure rename)
**Phase 1.5:** EventBus field is optional, events are additive (safe to skip)
**Phase 2:** Keep old constructor alongside new one during transition
**Phase 3:** TorrentManager is optional, doesn't affect existing code

---

## Reference Counting Example

```c3
// SharedResources implementation
fn SharedResources* create(EventLoop* loop)
{
    SharedResources* shared = mem::new(SharedResources);
    shared.loop = loop;
    shared.dht = dht_client::create(loop);
    shared.peer_discovery = peer_discovery::create_composite(shared.dht, ...);
    shared.ref_count = 0;  // No sessions yet
    return shared;
}

fn void SharedResources.add_ref(&self)
{
    self.ref_count++;
}

fn void SharedResources.release(&self)
{
    self.ref_count--;
    if (self.ref_count == 0)
    {
        // Last session released, auto-free
        self.free();
    }
}

// Session uses it
fn Session* create(TorrentFile* torrent, SharedResources* shared)
{
    Session* session = mem::new(Session);
    session.shared = shared;
    session.shared.add_ref();  // Increment ref count
    // ... initialize session ...
    return session;
}

fn void Session.free(&self)
{
    // ... cleanup session resources ...
    self.shared.release();  // Decrement ref count (may auto-free)
    free(self);
}
```

---

## Next Steps

1. **Review this plan** - Confirm unified resource model and EventBus integration
2. **Execute Phase 1** - Rename DownloadContext → Session
3. **Execute Phase 1.5** - Integrate EventBus for session events
4. **Test thoroughly** - Ensure no regressions
5. **Execute Phase 2** - Extract SharedResources with reference counting
6. **Execute Phase 3** - Implement TorrentManager when ready

---

## Questions for Discussion

1. Should reference counting be atomic (thread-safe)?
2. Should we add `BandwidthManager` in Phase 2 or defer to later?
3. Should `TorrentManager` be in `libtorrent::` or `torrent_client::`?
4. ~~Should we add session events/callbacks for state changes?~~ **✅ RESOLVED: Using EventBus (Phase 1.5)**
5. Should we support torrent queuing (max active downloads)?
6. Should `SharedResources.release()` auto-free or require explicit `free()`?

---

**Document Version:** 2.1
**Last Updated:** 2025-11-12
**Status:** Planning Phase
**Key Changes:**
- Unified resource model - always use SharedResources (simpler!)
- EventBus integration for session events (Phase 1.5)
**Next Action:** Execute Phase 1 (Rename)
