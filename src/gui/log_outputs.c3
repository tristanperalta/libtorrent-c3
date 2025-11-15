module torrent_client::log_outputs;

import libtorrent::logger;
import raylib_gui;

// ============================================================================
// GUI Log Output Implementation
// ============================================================================

<*
 GUI Log Output - Writes log messages to the raylib GUI.
*>
struct GuiLogOutput (logger::LogOutput)
{
    raylib_gui::UIState* ui;
}

fn void GuiLogOutput.write_log(GuiLogOutput* self, logger::LogLevel level, String message) @dynamic
{
    if (self.ui)
    {
        // Format message with level prefix
        DString formatted;
        formatted.appendf("[%s] %s", logger::level_to_string(level), message);
        raylib_gui::add_log(self.ui, formatted.str_view());
    }
}

fn void GuiLogOutput.close(GuiLogOutput* self) @dynamic
{
    // Free the GUI output struct
    free(self);
}

<*
 Log sink configuration for routing log messages to GUI.
*>
struct LogSink
{
    logger::LogOutput[] outputs;  // Array of log output interfaces
}

<*
 Log callback - routes library log messages to GUI.

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
 Create log sink for GUI logging.

 Sets up logging to the raylib GUI interface and registers
 the logger callback.

 @param ui : "GUI state"
 @return "Configured log sink (caller must free outputs array)"
*>
fn LogSink* setup_gui_logging(raylib_gui::UIState* ui) @public
{
    LogSink* sink = mem::new(LogSink);
    GuiLogOutput* gui_out = mem::new(GuiLogOutput);
    gui_out.ui = ui;

    sink.outputs = mem::new_array(logger::LogOutput, 1);
    sink.outputs[0] = gui_out;

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
