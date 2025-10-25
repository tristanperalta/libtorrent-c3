# Peer Pool Implementation Plan

## Overview

Create an async peer pool module (`peer_pool.c3`) inspired by libtorrent's `peer_list` class. This module will manage peer discovery, connection lifecycle, quality tracking, and connection prioritization for efficient BitTorrent downloads.

## Current Limitations

The current implementation in `src/main.c3` uses a fixed array of 10 peers with significant limitations:

- **No deduplication** - Can connect to same peer multiple times
- **No capacity management** - Fixed at 10 peers
- **No prioritization** - First-come-first-served
- **No failure handling** - Failed peers not tracked or banned
- **No statistics** - No download speed or quality tracking
- **Manual management** - No automatic peer replacement

## Architecture

### Design Principles

1. **Per-Torrent Design**: Each download has its own `PeerPool` instance (not global)
2. **Two-Tier Storage**:
   - **Peer List**: All discovered peers (configurable max, default 1000)
   - **Active Connections**: Currently connected peers (configurable max, default 25)
   - **Candidate Cache**: Pre-sorted peers ready to connect (by rank)
3. **Fully Async**: All operations use event loop and callbacks
4. **Quality-Based Selection**: Prioritize fast, reliable peers
5. **Automatic Recovery**: Replace failed connections automatically

### Peer Lifecycle

```
DISCOVERED → CANDIDATE → CONNECTING → CONNECTED → DISCONNECTED
     ↓           ↓            ↓            ↓
  BANNED ← (too many failures or misbehavior)
```

### Peer Sources (Current & Future)

- ✅ **Tracker** - HTTP/HTTPS/UDP tracker announces (implemented)
- ⏸️ **DHT** - Distributed Hash Table (future)
- ⏸️ **PEX** - Peer Exchange messages (future)
- ⏸️ **LSD** - Local Service Discovery (future)
- ⏸️ **Incoming** - Accept incoming connections (future)

## Data Structures

### Configuration

```c3
// Configuration (inspired by libtorrent's torrent_state)
struct PeerPoolConfig {
    usz max_peerlist_size;      // Default: 1000 (libtorrent default)
    usz max_active_connections; // Default: 25
    usz max_failcount;          // Default: 3 (ban after 3 failures)
    uint min_reconnect_time;    // Default: 60 seconds
}
```

### Peer State

```c3
enum PeerState : const char {
    DISCOVERED,    // Just learned about this peer
    CANDIDATE,     // Ready to connect (passed initial filters)
    CONNECTING,    // Connection in progress (async)
    CONNECTED,     // Active connection established
    DISCONNECTED,  // Previously connected, now closed
    BANNED         // Too many failures or misbehavior - never retry
}
```

### Single Peer (inspired by libtorrent's torrent_peer)

```c3
struct TorrentPeer {
    // Identity
    char[4] ip;                  // IPv4 address
    ushort port;                 // Port number
    char[20] peer_id;            // Peer ID (empty until handshake)

    // Connection
    peer_connection::PeerConnection* connection;  // Active connection (null if not connected)
    PeerState state;             // Current state

    // Statistics (for ranking and quality tracking)
    ulong prev_amount_download;  // Bytes downloaded from this peer
    ulong prev_amount_upload;    // Bytes uploaded to this peer
    uint hashfails;              // Failed piece hash verifications
    uint failcount;              // Connection failures (ban if >= max_failcount)
    uint last_connected;         // Timestamp of last connection (seconds since epoch)

    // Flags
    bool seed;                   // Is this peer a seed (has all pieces)?
    bool optimistically_unchoked; // Currently optimistically unchoked?

    // Ranking
    int peer_rank;               // Priority for connection (higher = better)

    // Source tracking
    bool from_tracker;           // Did we get this peer from tracker?
    bool from_dht;               // Future: from DHT?
    bool from_pex;               // Future: from PEX?
}
```

### Main Pool (inspired by libtorrent's peer_list)

