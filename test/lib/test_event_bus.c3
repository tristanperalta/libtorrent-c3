module libtorrent::event_bus_test;

import std::io;
import libtorrent::event_bus;
import async::event_loop;

/**
 * EventBus Test Suite
 * ====================
 * Tests for pub/sub event bus with async dispatch.
 */

// Test state for subscriber callbacks
struct TestCallbackData
{
    int call_count;
    String last_event_type;
    int last_value;
}

/**
 * Simple subscriber callback for testing.
 */
fn void test_subscriber_callback(String event_type, void* event_data, void* user_data)
{
    TestCallbackData* data = (TestCallbackData*)user_data;
    data.call_count++;
    data.last_event_type = event_type;
    data.last_value = *(int*)event_data;
}

/**
 * Test basic subscription and unsubscription.
 */
fn void test_subscribe_unsubscribe() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    event_bus::EventBus* bus = event_bus::create(&loop);
    defer {
        if (bus.dispatch_timer) bus.dispatch_timer.close();
        bus.free();
        loop.run_once();  // Process pending timer close
    }

    // Initially no subscribers
    assert(bus.get_subscriber_count() == 0, "Should have no subscribers initially");

    // Subscribe to event
    TestCallbackData data;
    data.call_count = 0;
    bus.subscribe("test.event", &test_subscriber_callback, &data);

    // Should have 1 subscriber
    assert(bus.get_subscriber_count() == 1, "Should have 1 subscriber");
    assert(bus.get_subscriber_count_for("test.event") == 1, "Should have 1 subscriber for test.event");

    // Unsubscribe
    bus.unsubscribe("test.event", &test_subscriber_callback);

    // Should have no subscribers
    assert(bus.get_subscriber_count() == 0, "Should have no subscribers after unsubscribe");

    io::printn("✓ Subscribe/unsubscribe");
}

/**
 * Test multiple subscribers to same event.
 */
fn void test_multiple_subscribers() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    event_bus::EventBus* bus = event_bus::create(&loop);
    defer {
        if (bus.dispatch_timer) bus.dispatch_timer.close();
        bus.free();
        loop.run_once();  // Process pending timer close
    }

    TestCallbackData data1;
    data1.call_count = 0;
    TestCallbackData data2;
    data2.call_count = 0;

    // Subscribe both callbacks to same event
    bus.subscribe("test.event", &test_subscriber_callback, &data1);
    bus.subscribe("test.event", &test_subscriber_callback, &data2);

    // Should have 2 subscribers
    assert(bus.get_subscriber_count() == 2, "Should have 2 subscribers");
    assert(bus.get_subscriber_count_for("test.event") == 2, "Should have 2 subscribers for test.event");

    io::printn("✓ Multiple subscribers");
}

/**
 * Test wildcard subscription (subscribe to all events).
 */
fn void test_wildcard_subscription() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    event_bus::EventBus* bus = event_bus::create(&loop);
    defer {
        if (bus.dispatch_timer) bus.dispatch_timer.close();
        bus.free();
        loop.run_once();  // Process pending timer close
    }

    TestCallbackData data;
    data.call_count = 0;

    // Subscribe to all events with wildcard
    bus.subscribe("*", &test_subscriber_callback, &data);

    // Should count for any event type
    assert(bus.get_subscriber_count_for("test.event") == 1, "Wildcard should match test.event");
    assert(bus.get_subscriber_count_for("other.event") == 1, "Wildcard should match other.event");

    io::printn("✓ Wildcard subscription");
}

/**
 * Test event publishing with async dispatch.
 */
fn void test_publish_async_dispatch() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    event_bus::EventBus* bus = event_bus::create(&loop);
    defer {
        if (bus.dispatch_timer) bus.dispatch_timer.close();
        bus.free();
        loop.run_once();  // Process pending timer close
    }

    TestCallbackData data;
    data.call_count = 0;
    data.last_value = 0;

    // Subscribe to event
    bus.subscribe("test.event", &test_subscriber_callback, &data);

    // Publish event (queues for async dispatch)
    int test_value = 42;
    bus.publish("test.event", &test_value, int.sizeof);

    // Callback should NOT be called yet (async dispatch)
    assert(data.call_count == 0, "Callback should not be called immediately (async)");

    // Run one iteration of event loop to dispatch queued events
    loop.run_once();

    // Now callback should have been called
    assert(data.call_count == 1, "Callback should be called after event loop iteration");
    assert(data.last_value == 42, "Callback should receive correct value");

    io::printn("✓ Async event dispatch");
}

/**
 * Test event batching (multiple events queued before dispatch).
 */
fn void test_event_batching() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    event_bus::EventBus* bus = event_bus::create(&loop);
    defer {
        if (bus.dispatch_timer) bus.dispatch_timer.close();
        bus.free();
        loop.run_once();  // Process pending timer close
    }

    TestCallbackData data;
    data.call_count = 0;

    // Subscribe to event
    bus.subscribe("test.event", &test_subscriber_callback, &data);

    // Publish 3 events (all queued before dispatch)
    int value1 = 1;
    int value2 = 2;
    int value3 = 3;
    bus.publish("test.event", &value1, int.sizeof);
    bus.publish("test.event", &value2, int.sizeof);
    bus.publish("test.event", &value3, int.sizeof);

    // No callbacks yet
    assert(data.call_count == 0, "No callbacks before event loop run");

    // Run event loop - all events should be dispatched in batch
    loop.run_once();

    // All 3 callbacks should have fired
    assert(data.call_count == 3, "All 3 events should be dispatched");
    assert(data.last_value == 3, "Last value should be from last event");

    io::printn("✓ Event batching");
}

/**
 * Test unsubscribing one of multiple subscribers.
 */
fn void test_unsubscribe_one_of_many() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    event_bus::EventBus* bus = event_bus::create(&loop);
    defer {
        if (bus.dispatch_timer) bus.dispatch_timer.close();
        bus.free();
        loop.run_once();  // Process pending timer close
    }

    TestCallbackData data1;
    data1.call_count = 0;
    TestCallbackData data2;
    data2.call_count = 0;

    // Subscribe both
    bus.subscribe("test.event", &test_subscriber_callback, &data1);
    bus.subscribe("test.event", &test_subscriber_callback, &data2);

    assert(bus.get_subscriber_count() == 2, "Should have 2 subscribers");

    // Unsubscribe first one only
    bus.unsubscribe("test.event", &test_subscriber_callback);

    // Should still have subscribers (both were using same callback)
    // Note: unsubscribe removes ALL instances with matching event_type and callback
    assert(bus.get_subscriber_count() == 0, "Should have no subscribers (all instances removed)");

    io::printn("✓ Unsubscribe with multiple instances");
}

/**
 * Test different event types.
 */
fn void test_different_event_types() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;
    defer loop.free();

    event_bus::EventBus* bus = event_bus::create(&loop);
    defer {
        if (bus.dispatch_timer) bus.dispatch_timer.close();
        bus.free();
        loop.run_once();  // Process pending timer close
    }

    TestCallbackData data1;
    data1.call_count = 0;
    TestCallbackData data2;
    data2.call_count = 0;

    // Subscribe to different events
    bus.subscribe("event.a", &test_subscriber_callback, &data1);
    bus.subscribe("event.b", &test_subscriber_callback, &data2);

    // Publish to event.a only
    int value = 100;
    bus.publish("event.a", &value, int.sizeof);

    loop.run_once();

    // Only data1 should be called
    assert(data1.call_count == 1, "event.a subscriber should be called");
    assert(data2.call_count == 0, "event.b subscriber should NOT be called");

    io::printn("✓ Different event types");
}
