module torrent_client::log_outputs;

import libtorrent::logger;
import std::io;

// ============================================================================
// Log Output Implementations (CLI Only)
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

// ============================================================================
// Log Setup Helpers
// ============================================================================

<*
 Create log sink for console logging (file and/or stderr).

 Sets up logging to file and/or stderr based on parameters and
 registers the logger callback.

 @param log_file_path : "Path to log file (empty string = no file logging)"
 @param debug_mode : "Enable stderr logging"
 @return "Configured log sink or null if no outputs (caller must free outputs and individual output structs)"
*>
fn LogSink*? setup_console_logging(String log_file_path, bool debug_mode) @public
{
    // Count outputs
    usz num_outputs = 0;
    if (log_file_path.len > 0) num_outputs++;
    if (debug_mode) num_outputs++;

    if (num_outputs == 0)
    {
        return null;  // No logging requested
    }

    LogSink* sink = mem::new(LogSink);
    sink.outputs = mem::new_array(logger::LogOutput, num_outputs);
    usz output_idx = 0;

    // Add file output if requested
    if (log_file_path.len > 0)
    {
        FileLogOutput* file_out = mem::new(FileLogOutput);
        file_out.file = file::open(log_file_path, "w")!!;
        file_out.is_open = true;
        sink.outputs[output_idx] = file_out;
        output_idx++;
        io::printfn("Logging to file: %s", log_file_path);
    }

    // Add stderr output if requested
    if (debug_mode)
    {
        StderrLogOutput* stderr_out = mem::new(StderrLogOutput);
        sink.outputs[output_idx] = stderr_out;
        io::printfn("Debug logging to stderr enabled");
    }

    logger::set_log_callback(&on_log_message, sink);
    return sink;
}

<*
 Cleanup log sink resources.

 Closes all outputs and frees the sink structure.
 Call this before program exit.

 @param sink : "Log sink to cleanup (can be null)"
*>
fn void cleanup_log_sink(LogSink* sink) @public
{
    if (!sink) return;

    // Close all outputs
    foreach (output : sink.outputs)
    {
        output.close();
    }

    // Free outputs array
    if (sink.outputs.len > 0)
    {
        free(sink.outputs);
    }

    // Free sink
    free(sink);
}
