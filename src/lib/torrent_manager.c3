module libtorrent::torrent_manager;

import std::io;
import std::collections::map;
import libtorrent::common;
import libtorrent::metainfo;
import libtorrent::dht_client;
import libtorrent::lsd;
import libtorrent::ports::peer_discovery;
import libtorrent::adapters::composite_peer_discovery;
import torrent_client::session;
import async::event_loop;
import async::timer;

/**
 * TorrentManager - Manages multiple torrent download sessions
 * =============================================================
 *
 * Central coordinator for multi-torrent downloads:
 * - Manages multiple Session instances (one per torrent)
 * - All sessions share a single SharedResources instance
 * - Provides session lookup by info hash
 * - Handles session lifecycle (add, remove, pause, resume)
 * - Aggregates statistics across all torrents
 *
 * Architecture:
 * - One TorrentManager per application instance
 * - One SharedResources (shared event loop, DHT, LSD)
 * - Multiple Sessions (one per active torrent)
 */

/**
 * Statistics for a single torrent session.
 */
struct TorrentStats
{
    common::InfoHash info_hash;
    String name;
    ulong total_size;
    ulong downloaded;
    ulong uploaded;
    float progress;           // 0.0 to 1.0
    int download_rate;        // bytes/sec
    int upload_rate;          // bytes/sec
    int connected_peers;
    int total_peers;
    bool is_complete;
    bool is_paused;
}

/**
 * Torrent manager for coordinating multiple downloads.
 *
 * OWNERSHIP MODEL:
 * - TorrentManager owns all shared resources directly (no SharedResources wrapper)
 * - TorrentManager owns all Session instances
 * - Sessions borrow TorrentManager pointer (no ownership transfer)
 */
struct TorrentManager
{
    // Event loop (borrowed from caller - NOT owned)
    event_loop::EventLoop* loop;

    // Shared resources (owned by TorrentManager)
    dht_client::DhtClient* dht;
    // WORKAROUND: Store concrete type instead of interface due to C3 vtable bug
    composite_peer_discovery::CompositePeerDiscovery* peer_discovery;
    lsd::LsdManager* lsd_mgr;

    // Shared timers
    async::timer::Timer* dht_tick_timer;
    async::timer::Timer* lsd_timer;

    // DHT/LSD flags
    bool dht_enabled;
    bool lsd_enabled;

    // Network configuration
    ushort listen_port;

    // Active sessions indexed by info hash (owned by TorrentManager)
    HashMap{common::InfoHash, session::Session*} sessions;

    // Manager state
    bool is_running;
    uint max_active_torrents;  // 0 = unlimited

    // Statistics
    uint active_sessions;
    ulong total_download_rate;
    ulong total_upload_rate;
}

/**
 * Create a torrent manager with shared resources.
 *
 * @param loop : "Event loop (manager does not own - caller manages lifetime)"
 * @param max_active : "Maximum concurrent torrents (0 = unlimited)"
 * @return "New TorrentManager instance"
 */
fn TorrentManager* create(event_loop::EventLoop* loop, uint max_active = 0) @public
{
    TorrentManager* mgr = mem::new(TorrentManager);

    // Initialize event loop (borrowed, not owned)
    mgr.loop = loop;

    // Initialize shared resources (owned by manager)
    mgr.dht = null;
    mgr.peer_discovery = null;
    mgr.lsd_mgr = null;
    mgr.dht_tick_timer = null;
    mgr.lsd_timer = null;
    mgr.dht_enabled = false;
    mgr.lsd_enabled = false;
    mgr.listen_port = 6881;  // Default BitTorrent port

    // Initialize sessions map
    mgr.sessions.init(mem);

    // Manager state
    mgr.is_running = true;
    mgr.max_active_torrents = max_active;

    // Statistics
    mgr.active_sessions = 0;
    mgr.total_download_rate = 0;
    mgr.total_upload_rate = 0;

    return mgr;
}

