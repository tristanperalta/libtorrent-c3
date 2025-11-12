module libtorrent::adapters::fastresume_state_provider;

import std::io;
import std::core::mem;
import libtorrent::bencode;
import libtorrent::ports::state_provider;
import async::file;

/**
 * FastResumeStateProvider - libtorrent-rasterbar compatible fastresume format.
 * ============================================================================
 *
 * Implements state persistence using libtorrent's fastresume bencode format.
 * This format is compatible with libtorrent-rasterbar and other clients that
 * use the same format (Deluge, qBittorrent when using libtorrent backend).
 *
 * FastResume Format (bencode dictionary):
 * {
 *   "file-format": "libtorrent resume file",
 *   "file-version": 2,
 *   "libtorrent-version": "2.0.0.0",
 *   "allocation": "sparse" | "full",
 *
 *   // Piece verification (essential)
 *   "pieces": <bitmask>,              // Which pieces are verified
 *   "unfinished": [                   // Partially downloaded pieces
 *     {
 *       "piece": <int>,
 *       "bitmask": <string>,
 *       "adler32": <int>
 *     }
 *   ],
 *
 *   // Statistics
 *   "total_downloaded": <int>,
 *   "total_uploaded": <int>,
 *   "active_time": <int>,
 *   "seeding_time": <int>,
 *   "added_time": <int>,
 *   "completed_time": <int>,
 *   "last_seen_complete": <int>,
 *
 *   // File priorities
 *   "file_priority": [<int>, ...],
 *   "piece_priority": <string>,
 *
 *   // Settings
 *   "upload_rate_limit": <int>,
 *   "download_rate_limit": <int>,
 *   "max_connections": <int>,
 *   "max_uploads": <int>,
 *   "paused": <int>,
 *   "auto_managed": <int>,
 *   "sequential_download": <int>,
 *   "seed_mode": <int>,
 *   "save_path": <string>,
 *
 *   // Transmission-specific fields (for compatibility)
 *   "activity_date": <int>,
 *   "corrupt": <int>,
 *   "bandwidth_priority": <int>,
 *   "ratio_limit": <real>,
 *   "idle_limit": <int>,
 *   "speed_limit_up_enabled": <int>,
 *   "speed_limit_down_enabled": <int>
 * }
 *
 * Reference:
 * - libtorrent documentation: https://www.libtorrent.org/manual-ref.html#fast-resume
 * - Format spec: https://www.libtorrent.org/manual-ref.html#resume-data
 */

const int FASTRESUME_VERSION = 2;
const String FASTRESUME_FILE_FORMAT = "libtorrent resume file";
const String LIBTORRENT_VERSION = "2.0.0.0";

faultdef FASTRESUME_FILE_NOT_FOUND;
faultdef FASTRESUME_PARSE_ERROR;
faultdef FASTRESUME_WRITE_ERROR;
faultdef FASTRESUME_INVALID_VERSION;

/**
 * FastResumeStateProvider struct.
 */
struct FastResumeStateProvider (state_provider::StateProvider)
{
    // Dummy fields - C3 interfaces may need extra space for vtable metadata
    // This provider is stateless, so the fields are unused
    void*[2] _dummy;
}

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Get fastresume file path for a torrent file.
 * Returns: <torrent_path>.fastresume
 *
 * Example: "ubuntu.torrent" -> "ubuntu.torrent.fastresume"
 */
fn String get_fastresume_path(String torrent_path)
{
    DString buf;
    buf.append(torrent_path);
    buf.append(".fastresume");
    return buf.copy_str(mem);
}

/**
 * Helper to copy char[] array (for binary data like bitmasks).
 */
fn char[] copy_char_array(char[] src)
{
    if (src.len == 0) return {};
    char[] dest = mem::new_array(char, src.len);
    foreach (i, byte : src)
    {
        dest[i] = byte;
    }
    return dest;
}

