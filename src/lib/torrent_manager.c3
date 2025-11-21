module libtorrent::torrent_manager;

import std::io;
import std::collections::map;
import std::collections::list;
import libtorrent::common;
import libtorrent::metainfo;
import libtorrent::dht_client;
import libtorrent::lsd;
import libtorrent::discovery;
import libtorrent::discovery::composite;
import libtorrent::session;
import libtorrent::resolve_links;
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
    composite::CompositePeerDiscovery* peer_discovery;
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

// ============================================================================
// BEP 38: Swarm Metadata - File Reuse
// ============================================================================

/**
 * Find all torrents that belong to a specific collection (BEP 38).
 *
 * @param collection_name Name of collection to search for
 * @return Array of sessions in this collection (caller must free)
 */
fn session::Session*[] TorrentManager.find_by_collection(&self, String collection_name) @public
{
    if (self.sessions.count == 0) return {};

    // Use temp List to accumulate matching sessions
    List{session::Session*} matches;
    matches.init(mem);
    defer matches.free();

    self.sessions.@each(; common::InfoHash hash, session::Session* ctx)
    {
        // Check if this torrent has the collection
        foreach (collection : ctx.torrent.collections)
        {
            if (collection == collection_name)
            {
                matches.push(ctx);
                break;  // Only add once even if collection appears multiple times
            }
        }
    };

    // Convert List to array
    if (matches.len() == 0) return {};

    session::Session*[] result = mem::new_array(session::Session*, matches.len());
    foreach (i, ctx : matches)
    {
        result[i] = ctx;
    }

    return result;
}

/**
 * Check if files from existing torrents can be reused for a new torrent (BEP 38).
 *
 * This implements the core BEP 38 file reuse algorithm:
 * 1. Search torrents in the same collection
 * 2. Search similar torrents (from similar field)
 * 3. Match files by piece hash comparison
 * 4. Return ResolveLinks with matched files
 *
 * @param target New torrent being added
 * @return ResolveLinks with matched files (caller must call .free())
 */
fn resolve_links::ResolveLinks TorrentManager.check_similar_torrents(
    &self,
    metainfo::TorrentFile* target
) @public
{
    resolve_links::ResolveLinks links = resolve_links::create(target);

    io::printfn("[BEP 38] Checking for reusable files (target: %s)", target.info.name);

    // Strategy 1: Search torrents in the same collection
    foreach (collection : target.collections)
    {
        session::Session*[] collection_torrents = self.find_by_collection(collection);
        defer free(collection_torrents);

        io::printfn("[BEP 38] Found %d torrents in collection '%s'",
            collection_torrents.len, collection);

        foreach (source_session : collection_torrents)
        {
            // Skip self (shouldn't happen but be safe)
            if (source_session.torrent == target) continue;

            // Try to match files from this source
            links.match_torrent(
                source_session.torrent,
                source_session.save_path
            );
        }
    }

    // Strategy 2: Search similar torrents (from similar field)
    if (target.similar_count > 0)
    {
        io::printfn("[BEP 38] Checking %d similar torrents", target.similar_count);

        for (usz i = 0; i < target.similar_count; i++)
        {
            // Extract info hash (20 bytes)
            usz offset = i * common::SHA1_HASH_SIZE;
            common::InfoHash similar_hash;
            foreach (j, byte : target.similar[offset:common::SHA1_HASH_SIZE])
            {
                similar_hash[j] = byte;
            }

            // Look up session by info hash
            session::Session* source_session = self.get_session(&similar_hash);
            if (source_session)
            {
                // Try to match files from this source
                links.match_torrent(
                    source_session.torrent,
                    source_session.save_path
                );
            }
        }
    }

    io::printfn("[BEP 38] File reuse check complete: %d matches found",
        links.get_match_count());

    return links;
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