```c3
struct PeerPool {
    event_loop::EventLoop* loop;  // Event loop for async operations
    PeerPoolConfig config;        // Configuration

    // Storage
    // Note: C3 doesn't have HashMap yet, so we use sorted array for O(log n) lookups
    // Future: Replace with HashMap when available for O(1) lookups
    TorrentPeer*[] peers;         // Main peer list (sorted by IP:port)
    TorrentPeer*[] candidate_cache;  // Ready to connect (sorted by rank, highest first)
    TorrentPeer*[] active_connections; // Currently connected peers

    // Torrent info (needed for peer connections)
    char[20] info_hash;           // Torrent info hash
    char[20] our_peer_id;         // Our peer ID

    // Callbacks (user-provided)
    PeerConnectedCallback on_connected;       // Called when peer connects successfully
    PeerMessageCallback on_message;           // Called when peer sends message
    PeerDisconnectedCallback on_disconnected; // Called when peer disconnects
    void* user_data;              // User data passed to callbacks

    // Timers
    async_timer::Timer* choke_timer;  // Periodic rechoking (future)
}
```

### Callbacks

```c3
// Called when peer successfully connects and completes handshake
alias PeerConnectedCallback = fn void(peer_connection::PeerConnection* peer,
                                       char[4] ip, ushort port, void* user_data);

// Called when peer sends a message
alias PeerMessageCallback = fn void(peer_connection::PeerConnection* peer,
                                     peer_wire::Message* msg,
                                     char[4] ip, ushort port, void* user_data);

// Called when peer disconnects
alias PeerDisconnectedCallback = fn void(char[4] ip, ushort port,
                                          bool was_error, void* user_data);
```

## Public API

### Core Functions

```c3
module libtorrent::peer_pool;

// Create peer pool for a torrent
fn PeerPool* create(event_loop::EventLoop* loop,
                    PeerPoolConfig config,
                    char[20]* info_hash,
                    char[20]* our_peer_id) @public;

// Free peer pool and all associated resources
fn void free(PeerPool* pool) @public;

// Add single peer from any source (deduplicates by IP:port)
fn void add_peer(PeerPool* pool, char[4] ip, ushort port, bool from_tracker) @public;

// Batch add peers from tracker response
fn void add_peers_from_tracker(PeerPool* pool, tracker::Peer[] peers) @public;

// Set event callbacks
fn void set_callbacks(PeerPool* pool,
                      PeerConnectedCallback on_connected,
                      PeerMessageCallback on_message,
                      PeerDisconnectedCallback on_disconnected,
                      void* user_data) @public;
```

### Connection Management

```c3
// Fill available connection slots with best candidates
// Automatically called after add_peers_from_tracker() or connection failures
fn void connect_to_peers(PeerPool* pool) @public;

// Disconnect specific peer
fn void disconnect_peer(PeerPool* pool, char[4] ip, ushort port) @public;

// Disconnect all peers
fn void disconnect_all(PeerPool* pool) @public;
```

### Peer Quality Tracking

```c3
// Update download/upload statistics for peer (affects ranking)
fn void update_peer_stats(PeerPool* pool, char[4] ip, ushort port,
                          ulong bytes_downloaded, ulong bytes_uploaded) @public;

// Mark piece hash failure from this peer (penalizes ranking, may ban)
fn void mark_hash_failure(PeerPool* pool, char[4] ip, ushort port) @public;

// Mark peer as seed (boosts ranking)
fn void mark_peer_seed(PeerPool* pool, char[4] ip, ushort port) @public;
```

### Queries

```c3
// Find peer by IP:port (returns null if not found)
fn TorrentPeer*? find_peer(PeerPool* pool, char[4] ip, ushort port) @public;

// Get statistics
fn void get_stats(PeerPool* pool,
                  usz* total_peers,       // Total peers in list
                  usz* candidates,        // Peers ready to connect
                  usz* connecting,        // Connections in progress
                  usz* connected) @public; // Active connections
```

