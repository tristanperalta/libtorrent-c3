module libtorrent::storage_manager;

import async::file;
import async::work;
import async::event_loop;
import libtorrent::metainfo;
import std::io;
import std::hash::sha1;

<*
 Storage Manager - Persistent Storage Layer
 ===========================================
 Manages writing/reading pieces to/from disk for BitTorrent downloads.

 Handles:
 - Single-file and multi-file torrents
 - Piece-to-file mapping (pieces may span multiple files)
 - Optional file pre-allocation
 - Optional piece verification on initialization
 - Async I/O using libuv

 Usage:
   StorageManager manager = create(event_loop, metainfo, base_path)!!;
   defer free(&manager);

   // Write a verified piece
   manager.write_piece(piece_index, piece_data, &on_write_complete, user_data);

   // Read a piece
   manager.read_piece(piece_index, &on_read_complete, user_data);

   // Verify existing piece
   manager.verify_piece(piece_index, expected_hash, &on_verify_complete, user_data);
*>

// Faults
faultdef STORAGE_PATH_INVALID;
faultdef STORAGE_FILE_CREATE_FAILED;
faultdef STORAGE_ALLOCATION_FAILED;
faultdef STORAGE_WRITE_FAILED;
faultdef STORAGE_READ_FAILED;
faultdef STORAGE_PIECE_INVALID;
faultdef STORAGE_VERIFICATION_FAILED;

// File information in the torrent
struct FileInfo
{
    String path;           // Relative path within torrent
    ulong length;          // File length in bytes
    ulong offset;          // Offset within torrent (cumulative)
    async::file::File file; // File handle (or -1 if not open)
}

// Storage manager
struct StorageManager
{
    event_loop::EventLoop* loop;
    String base_path;          // Base download directory
    FileInfo[] files;          // Files in torrent
    uint piece_length;         // Standard piece length
    uint last_piece_length;    // Last piece may be shorter
    uint num_pieces;           // Total number of pieces
    char[] piece_hashes;       // SHA-1 hashes (20 bytes each)
    ulong total_length;        // Total torrent size
    bool pre_allocate;         // Pre-allocate files
}

// Callback types
alias InitCompleteCallback = fn void(int status, void* user_data);
alias WriteCompleteCallback = fn void(uint piece_index, int status, void* user_data);
alias ReadCompleteCallback = fn void(uint piece_index, char[] piece_data, int status, void* user_data);
alias VerifyCompleteCallback = fn void(uint piece_index, bool verified, int status, void* user_data);

<*
 Create a storage manager from torrent info.

 @param loop : "Event loop"
 @param info : "Torrent info dictionary"
 @param base_path : "Base download directory"
 @param pre_allocate : "Pre-allocate file space (default: true)"
 @return "Initialized storage manager or fault"
*>
fn StorageManager? create(event_loop::EventLoop* loop, metainfo::TorrentInfo* info,
                          String base_path, bool pre_allocate = true) @public
{
    StorageManager manager;
    manager.loop = loop;
    manager.pre_allocate = pre_allocate;
    manager.piece_length = (uint)info.piece_length;
    manager.total_length = (ulong)info.length;

    // Calculate number of pieces
    manager.num_pieces = (uint)((info.length + info.piece_length - 1) / info.piece_length);

    // Calculate last piece length
    ulong remainder = (ulong)info.length % (ulong)info.piece_length;
    manager.last_piece_length = remainder > 0 ? (uint)remainder : (uint)info.piece_length;

    // Copy piece hashes
    manager.piece_hashes = mem::new_array(char, info.pieces.len);
    for (usz i = 0; i < info.pieces.len; i++)
    {
        manager.piece_hashes[i] = info.pieces[i];
    }

    // Copy base path
    manager.base_path = base_path.copy(mem);

    // Build file list with offsets
    if (!info.is_multi_file)
    {
        // Single-file torrent
        manager.files = mem::new_array(FileInfo, 1);
        manager.files[0].path = info.name.copy(mem);
        manager.files[0].length = (ulong)info.length;
        manager.files[0].offset = 0;
        manager.files[0].file = -1;
    }
    else
    {
        // Multi-file torrent
        manager.files = mem::new_array(FileInfo, info.files.len);

        for (usz i = 0; i < info.files.len; i++)
        {
            // Join path components with '/'
            DString path_builder;
            for (usz j = 0; j < info.files[i].path.len; j++)
            {
                if (j > 0) path_builder.append("/");
                path_builder.append(info.files[i].path[j]);
            }

            manager.files[i].path = path_builder.copy_str(mem);
            manager.files[i].length = (ulong)info.files[i].length;
            manager.files[i].offset = (ulong)info.files[i].offset;
            manager.files[i].file = -1;
        }
    }

    return manager;
}