/**
 * Encode DownloadState to fastresume bencode dictionary.
 *
 * IMPORTANT: Keys MUST be added in lexicographically sorted order!
 *
 * @param state: "State to encode"
 * @return "Bencode dictionary representing fastresume data"
 */
fn BencodeValue* encode_fastresume(state_provider::DownloadState* state)
{
    BencodeValue* dict = bencode::make_dict();

    // All keys must be in lexicographic order (byte-by-byte comparison)
    // Order: active_time, activity_date, added_time, allocation, auto_managed,
    //        bandwidth_priority, completed_time, corrupt, download_rate_limit,
    //        file-format, file-version, file_priority, idle_limit,
    //        last_seen_complete, libtorrent-version, max_connections, max_uploads,
    //        paused, pieces, ratio_limit, save_path, seed_mode, seeding_time,
    //        sequential_download, speed_limit_down_enabled, speed_limit_up_enabled,
    //        total_downloaded, total_uploaded, unfinished, upload_rate_limit

    if (state.active_time > 0)
    {
        dict.dict_set("active_time", bencode::make_integer((long)state.active_time));
    }

    if (state.activity_date > 0)
    {
        dict.dict_set("activity_date", bencode::make_integer(state.activity_date));
    }

    if (state.added_time > 0)
    {
        dict.dict_set("added_time", bencode::make_integer(state.added_time));
    }

    dict.dict_set("allocation", bencode::make_string("sparse"));

    if (state.auto_managed)
    {
        dict.dict_set("auto_managed", bencode::make_integer(1));
    }

    if (state.bandwidth_priority != 0)
    {
        dict.dict_set("bandwidth_priority", bencode::make_integer((long)state.bandwidth_priority));
    }

    if (state.completed_time > 0)
    {
        dict.dict_set("completed_time", bencode::make_integer(state.completed_time));
    }

    if (state.corrupt > 0)
    {
        dict.dict_set("corrupt", bencode::make_integer((long)state.corrupt));
    }

    if (state.download_rate_limit > 0)
    {
        dict.dict_set("download_rate_limit", bencode::make_integer((long)state.download_rate_limit));
    }

    dict.dict_set("file-format", bencode::make_string(FASTRESUME_FILE_FORMAT));

    dict.dict_set("file-version", bencode::make_integer(FASTRESUME_VERSION));

    if (state.file_priority.len > 0)
    {
        BencodeValue* file_prio_list = bencode::make_list();
        foreach (priority : state.file_priority)
        {
            file_prio_list.list_append(bencode::make_integer((long)priority));
        }
        dict.dict_set("file_priority", file_prio_list);
    }

    // File resume data for validation (libtorrent-rasterbar compatible)
    if (state.file_resume.len > 0)
    {
        BencodeValue* file_resume_list = bencode::make_list();
        foreach (resume_data : state.file_resume)
        {
            BencodeValue* file_dict = bencode::make_dict();
            file_dict.dict_set("mtime", bencode::make_integer(resume_data.mtime));
            file_dict.dict_set("size", bencode::make_integer((long)resume_data.size));
            file_resume_list.list_append(file_dict);
        }
        dict.dict_set("file_resume", file_resume_list);
    }

    if (state.idle_limit > 0)
    {
        dict.dict_set("idle_limit", bencode::make_integer((long)state.idle_limit));
    }

    if (state.last_seen_complete > 0)
    {
        dict.dict_set("last_seen_complete", bencode::make_integer(state.last_seen_complete));
    }

    dict.dict_set("libtorrent-version", bencode::make_string(LIBTORRENT_VERSION));

    if (state.max_connections > 0)
    {
        dict.dict_set("max_connections", bencode::make_integer((long)state.max_connections));
    }

    if (state.max_uploads > 0)
    {
        dict.dict_set("max_uploads", bencode::make_integer((long)state.max_uploads));
    }

    if (state.paused)
    {
        dict.dict_set("paused", bencode::make_integer(1));
    }

    if (state.have_pieces.len > 0)
    {
        dict.dict_set("pieces", bencode::make_string((String)state.have_pieces));
    }

    if (state.ratio_limit > 0.0)
    {
        // Bencode doesn't have native float, store as string
        DString ratio_str;
        ratio_str.appendf("%f", state.ratio_limit);
        String ratio_copy = ratio_str.copy_str(mem);
        dict.dict_set("ratio_limit", bencode::make_string(ratio_copy));
        free(ratio_copy);
    }

    if (state.save_path.len > 0)
    {
        dict.dict_set("save_path", bencode::make_string(state.save_path));
    }

    if (state.seed_mode)
    {
        dict.dict_set("seed_mode", bencode::make_integer(1));
    }

    if (state.seeding_time > 0)
    {
        dict.dict_set("seeding_time", bencode::make_integer((long)state.seeding_time));
    }

    if (state.sequential_download)
    {
        dict.dict_set("sequential_download", bencode::make_integer(1));
    }

    if (state.speed_limit_down_enabled)
    {
        dict.dict_set("speed_limit_down_enabled", bencode::make_integer(1));
    }

    if (state.speed_limit_up_enabled)
    {
        dict.dict_set("speed_limit_up_enabled", bencode::make_integer(1));
    }

    if (state.total_downloaded > 0)
    {
        dict.dict_set("total_downloaded", bencode::make_integer((long)state.total_downloaded));
    }

    if (state.total_uploaded > 0)
    {
        dict.dict_set("total_uploaded", bencode::make_integer((long)state.total_uploaded));
    }

    if (state.unfinished.len > 0)
    {
        BencodeValue* unfinished_list = bencode::make_list();
        foreach (piece : state.unfinished)
        {
            // Unfinished piece dictionary keys: bitmask, piece (sorted)
            BencodeValue* piece_dict = bencode::make_dict();
            piece_dict.dict_set("bitmask", bencode::make_string((String)piece.blocks_bitmask));
            piece_dict.dict_set("piece", bencode::make_integer((long)piece.piece_index));
            unfinished_list.list_append(piece_dict);
        }
        dict.dict_set("unfinished", unfinished_list);
    }

    if (state.upload_rate_limit > 0)
    {
        dict.dict_set("upload_rate_limit", bencode::make_integer((long)state.upload_rate_limit));
    }

    return dict;
}