### Future: Choking Algorithms

```c3
// Start periodic choking timer (calls rechoking logic every 10s per BEP 3)
fn void start_choke_timer(PeerPool* pool) @public;

// Stop choking timer
fn void stop_choke_timer(PeerPool* pool) @public;
```

## Implementation Phases

### Phase 1: Core Storage & Discovery ⭐ **HIGH PRIORITY**

**Goal**: Basic peer storage with deduplication and capacity management.

**Files**:
- Create: `src/lib/peer_pool.c3`
- Create: `test/lib/test_peer_pool.c3`

**Structures**:
- `PeerPoolConfig`
- `PeerState` enum
- `TorrentPeer` struct
- `PeerPool` struct

**Functions**:
- `create()` / `free()`
- `add_peer()` - Single peer with deduplication
- `add_peers_from_tracker()` - Batch add
- `find_peer()` - Binary search on sorted array
- `erase_peer()` - Remove peer
- `get_stats()` - Statistics

**Internal Helpers**:
- `compare_peers()` - For sorting by IP:port
- `find_peer_index()` - Binary search helper
- `enforce_peer_limit()` - Remove lowest-ranked peers if over limit

**Tests** (`test/lib/test_peer_pool.c3`):
```c3
fn void test_create_and_free() @test;
fn void test_add_single_peer() @test;
fn void test_add_duplicate_peer() @test;  // Should not create duplicate
fn void test_add_peers_from_tracker() @test;
fn void test_find_peer() @test;
fn void test_erase_peer() @test;
fn void test_peer_limit_enforcement() @test;  // Max 1000 peers
fn void test_statistics() @test;
```

**Estimated Size**: ~200 lines implementation + ~150 lines tests

---

### Phase 2: Peer Ranking & Candidate Selection ⭐ **HIGH PRIORITY**

**Goal**: Prioritize high-quality peers for connections.

**Functions**:
- `calculate_peer_rank()` - Ranking algorithm
- `update_candidate_cache()` - Re-sort by rank
- `pick_best_candidate()` - Get highest-ranked peer

**Ranking Algorithm** (simplified version of libtorrent):
```c3
fn int calculate_peer_rank(PeerPool* pool, TorrentPeer* peer) {
    int rank = 0;

    // Prioritize peers we've successfully downloaded from
    if (peer.prev_amount_download > 0) {
        rank += 100;
    }

    // Prioritize seeds if we're downloading
    if (peer.seed) {
        rank += 50;
    }

    // Penalize failed connections
    rank -= (int)peer.failcount * 20;

    // Penalize hash failures (bad peer)
    rank -= (int)peer.hashfails * 30;

    // Add deterministic randomness based on IP (ensures symmetric priority)
    rank += ((int)peer.ip[3] * 7) % 20;

    return rank;
}
```

**Tests**:
```c3
fn void test_peer_rank_calculation() @test;
fn void test_candidate_cache_sorting() @test;
fn void test_pick_best_candidate() @test;
fn void test_seed_priority() @test;
fn void test_failure_penalty() @test;
```

**Estimated Size**: ~100 lines implementation + ~100 lines tests

---

### Phase 3: Async Connection Management ⭐ **HIGH PRIORITY**

**Goal**: Automatically manage peer connections with retry and failure handling.

**Functions**:
- `connect_to_peers()` - Fill connection slots
- `new_connection()` - Handle successful connection
- `connection_closed()` - Handle disconnect
- `disconnect_peer()` - Manual disconnect
- `disconnect_all()` - Disconnect all
- `set_callbacks()` - Set user callbacks

**Internal Callbacks** (bridge between peer_connection and user):
- `on_peer_state_change()` - Routes peer_connection state to pool
- `on_peer_message_internal()` - Routes messages to user callback