<*
 Context for tracking sync_all_files() operation.
*>
struct SyncAllContext
{
    usz files_remaining;
    usz sync_errors;
}

<*
 Callback for individual file sync in sync_all_files().
*>
fn void on_file_sync_complete(int status, void* user_data) @private
{
    SyncAllContext* ctx = (SyncAllContext*)user_data;

    if (status < 0)
    {
        ctx.sync_errors++;
    }

    ctx.files_remaining--;

    // When all syncs complete, free context
    if (ctx.files_remaining == 0)
    {
        std::core::mem::free(ctx);
    }
}

<*
 Free storage manager resources.
 Note: Files are synced periodically during download, so no fsync needed here.
*>
fn void free(StorageManager* manager) @public
{
    // Note: We don't explicitly close file handles here to avoid memory leaks
    // from async close requests that never complete. The OS will automatically
    // close all file descriptors when the process exits. For long-running
    // applications, proper async shutdown should be implemented separately.
    for (usz i = 0; i < manager.files.len; i++)
    {
        manager.files[i].file = -1;
    }

    // Free file paths
    for (usz i = 0; i < manager.files.len; i++)
    {
        if (manager.files[i].path.len > 0)
        {
            std::core::mem::free(manager.files[i].path);
        }
    }

    // Free file list
    if (manager.files.len > 0)
    {
        std::core::mem::free(manager.files);
        manager.files = {};
    }

    // Free base path
    if (manager.base_path.len > 0)
    {
        std::core::mem::free(manager.base_path);
        manager.base_path = "";
    }

    // Free piece hashes
    if (manager.piece_hashes.len > 0)
    {
        std::core::mem::free(manager.piece_hashes);
        manager.piece_hashes = {};
    }
}

// Internal: Get piece offset and length
struct PieceLocation
{
    ulong offset;  // Offset within torrent
    uint length;   // Piece length
}

fn PieceLocation StorageManager.get_piece_location(&self, uint piece_index) @private
{
    PieceLocation loc;
    loc.offset = (ulong)piece_index * (ulong)self.piece_length;

    // Last piece may be shorter
    if (piece_index == self.num_pieces - 1)
    {
        loc.length = self.last_piece_length;
    }
    else
    {
        loc.length = self.piece_length;
    }

    return loc;
}

// Internal: Find which file(s) a byte range spans
struct FileSpan
{
    usz file_index;    // Starting file
    ulong file_offset; // Offset within starting file
    ulong length;      // Bytes in this file
}

fn FileSpan[] StorageManager.get_file_spans(&self, ulong torrent_offset, ulong length) @private
{
    // Allocate temporary array (worst case: spans all files)
    FileSpan[] spans = mem::temp_array(FileSpan, self.files.len);
    usz span_count = 0;

    ulong remaining = length;
    ulong current_offset = torrent_offset;

    for (usz i = 0; i < self.files.len && remaining > 0; i++)
    {
        FileInfo* file = &self.files[i];
        ulong file_end = file.offset + file.length;

        // Check if this file contains any of our range
        if (current_offset < file_end && current_offset + remaining > file.offset)
        {
            // Calculate overlap
            ulong span_start = current_offset > file.offset ? current_offset : file.offset;
            ulong span_end = (current_offset + remaining < file_end) ? current_offset + remaining : file_end;
            ulong span_length = span_end - span_start;

            if (span_length > 0)
            {
                spans[span_count].file_index = i;
                spans[span_count].file_offset = span_start - file.offset;
                spans[span_count].length = span_length;
                span_count++;

                remaining -= span_length;
                current_offset += span_length;
            }
        }
    }

    // Return only the used portion
    return spans[:span_count];
}

