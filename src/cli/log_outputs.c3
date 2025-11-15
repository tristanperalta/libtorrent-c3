module torrent_client::log_outputs;

import std::core::log;
import std::io;

// ============================================================================
// Log Output Implementations (CLI Only) - Using std::core::log
// ============================================================================

<*
 File Log Output - Writes log messages to a file.
*>
struct FileLogger (log::Logger)
{
    std::io::File file;
    bool is_open;
}

fn void FileLogger.log(&self, log::LogPriority priority, log::LogCategory category, log::LogTag tag, String file, String function, int line, String fmt, any[] args) @dynamic
{
    if (self.is_open)
    {
        DString buf;
        buf.appendf("[%s] ", priority);
        buf.appendf(fmt, ...args);
        buf.append_char('\n');
        self.file.write(buf.str_view())!!;
        self.file.flush()!!;  // Ensure logs are written immediately
    }
}

<*
 Stderr Log Output - Writes log messages to stderr.
*>
struct StderrLogger (log::Logger)
{
    char _dummy;  // C3 doesn't allow zero-sized structs
}

fn void StderrLogger.log(&self, log::LogPriority priority, log::LogCategory category, log::LogTag tag, String file, String function, int line, String fmt, any[] args) @dynamic
{
    DString buf;
    buf.appendf(fmt, ...args);
    io::eprintfn("[%s] %s", priority, buf.str_view());
}

// ============================================================================
// Log Setup Helpers
// ============================================================================

<*
 Create logger for console logging (file and/or stderr).

 Sets up logging to file and/or stderr based on parameters.

 @param log_file_path : "Path to log file (empty string = no file logging)"
 @param debug_mode : "Enable stderr logging"
 @return "Configured logger or null if no outputs"
*>
fn log::Logger? setup_console_logging(String log_file_path, bool debug_mode) @public
{
    // Count outputs
    usz num_outputs = 0;
    if (log_file_path.len > 0) num_outputs++;
    if (debug_mode) num_outputs++;

    if (num_outputs == 0)
    {
        return null;  // No logging requested
    }

    if (num_outputs == 1)
    {
        // Single logger
        if (log_file_path.len > 0)
        {
            FileLogger* file_logger = mem::new(FileLogger);
            file_logger.file = file::open(log_file_path, "w")!!;
            file_logger.is_open = true;
            io::printfn("Logging to file: %s", log_file_path);
            return file_logger;
        }
        else
        {
            StderrLogger* stderr_logger = mem::new(StderrLogger);
            io::printfn("Debug logging to stderr enabled");
            return stderr_logger;
        }
    }

    // Multiple loggers - use MultiLogger
    log::MultiLogger* multi = mem::new(log::MultiLogger);
    multi.loggers = mem::new_array(log::Logger, num_outputs);
    usz idx = 0;

    if (log_file_path.len > 0)
    {
        FileLogger* file_logger = mem::new(FileLogger);
        file_logger.file = file::open(log_file_path, "w")!!;
        file_logger.is_open = true;
        multi.loggers[idx++] = file_logger;
        io::printfn("Logging to file: %s", log_file_path);
    }

    if (debug_mode)
    {
        StderrLogger* stderr_logger = mem::new(StderrLogger);
        multi.loggers[idx] = stderr_logger;
        io::printfn("Debug logging to stderr enabled");
    }

    return multi;
}