**Auto-Retry Logic**:
```c3
fn void connection_closed(PeerPool* pool, TorrentPeer* peer, bool error) {
    if (error) {
        peer.failcount++;
    }

    if (peer.failcount >= pool.config.max_failcount) {
        // Ban peer - never retry
        peer.state = PeerState.BANNED;
    } else {
        // Allow retry after cooldown
        peer.state = PeerState.DISCONNECTED;
        peer.last_connected = current_time();
    }

    // Remove from active connections
    // ...

    // Automatically try to replace this connection
    connect_to_peers(pool);
}
```

**Tests**:
```c3
fn void test_connect_to_best_peer() @test;
fn void test_connection_success() @test;
fn void test_connection_failure() @test;
fn void test_auto_retry_after_failure() @test;
fn void test_ban_after_max_failures() @test;
fn void test_fill_connection_slots() @test;
fn void test_disconnect_peer() @test;
fn void test_callbacks() @test;
```

**Estimated Size**: ~200 lines implementation + ~150 lines tests

---

### Phase 4: Statistics & Quality Tracking ⭐ **MEDIUM PRIORITY**

**Goal**: Track peer performance to improve ranking over time.

**Functions**:
- `update_peer_stats()` - Track bytes downloaded/uploaded
- `mark_hash_failure()` - Penalize bad peers
- `mark_peer_seed()` - Boost seed ranking

**Usage Example**:
```c3
// When receiving a piece block from peer
pool.update_peer_stats(peer_ip, peer_port, block_size, 0);

// When piece hash verification fails
pool.mark_hash_failure(peer_ip, peer_port);

// When peer sends BITFIELD showing all pieces
pool.mark_peer_seed(peer_ip, peer_port);
```

**Tests**:
```c3
fn void test_update_download_stats() @test;
fn void test_update_upload_stats() @test;
fn void test_hash_failure_penalty() @test;
fn void test_seed_boost() @test;
fn void test_rank_improves_with_good_performance() @test;
```

**Estimated Size**: ~80 lines implementation + ~80 lines tests

---

### Phase 5: Choking Algorithms ⏸️ **LOW PRIORITY (Future Enhancement)**

**Goal**: Implement BEP 3 choking algorithms for optimal swarm performance.

**Functions**:
- `start_choke_timer()` / `stop_choke_timer()`
- `optimistic_unchoke()` - Randomly unchoke one peer
- `round_robin_unchoke()` - Fair unchoke rotation
- `recalculate_unchoke()` - Called every 10 seconds

**BEP 3 Choking Strategy**:
- Unchoke top 4 uploaders
- Optimistically unchoke 1 random peer every 30s
- Recalculate every 10s

**Tests**:
```c3
fn void test_optimistic_unchoke() @test;
fn void test_round_robin() @test;
fn void test_periodic_rechoke() @test;
```

**Estimated Size**: ~120 lines implementation + ~80 lines tests

---

### Phase 6: Integration with Download Command ⭐ **HIGH PRIORITY**

**Goal**: Replace fixed peer array in `main.c3` with peer pool.

**Changes to `src/main.c3`**:

**Before**:
```c3
struct DownloadContext {
    // ...
    DownloadPeerInfo[] peers;  // Fixed array of 10 peers
    int num_peers;
    int max_peers;
}
```

**After**:
```c3
struct DownloadContext {
    // ...
    peer_pool::PeerPool* peer_pool;  // Dynamic peer pool
}
```

**Refactoring Steps**:

1. **Create peer pool in `cmd_download()`**:
```c3
fn int cmd_download(event_loop::EventLoop* loop, String torrent_path,
                    String save_path, int numwant) {
    // ...

    // Create peer pool
    peer_pool::PeerPoolConfig pool_config = {
        .max_peerlist_size = 1000,
        .max_active_connections = 25,
        .max_failcount = 3,
        .min_reconnect_time = 60
    };

    ctx.peer_pool = peer_pool::create(loop, pool_config,
                                       &torrent.info_hash, &our_peer_id);
    defer peer_pool::free(ctx.peer_pool);

    // Set callbacks
    peer_pool::set_callbacks(ctx.peer_pool,
                              &on_download_peer_connected,
                              &on_download_peer_message,
                              &on_download_peer_disconnected,
                              &ctx);
}
```