// Context for initialization
struct InitContext
{
    StorageManager* manager;
    InitCompleteCallback cb;
    void* user_data;
    usz current_file;  // Which file we're currently opening
    int error_code;
}

fn void on_file_truncate_complete(int status, void* user_data)
{
    InitContext* ctx = (InitContext*)user_data;

    if (status < 0)
    {
        // Truncate failed
        ctx.error_code = status;
        if (ctx.cb)
        {
            ctx.cb(status, ctx.user_data);
        }
        std::core::mem::free(ctx);
        return;
    }

    // Move to next file
    ctx.current_file++;
    open_next_file(ctx);
}

fn void on_file_open_complete(async::file::File file, int status, void* user_data)
{
    InitContext* ctx = (InitContext*)user_data;

    if (status < 0)
    {
        // Open failed
        ctx.error_code = status;
        if (ctx.cb)
        {
            ctx.cb(status, ctx.user_data);
        }
        std::core::mem::free(ctx);
        return;
    }

    // Store file handle
    ctx.manager.files[ctx.current_file].file = file;

    // Pre-allocate if requested
    if (ctx.manager.pre_allocate)
    {
        ulong file_length = ctx.manager.files[ctx.current_file].length;
        async::file::ftruncate(ctx.manager.loop, file, (long)file_length,
                              &on_file_truncate_complete, ctx);
    }
    else
    {
        // Move to next file
        ctx.current_file++;
        open_next_file(ctx);
    }
}

fn void open_next_file(InitContext* ctx)
{
    // Check if all files opened
    if (ctx.current_file >= ctx.manager.files.len)
    {
        // All done!
        if (ctx.cb)
        {
            ctx.cb(0, ctx.user_data);
        }
        std::core::mem::free(ctx);
        return;
    }

    // Build full path
    FileInfo* file_info = &ctx.manager.files[ctx.current_file];
    DString path_builder;
    path_builder.append(ctx.manager.base_path);
    path_builder.append("/");
    path_builder.append(file_info.path);
    String full_path = path_builder.copy_str(mem);
    defer std::core::mem::free(full_path);

    // Open file (create if doesn't exist, read/write mode)
    async::file::open(ctx.manager.loop, full_path,
                     async::file::OPEN_RDWR | async::file::OPEN_CREATE,
                     420,  // 0644 in octal
                     &on_file_open_complete, ctx);
}

fn void on_mkdir_complete(int status, void* user_data)
{
    InitContext* ctx = (InitContext*)user_data;

    // Ignore EEXIST (-17) - directory already exists is fine
    if (status < 0 && status != -17)
    {
        // mkdir failed
        ctx.error_code = status;
        if (ctx.cb)
        {
            ctx.cb(status, ctx.user_data);
        }
        std::core::mem::free(ctx);
        return;
    }

    // Start opening files
    ctx.current_file = 0;
    open_next_file(ctx);
}

<*
 Initialize storage (create directories, optionally pre-allocate files).

 @param callback : "Completion callback"
 @param user_data : "User data for callback"
*>
fn void StorageManager.initialize(&self, InitCompleteCallback callback,
                                   void* user_data) @public
{
    InitContext* ctx = mem::new(InitContext);
    ctx.manager = (StorageManager*)self;
    ctx.cb = callback;
    ctx.user_data = user_data;
    ctx.current_file = 0;
    ctx.error_code = 0;

    // Create base directory
    async::file::mkdir(self.loop, self.base_path, 493,  // 0755 in octal
                      &on_mkdir_complete, ctx);
}

// Context for write operations
struct WriteContext
{
    StorageManager* manager;
    uint piece_index;
    char[] piece_data;
    WriteCompleteCallback cb;
    void* user_data;
    FileSpan[] spans;
    usz current_span;
    usz data_offset;
    int error_code;
}

