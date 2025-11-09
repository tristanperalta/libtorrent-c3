module libtorrent::event_bus;

import std::io;
import std::collections::list;
import async::event_loop;
import async::timer;

// Event callback function type
// Parameters: event_type, event_data, user_data
alias EventCallback = fn void(String event_type, void* event_data, void* user_data);

// Subscriber structure
struct Subscriber
{
    String event_type;        // Event type to listen for (or "*" for all events)
    EventCallback callback;   // Function to call when event fires
    void* user_data;         // User data to pass to callback
}

// Queued event structure (for async dispatch)
struct QueuedEvent
{
    String event_type;        // Event type (copied)
    void* event_data;         // Event data (copied)
    usz event_data_size;      // Size of event data for copying
}

// Event bus structure
struct EventBus
{
    event_loop::EventLoop* loop;        // Event loop for async dispatch
    List{Subscriber} subscribers;       // Event subscribers
    List{QueuedEvent} event_queue;      // Queued events (dispatched on next tick)
    timer::Timer* dispatch_timer;       // Timer for async event dispatch
    bool dispatch_pending;              // Is dispatch already scheduled?
}

/**
 * Create a new EventBus.
 *
 * @param loop : "Event loop for async dispatch"
 * @return "Initialized EventBus"
 */
fn EventBus* create(event_loop::EventLoop* loop) @public
{
    EventBus* bus = mem::new(EventBus);
    bus.loop = loop;
    bus.subscribers.init(mem);
    bus.event_queue.init(mem);
    bus.dispatch_pending = false;

    // Create timer for async event dispatch (not started yet)
    timer::Timer*? timer_opt = timer::create(loop);
    if (catch timer_opt)
    {
        io::eprintfn("Warning: Failed to create event bus dispatch timer");
        bus.dispatch_timer = null;
    }
    else
    {
        bus.dispatch_timer = timer_opt;
    }

    return bus;
}

/**
 * Subscribe to an event type.
 *
 * @param event_type : "Event type to listen for (use '*' for all events)"
 * @param callback : "Function to call when event fires"
 * @param user_data : "User data to pass to callback"
 */
fn void EventBus.subscribe(&self, String event_type, EventCallback callback, void* user_data) @public
{
    Subscriber sub;
    sub.event_type = event_type.copy(mem);
    sub.callback = callback;
    sub.user_data = user_data;

    self.subscribers.push(sub);
}

/**
 * Unsubscribe from an event type.
 *
 * @param event_type : "Event type to stop listening for"
 * @param callback : "Callback function to remove"
 */
fn void EventBus.unsubscribe(&self, String event_type, EventCallback callback) @public
{
    // Find and remove matching subscribers
    for (usz i = 0; i < self.subscribers.len(); i++)
    {
        Subscriber sub = self.subscribers.get(i);
        if (sub.event_type == event_type && sub.callback == callback)
        {
            free(sub.event_type);
            self.subscribers.remove_at(i);
            i--;  // Adjust index after removal
        }
    }
}

/**
 * Async event dispatch callback - processes queued events on next event loop tick.
 */
fn void dispatch_queued_events(timer::Timer* timer, void* user_data)
{
    EventBus* bus = (EventBus*)user_data;
    bus.dispatch_pending = false;

    // Dispatch all queued events to subscribers
    foreach (evt : bus.event_queue.array_view())
    {
        foreach (sub : bus.subscribers.array_view())
        {
            // Call subscriber if event type matches or listens to all events
            if (sub.event_type == evt.event_type || sub.event_type == "*")
            {
                sub.callback(evt.event_type, evt.event_data, sub.user_data);
            }
        }

        // Free copied event data and type
        free(evt.event_data);
        free(evt.event_type);
    }

    // Clear queue
    bus.event_queue.clear();
}

/**
 * Publish an event to all subscribers (async - dispatched on next event loop tick).
 *
 * @param event_type : "Event type to publish"
 * @param event_data : "Event data pointer (will be copied)"
 * @param event_data_size : "Size of event data in bytes"
 */
fn void EventBus.publish(&self, String event_type, void* event_data, usz event_data_size) @public
{
    if (!self.dispatch_timer) return;  // No timer, can't dispatch

    // Copy event data (must persist until dispatch)
    char[] event_data_copy = mem::new_array(char, event_data_size);
    for (usz i = 0; i < event_data_size; i++)
    {
        event_data_copy[i] = ((char*)event_data)[i];
    }

    // Queue event
    QueuedEvent evt;
    evt.event_type = event_type.copy(mem);
    evt.event_data = event_data_copy;
    evt.event_data_size = event_data_size;

    self.event_queue.push(evt);

    // Schedule dispatch on next event loop tick (if not already scheduled)
    if (!self.dispatch_pending)
    {
        self.dispatch_pending = true;
        // Use 0ms timeout to dispatch on next tick
        self.dispatch_timer.start(0, 0, &dispatch_queued_events, self);
    }
}

/**
 * Get the number of subscribers.
 *
 * @return "Number of registered subscribers"
 */
fn usz EventBus.get_subscriber_count(&self) @public
{
    return self.subscribers.len();
}

/**
 * Get the number of subscribers for a specific event type.
 *
 * @param event_type : "Event type to count subscribers for"
 * @return "Number of subscribers for this event type"
 */
fn usz EventBus.get_subscriber_count_for(&self, String event_type) @public
{
    usz count = 0;
    foreach (sub : self.subscribers.array_view())
    {
        if (sub.event_type == event_type || sub.event_type == "*")
        {
            count++;
        }
    }
    return count;
}

/**
 * Free the EventBus and all its resources.
 */
fn void EventBus.free(&self) @public
{
    // NOTE: dispatch_timer should be closed BEFORE close_all_handles() in main.c3
    // This .free() is called AFTER close_all_handles(), so timer is already freed
    // Just null out the pointer for safety
    if (self.dispatch_timer)
    {
        self.dispatch_timer = null;
    }

    // Free all queued events
    foreach (evt : self.event_queue.array_view())
    {
        free(evt.event_data);
        free(evt.event_type);
    }
    self.event_queue.free();

    // Free all subscriber event type strings
    foreach (sub : self.subscribers.array_view())
    {
        free(sub.event_type);
    }
    self.subscribers.free();

    free(self);
}