2. **Route tracker responses to pool**:
```c3
fn void on_download_tracker_complete(tracker::TrackerResponse* response,
                                      int status, void* user_data) {
    DownloadContext* ctx = (DownloadContext*)user_data;

    if (status == 0 && response && response.peers.len > 0) {
        // Add peers to pool (deduplicates automatically)
        ctx.peer_pool.add_peers_from_tracker(response.peers);

        // Start connecting to best peers
        ctx.peer_pool.connect_to_peers();
    }
}
```

3. **Remove old peer management code**:
- Delete `DownloadPeerInfo` struct
- Delete manual peer tracking arrays
- Delete manual connection code

4. **Update message handlers**:
```c3
fn void on_download_peer_message(peer_connection::PeerConnection* peer,
                                  peer_wire::Message* msg,
                                  char[4] ip, ushort port,
                                  void* user_data) {
    // Message handling stays the same, just different signature
    // ...
}
```

5. **Add quality tracking**:
```c3
// When receiving PIECE block
ctx.peer_pool.update_peer_stats(ip, port, block_size, 0);

// When hash verification fails
ctx.peer_pool.mark_hash_failure(ip, port);

// When peer sends full BITFIELD
if (all_pieces) {
    ctx.peer_pool.mark_peer_seed(ip, port);
}
```

**Estimated Changes**: ~150 lines modified/deleted

---

## Testing Strategy

### Unit Tests (`test/lib/test_peer_pool.c3`)

- **Phase 1**: Core storage operations
- **Phase 2**: Ranking calculations
- **Phase 3**: Connection lifecycle
- **Phase 4**: Statistics tracking
- **Phase 5**: Choking algorithms

**Test Utilities**:
- Mock `peer_connection` for testing without network I/O
- Helper functions to create test peers
- Assert macros for comparing peers

### Integration Tests

- Test full download with real torrent file
- Verify automatic peer replacement on failure
- Verify ranking improves speed over time
- Test with 100+ peers from tracker

### Memory Testing

- Run all tests under Valgrind
- Test with 1000+ peers to check memory usage
- Verify no leaks on pool free

## Benefits Comparison

| Feature | Current (Fixed Array) | New (PeerPool) |
|---------|----------------------|----------------|
| **Capacity** | 10 peers | 1000+ peers (configurable) |
| **Deduplication** | None | Yes (by IP:port) |
| **Auto-replacement** | No | Yes |
| **Prioritization** | First-come-first-served | Quality-based ranking |
| **Failure handling** | None | Ban after N failures |
| **Retry logic** | Manual | Auto with cooldown |
| **Statistics** | None | Download/upload/failures |
| **Quality tracking** | None | Speed & reliability |
| **Connection limits** | Fixed at 10 | Configurable (e.g., 25) |
| **Memory efficiency** | Fixed allocation | Dynamic, sorted array |
| **Peer sources** | Tracker only | Multi-source ready |

## File Summary

### New Files

- **`src/lib/peer_pool.c3`** (~600 lines)
  - Core implementation
  - All 6 phases combined

- **`test/lib/test_peer_pool.c3`** (~400 lines)
  - Unit tests for all phases
  - Mock helpers

### Modified Files

- **`src/main.c3`** (~150 lines changed)
  - Replace `DownloadPeerInfo[]` with `PeerPool*`
  - Route tracker responses to pool
  - Update callbacks
  - Remove manual peer management

### Total Estimated Size

**~1150 lines** (600 implementation + 400 tests + 150 refactoring)

## Implementation Timeline

### Sprint 1: Core Functionality (Minimum Viable Product)
**Goal**: Replace fixed array with working peer pool