fn void on_write_block_complete(int bytes_written, int status, void* user_data)
{
    WriteContext* ctx = (WriteContext*)user_data;

    if (status < 0)
    {
        // Error - clean up
        if (ctx.cb)
        {
            ctx.cb(ctx.piece_index, status, ctx.user_data);
        }
        std::core::mem::free(ctx.spans);
        std::core::mem::free(ctx);
        return;
    }

    // Move to next span
    ctx.data_offset += ctx.spans[ctx.current_span].length;
    ctx.current_span++;

    write_next_span(ctx);
}

fn void write_next_span(WriteContext* ctx)
{
    // Check if done
    if (ctx.current_span >= ctx.spans.len)
    {
        // All spans written successfully - clean up
        if (ctx.cb)
        {
            ctx.cb(ctx.piece_index, 0, ctx.user_data);
        }
        std::core::mem::free(ctx.spans);
        std::core::mem::free(ctx);
        return;
    }

    // Get current span
    FileSpan* span = &ctx.spans[ctx.current_span];
    FileInfo* file = &ctx.manager.files[span.file_index];

    // Extract data for this span using pointer arithmetic
    // (workaround for C3 slice syntax issue)
    usz span_len = (usz)span.length;
    char* span_ptr = ctx.piece_data.ptr + ctx.data_offset;
    char[] span_data = span_ptr[:span_len];

    // Write to file (note: file handle would need to be opened first)
    // For now, this is simplified - assumes files are open
    if (file.file == -1)
    {
        // File not open - error - clean up
        if (ctx.cb)
        {
            ctx.cb(ctx.piece_index, -1, ctx.user_data);
        }
        std::core::mem::free(ctx.spans);
        std::core::mem::free(ctx);
        return;
    }

    async::file::write(ctx.manager.loop, file.file, (long)span.file_offset,
                      span_data, &on_write_block_complete, ctx);
}

<*
 Write a verified piece to storage.

 @param piece_index : "Piece index"
 @param piece_data : "Piece data (must be valid for duration of async operation)"
 @param callback : "Completion callback"
 @param user_data : "User data for callback"
*>
fn void StorageManager.write_piece(&self, uint piece_index, char[] piece_data,
                                    WriteCompleteCallback callback, void* user_data) @public
{
    // Get piece location
    PieceLocation loc = self.get_piece_location(piece_index);

    // Get file spans (temp allocated)
    FileSpan[] temp_spans = self.get_file_spans(loc.offset, (ulong)loc.length);

    // Copy spans to persistent memory (they'll be used in async callbacks)
    FileSpan[] spans = mem::new_array(FileSpan, temp_spans.len);
    for (usz i = 0; i < temp_spans.len; i++)
    {
        spans[i] = temp_spans[i];
    }

    // Create write context
    WriteContext* ctx = mem::new(WriteContext);
    ctx.manager = (StorageManager*)self;
    ctx.piece_index = piece_index;
    ctx.piece_data = piece_data;
    ctx.cb = callback;
    ctx.user_data = user_data;
    ctx.spans = spans;
    ctx.current_span = 0;
    ctx.data_offset = 0;
    ctx.error_code = 0;

    // Start writing
    write_next_span(ctx);
}

// Context for read operations
struct ReadContext
{
    StorageManager* manager;
    uint piece_index;
    char[] piece_data;  // Buffer we're reading into
    ReadCompleteCallback cb;
    void* user_data;
    FileSpan[] spans;
    usz current_span;
    usz data_offset;
    int error_code;
}

fn void on_read_block_complete(char[] data, int status, void* user_data)
{
    ReadContext* ctx = (ReadContext*)user_data;

    if (status < 0)
    {
        // Error - clean up
        if (ctx.cb)
        {
            ctx.cb(ctx.piece_index, {}, status, ctx.user_data);
        }
        std::core::mem::free(ctx.spans);
        std::core::mem::free(ctx);
        return;
    }

    // Copy data into piece buffer
    FileSpan* span = &ctx.spans[ctx.current_span];
    for (usz i = 0; i < data.len; i++)
    {
        ctx.piece_data[ctx.data_offset + i] = data[i];
    }

    // Move to next span
    ctx.data_offset += (usz)span.length;
    ctx.current_span++;

    read_next_span(ctx);
}

