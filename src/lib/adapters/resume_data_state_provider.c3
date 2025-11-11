module libtorrent::adapters::resume_data_state_provider;

import std::io;
import std::core::mem;
import libtorrent::bencode;
import libtorrent::file_selection;
import libtorrent::ports::state_provider;
import async::file;

/**
 * Resume Data Module (BEP 21 Support)
 * ====================================
 *
 * Provides persistence for torrent download state, particularly file selection.
 * Saves/loads resume data in bencode format to `.resume` files.
 *
 * Resume file format (bencode dictionary):
 * {
 *   "file_selection": "0,2,4",  // Comma-separated selected file indices
 *   "version": 1                // Resume format version
 * }
 */

faultdef RESUME_FILE_NOT_FOUND;
faultdef RESUME_PARSE_ERROR;
faultdef RESUME_WRITE_ERROR;

const int RESUME_VERSION = 1;

/**
 * Resume data structure.
 */
struct ResumeData
{
    String file_selection;  // Comma-separated file indices (e.g., "0,2,4")
    int version;            // Resume format version
}

/**
 * ResumeDataProvider - File-based implementation of StateProvider interface.
 * Implements state persistence using bencode files (.torrent.resume).
 */
struct ResumeDataProvider (state_provider::StateProvider)
{
    void* _vtable;     // Space for interface vtable pointer
    void* _typeinfo;   // Space for interface type information
}

/**
 * Get resume file path for a torrent file.
 * Returns: <torrent_path>.resume
 *
 * Example: "ubuntu.torrent" -> "ubuntu.torrent.resume"
 */
fn String get_resume_path(String torrent_path) @public
{
    DString buf;
    buf.append(torrent_path);
    buf.append(".resume");
    return buf.copy_str(mem);
}

/**
 * Save resume data to disk.
 *
 * @param torrent_path: "Path to the .torrent file"
 * @param file_selection: "File selection to save (e.g., '0,2,4')"
 * @return "Fault if save fails"
 */
fn void? save_resume_data(String torrent_path, String file_selection) @public
{
    String resume_path = get_resume_path(torrent_path);
    defer free(resume_path);

    // Build bencode dictionary
    DString buf;
    buf.append("d");

    // file_selection: "0,2,4"
    buf.appendf("14:file_selection%d:", file_selection.len);
    buf.append(file_selection);

    // version: 1
    buf.append("7:versioni1e");

    buf.append("e");

    // Write to file
    String data = buf.str_view();
    if (catch err = file::save(resume_path, (char[])data))
    {
        return RESUME_WRITE_ERROR?;
    }
}

/**
 * Load resume data from disk.
 *
 * @param torrent_path: "Path to the .torrent file"
 * @return "Resume data or fault if not found/parse error"
 */
fn ResumeData? load_resume_data(String torrent_path) @public
{
    String resume_path = get_resume_path(torrent_path);
    defer free(resume_path);

    // Load file
    char[]? data_opt = file::load(mem, resume_path);
    if (catch err = data_opt)
    {
        return RESUME_FILE_NOT_FOUND?;
    }
    char[] data = data_opt;
    defer free(data);

    // Parse bencode
    bencode::BencodeValue*? root_opt = bencode::decode((String)data);
    if (catch err = root_opt)
    {
        return RESUME_PARSE_ERROR?;
    }
    bencode::BencodeValue* root = root_opt;
    defer root.free();

    if (root.type != bencode::BencodeType.DICT)
    {
        return RESUME_PARSE_ERROR?;
    }

    ResumeData resume;
    resume.file_selection = "";
    resume.version = RESUME_VERSION;

    // Extract file_selection
    bencode::BencodeValue* file_sel = root.dict_get("file_selection");
    if (file_sel && file_sel.type == bencode::BencodeType.STRING)
    {
        // Copy the string (caller must free)
        resume.file_selection = ((String)file_sel.string).copy(mem);
    }

    // Extract version
    bencode::BencodeValue* version_val = root.dict_get("version");
    if (version_val && version_val.type == bencode::BencodeType.INTEGER)
    {
        resume.version = (int)version_val.integer;
    }

    return resume;
}

/**
 * Check if resume file exists for a torrent.
 */
fn bool has_resume_data(String torrent_path) @public
{
    String resume_path = get_resume_path(torrent_path);
    defer free(resume_path);

    return file::is_file(resume_path);
}

/**
 * Delete resume file for a torrent.
 */
fn void? delete_resume_data(String torrent_path) @public
{
    String resume_path = get_resume_path(torrent_path);
    defer free(resume_path);

    if (file::is_file(resume_path))
    {
        file::delete(resume_path)!;
    }
}

/**
 * Free resume data resources.
 */
fn void ResumeData.free(&self) @public
{
    if (self.file_selection.len > 0)
    {
        free(self.file_selection);
    }
}

// ============================================================================
// StateProvider Interface Implementation (C3 @dynamic methods)
// ============================================================================

/**
 * Load state implementation.
 */
fn state_provider::DownloadState? ResumeDataProvider.load_state(&self, String torrent_path) @dynamic
{
    // Load resume data
    ResumeData? resume_opt = load_resume_data(torrent_path);
    if (catch err = resume_opt)
    {
        return state_provider::STATE_LOAD_ERROR?;
    }
    ResumeData resume = resume_opt;
    defer resume.free();

    // Convert to DownloadState
    state_provider::DownloadState state;
    state.file_selection = resume.file_selection.copy(mem);
    state.version = resume.version;

    return state;
}

/**
 * Save state implementation.
 */
fn void? ResumeDataProvider.save_state(&self, String torrent_path, state_provider::DownloadState* state) @dynamic
{
    // Save resume data
    if (catch err = save_resume_data(torrent_path, state.file_selection))
    {
        return state_provider::STATE_SAVE_ERROR?;
    }
}

/**
 * Has state implementation.
 */
fn bool ResumeDataProvider.has_state(&self, String torrent_path) @dynamic
{
    return has_resume_data(torrent_path);
}

/**
 * Delete state implementation.
 */
fn void? ResumeDataProvider.delete_state(&self, String torrent_path) @dynamic
{
    if (catch err = delete_resume_data(torrent_path))
    {
        return state_provider::STATE_SAVE_ERROR?;
    }
}

/**
 * Create a resume data provider (file-based bencode storage).
 *
 * @return "Provider instance (can be used as StateProvider interface)"
 */
fn state_provider::StateProvider* create_resume_data_provider() @public
{
    ResumeDataProvider* provider = mem::new(ResumeDataProvider);
    return (state_provider::StateProvider*)provider;
}
