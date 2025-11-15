module torrent_client::log_outputs;

import std::core::log;
import raylib_gui;

// ============================================================================
// GUI Log Output Implementation - Using std::core::log
// ============================================================================

<*
 GUI Log Output - Writes log messages to the raylib GUI.
*>
struct GuiLogger (log::Logger)
{
    raylib_gui::UIState* ui;
}

fn void GuiLogger.log(&self, log::LogPriority priority, log::LogCategory category, log::LogTag tag, String file, String function, int line, String fmt, any[] args) @dynamic
{
    if (self.ui)
    {
        // Format message with level prefix
        DString formatted;
        formatted.appendf("[%s] ", priority);
        formatted.appendf(fmt, ...args);
        raylib_gui::add_log(self.ui, formatted.str_view());
    }
}

// ============================================================================
// Log Setup Helpers
// ============================================================================

<*
 Create logger for GUI logging.

 Sets up logging to the raylib GUI interface.

 @param ui : "GUI state"
 @return "Configured GUI logger"
*>
fn log::Logger setup_gui_logging(raylib_gui::UIState* ui) @public
{
    GuiLogger* gui_logger = mem::new(GuiLogger);
    gui_logger.ui = ui;
    return gui_logger;
}