/**
 * Decode fastresume bencode dictionary to DownloadState.
 *
 * @param root: "Bencode dictionary to decode"
 * @return "Download state or fault on error"
 */
fn state_provider::DownloadState? decode_fastresume(BencodeValue* root)
{
    if (root.type != bencode::BencodeType.DICT)
    {
        return FASTRESUME_PARSE_ERROR?;
    }

    // Validate file format
    BencodeValue* file_format = root.dict_get("file-format");
    if (!file_format || file_format.type != bencode::BencodeType.STRING)
    {
        return FASTRESUME_PARSE_ERROR?;
    }
    if ((String)file_format.string != FASTRESUME_FILE_FORMAT)
    {
        return FASTRESUME_PARSE_ERROR?;
    }

    // Validate file version
    BencodeValue* file_version = root.dict_get("file-version");
    if (!file_version || file_version.type != bencode::BencodeType.INTEGER)
    {
        return FASTRESUME_PARSE_ERROR?;
    }
    if (file_version.integer != FASTRESUME_VERSION)
    {
        return FASTRESUME_INVALID_VERSION?;
    }

    // Initialize state
    state_provider::DownloadState state;
    state.version = state_provider::STATE_VERSION;

    // Extract all fields (with defaults for missing fields)

    // Essential fields
    BencodeValue* pieces = root.dict_get("pieces");
    if (pieces && pieces.type == bencode::BencodeType.STRING)
    {
        state.have_pieces = copy_char_array(pieces.string);
    }
    else
    {
        state.have_pieces = {};
    }

    state.file_selection = "";  // Not stored in fastresume format

    // Important fields
    BencodeValue* total_downloaded = root.dict_get("total_downloaded");
    state.total_downloaded = (total_downloaded && total_downloaded.type == bencode::BencodeType.INTEGER)
                             ? (ulong)total_downloaded.integer : 0;

    BencodeValue* total_uploaded = root.dict_get("total_uploaded");
    state.total_uploaded = (total_uploaded && total_uploaded.type == bencode::BencodeType.INTEGER)
                           ? (ulong)total_uploaded.integer : 0;

    BencodeValue* added_time = root.dict_get("added_time");
    state.added_time = (added_time && added_time.type == bencode::BencodeType.INTEGER)
                       ? added_time.integer : 0;

    BencodeValue* completed_time = root.dict_get("completed_time");
    state.completed_time = (completed_time && completed_time.type == bencode::BencodeType.INTEGER)
                           ? completed_time.integer : 0;

    BencodeValue* active_time = root.dict_get("active_time");
    state.active_time = (active_time && active_time.type == bencode::BencodeType.INTEGER)
                        ? (uint)active_time.integer : 0;

    BencodeValue* seeding_time = root.dict_get("seeding_time");
    state.seeding_time = (seeding_time && seeding_time.type == bencode::BencodeType.INTEGER)
                         ? (uint)seeding_time.integer : 0;

    BencodeValue* last_seen_complete = root.dict_get("last_seen_complete");
    state.last_seen_complete = (last_seen_complete && last_seen_complete.type == bencode::BencodeType.INTEGER)
                               ? last_seen_complete.integer : 0;

    // Unfinished pieces
    BencodeValue* unfinished = root.dict_get("unfinished");
    if (unfinished && unfinished.type == bencode::BencodeType.LIST)
    {
        usz count = unfinished.list.size;
        if (count > 0)
        {
            state.unfinished = mem::new_array(state_provider::UnfinishedPiece, count);
            foreach (i, piece_val : unfinished.list.array_view())
            {
                if (piece_val.type == bencode::BencodeType.DICT)
                {
                    BencodeValue* piece_idx = piece_val.dict_get("piece");
                    BencodeValue* bitmask = piece_val.dict_get("bitmask");

                    state.unfinished[i].piece_index = (piece_idx && piece_idx.type == bencode::BencodeType.INTEGER)
                                                      ? (uint)piece_idx.integer : 0;
                    state.unfinished[i].blocks_bitmask = (bitmask && bitmask.type == bencode::BencodeType.STRING)
                                                         ? copy_char_array(bitmask.string) : {};
                    state.unfinished[i].num_blocks_received = 0;  // Not stored in fastresume
                }
            }
        }
        else
        {
            state.unfinished = {};
        }
    }
    else
    {
        state.unfinished = {};
    }

    // Optional fields
    BencodeValue* file_priority = root.dict_get("file_priority");
    if (file_priority && file_priority.type == bencode::BencodeType.LIST)
    {
        usz count = file_priority.list.size;
        if (count > 0)
        {
            state.file_priority = mem::new_array(char, count);
            foreach (i, prio_val : file_priority.list.array_view())
            {
                if (prio_val.type == bencode::BencodeType.INTEGER)
                {
                    state.file_priority[i] = (char)prio_val.integer;
                }
            }
        }
        else
        {
            state.file_priority = {};
        }
    }
    else
    {
        state.file_priority = {};
    }

    // File resume data for validation (libtorrent-rasterbar compatible)
    BencodeValue* file_resume = root.dict_get("file_resume");
    if (file_resume && file_resume.type == bencode::BencodeType.LIST)
    {
        usz count = file_resume.list.size;
        if (count > 0)
        {
            state.file_resume = mem::new_array(state_provider::FileResumeData, count);
            foreach (i, file_dict : file_resume.list.array_view())
            {
                if (file_dict.type == bencode::BencodeType.DICT)
                {
                    BencodeValue* mtime_val = file_dict.dict_get("mtime");
                    BencodeValue* size_val = file_dict.dict_get("size");

                    if (mtime_val && mtime_val.type == bencode::BencodeType.INTEGER)
                    {
                        state.file_resume[i].mtime = mtime_val.integer;
                    }

                    if (size_val && size_val.type == bencode::BencodeType.INTEGER)
                    {
                        state.file_resume[i].size = (ulong)size_val.integer;
                    }
                }
            }
        }
        else
        {
            state.file_resume = {};
        }
    }
    else
    {
        state.file_resume = {};
    }

    BencodeValue* upload_rate_limit = root.dict_get("upload_rate_limit");
    state.upload_rate_limit = (upload_rate_limit && upload_rate_limit.type == bencode::BencodeType.INTEGER)
                              ? (int)upload_rate_limit.integer : 0;

    BencodeValue* download_rate_limit = root.dict_get("download_rate_limit");
    state.download_rate_limit = (download_rate_limit && download_rate_limit.type == bencode::BencodeType.INTEGER)
                                ? (int)download_rate_limit.integer : 0;

    BencodeValue* max_connections = root.dict_get("max_connections");
    state.max_connections = (max_connections && max_connections.type == bencode::BencodeType.INTEGER)
                            ? (int)max_connections.integer : 0;

    BencodeValue* max_uploads = root.dict_get("max_uploads");
    state.max_uploads = (max_uploads && max_uploads.type == bencode::BencodeType.INTEGER)
                        ? (int)max_uploads.integer : 0;

    BencodeValue* paused = root.dict_get("paused");
    state.paused = (paused && paused.type == bencode::BencodeType.INTEGER && paused.integer != 0);

    BencodeValue* auto_managed = root.dict_get("auto_managed");
    state.auto_managed = (auto_managed && auto_managed.type == bencode::BencodeType.INTEGER && auto_managed.integer != 0);

    BencodeValue* sequential_download = root.dict_get("sequential_download");
    state.sequential_download = (sequential_download && sequential_download.type == bencode::BencodeType.INTEGER && sequential_download.integer != 0);

    BencodeValue* seed_mode = root.dict_get("seed_mode");
    state.seed_mode = (seed_mode && seed_mode.type == bencode::BencodeType.INTEGER && seed_mode.integer != 0);

    BencodeValue* save_path = root.dict_get("save_path");
    if (save_path && save_path.type == bencode::BencodeType.STRING)
    {
        state.save_path = ((String)save_path.string).copy(mem);
    }
    else
    {
        state.save_path = "";
    }

    // Transmission-specific fields
    BencodeValue* activity_date = root.dict_get("activity_date");
    state.activity_date = (activity_date && activity_date.type == bencode::BencodeType.INTEGER)
                          ? activity_date.integer : 0;

    BencodeValue* corrupt = root.dict_get("corrupt");
    state.corrupt = (corrupt && corrupt.type == bencode::BencodeType.INTEGER)
                    ? (ulong)corrupt.integer : 0;

    BencodeValue* bandwidth_priority = root.dict_get("bandwidth_priority");
    state.bandwidth_priority = (bandwidth_priority && bandwidth_priority.type == bencode::BencodeType.INTEGER)
                               ? (int)bandwidth_priority.integer : 0;

    BencodeValue* ratio_limit = root.dict_get("ratio_limit");
    if (ratio_limit && ratio_limit.type == bencode::BencodeType.STRING)
    {
        // Parse string as double
        DString ratio_buf;
        ratio_buf.append((String)ratio_limit.string);
        state.ratio_limit = ratio_buf.str_view().to_double() ?? 0.0;
    }
    else
    {
        state.ratio_limit = 0.0;
    }

    BencodeValue* idle_limit = root.dict_get("idle_limit");
    state.idle_limit = (idle_limit && idle_limit.type == bencode::BencodeType.INTEGER)
                       ? (uint)idle_limit.integer : 0;

    BencodeValue* speed_limit_up_enabled = root.dict_get("speed_limit_up_enabled");
    state.speed_limit_up_enabled = (speed_limit_up_enabled && speed_limit_up_enabled.type == bencode::BencodeType.INTEGER && speed_limit_up_enabled.integer != 0);

    BencodeValue* speed_limit_down_enabled = root.dict_get("speed_limit_down_enabled");
    state.speed_limit_down_enabled = (speed_limit_down_enabled && speed_limit_down_enabled.type == bencode::BencodeType.INTEGER && speed_limit_down_enabled.integer != 0);

    return state;
}

