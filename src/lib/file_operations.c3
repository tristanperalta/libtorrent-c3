module libtorrent::file_operations;

import std::io;
import libc;

<*
 Cross-platform file operations for BEP 38 file reuse.

 Provides hard link support with automatic fallback to copy on filesystems
 that don't support hard links (FAT32, exFAT, some network mounts).

 Strategy:
 1. Try hard link first (instant, zero disk space)
 2. If hard link fails due to filesystem limitation, fall back to copy
 3. Copy uses async I/O to avoid blocking event loop
*>

faultdef FILE_HARD_LINK_FAILED;
faultdef FILE_COPY_FAILED;
faultdef FILE_NOT_FOUND;

// Windows constants and functions
const int ERROR_INVALID_FUNCTION = 1;
const int ERROR_FILE_NOT_FOUND = 2;
const int ERROR_PATH_NOT_FOUND = 3;
const int ERROR_ALREADY_EXISTS = 183;

// POSIX errno constants
const int EXDEV = 18;
const int EMLINK = 31;
const int EPERM = 1;
const int ENOENT = 2;
const int EEXIST = 17;

// Platform-specific extern functions (only one set will be linked)
extern fn int create_hard_link_w(ushort* new_path, ushort* existing_path, void* security) @cname("CreateHardLinkW");
extern fn uint get_last_error() @cname("GetLastError");
extern fn int link(ZString existing_path, ZString new_path);

<*
 Try to create a hard link from existing_path to new_path.

 Returns fault if:
 - Filesystem doesn't support hard links (caller should fall back to copy)
 - File not found
 - Other I/O error
*>
fn void? try_hard_link(String existing_path, String new_path)
{
    $if env::WIN32:
        // Windows implementation using CreateHardLinkW
        // Convert UTF-8 to UTF-16 for Windows API
        @pool() {
            // Note: Simplified - production would use proper UTF-8 to UTF-16 conversion
            DString existing_cstr;
            existing_cstr.append(existing_path);
            existing_cstr.append_char('\0');

            DString new_cstr;
            new_cstr.append(new_path);
            new_cstr.append_char('\0');

            // Call CreateHardLinkW (expects UTF-16 wide strings)
            // TODO: Proper UTF-8 -> UTF-16 conversion needed
            // For now, using simplified approach for ASCII paths
            int result = create_hard_link_w(
                (ushort*)new_cstr.str_view().ptr,
                (ushort*)existing_cstr.str_view().ptr,
                null
            );

            if (result == 0)
            {
                uint error = get_last_error();

                if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND)
                {
                    io::printfn("Hard link failed: file not found");
                    return FILE_NOT_FOUND?;
                }

                if (error == ERROR_INVALID_FUNCTION)
                {
                    // FAT32/exFAT - filesystem doesn't support hard links
                    io::printfn("Hard link failed: filesystem doesn't support hard links (FAT32/exFAT?)");
                    return FILE_HARD_LINK_FAILED?;
                }

                if (error == ERROR_ALREADY_EXISTS)
                {
                    // File already exists - that's OK for our use case
                    return;
                }

                // Other error
                io::printfn("Hard link failed: Windows error %d", error);
                return FILE_HARD_LINK_FAILED?;
            }
        };

    $else
        // POSIX implementation using link()
        @pool() {
            DString existing_cstr;
            existing_cstr.append(existing_path);
            existing_cstr.append_char('\0');

            DString new_cstr;
            new_cstr.append(new_path);
            new_cstr.append_char('\0');

            int result = link(
                (ZString)existing_cstr.str_view().ptr,
                (ZString)new_cstr.str_view().ptr
            );

            if (result != 0)
            {
                int error = libc::errno();

                if (error == ENOENT)
                {
                    io::printfn("Hard link failed: file not found");
                    return FILE_NOT_FOUND?;
                }

                if (error == EXDEV || error == EMLINK || error == EPERM)
                {
                    // Filesystem limitation:
                    // - EXDEV: Cross-device link (different filesystem)
                    // - EMLINK: Too many links (NTFS max 1024)
                    // - EPERM: Filesystem doesn't support hard links
                    io::printfn("Hard link failed: filesystem limitation (errno %d)", error);
                    return FILE_HARD_LINK_FAILED?;
                }

                if (error == EEXIST)
                {
                    // File already exists - that's OK
                    return;
                }

                // Other error
                io::printfn("Hard link failed: errno %d", error);
                return FILE_HARD_LINK_FAILED?;
            }
        };
    $endif
}

<*
 Copy file from source to destination using blocking I/O.

 Note: This is a simplified synchronous implementation.
 TODO: Use async::file for non-blocking copy in production.
*>
fn void? copy_file_sync(String source_path, String dest_path)
{
    // Open source file
    @pool() {
        DString src_cstr;
        src_cstr.append(source_path);
        src_cstr.append_char('\0');

        DString dst_cstr;
        dst_cstr.append(dest_path);
        dst_cstr.append_char('\0');

        // Use libc file I/O for simplicity (TODO: async::file)
        void* src_file = libc::fopen((ZString)src_cstr.str_view().ptr, "rb");
        if (!src_file)
        {
            io::printfn("Failed to open source file: %s", source_path);
            return FILE_NOT_FOUND?;
        }
        defer libc::fclose(src_file);

        void* dst_file = libc::fopen((ZString)dst_cstr.str_view().ptr, "wb");
        if (!dst_file)
        {
            io::printfn("Failed to create destination file: %s", dest_path);
            return FILE_COPY_FAILED?;
        }
        defer libc::fclose(dst_file);

        // Copy in 1MB chunks
        const usz BUFFER_SIZE = 1024 * 1024;
        char[] buffer = mem::new_array(char, BUFFER_SIZE);
        defer free(buffer);

        while (true)
        {
            usz bytes_read = libc::fread(buffer.ptr, 1, BUFFER_SIZE, src_file);
            if (bytes_read == 0) break;

            usz bytes_written = libc::fwrite(buffer.ptr, 1, bytes_read, dst_file);
            if (bytes_written != bytes_read)
            {
                io::printfn("Write error during file copy");
                return FILE_COPY_FAILED?;
            }
        }

        io::printfn("Copied file: %s -> %s", source_path, dest_path);
    };
}

<*
 Create a hard link or copy file if hard link is not supported.

 This is the main entry point for BEP 38 file reuse.

 Strategy:
 1. Try hard link first (instant, zero disk space)
 2. If filesystem doesn't support hard links, fall back to copy
 3. Report errors for file not found or I/O failures

 existing_path: Path to existing file (source)
 new_path: Path to create hard link or copy (destination)
*>
fn void? hard_link_or_copy(String existing_path, String new_path) @public
{
    // Try hard link first
    if (catch err = try_hard_link(existing_path, new_path))
    {
        if (err == FILE_HARD_LINK_FAILED)
        {
            // Hard link not supported - fall back to copy
            io::printfn("Hard link not supported, copying file instead...");
            copy_file_sync(existing_path, new_path)!;
        }
        else
        {
            // File not found or other error - propagate
            return err?;
        }
    }
    else
    {
        io::printfn("Hard linked: %s -> %s", existing_path, new_path);
    }
}