/**
 * Add a torrent to the manager and start downloading.
 *
 * @param mgr : "Torrent manager"
 * @param torrent : "Parsed torrent file (manager takes ownership)"
 * @param save_path : "Directory to save downloaded files"
 * @param user_data : "Optional user data for callbacks"
 * @return "Session pointer on success, null on failure"
 */
fn session::Session*? TorrentManager.add_torrent(&self,
                                                  metainfo::TorrentFile* torrent,
                                                  String save_path,
                                                  void* user_data = null) @public
{
    // Check if already added
    if (self.sessions.has_key(torrent.info_hash))
    {
        io::eprintfn("[TorrentManager] Torrent already added: %s", torrent.info.name);
        return null;
    }

    // Check max active limit
    if (self.max_active_torrents > 0 && self.sessions.count >= self.max_active_torrents)
    {
        io::eprintfn("[TorrentManager] Maximum active torrents reached (%d)",
                     self.max_active_torrents);
        return null;
    }

    // Create new session
    session::Session* ctx = mem::new(session::Session);

    // Initialize session with manager reference (borrowed, not owned)
    ctx.manager = self;

    // TODO: Initialize session fields
    // This would normally be done in a session::create() function
    // For now, we'll do minimal initialization
    ctx.torrent = torrent;
    ctx.save_path = save_path.copy(mem);
    ctx.download_complete = false;
    ctx.is_partial_seed = false;
    ctx.exit_code = 0;

    // Add to sessions map
    self.sessions.set(torrent.info_hash, ctx);
    self.active_sessions++;

    io::printfn("[TorrentManager] Added torrent: %s (total: %d)",
                torrent.info.name, self.sessions.count);

    return ctx;
}

/**
 * Remove a torrent from the manager and stop downloading.
 *
 * @param mgr : "Torrent manager"
 * @param info_hash : "Info hash of torrent to remove"
 * @return "True if removed, false if not found"
 */
fn bool TorrentManager.remove_torrent(&self, common::InfoHash* info_hash) @public
{
    session::Session**? ctx_ptr_opt = self.sessions.get_ref(*info_hash);
    if (catch excuse = ctx_ptr_opt)
    {
        io::eprintfn("[TorrentManager] Torrent not found for removal");
        return false;
    }

    session::Session** ctx_ptr = ctx_ptr_opt;
    session::Session* ctx = *ctx_ptr;

    io::printfn("[TorrentManager] Removing torrent: %s", ctx.torrent.info.name);

    // Decrement active session count
    if (self.active_sessions > 0)
    {
        self.active_sessions--;
    }

    // Free session-specific resources
    if (ctx.torrent)
    {
        io::printfn("[TorrentManager] Freeing torrent: %s", ctx.torrent.info.name);
        ctx.torrent.free();
    }

    if (ctx.save_path.len > 0)
    {
        free(ctx.save_path);
    }

    // Free session
    free(ctx);

    // Remove from map
    self.sessions.remove(*info_hash);

    io::printfn("[TorrentManager] Removed torrent (remaining: %d)", self.sessions.count);

    return true;
}

/**
 * Get a session by info hash.
 *
 * @param mgr : "Torrent manager"
 * @param info_hash : "Info hash to lookup"
 * @return "Session pointer or null if not found"
 */
fn session::Session* TorrentManager.get_session(&self, common::InfoHash* info_hash) @public
{
    session::Session**? ctx_ptr_opt = self.sessions.get_ref(*info_hash);
    if (catch excuse = ctx_ptr_opt)
    {
        return null;
    }
    return *ctx_ptr_opt;
}

/**
 * Get statistics for a specific torrent.
 *
 * @param mgr : "Torrent manager"
 * @param info_hash : "Info hash of torrent"
 * @return "Statistics or null if torrent not found"
 */