// ============================================================================
// StateProvider Interface Implementation
// ============================================================================

/**
 * Load state implementation.
 */
fn state_provider::DownloadState? FastResumeStateProvider.load_state(&self, String torrent_path) @dynamic
{
    String fastresume_path = get_fastresume_path(torrent_path);
    defer free(fastresume_path);

    // Load file
    char[]? data_opt = file::load(mem, fastresume_path);
    if (catch err = data_opt)
    {
        return FASTRESUME_FILE_NOT_FOUND?;
    }
    char[] data = data_opt;
    defer free(data);

    // Parse bencode
    BencodeValue*? root_opt = bencode::decode((String)data);
    if (catch err = root_opt)
    {
        return FASTRESUME_PARSE_ERROR?;
    }
    BencodeValue* root = root_opt;
    defer root.free();

    // Decode to DownloadState
    return decode_fastresume(root);
}

/**
 * Save state implementation.
 */
fn void? FastResumeStateProvider.save_state(&self, String torrent_path, state_provider::DownloadState* state) @dynamic
{
    String fastresume_path = get_fastresume_path(torrent_path);
    defer free(fastresume_path);

    // Encode to bencode
    BencodeValue* dict = encode_fastresume(state);
    defer dict.free();

    // Encode to string
    String encoded = dict.encode();
    defer free(encoded);

    // Write to file
    if (catch err = file::save(fastresume_path, (char[])encoded))
    {
        return FASTRESUME_WRITE_ERROR?;
    }
}

