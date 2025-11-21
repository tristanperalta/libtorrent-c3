module libtorrent::resolve_links;

import std::io;
import std::collections::list;
import libtorrent::metainfo;
import libtorrent::common;

<*
 BEP 38: Swarm Metadata - File Reuse via Piece Hash Comparison

 This module implements the core file matching algorithm for BEP 38 Phase 2.
 It compares piece hashes between a new torrent and existing torrents to find
 files that can be reused (via hard link or copy).

 Algorithm:
 1. Filter by piece length (must match)
 2. For each target file, find source file with same size
 3. Compare piece hashes piece-by-piece
 4. If all pieces match → record FileMatch

 Based on libtorrent-rasterbar's resolve_links implementation (session-based).
*>

faultdef RESOLVE_LINKS_INVALID_PIECE_LENGTH;
faultdef RESOLVE_LINKS_NO_FILES;

/**
 * Represents a file that can be reused from an existing torrent.
 */
struct FileMatch
{
    usz file_index;         // Index in target torrent's files array
    String source_path;     // Full path to existing file on disk
    usz first_piece;        // First piece index of this file in target torrent
    usz piece_count;        // Number of pieces this file spans
}

/**
 * Manages file matching between a target torrent and existing source torrents.
 */
struct ResolveLinks
{
    metainfo::TorrentFile* target;  // New torrent being added
    List{FileMatch} matches;        // Files that can be reused
}

/**
 * Create a new ResolveLinks instance for a target torrent.
 *
 * @param target The new torrent being added
 * @return Initialized ResolveLinks instance
 */
fn ResolveLinks create(metainfo::TorrentFile* target) @public
{
    ResolveLinks links;
    links.target = target;
    links.matches.init(mem);
    return links;
}

/**
 * Free all resources used by ResolveLinks.
 */
fn void ResolveLinks.free(&self) @public
{
    // Free all source_path strings in matches
    foreach (match : self.matches)
    {
        free(match.source_path);
    }

    self.matches.free();
}

/**
 * Calculate which pieces a file spans in a torrent.
 *
 * @param file_offset Byte offset of file in torrent
 * @param file_length Length of file in bytes
 * @param piece_length Piece length of torrent
 * @param first_piece Output: index of first piece
 * @param piece_count Output: number of pieces spanned
 */
fn void calculate_file_pieces(
    long file_offset,
    long file_length,
    long piece_length,
    usz* first_piece,
    usz* piece_count
) @private
{
    // Empty files don't span any pieces
    if (file_length == 0)
    {
        *first_piece = 0;
        *piece_count = 0;
        return;
    }

    // First piece: floor(offset / piece_length)
    *first_piece = (usz)(file_offset / piece_length);

    // Last piece: floor((offset + length - 1) / piece_length)
    usz last_piece = (usz)((file_offset + file_length - 1) / piece_length);

    // Piece count: last - first + 1
    *piece_count = last_piece - *first_piece + 1;
}

/**
 * Compare piece hashes between source and target torrents.
 *
 * @param source Source torrent with known-good data
 * @param target Target torrent to verify
 * @param first_piece First piece index to compare
 * @param piece_count Number of pieces to compare
 * @return true if all hashes match, false otherwise
 */
fn bool compare_piece_hashes(
    metainfo::TorrentFile* source,
    metainfo::TorrentFile* target,
    usz first_piece,
    usz piece_count
) @private
{
    // Get total piece counts for validation
    usz source_num_pieces = source.get_num_pieces();
    usz target_num_pieces = target.get_num_pieces();

    // Validate piece range is within bounds for both torrents
    if (first_piece + piece_count > source_num_pieces ||
        first_piece + piece_count > target_num_pieces)
    {
        return false;
    }

    // Compare each piece hash
    for (usz i = 0; i < piece_count; i++)
    {
        usz piece_idx = first_piece + i;

        // Get piece hash offsets directly from pieces array
        usz source_offset = piece_idx * common::SHA1_HASH_SIZE;
        usz target_offset = piece_idx * common::SHA1_HASH_SIZE;

        // Compare hashes byte-by-byte directly from pieces arrays
        for (usz j = 0; j < common::SHA1_HASH_SIZE; j++)
        {
            if (source.info.pieces[source_offset + j] != target.info.pieces[target_offset + j])
            {
                io::printfn("  Piece %d hash mismatch at byte %d: %d != %d",
                    piece_idx, j,
                    source.info.pieces[source_offset + j],
                    target.info.pieces[target_offset + j]);
                return false;  // Mismatch - file is different
            }
        }
    }

    return true;  // All pieces match!
}

/**
 * Build full file path from torrent name and file entry.
 *
 * @param base_path Base directory where torrent is stored
 * @param file FileEntry with path components
 * @return Full path string (heap allocated - caller must free)
 */
