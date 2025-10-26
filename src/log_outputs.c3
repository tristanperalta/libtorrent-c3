module torrent_client::log_outputs;

import libtorrent::logger;
import std::io;

// ============================================================================
// Log Output Implementations
// ============================================================================

<*
 File Log Output - Writes log messages to a file.
*>
struct FileLogOutput (logger::LogOutput)
{
    std::io::File file;
    bool is_open;
}

fn void FileLogOutput.write_log(FileLogOutput* self, logger::LogLevel level, String message) @dynamic
{
    if (self.is_open)
    {
        DString buf;
        buf.appendf("[%s] %s\n", logger::level_to_string(level), message);
        self.file.write(buf.str_view())!!;
        self.file.flush()!!;  // Ensure logs are written immediately
    }
}

fn void FileLogOutput.close(FileLogOutput* self) @dynamic
{
    if (self.is_open)
    {
        self.file.close()!!;
        self.is_open = false;
    }
}

<*
 Stderr Log Output - Writes log messages to stderr.
*>
struct StderrLogOutput (logger::LogOutput)
{
    char _dummy;  // C3 doesn't allow zero-sized structs
}

fn void StderrLogOutput.write_log(StderrLogOutput* self, logger::LogLevel level, String message) @dynamic
{
    io::eprintfn("[%s] %s", logger::level_to_string(level), message);
}

fn void StderrLogOutput.close(StderrLogOutput* self) @dynamic
{
    // No cleanup needed for stderr
}

<*
 Log sink configuration for routing log messages to multiple destinations.
*>
struct LogSink
{
    logger::LogOutput[] outputs;  // Array of log output interfaces
}

<*
 Log callback - routes library log messages to all registered outputs.

 @param level : "Log level"
 @param message : "Log message"
 @param user_data : "LogSink pointer"
*>
fn void on_log_message(logger::LogLevel level, String message, void* user_data) @public
{
    LogSink* sink = (LogSink*)user_data;

    // Write to all registered log outputs
    foreach (output : sink.outputs)
    {
        output.write_log(level, message);
    }
}