/**
 * Has state implementation.
 */
fn bool FastResumeStateProvider.has_state(&self, String torrent_path) @dynamic
{
    String fastresume_path = get_fastresume_path(torrent_path);
    defer free(fastresume_path);

    return file::is_file(fastresume_path);
}

/**
 * Delete state implementation.
 */
fn void? FastResumeStateProvider.delete_state(&self, String torrent_path) @dynamic
{
    String fastresume_path = get_fastresume_path(torrent_path);
    defer free(fastresume_path);

    if (file::is_file(fastresume_path))
    {
        file::delete(fastresume_path)!;
    }
}

fn void FastResumeStateProvider.free(&self) @dynamic
{
    // Free the provider itself
    free(self);
}

// ============================================================================
// Factory Function
// ============================================================================

/**
 * Create a fastresume state provider (libtorrent-compatible format).
 *
 * @return "Provider instance (concrete type, not interface)"
 */
fn FastResumeStateProvider* create() @public
{
    FastResumeStateProvider* provider = mem::new(FastResumeStateProvider);
    return provider;
}

// ============================================================================
// Public Wrapper Functions (Workaround for C3 Interface Limitation)
// ============================================================================
//
// C3's interface system does not work with heap-allocated structs (mem::new).
// Even though we implement StateProvider interface with @dynamic methods,
// calling those methods through an interface pointer causes segfaults.
//
// Workaround: Provide public wrapper functions that call the concrete type methods.
// This sacrifices polymorphism but actually works.

/**
 * Load fastresume state (wrapper function).
 *
 * @param torrent_path: "Path to .torrent file"
 * @return "Download state or fault if not found/invalid"
 */
fn state_provider::DownloadState? load(String torrent_path) @public
{
    FastResumeStateProvider provider;
    return provider.load_state(torrent_path);
}

/**
 * Save fastresume state (wrapper function).
 *
 * @param torrent_path: "Path to .torrent file"
 * @param state: "Download state to save"
 * @return "Fault if save fails"
 */
fn void? save(String torrent_path, state_provider::DownloadState* state) @public
{
    FastResumeStateProvider provider;
    return provider.save_state(torrent_path, state);
}
