module mktorrent;

import std::io;
import std::hash::sha1;
import std::hash::sha256;
import libtorrent::merkle_tree;
import libtorrent::metainfo;
import libc;

// Import MerkleTree type
alias MerkleTree = merkle_tree::MerkleTree;

<*
 Check if a path is a directory
*>
fn bool is_directory_path(String path)
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

    return (stat_buf.st_mode & S_IFMT) == S_IFDIR;
}

<*
 Hashing result for a torrent
*>
struct HashResult
{
    // v1 hashes
    char[] pieces_v1;  // Concatenated SHA-1 hashes (20 bytes each)

    // v2 hashes
    char[32] root_hash_v2;  // Root hash of Merkle tree
    char[] piece_layers;    // Encoded piece layers

    uint num_pieces;
}

<*
 Read a file in chunks and hash it

 For v1: Computes SHA-1 hashes of pieces
 For v2: Computes SHA-256 hashes for Merkle tree
*>
fn void hash_files(FileEntry[] files, String base_path, uint piece_length, int version, HashResult* result)
{
    result.num_pieces = 0;

    // Calculate total number of pieces
    long total_size = 0;
    foreach (file : files) {
        total_size += file.size;
    }
    uint num_pieces = (uint)((total_size + piece_length - 1) / piece_length);
    result.num_pieces = num_pieces;

    io::printfn("Hashing %d pieces...", num_pieces);

    // v1: Allocate buffer for SHA-1 hashes (20 bytes per piece)
    if (version == 1 || version == 3) {
        result.pieces_v1 = mem::new_array(char, (usz)(num_pieces * 20));
    }

    // v2: Build Merkle tree
    if (version == 2 || version == 3) {
        hash_files_v2(files, base_path, piece_length, result);
    }

    // v1: Hash pieces with SHA-1
    if (version == 1 || version == 3) {
        hash_files_v1(files, base_path, piece_length, result);
    }
}

<*
 Hash files using SHA-1 for v1 torrents
*>
fn void hash_files_v1(FileEntry[] files, String base_path, uint piece_length, HashResult* result)
{
    char[] buffer = mem::new_array(char, piece_length);
    defer free(buffer);

    uint piece_index = 0;
    uint buffer_offset = 0;

    foreach (file_idx, file : files) {
        // Build full file path
        DString path;

        // For single files, base_path is the full file path
        if (files.len == 1 && !is_directory_path(base_path)) {
            path.append(base_path);
        } else {
            // For directories, append relative components
            path.append(base_path);
            if (!base_path.ends_with("/")) {
                path.append("/");
            }
            for (usz i = 0; i < file.path_components.len; i++) {
                if (i > 0) path.append("/");
                path.append(file.path_components[i]);
            }
        }

        // Open file
        File? f = io::file::open(path.str_view(), "rb");
        if (catch err = f) {
            io::printfn("Error opening file %s: %s", path.str_view(), err);
            continue;
        }
        defer (void)f.close();

        // Read file in chunks
        long remaining = file.size;
        while (remaining > 0) {
            // How much to read for this piece
            uint to_read = (uint)(remaining < (long)(piece_length - buffer_offset) ?
                                  remaining : (long)(piece_length - buffer_offset));

            // Read chunk directly into buffer using length syntax
            usz? bytes_read = f.read(buffer[buffer_offset : to_read]);
            if (catch err = bytes_read) {
                io::printfn("Error reading file: %s", err);
                break;
            }

            buffer_offset += (uint)bytes_read;
            remaining -= (long)bytes_read;

            // If buffer is full, hash it
            if (buffer_offset >= piece_length) {
                // Hash the piece using length syntax
                char[] piece_data = buffer[0 : buffer_offset];
                Sha1 hasher;
                hasher.init();
                hasher.update(piece_data);
                char[20] hash = hasher.final();

                // Copy hash to result
                for (usz i = 0; i < 20; i++) {
                    result.pieces_v1[(usz)piece_index * 20 + i] = hash[i];
                }

                piece_index++;
                buffer_offset = 0;

                if (piece_index % 100 == 0) {
                    io::printfn("Hashed %d/%d pieces...", piece_index, result.num_pieces);
                }
            }
        }
    }

    // Hash final partial piece if any data remains
    if (buffer_offset > 0) {
        char[] piece_data = buffer[0 : buffer_offset];
        Sha1 hasher;
        hasher.init();
        hasher.update(piece_data);
        char[20] hash = hasher.final();

        // Copy hash to result
        for (usz i = 0; i < 20; i++) {
            result.pieces_v1[(usz)piece_index * 20 + i] = hash[i];
        }

        piece_index++;
    }

    io::printfn("Hashed %d pieces (v1)", piece_index);
}

<*
 Hash files using SHA-256 and build Merkle tree for v2 torrents

 BEP 52: Each file gets its own Merkle tree with 16 KiB blocks.
 For simplicity in mktorrent, we build one tree for the entire torrent.
*>
fn void hash_files_v2(FileEntry[] files, String base_path, uint piece_length, HashResult* result)
{
    // For v2, we build a Merkle tree with 16 KiB blocks
    // Read all files into a buffer and build one tree

    // Calculate total size
    long total_size = 0;
    foreach (file : files) {
        total_size += file.size;
    }

    if (total_size == 0) {
        io::printn("Warning: No data to hash for v2");
        return;
    }

    // Allocate buffer for all data
    char[] data = mem::new_array(char, (usz)total_size);
    defer free(data);

    // Read all files into buffer
    usz data_offset = 0;
    foreach (file : files) {
        // Build full file path
        DString path;

        // For single files, base_path is the full file path
        if (files.len == 1 && !is_directory_path(base_path)) {
            path.append(base_path);
        } else {
            // For directories, append relative components
            path.append(base_path);
            if (!base_path.ends_with("/")) {
                path.append("/");
            }
            for (usz i = 0; i < file.path_components.len; i++) {
                if (i > 0) path.append("/");
                path.append(file.path_components[i]);
            }
        }

        // Open and read file
        File? f = io::file::open(path.str_view(), "rb");
        if (catch err = f) {
            io::printfn("Error opening file %s: %s", path.str_view(), err);
            continue;
        }
        defer (void)f.close();

        // Read entire file using length syntax (offset:length)
        usz? bytes_read = f.read(data[data_offset : (usz)file.size]);
        if (catch err = bytes_read) {
            io::printfn("Error reading file: %s", err);
            continue;
        }

        data_offset += bytes_read;
    }

    // Build Merkle tree using length syntax
    io::printn("Building Merkle tree...");
    MerkleTree* tree = merkle_tree::build(data[0 : data_offset]);
    defer tree.free();

    // Get root hash
    for (usz i = 0; i < 32; i++) {
        result.root_hash_v2[i] = tree.pieces_root[i];
    }

    // Select appropriate layer based on piece_length
    uint selected_layer = tree.select_layer(piece_length);

    io::printfn("Built Merkle tree: %d blocks, height %d, selected layer %d",
                tree.num_blocks, tree.tree_height, selected_layer);

    // TODO: Extract and encode piece layers for .torrent file
    // For now, we just have the root hash
}