fn TorrentStats* TorrentManager.get_stats(&self, common::InfoHash* info_hash) @public
{
    session::Session* ctx = self.get_session(info_hash);
    if (!ctx) return null;

    TorrentStats* stats = mem::new(TorrentStats);
    stats.info_hash = *info_hash;
    stats.name = ctx.torrent.info.name.copy(mem);
    stats.total_size = (ulong)ctx.torrent.info.length;
    stats.downloaded = ctx.total_bytes_downloaded;
    stats.uploaded = 0;  // TODO: Track upload stats
    stats.progress = 0.0;  // TODO: Calculate from download manager
    stats.download_rate = (int)ctx.current_download_speed;
    stats.upload_rate = 0;  // TODO: Track upload rate
    stats.connected_peers = 0;  // TODO: Get from peer pool
    stats.total_peers = 0;  // TODO: Get from peer pool
    stats.is_complete = ctx.download_complete;
    stats.is_paused = false;  // TODO: Add pause state

    return stats;
}

/**
 * Get number of active torrents.
 *
 * @param mgr : "Torrent manager"
 * @return "Number of active torrents"
 */
fn uint TorrentManager.get_torrent_count(&self) @public
{
    return (uint)self.sessions.count;
}

/**
 * Check if a torrent is being managed.
 *
 * @param mgr : "Torrent manager"
 * @param info_hash : "Info hash to check"
 * @return "True if torrent is active"
 */
fn bool TorrentManager.has_torrent(&self, common::InfoHash* info_hash) @public
{
    return self.sessions.has_key(*info_hash);
}

/**
 * Get all info hashes of managed torrents.
 *
 * @param mgr : "Torrent manager"
 * @return "Array of info hashes (caller must free)"
 */
fn common::InfoHash[] TorrentManager.get_all_info_hashes(&self) @public
{
    if (self.sessions.count == 0) return {};

    common::InfoHash[] hashes = mem::new_array(common::InfoHash, self.sessions.count);
    usz index = 0;

    self.sessions.@each(; common::InfoHash hash, session::Session* ctx)
    {
        hashes[index] = hash;
        index++;
    };

    return hashes;
}

/**
 * Pause all torrents.
 *
 * @param mgr : "Torrent manager"
 */
fn void TorrentManager.pause_all(&self) @public
{
    io::printfn("[TorrentManager] Pausing all torrents (%d active)", self.sessions.count);

    self.sessions.@each(; common::InfoHash hash, session::Session* ctx)
    {
        // TODO: Implement pause logic
        // - Stop timers
        // - Save state
        // - Disconnect peers gracefully
    };
}

/**
 * Resume all torrents.
 *
 * @param mgr : "Torrent manager"
 */
fn void TorrentManager.resume_all(&self) @public
{
    io::printfn("[TorrentManager] Resuming all torrents (%d active)", self.sessions.count);

    self.sessions.@each(; common::InfoHash hash, session::Session* ctx)
    {
        // TODO: Implement resume logic
        // - Restart timers
        // - Reconnect to peers
        // - Resume announces
    };
}

/**
 * Free all resources and stop all torrents.
 *
 * @param mgr : "Torrent manager"
 */
fn void TorrentManager.free(&self) @public
{
    io::eprintfn("[TorrentManager] Shutting down (%d active torrents)", self.sessions.count);

    // Remove all torrents
    common::InfoHash[] hashes = self.get_all_info_hashes();
    defer if (hashes.len > 0) free(hashes);

    foreach (hash : hashes)
    {
        self.remove_torrent(&hash);
    }

    // Free sessions map
    self.sessions.free();

    // Close shared timers
    if (self.dht_tick_timer)
    {
        self.dht_tick_timer.close();
    }

    if (self.lsd_timer)
    {
        self.lsd_timer.close();
    }

    // Free shared resources (owned by manager)
    if (self.dht)
    {
        self.dht.free();
    }

    if (self.lsd_mgr)
    {
        self.lsd_mgr.free();
    }

    if (self.peer_discovery)
    {
        free(self.peer_discovery);
    }

    // Note: Event loop is NOT owned by TorrentManager (borrowed from caller)

    free(self);
}
