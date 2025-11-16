module mktorrent;

import std::io;
import libtorrent::bencode;

<*
 Write a .torrent file from scan and hash results
*>
fn void write_torrent_file(
    String output_path,
    String input_path,
    String[] announce_urls,
    String comment,
    bool is_private,
    FileEntry[] files,
    HashResult* hash_result,
    uint piece_length,
    int version
)
{
    // Create root dictionary
    BencodeValue* root = bencode::make_dict();
    defer root.free();

    // Add announce URL
    if (announce_urls.len > 0) {
        root.dict_set("announce", bencode::make_string(announce_urls[0]));
    }

    // Add comment if provided
    if (comment.len > 0) {
        root.dict_set("comment", bencode::make_string(comment));
    }

    // Build info dictionary
    BencodeValue* info = bencode::make_dict();

    // Extract name from input path
    usz last_slash = input_path.rindex_of_char('/') ?? 0;
    String name = last_slash > 0 ? input_path[last_slash+1..] : input_path;
    info.dict_set("name", bencode::make_string(name));

    // Add piece length
    info.dict_set("piece length", bencode::make_integer((long)piece_length));

    // Add v1 pieces if version includes v1
    if (version == 1 || version == 3) {
        // Convert pieces_v1 array to String for bencode
        String pieces_str = (String)hash_result.pieces_v1;
        info.dict_set("pieces", bencode::make_string(pieces_str));
    }

    // Add v2 metadata if version includes v2
    if (version == 2 || version == 3) {
        // Add meta version
        info.dict_set("meta version", bencode::make_integer(2));

        // Add file tree with Merkle root
        BencodeValue* file_tree = bencode::make_dict();

        // For single file, use the file name as key
        if (files.len == 1) {
            // Create file metadata dict (with empty string "" key)
            BencodeValue* file_metadata = bencode::make_dict();
            file_metadata.dict_set("length", bencode::make_integer(files[0].size));

            // Add pieces root (32-byte SHA-256 hash)
            String pieces_root = (String)hash_result.root_hash_v2[0:32];
            file_metadata.dict_set("pieces root", bencode::make_string(pieces_root));

            // Create file entry dict
            BencodeValue* file_entry = bencode::make_dict();
            file_entry.dict_set("", file_metadata);  // Empty string key for file metadata

            file_tree.dict_set(name, file_entry);
        }
        // TODO: Multi-file v2 torrents need directory tree structure

        info.dict_set("file tree", file_tree);
    }

    // Add files list for multi-file torrents (v1 format)
    if (files.len > 1 && (version == 1 || version == 3)) {
        BencodeValue* files_list = bencode::make_list();

        foreach (file : files) {
            BencodeValue* file_dict = bencode::make_dict();

            // Add file length
            file_dict.dict_set("length", bencode::make_integer(file.size));

            // Add file path
            BencodeValue* path_list = bencode::make_list();
            foreach (component : file.path_components) {
                path_list.list_append(bencode::make_string(component));
            }
            file_dict.dict_set("path", path_list);

            files_list.list_append(file_dict);
        }

        info.dict_set("files", files_list);
    } else if (files.len == 1 && (version == 1 || version == 3)) {
        // Single file torrent (v1 format only, v2 uses file tree)
        info.dict_set("length", bencode::make_integer(files[0].size));
    }

    // Add private flag if set
    if (is_private) {
        info.dict_set("private", bencode::make_integer(1));
    }

    // Add info to root
    root.dict_set("info", info);

    // Encode to bencode format
    String encoded = root.encode();
    defer free(encoded);

    // Write to file
    File? f = io::file::open(output_path, "wb");
    if (catch err = f) {
        io::printfn("Error creating output file: %s", err);
        return;
    }
    defer (void)f.close();

    (void)f.write(encoded);

    io::printfn("Wrote .torrent file: %s", output_path);
}
