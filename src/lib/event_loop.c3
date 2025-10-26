module libtorrent::event_loop;

import uv;
import std::io;
import libtorrent::logger;

<*
 Event Loop Wrapper for libuv
 =============================
 Provides an idiomatic C3 interface for libuv's event loop.

 The event loop is the core of async I/O in libuv. It runs callbacks
 when I/O operations complete, timers expire, etc.

 Usage:
   EventLoop? loop = event_loop::create();
   defer loop.free();

   // Add handles (TCP sockets, timers, etc.) to the loop

   loop.run();  // Blocks until no more events
*>

// Faults
faultdef EVENT_LOOP_INIT_FAILED;
faultdef EVENT_LOOP_RUN_FAILED;
faultdef EVENT_LOOP_CLOSE_FAILED;
faultdef EVENT_LOOP_STILL_ACTIVE;

<*
 Event loop wrapper.
 Manages libuv event loop lifecycle.
*>
struct EventLoop
{
    uv::Loop* loop;
}

<*
 Create and initialize an event loop.
*>
fn EventLoop? create() @public
{
    // Allocate loop structure
    usz loop_size = uv::loop_size();
    uv::Loop* loop = mem::new_array(char, loop_size);

    // Initialize the loop
    int result = uv::loop_init(loop);
    if (result != 0)
    {
        free(loop);
        logger::logf(logger::LogLevel.ERROR, "Failed to initialize event loop: %s", (ZString)uv::strerror(result));
        return EVENT_LOOP_INIT_FAILED?;
    }

    return (EventLoop){ loop };
}

<*
 Run the event loop until there are no more active handles.
 This blocks until all async operations complete.
*>
fn void? EventLoop.run(&self) @public
{
    int result = uv::run(self.loop, uv::RunMode.DEFAULT);
    uv::@uv_check(result, "Event loop run failed", EVENT_LOOP_RUN_FAILED)!;
}

<*
 Run the event loop in non-blocking mode (process pending events only).
 Returns true if there are still active handles, false otherwise.
*>
fn bool EventLoop.run_nowait(&self) @public
{
    int result = uv::run(self.loop, uv::RunMode.NOWAIT);
    return uv::loop_alive(self.loop) != 0;
}

<*
 Run the event loop once (process one event).
 Returns true if there are still active handles, false otherwise.
*>
fn bool EventLoop.run_once(&self) @public
{
    uv::run(self.loop, uv::RunMode.ONCE);
    return uv::loop_alive(self.loop) != 0;
}

<*
 Stop the event loop.
 Causes run() to return at the earliest safe point.
*>
fn void EventLoop.stop(&self) @public
{
    uv::stop(self.loop);
}

<*
 Check if the event loop has active handles or requests.
 Returns true if there are active operations, false otherwise.
*>
fn bool EventLoop.is_alive(&self) @public
{
    return uv::loop_alive(self.loop) != 0;
}

<*
 Close and free the event loop.
 All handles must be closed before calling this.
*>
fn void? EventLoop.close(&self) @public
{
    int result = uv::loop_close(self.loop);
    if (result != 0)
    {
        logger::logf(logger::LogLevel.ERROR, "Failed to close event loop: %s", (ZString)uv::strerror(result));
        if (result == -16)  // UV_EBUSY
        {
            return EVENT_LOOP_STILL_ACTIVE?;
        }
        return EVENT_LOOP_CLOSE_FAILED?;
    }
}

<*
 Free the event loop (close and deallocate).
 This is the main cleanup method.
*>
fn void EventLoop.free(&self) @public
{
    // Try to close the loop
    if (catch err = self.close())
    {
        logger::logf(logger::LogLevel.WARN, "Error closing event loop during free: %s", err);
    }

    // Free the memory
    free(self.loop);
}