- ✅ Phase 1: Core Storage (2-3 days)
- ✅ Phase 2: Ranking (1-2 days)
- ✅ Phase 3: Connection Management (2-3 days)
- ✅ Phase 6: Integration (1-2 days)

**Total**: ~1-2 weeks

### Sprint 2: Enhancements (Future)
**Goal**: Add advanced features

- Phase 4: Statistics Tracking (1 day)
- Phase 5: Choking Algorithms (2 days)

**Total**: ~3 days

## Success Criteria

### Phase 1-3 Success
- [ ] Can add 1000+ peers without crashes
- [ ] No duplicate peers by IP:port
- [ ] Automatic peer replacement on disconnect
- [ ] All unit tests pass
- [ ] No memory leaks (Valgrind clean)

### Phase 6 Success
- [ ] Download command works with peer pool
- [ ] Can download real torrent file
- [ ] Handles tracker responses correctly
- [ ] All integration tests pass

### Phase 4-5 Success
- [ ] Peer ranking improves over time
- [ ] Fast peers prioritized
- [ ] Bad peers banned
- [ ] Choking algorithm works

## Future Enhancements

### Beyond This Plan

1. **DHT Support**
   - Add `add_peer_from_dht()`
   - Track DHT as peer source

2. **PEX (Peer Exchange)**
   - Parse PEX messages
   - Add `add_peer_from_pex()`

3. **IPv6 Support**
   - Change `char[4] ip` to `char[16] ip`
   - Support both IPv4 and IPv6

4. **Incoming Connections**
   - Add `accept_incoming_connection()`
   - Handle incoming handshakes

5. **Persistence**
   - Save peer list to disk
   - Resume with known-good peers

6. **Advanced Ranking**
   - Track latency (ping time)
   - Track piece diversity
   - Implement full libtorrent peer_priority algorithm

## References

### libtorrent Source Code
- `include/libtorrent/peer_list.hpp` - Main peer pool
- `include/libtorrent/torrent_peer.hpp` - Peer structure
- `test/test_peer_list.cpp` - 1249 lines of tests

### BitTorrent Protocol
- **BEP 3**: The BitTorrent Protocol
  - http://www.bittorrent.org/beps/bep_0003.html
  - Choking algorithm specification

- **BEP 5**: DHT Protocol
  - http://www.bittorrent.org/beps/bep_0005.html
  - Future: DHT peer discovery

- **BEP 11**: Peer Exchange (PEX)
  - http://www.bittorrent.org/beps/bep_0011.html
  - Future: PEX messages

### libtorrent Blog
- Swarm Connectivity: http://blog.libtorrent.org/2012/12/swarm-connectivity/
- Peer ranking algorithm explanation

## Notes

### Why Not HashMap?
C3 doesn't have a built-in HashMap (as of 0.7.6), so we use a sorted array with binary search:
- **Lookup**: O(log n) instead of O(1)
- **Insert**: O(n) instead of O(1)
- **For 1000 peers**: ~10 comparisons for lookup (acceptable)
- **Future**: Replace with HashMap when available

### Why Sorted Array?
- **Deduplication**: Binary search prevents duplicates
- **Memory efficient**: No hash table overhead
- **Cache friendly**: Sequential memory access
- **Simple**: No complex hash function needed

### Thread Safety
Not thread-safe (by design):
- All operations must be called from event loop thread
- Uses async callbacks, not threads
- Matches C3/libuv async model

---

## Conclusion

This plan provides a comprehensive, incremental approach to implementing a production-quality peer pool inspired by libtorrent. The phased approach allows us to:

1. **Start simple** (Phase 1-3) - Get basic functionality working
2. **Integrate early** (Phase 6) - Validate design with real usage
3. **Enhance later** (Phase 4-5) - Add advanced features once basics work

The peer pool will transform the BitTorrent client from a simple proof-of-concept with 10 hardcoded peers into a scalable, production-ready implementation capable of managing thousands of peers with intelligent prioritization and automatic failure recovery.
