module libtorrent::logger;

import std::io;
import std::collections::list;

// Logger - Async Non-Blocking Logging for Library
// ===============================================
// Provides a message queue-based logging system that doesn't block the event loop.
// Messages are enqueued immediately and flushed periodically on event loop ticks.
//
// Usage:
//   // In application (e.g., main.c3):
//   logger::set_log_callback(&my_log_handler);
//
//   fn void my_log_handler(logger::LogLevel level, String message, void* user_data) {
//       // Handle log message (write to file, stderr, etc.)
//   }
//
//   // In event loop (e.g., progress timer):
//   logger::flush_logs();  // Drain queue and invoke callback
//
//   // In library code:
//   logger::log(logger::LogLevel.ERROR, "Failed to connect");
//   logger::logf(logger::LogLevel.INFO, "Connected to %s:%d", ip, port);

// Log levels
enum LogLevel : char
{
    ERROR,   // Critical errors
    WARN,    // Warnings
    INFO,    // Informational messages
    DEBUG    // Debug/verbose messages
}

// LogOutput Interface - Polymorphic log destination.
//
// Implement this interface to create custom log outputs (file, network, etc.).
// Multiple outputs can be registered to receive the same log messages.
interface LogOutput
{
    fn void write_log(LogLevel level, String message);
    fn void close();
}

// Queued log message
struct LogMessage
{
    LogLevel level;
    char[] message;  // Heap-allocated copy
}

// Log callback type
alias LogCallback = fn void(LogLevel level, String message, void* user_data);

// Global logger state
struct Logger
{
    LogMessage[] queue;
    usz queue_size;
    usz queue_capacity;
    LogCallback callback;
    void* user_data;
    bool has_callback;
}

// Global logger instance
Logger g_logger;

const usz INITIAL_QUEUE_CAPACITY = 100;

// Initialize the logger (called automatically on first use).
fn void init()
{
    if (g_logger.queue_capacity > 0) return;  // Already initialized

    g_logger.queue = mem::new_array(LogMessage, INITIAL_QUEUE_CAPACITY);
    g_logger.queue_size = 0;
    g_logger.queue_capacity = INITIAL_QUEUE_CAPACITY;
    g_logger.has_callback = false;
}

// Set the log callback function.
//
// @param callback : "Function to call for log messages during flush"
// @param user_data : "User data passed to callback"
fn void set_log_callback(LogCallback callback, void* user_data) @public
{
    init();
    g_logger.callback = callback;
    g_logger.user_data = user_data;
    g_logger.has_callback = true;
}

// Clear the log callback (disables logging).
fn void clear_log_callback() @public
{
    g_logger.has_callback = false;
}

// Enqueue a log message (non-blocking, async-safe).
//
// The message is copied to the heap and queued for later flushing.
//
// @param level : "Log level"
// @param message : "Message to log"
fn void log(LogLevel level, String message) @public
{
    init();

    if (!g_logger.has_callback) return;  // No callback, skip

    // Grow queue if needed
    if (g_logger.queue_size >= g_logger.queue_capacity)
    {
        usz new_capacity = g_logger.queue_capacity * 2;
        LogMessage[] new_queue = mem::new_array(LogMessage, new_capacity);

        // Copy existing messages
        for (usz i = 0; i < g_logger.queue_size; i++)
        {
            new_queue[i] = g_logger.queue[i];
        }

        free(g_logger.queue);
        g_logger.queue = new_queue;
        g_logger.queue_capacity = new_capacity;
    }

    // Copy message to heap with null terminator
    // IMPORTANT: Must copy AND sanitize to remove non-printable characters
    usz copy_len = message.len;
    char[] heap_copy = mem::new_array(char, copy_len + 1);

    // Copy message content, sanitizing non-printable characters
    for (usz i = 0; i < copy_len; i++)
    {
        char c = message[i];
        // Only allow printable ASCII (32-126), newline (10), and tab (9)
        if ((c >= 32 && c <= 126) || c == '\n' || c == '\t')
        {
            heap_copy[i] = c;
        }
        else
        {
            heap_copy[i] = '?';  // Replace non-printable with ?
        }
    }
    heap_copy[copy_len] = 0;  // Null terminate

    // Store the message as a slice (length without null terminator)
    char[] stored_message = heap_copy[0..copy_len];

    // Add to queue
    g_logger.queue[g_logger.queue_size].level = level;
    g_logger.queue[g_logger.queue_size].message = stored_message;
    g_logger.queue_size++;
}

// Enqueue a formatted log message (convenience macro).
//
// @param level : "Log level"
// @param format : "Printf-style format string"
// @param args : "Format arguments"
macro void logf(LogLevel level, String format, args...) @public
{
    DString buf;
    buf.appendf(format, args);
    // IMPORTANT: Use copy_str(mem) to create persistent heap copy
    // str_view() returns a view into temp-allocated memory that becomes invalid
    String heap_str = buf.copy_str(mem);
    defer free(heap_str);
    log(level, heap_str);
}

// Flush all queued log messages to the callback.
//
// This should be called periodically from the event loop (e.g., every 100-500ms).
// It drains the queue and invokes the callback for each message.
fn void flush_logs() @public
{
    if (!g_logger.has_callback || g_logger.queue_size == 0) return;

    // Process all queued messages
    for (usz i = 0; i < g_logger.queue_size; i++)
    {
        LogMessage* msg = &g_logger.queue[i];
        String msg_str = (String)msg.message;
        g_logger.callback(msg.level, msg_str, g_logger.user_data);

        // Free the heap-allocated message
        free(msg.message);
    }

    // Reset queue
    g_logger.queue_size = 0;
}

// Convert log level to string representation.
//
// @param level : "Log level"
// @return "String representation"
fn String level_to_string(LogLevel level) @public
{
    switch (level)
    {
        case LogLevel.ERROR: return "ERROR";
        case LogLevel.WARN:  return "WARN";
        case LogLevel.INFO:  return "INFO";
        case LogLevel.DEBUG: return "DEBUG";
    }
    return "UNKNOWN";
}

// Free logger resources (called on shutdown).
fn void free_logger() @public
{
    // Free any remaining queued messages
    for (usz i = 0; i < g_logger.queue_size; i++)
    {
        free(g_logger.queue[i].message);
    }

    if (g_logger.queue_capacity > 0)
    {
        free(g_logger.queue);
        g_logger.queue = {};  // Reset to empty slice
        g_logger.queue_capacity = 0;
        g_logger.queue_size = 0;
    }
}
