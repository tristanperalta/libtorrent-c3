module mktorrent;

import std::io;
import std::collections::list;
import libc;

<*
 File scanner using POSIX directory functions

 Scans a directory recursively and collects file metadata.
*>

// File metadata
struct FileEntry
{
    String[] path_components;  // Relative path components
    long size;                 // File size in bytes
    long offset;               // Byte offset in torrent
}

// Scan result
struct ScanResult
{
    List{FileEntry} files;
    long total_size;
}

<*
 Free all allocated memory in ScanResult
*>
fn void ScanResult.free(&self)
{
    // Free each file's path components
    foreach (file : self.files) {
        // Free each path component string
        foreach (component : file.path_components) {
            free(component);
        }
        // Free the path components array
        free(file.path_components);
    }

    // Free the files list
    self.files.free();
}

// Define dirent struct layout for direct field access
struct Dirent @cname("dirent")
{
    ulong d_ino;      // inode number
    long d_off;       // offset to next dirent
    ushort d_reclen;  // length of this record
    char d_type;      // type of file
    char[256] d_name; // filename
}

// External C functions for directory scanning
extern fn void* opendir(ZString name);
extern fn Dirent* readdir(void* dirp);
extern fn int closedir(void* dirp);

// File type constants from dirent.h
const char DT_UNKNOWN = 0;
const char DT_FIFO = 1;
const char DT_CHR = 2;
const char DT_DIR = 4;
const char DT_BLK = 6;
const char DT_REG = 8;
const char DT_LNK = 10;
const char DT_SOCK = 12;

// stat() mode constants
const uint S_IFMT = 0170000;   // File type mask
const uint S_IFDIR = 0040000;  // Directory

<*
 Get file size using stat
*>
fn long get_file_size(String path)
{
    // Use libc stat
    char[1024] path_buf;
    for (usz i = 0; i < path.len && i < 1023; i++) {
        path_buf[i] = path[i];
    }
    path_buf[path.len] = 0;

    libc::Stat stat_buf;
    int result = libc::stat((ZString)&path_buf[0], &stat_buf);
    if (result < 0) {
        return 0;
    }

    return (long)stat_buf.st_size;
}

<*
 Split path into components relative to base path
*>
fn String[] get_path_components(String full_path, String base_path)
{
    // Remove base path prefix
    String relative = full_path;
    if (full_path.starts_with(base_path)) {
        relative = full_path[base_path.len..];
        // Remove leading slash
        while (relative.len > 0 && relative[0] == '/') {
            relative = relative[1..];
        }
    }

    // Split by '/' - tsplit uses temp allocator, so copy to heap
    String[] temp_components = relative.tsplit("/");

    // Copy to heap allocator so it persists
    String[] components = mem::new_array(String, temp_components.len);
    for (usz i = 0; i < temp_components.len; i++) {
        components[i] = temp_components[i].copy(mem);
    }

    return components;
}

<*
 Recursively scan a directory
*>
fn void scan_directory_recursive(String dir_path, String base_path, List{FileEntry}* files, long* total_size)
{
    // Convert path to C string
    char[4096] path_buf;
    for (usz i = 0; i < dir_path.len && i < 4095; i++) {
        path_buf[i] = dir_path[i];
    }
    path_buf[dir_path.len] = 0;

    void* dir = opendir((ZString)&path_buf[0]);
    if (!dir) {
        io::printfn("Warning: Cannot open directory: %s", dir_path);
        return;
    }

    while (true) {
        Dirent* entry = readdir(dir);
        if (!entry) break;

        // Access fields directly - no helper functions needed!
        String name = ((ZString)&entry.d_name[0]).str_view();

        // Skip . and ..
        if (name == "." || name == "..") continue;

        // Build full path
        DString full_path;
        full_path.append(dir_path);
        if (!dir_path.ends_with("/")) {
            full_path.append("/");
        }
        full_path.append(name);
        String path_str = full_path.copy_str(mem);
        defer free(path_str);  // Free after use

        char entry_type = entry.d_type;

        if (entry_type == DT_DIR) {
            // Recurse into subdirectory
            scan_directory_recursive(path_str, base_path, files, total_size);
        } else if (entry_type == DT_REG) {
            // Regular file
            long file_size = get_file_size(path_str);

            FileEntry file;
            file.path_components = get_path_components(path_str, base_path);
            file.size = file_size;
            file.offset = *total_size;

            files.push(file);
            *total_size += file_size;
        }
    }

    closedir(dir);
}

<*
 Check if path is a directory
*>
fn bool is_directory(String path)
{
    char[1024] path_buf;
    for (usz i = 0; i < path.len && i < 1023; i++) {
        path_buf[i] = path[i];
    }
    path_buf[path.len] = 0;

    libc::Stat stat_buf;
    int result = libc::stat((ZString)&path_buf[0], &stat_buf);
    if (result < 0) {
        return false;
    }

    // S_ISDIR macro: (st_mode & S_IFMT) == S_IFDIR
    return (stat_buf.st_mode & S_IFMT) == S_IFDIR;
}

<*
 Scan a file or directory and return scan result
*>
fn ScanResult scan_path(String path)
{
    ScanResult result;
    result.files = {};
    result.total_size = 0;

    if (is_directory(path)) {
        // Directory - scan recursively
        scan_directory_recursive(path, path, &result.files, &result.total_size);
    } else {
        // Single file
        long file_size = get_file_size(path);

        FileEntry file;

        // Extract filename from path
        usz last_slash = path.rindex_of_char('/') ?? 0;
        String filename = last_slash > 0 ? path[last_slash+1..] : path;

        // Allocate path components on heap
        file.path_components = mem::new_array(String, 1);
        file.path_components[0] = filename.copy(mem);
        file.size = file_size;
        file.offset = 0;

        result.files.push(file);
        result.total_size = file_size;
    }

    return result;
}
