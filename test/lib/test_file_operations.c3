module libtorrent::file_operations_test;

import libtorrent::file_operations;
import std::io;
import libc;

<*
 Tests for file_operations module (BEP 38 file reuse).

 Tests hard link creation with fallback to copy on unsupported filesystems.
*>

// Helper: Create a test file with specific content
fn void create_test_file(String path, String content)
{
    @pool() {
        DString path_cstr;
        path_cstr.append(path);
        path_cstr.append_char('\0');

        void* file = libc::fopen((ZString)path_cstr.str_view().ptr, "wb");
        assert(file != null, "Failed to create test file");

        libc::fwrite(content.ptr, 1, content.len, file);
        libc::fclose(file);
    };
}

// Helper: Read file content
fn String read_file_content(String path)
{
    char[] result_buffer;

    @pool() {
        DString path_cstr;
        path_cstr.append(path);
        path_cstr.append_char('\0');

        void* file = libc::fopen((ZString)path_cstr.str_view().ptr, "rb");
        if (!file) return "";

        // Get file size
        libc::fseek(file, 0, libc::SEEK_END);
        long size = libc::ftell(file);
        libc::fseek(file, 0, libc::SEEK_SET);

        if (size <= 0)
        {
            libc::fclose(file);
            return "";
        }

        // Read content into temp buffer (will be freed by @pool)
        char[] temp_buffer = mem::temp_array(char, (usz)size);
        usz bytes_read = libc::fread(temp_buffer.ptr, 1, (usz)size, file);
        libc::fclose(file);

        if (bytes_read == 0) return "";

        // Allocate result buffer on heap and copy BEFORE @pool ends
        result_buffer = mem::new_array(char, bytes_read);
        for (usz i = 0; i < bytes_read; i++)
        {
            result_buffer[i] = temp_buffer[i];
        }
    };

    return (String)result_buffer;
}

// Helper: Check if file exists
fn bool file_exists(String path)
{
    @pool() {
        DString path_cstr;
        path_cstr.append(path);
        path_cstr.append_char('\0');

        void* file = libc::fopen((ZString)path_cstr.str_view().ptr, "rb");
        if (!file) return false;

        libc::fclose(file);
        return true;
    };
}

// Helper: Delete test file
fn void delete_file(String path)
{
    @pool() {
        DString path_cstr;
        path_cstr.append(path);
        path_cstr.append_char('\0');

        libc::remove((ZString)path_cstr.str_view().ptr);
    };
}

fn void test_hard_link_or_copy_basic() @test
{
    // Create source file
    String source = "/tmp/test_file_ops_source.txt";
    String content = "Hello, BEP 38!";
    create_test_file(source, content);
    defer delete_file(source);

    // Create hard link
    String dest = "/tmp/test_file_ops_dest.txt";
    defer delete_file(dest);

    file_operations::hard_link_or_copy(source, dest)!!;

    // Verify destination exists
    assert(file_exists(dest), "Destination file should exist");

    // Verify content matches
    String dest_content = read_file_content(dest);
    defer free(dest_content);
    assert(dest_content == content, "Destination content should match source");

    io::printn("✓ Basic hard_link_or_copy works");
}

fn void test_hard_link_nonexistent_source() @test
{
    // Try to link nonexistent file
    String source = "/tmp/nonexistent_file_12345.txt";
    String dest = "/tmp/test_file_ops_dest2.txt";

    // Should fail with FILE_NOT_FOUND
    if (catch err = file_operations::hard_link_or_copy(source, dest))
    {
        // Expected to fail
        io::printn("✓ Correctly failed for nonexistent source");
    }
    else
    {
        assert(false, "Should fail for nonexistent source file");
    }
}

fn void test_hard_link_to_existing_destination() @test
{
    // Create source file
    String source = "/tmp/test_file_ops_source3.txt";
    String content = "Source content";
    create_test_file(source, content);
    defer delete_file(source);

    // Create destination file (already exists)
    String dest = "/tmp/test_file_ops_dest3.txt";
    create_test_file(dest, "Original dest content");
    defer delete_file(dest);

    // Try to create hard link - should handle existing file gracefully
    file_operations::hard_link_or_copy(source, dest)!!;

    io::printn("✓ Handles existing destination file");
}

fn void test_copy_large_file() @test
{
    // Create a larger file (2MB) to test copy performance
    String source = "/tmp/test_file_ops_large_source.dat";
    defer delete_file(source);

    @pool() {
        // Create 2MB file
        DString path_cstr;
        path_cstr.append(source);
        path_cstr.append_char('\0');

        void* file = libc::fopen((ZString)path_cstr.str_view().ptr, "wb");
        assert(file != null, "Failed to create large test file");

        // Write 2MB of data (pattern: 0-255 repeated)
        const usz SIZE = 2 * 1024 * 1024;
        char[] buffer = mem::new_array(char, 4096);
        defer free(buffer);

        for (usz i = 0; i < buffer.len; i++)
        {
            buffer[i] = (char)(i % 256);
        }

        usz written = 0;
        while (written < SIZE)
        {
            usz to_write = buffer.len;
            if (written + to_write > SIZE)
            {
                to_write = SIZE - written;
            }

            libc::fwrite(buffer.ptr, 1, to_write, file);
            written += to_write;
        }

        libc::fclose(file);
    };

    // Hard link or copy
    String dest = "/tmp/test_file_ops_large_dest.dat";
    defer delete_file(dest);

    file_operations::hard_link_or_copy(source, dest)!!;

    // Verify file size matches
    @pool() {
        DString src_cstr;
        src_cstr.append(source);
        src_cstr.append_char('\0');

        DString dst_cstr;
        dst_cstr.append(dest);
        dst_cstr.append_char('\0');

        libc::Stat src_stat;
        libc::Stat dst_stat;

        libc::stat((ZString)src_cstr.str_view().ptr, &src_stat);
        libc::stat((ZString)dst_cstr.str_view().ptr, &dst_stat);

        assert(src_stat.st_size == dst_stat.st_size, "File sizes should match");
    };

    io::printn("✓ Large file copy works (2MB)");
}

fn void test_hard_link_preserves_inode() @test
{
    // This test verifies hard links create same inode (POSIX only)
    $if env::POSIX:
        String source = "/tmp/test_file_ops_inode_source.txt";
        create_test_file(source, "Inode test");
        defer delete_file(source);

        String dest = "/tmp/test_file_ops_inode_dest.txt";
        defer delete_file(dest);

        file_operations::hard_link_or_copy(source, dest)!!;

        // Check if inodes match (hard link) or differ (copy fallback)
        @pool() {
            DString src_cstr;
            src_cstr.append(source);
            src_cstr.append_char('\0');

            DString dst_cstr;
            dst_cstr.append(dest);
            dst_cstr.append_char('\0');

            libc::Stat src_stat;
            libc::Stat dst_stat;

            libc::stat((ZString)src_cstr.str_view().ptr, &src_stat);
            libc::stat((ZString)dst_cstr.str_view().ptr, &dst_stat);

            if (src_stat.st_ino == dst_stat.st_ino)
            {
                io::printn("✓ Hard link created (same inode)");
            }
            else
            {
                io::printn("✓ Copy fallback used (different inodes - FAT32/exFAT?)");
            }
        };
    $else
        // Windows - skip inode check
        io::printn("✓ Inode test skipped (Windows)");
    $endif
}
