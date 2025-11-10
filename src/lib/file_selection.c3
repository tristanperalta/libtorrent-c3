module libtorrent::file_selection;

import std::io;
import std::collections::list;

/**
 * File selection for multi-file torrents (BEP 21 - Partial Seeds).
 * Allows users to select which files to download.
 */
struct FileSelection
{
    bool[] selected_files;  // Indexed by file_index
    usz total_files;
}

/**
 * Create file selection from comma-separated indices (e.g., "0,2,4").
 *
 * @param indices_str "Comma-separated file indices"
 * @param total_files "Total number of files in torrent"
 * @return "FileSelection or fault if invalid"
 */
fn FileSelection? create_from_string(String indices_str, usz total_files) @public
{
    if (total_files == 0) return FILE_SELECTION_ERROR?;

    // Parse indices first (before allocation)
    if (indices_str.len == 0) return FILE_SELECTION_ERROR?;

    FileSelection selection;
    selection.total_files = total_files;
    selection.selected_files = mem::new_array(bool, total_files);

    // Initialize all to false
    for (usz i = 0; i < total_files; i++)
    {
        selection.selected_files[i] = false;
    }

    String[] parts = indices_str.split(mem, ",");
    defer free(parts);
    if (parts.len == 0)
    {
        free(selection.selected_files);
        return FILE_SELECTION_ERROR?;
    }

    bool any_selected = false;
    foreach (part : parts)
    {
        String trimmed = part.trim();
        if (trimmed.len == 0) continue;

        // Parse as integer
        int? index = trimmed.to_int();
        if (catch err = index)
        {
            // Invalid number
            free(selection.selected_files);
            return FILE_SELECTION_ERROR?;
        }

        // Validate range
        if (index < 0 || (usz)index >= total_files)
        {
            free(selection.selected_files);
            return FILE_SELECTION_ERROR?;
        }

        selection.selected_files[(usz)index] = true;
        any_selected = true;
    }

    // Must select at least one file
    if (!any_selected)
    {
        free(selection.selected_files);
        return FILE_SELECTION_ERROR?;
    }

    return selection;
}

/**
 * Create file selection with all files selected.
 *
 * @param total_files "Total number of files"
 * @return "FileSelection with all files selected"
 */
fn FileSelection create_all_selected(usz total_files) @public
{
    FileSelection selection;
    selection.total_files = total_files;
    selection.selected_files = mem::new_array(bool, total_files);

    for (usz i = 0; i < total_files; i++)
    {
        selection.selected_files[i] = true;
    }

    return selection;
}

/**
 * Check if a file is selected.
 *
 * @param file_index "File index to check"
 * @return "True if file is selected"
 */
fn bool FileSelection.is_file_selected(&self, usz file_index) @public
{
    if (file_index >= self.total_files) return false;
    return self.selected_files[file_index];
}

/**
 * Check if all files are selected.
 *
 * @return "True if all files selected"
 */
fn bool FileSelection.is_all_selected(&self) @public
{
    for (usz i = 0; i < self.total_files; i++)
    {
        if (!self.selected_files[i]) return false;
    }
    return true;
}

/**
 * Count how many files are selected.
 *
 * @return "Number of selected files"
 */
fn usz FileSelection.count_selected(&self) @public
{
    usz count = 0;
    for (usz i = 0; i < self.total_files; i++)
    {
        if (self.selected_files[i]) count++;
    }
    return count;
}

/**
 * Serialize to string for resume support (e.g., "0,2,4").
 *
 * @return "Comma-separated indices"
 */
fn String FileSelection.to_string(&self) @public
{
    DString buf;
    bool first = true;

    for (usz i = 0; i < self.total_files; i++)
    {
        if (self.selected_files[i])
        {
            if (!first) buf.append(",");
            buf.appendf("%d", i);
            first = false;
        }
    }

    return buf.copy_str(mem);
}

/**
 * Free file selection resources.
 */
fn void FileSelection.free(&self) @public
{
    if (self.selected_files.len > 0)
    {
        free(self.selected_files);
    }
}

// Fault definitions
faultdef FILE_SELECTION_ERROR;