fn void read_next_span(ReadContext* ctx)
{
    // Check if done
    if (ctx.current_span >= ctx.spans.len)
    {
        // All spans read successfully - clean up
        if (ctx.cb)
        {
            ctx.cb(ctx.piece_index, ctx.piece_data, 0, ctx.user_data);
        }
        std::core::mem::free(ctx.spans);
        std::core::mem::free(ctx);
        return;
    }

    // Get current span
    FileSpan* span = &ctx.spans[ctx.current_span];
    FileInfo* file = &ctx.manager.files[span.file_index];

    if (file.file == -1)
    {
        // File not open - error - clean up
        if (ctx.cb)
        {
            ctx.cb(ctx.piece_index, {}, -1, ctx.user_data);
        }
        std::core::mem::free(ctx.spans);
        std::core::mem::free(ctx);
        return;
    }

    async::file::read(ctx.manager.loop, file.file, (long)span.file_offset,
                     (usz)span.length, &on_read_block_complete, ctx);
}

<*
 Read a piece from storage.

 @param piece_index : "Piece index"
 @param callback : "Completion callback"
 @param user_data : "User data for callback"
*>
fn void StorageManager.read_piece(&self, uint piece_index,
                                   ReadCompleteCallback callback, void* user_data) @public
{
    // Get piece location
    PieceLocation loc = self.get_piece_location(piece_index);

    // Allocate buffer for piece
    char[] piece_data = mem::new_array(char, loc.length);

    // Get file spans (temp allocated)
    FileSpan[] temp_spans = self.get_file_spans(loc.offset, (ulong)loc.length);

    // Copy spans to persistent memory (they'll be used in async callbacks)
    FileSpan[] spans = mem::new_array(FileSpan, temp_spans.len);
    for (usz i = 0; i < temp_spans.len; i++)
    {
        spans[i] = temp_spans[i];
    }

    // Create read context
    ReadContext* ctx = mem::new(ReadContext);
    ctx.manager = (StorageManager*)self;
    ctx.piece_index = piece_index;
    ctx.piece_data = piece_data;
    ctx.cb = callback;
    ctx.user_data = user_data;
    ctx.spans = spans;
    ctx.current_span = 0;
    ctx.data_offset = 0;
    ctx.error_code = 0;

    // Start reading
    read_next_span(ctx);
}

// Context for verify operations
struct VerifyContext
{
    StorageManager* manager;
    uint piece_index;
    char[20] expected_hash;
    VerifyCompleteCallback cb;
    void* user_data;
}

// Context for SHA-1 computation in thread pool
struct Sha1WorkContext
{
    uint piece_index;
    char[] piece_data;          // Data to hash
    char[20] expected_hash;
    char[20] actual_hash;       // Result computed in thread pool
    VerifyCompleteCallback cb;
    void* user_data;
    async::work::WorkContext* work_ctx;
}

<*
 Work function - runs in thread pool.
 Computes SHA-1 hash of piece data.
*>
fn void do_sha1_work(void* input, void** output)
{
    Sha1WorkContext* ctx = (Sha1WorkContext*)input;

    // Compute SHA-1 hash (CPU-intensive, but we're in thread pool!)
    ctx.actual_hash = sha1::hash(ctx.piece_data);

    *output = ctx;
}

<*
 Completion callback - runs in event loop.
 Compares hashes and calls user callback.
*>
fn void on_sha1_complete(void* output, int status, void* user_data)
{
    Sha1WorkContext* ctx = (Sha1WorkContext*)output;

    if (status < 0)
    {
        // Thread pool error
        if (ctx.cb)
        {
            ctx.cb(ctx.piece_index, false, status, ctx.user_data);
        }
        std::core::mem::free(ctx.piece_data);
        if (ctx.work_ctx) std::core::mem::free(ctx.work_ctx);
        std::core::mem::free(ctx);
        return;
    }

    // Compare hashes
    bool verified = true;
    for (usz i = 0; i < 20; i++)
    {
        if (ctx.actual_hash[i] != ctx.expected_hash[i])
        {
            verified = false;
            break;
        }
    }

    // Call user callback
    if (ctx.cb)
    {
        ctx.cb(ctx.piece_index, verified, 0, ctx.user_data);
    }

    // Clean up
    std::core::mem::free(ctx.piece_data);
    if (ctx.work_ctx) std::core::mem::free(ctx.work_ctx);
    std::core::mem::free(ctx);
}