fn String build_file_path(String base_path, metainfo::FileEntry* file) @private => @pool()
{
    DString path;
    path.append(base_path);

    // Ensure base_path ends with separator
    if (!base_path.ends_with("/"))
    {
        path.append("/");
    }

    // Add each path component
    foreach (i, component : file.path)
    {
        if (i > 0) path.append("/");
        path.append(component);
    }

    return path.copy_str(mem);  // Caller must free
}

/**
 * Try to match a single source file against target torrent files.
 *
 * @param source_torrent Source torrent with existing files
 * @param source_base_path Base directory where source torrent is stored
 * @param source_file_idx Index of source file to match
 * @return void? - Success or fault if matching fails
 */
fn void? ResolveLinks.match_file(
    &self,
    metainfo::TorrentFile* source_torrent,
    String source_base_path,
    usz source_file_idx
) @public
{
    // Validate piece lengths match
    if (source_torrent.info.piece_length != self.target.info.piece_length)
    {
        return RESOLVE_LINKS_INVALID_PIECE_LENGTH?;
    }

    // Get source file
    metainfo::FileEntry* source_file;
    if (source_torrent.info.is_multi_file)
    {
        if (source_file_idx >= source_torrent.info.files.len)
        {
            return RESOLVE_LINKS_NO_FILES?;
        }
        source_file = &source_torrent.info.files[source_file_idx];
    }
    else
    {
        // Single-file torrent - use synthetic FileEntry
        // TODO: Handle single-file torrents properly
        return RESOLVE_LINKS_NO_FILES?;
    }

    // Calculate pieces for source file
    usz source_first_piece;
    usz source_piece_count;
    calculate_file_pieces(
        source_file.offset,
        source_file.length,
        source_torrent.info.piece_length,
        &source_first_piece,
        &source_piece_count
    );

    // Skip empty files
    if (source_piece_count == 0) return;

    // Try to match against each target file with same size
    if (self.target.info.is_multi_file)
    {
        foreach (target_idx, target_file : self.target.info.files)
        {
            // Size must match exactly
            if (target_file.length != source_file.length) continue;

            // Skip files already matched
            bool already_matched = false;
            foreach (match : self.matches)
            {
                if (match.file_index == target_idx)
                {
                    already_matched = true;
                    break;
                }
            }
            if (already_matched) continue;

            // Calculate pieces for target file
            usz target_first_piece;
            usz target_piece_count;
            calculate_file_pieces(
                target_file.offset,
                target_file.length,
                self.target.info.piece_length,
                &target_first_piece,
                &target_piece_count
            );

            // Piece counts must match (same size + same piece_length = same piece count)
            if (target_piece_count != source_piece_count) continue;

            // Compare piece hashes
            if (compare_piece_hashes(
                source_torrent,
                self.target,
                source_first_piece,
                source_piece_count
            ))
            {
                // Match found! Record it
                FileMatch match;
                match.file_index = target_idx;
                match.source_path = build_file_path(source_base_path, source_file);
                match.first_piece = target_first_piece;
                match.piece_count = target_piece_count;

                self.matches.push(match);

                io::printfn("✓ File match: target[%d] = source[%d] (%d pieces)",
                    target_idx, source_file_idx, target_piece_count);

                // Don't break - theoretically multiple target files could match
                // (though this would be unusual)
            }
        }
    }
}

/**
 * Try to match all files from a source torrent against target files.
 *
 * @param source_torrent Source torrent with existing files
 * @param source_base_path Base directory where source torrent is stored
 */
fn void ResolveLinks.match_torrent(
    &self,
    metainfo::TorrentFile* source_torrent,
    String source_base_path
) @public
{
    // Validate piece lengths match
    if (source_torrent.info.piece_length != self.target.info.piece_length)
    {
        io::printfn("⚠ Skipping torrent: piece length mismatch (%d != %d)",
            source_torrent.info.piece_length,
            self.target.info.piece_length);
        return;
    }

    // Try to match each source file
    if (source_torrent.info.is_multi_file)
    {
        foreach (i, source_file : source_torrent.info.files)
        {
            // Ignore faults - just skip files that can't be matched
            (void)self.match_file(source_torrent, source_base_path, i);
        }
    }
    else
    {
        // Single-file torrent
        // TODO: Implement single-file matching
        io::printfn("⚠ Single-file source torrents not yet supported");
    }
}

/**
 * Get the list of matched files.
 *
 * @return Array view of FileMatch structs
 */
fn FileMatch[] ResolveLinks.get_matches(&self) @public
{
    return self.matches.array_view();
}

/**
 * Get the number of matched files.
 */
fn usz ResolveLinks.get_match_count(&self) @public
{
    return self.matches.len();
}
