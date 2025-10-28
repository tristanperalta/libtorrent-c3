module libtorrent::torrent_loader;

import uv;
import async::file;
import async::event_loop;
import std::io;
import libtorrent::metainfo;

<*
 Torrent File Loader
 ===================
 Provides async loading of .torrent files from disk.

 Chains async file operations: stat → open → read → close

 Usage:
   load_file_async(loop, "ubuntu.torrent", &on_load_complete, user_data);

   // In on_load_complete callback:
   fn void on_load_complete(String data, int status, void* user_data)
   {
       if (status != 0) {
           io::eprintfn("Failed to load file");
           return;
       }
       // Use data...
       defer free(data);
   }
*>

// Faults
faultdef TORRENT_LOAD_STAT_FAILED;
faultdef TORRENT_LOAD_OPEN_FAILED;
faultdef TORRENT_LOAD_READ_FAILED;
faultdef TORRENT_LOAD_CLOSE_FAILED;

// Callback type for user code
alias LoadCompleteCallback = fn void(String data, int status, void* user_data);

// Context for the entire load operation
struct LoadContext
{
    event_loop::EventLoop* loop;
    String path;
    LoadCompleteCallback cb;
    void* user_data;
    async::file::File file;
    char[] file_data;
    long file_size;
}

<*
 stat() callback - got file size, now open file.
*>
fn void on_stat_complete(uv::FileStat* stat, int status, void* user_data)
{
    LoadContext* ctx = (LoadContext*)user_data;

    if (status < 0)
    {
        // stat failed
        if (ctx.cb)
        {
            ctx.cb("", status, ctx.user_data);
        }
        std::core::mem::free(ctx.path);
        std::core::mem::free(ctx);
        return;
    }

    // Store file size
    ctx.file_size = (long)stat.st_size;

    // Open file for reading
    async::file::open(ctx.loop, ctx.path, async::file::OPEN_RDONLY, 0,
                     &on_open_complete, ctx);
}

<*
 open() callback - file opened, now read contents.
*>
fn void on_open_complete(async::file::File file, int status, void* user_data)
{
    LoadContext* ctx = (LoadContext*)user_data;

    if (status < 0)
    {
        // open failed
        if (ctx.cb)
        {
            ctx.cb("", status, ctx.user_data);
        }
        std::core::mem::free(ctx.path);
        std::core::mem::free(ctx);
        return;
    }

    // Store file handle
    ctx.file = file;

    // Read entire file (offset 0, size from stat)
    async::file::read(ctx.loop, file, 0, (usz)ctx.file_size,
                     &on_read_complete, ctx);
}

<*
 read() callback - data read, now close file.
*>
fn void on_read_complete(char[] data, int status, void* user_data)
{
    LoadContext* ctx = (LoadContext*)user_data;

    if (status < 0)
    {
        // read failed - close file before cleanup
        if (ctx.cb)
        {
            ctx.cb("", status, ctx.user_data);
        }
        async::file::close(ctx.loop, ctx.file, null, null);
        std::core::mem::free(ctx.path);
        std::core::mem::free(ctx);
        return;
    }

    // Copy the data (async_file will free the buffer after this callback)
    ctx.file_data = mem::new_array(char, data.len);
    for (usz i = 0; i < data.len; i++)
    {
        ctx.file_data[i] = data[i];
    }

    // Close file
    async::file::close(ctx.loop, ctx.file, &on_close_complete, ctx);
}

<*
 close() callback - file closed, call user callback with data.
*>
fn void on_close_complete(int status, void* user_data)
{
    LoadContext* ctx = (LoadContext*)user_data;

    // Ignore close errors - we have the data

    // Call user callback with the loaded data
    if (ctx.cb)
    {
        String data = (String)ctx.file_data;
        ctx.cb(data, 0, ctx.user_data);  // status = 0 (success)
    }
    else
    {
        // No callback - free the data
        if (ctx.file_data.len > 0)
        {
            std::core::mem::free(ctx.file_data);
        }
    }

    // Clean up context
    std::core::mem::free(ctx.path);
    std::core::mem::free(ctx);
}

<*
 Load a torrent file asynchronously.

 Chains: stat → open → read → close

 @param loop : "Event loop"
 @param path : "Path to .torrent file"
 @param callback : "Completion callback with file data"
 @param user_data : "User data passed to callback"
*>
fn void load_file_async(event_loop::EventLoop* loop, String path,
                        LoadCompleteCallback callback, void* user_data) @public
{
    LoadContext* ctx = mem::new(LoadContext);
    ctx.loop = loop;
    ctx.path = path.copy(mem);  // Copy path since it may be temporary
    ctx.cb = callback;
    ctx.user_data = user_data;
    ctx.file = -1;
    ctx.file_data = {};
    ctx.file_size = 0;

    // Start by getting file size
    async::file::stat(loop, path, &on_stat_complete, ctx);
}

<*
 Load and parse a torrent file synchronously.

 Reads the file from disk and parses it into a TorrentFile structure.
 The caller is responsible for freeing the returned TorrentFile.

 @param path : "Path to .torrent file"
 @return "Parsed torrent file or fault on error"
*>
fn metainfo::TorrentFile*? load_torrent_sync(String path) @public
{
    // Open file for reading
    std::io::File file = std::io::file::open(path, "rb")!;
    defer (void)file.close();

    // Get file size
    usz file_size = (usz)file.seek(0, std::io::Seek.END)!;

    // Seek back to start
    file.seek(0, std::io::Seek.SET)!;

    // Read entire file
    char[] data = mem::new_array(char, file_size);
    defer free(data);

    usz bytes_read = (usz)file.read(data)!;

    if (bytes_read != file_size)
    {
        return TORRENT_LOAD_READ_FAILED?;
    }

    // Parse torrent file
    return metainfo::parse((String)data);
}