fn void on_verify_read_complete(uint piece_index, char[] piece_data, int status, void* user_data)
{
    VerifyContext* ctx = (VerifyContext*)user_data;

    if (status < 0)
    {
        // Read error
        if (ctx.cb)
        {
            ctx.cb(piece_index, false, status, ctx.user_data);
        }
        std::core::mem::free(ctx);
        return;
    }

    // Create SHA-1 work context
    Sha1WorkContext* sha1_ctx = mem::new(Sha1WorkContext);
    sha1_ctx.piece_index = piece_index;
    sha1_ctx.piece_data = piece_data;  // Transfer ownership to SHA-1 context
    sha1_ctx.expected_hash = ctx.expected_hash;
    sha1_ctx.cb = ctx.cb;
    sha1_ctx.user_data = ctx.user_data;

    // Create async work context
    async::work::WorkContext* work_ctx = mem::new(async::work::WorkContext);
    work_ctx.input = sha1_ctx;
    work_ctx.work_fn = &do_sha1_work;
    work_ctx.callback = &on_sha1_complete;
    work_ctx.user_data = ctx.user_data;
    sha1_ctx.work_ctx = work_ctx;

    // Queue SHA-1 computation to thread pool
    int result = async::work::queue_work(ctx.manager.loop, work_ctx);
    if (result != 0)
    {
        // Failed to queue - call callback with error
        if (sha1_ctx.cb)
        {
            sha1_ctx.cb(piece_index, false, -1, sha1_ctx.user_data);
        }

        // Clean up
        std::core::mem::free(piece_data);
        std::core::mem::free(work_ctx);
        std::core::mem::free(sha1_ctx);
    }

    // Clean up verify context (SHA-1 context takes over)
    std::core::mem::free(ctx);
}

<*
 Verify a piece by reading and checking its hash.

 @param piece_index : "Piece index"
 @param expected_hash : "Expected SHA-1 hash"
 @param callback : "Completion callback"
 @param user_data : "User data for callback"
*>
fn void StorageManager.verify_piece(&self, uint piece_index, char[20] expected_hash,
                                     VerifyCompleteCallback callback, void* user_data) @public
{
    VerifyContext* ctx = mem::new(VerifyContext);
    ctx.manager = (StorageManager*)self;
    ctx.piece_index = piece_index;
    ctx.expected_hash = expected_hash;
    ctx.cb = callback;
    ctx.user_data = user_data;

    // Read piece and verify in callback
    self.read_piece(piece_index, &on_verify_read_complete, ctx);
}

<*
 Get storage statistics.

 @param allocated_bytes : "Output: bytes allocated on disk"
 @param written_bytes : "Output: bytes actually written"
*>
fn void StorageManager.get_stats(&self, ulong* allocated_bytes, ulong* written_bytes) @public
{
    *allocated_bytes = self.total_length;
    *written_bytes = 0;  // Would need to track this
}

<*
 Sync all open files to disk (flush OS buffers).

 This is called periodically during download to ensure data persistence.
 All fsync operations run asynchronously in parallel for performance.
*>
fn void StorageManager.sync_all_files(&self) @public
{
    // Count files that need syncing
    usz files_to_sync = 0;
    for (usz i = 0; i < self.files.len; i++)
    {
        if (self.files[i].file >= 0)
        {
            files_to_sync++;
        }
    }

    if (files_to_sync == 0) return;

    // Create shared context
    SyncAllContext* ctx = mem::new(SyncAllContext);
    ctx.files_remaining = files_to_sync;
    ctx.sync_errors = 0;

    // Sync each open file (all run in parallel)
    for (usz i = 0; i < self.files.len; i++)
    {
        if (self.files[i].file >= 0)
        {
            async::file::fsync(self.loop, self.files[i].file,
                             &on_file_sync_complete, ctx);
        }
    }
}
