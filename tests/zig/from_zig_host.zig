//! Integration test for libsci host bridge API in Zig.
//!
//! Tests all C entry points:
//!   set_host_dispatcher, load_script, call_function,
//!   eval_in_context, reset_context, eval
//!
//! Build: zig build
//! Run:   zig build run

const std = @import("std");
const c = @import("libsci");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var test_count: u32 = 0;
var pass_count: u32 = 0;

// callPtr is imported by libsci.so via @CFunction static native.
// The host MUST export this function.
export fn callPtr(fn_ptr: i64, arg_ptr: i64) callconv(.c) i64 {
    const disp: *const fn (i64) callconv(.c) i64 = @ptrFromInt(@as(usize, @intCast(fn_ptr)));
    return disp(arg_ptr);
}

// Host dispatcher callback
const host_dispatcher = (struct {
    fn dispatch(args_json: [*:0]const u8) callconv(.c) [*:0]const u8 {
        return "{\"status\":\"ok\",\"value\":7}";
    }
}).dispatch;

fn run(comptime name: []const u8, test_fn: *const fn () bool) void {
    test_count += 1;
    const passed = test_fn();
    if (passed) {
        pass_count += 1;
        std.debug.print("  PASS: {s}\n", .{name});
    } else {
        std.debug.print("  FAIL: {s}\n", .{name});
    }
}

fn testSetHostDispatcher() bool {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    if (c.graal_create_isolate(null, &isolate, &thread) != 0) return false;
    c.set_host_dispatcher(@intFromPtr(thread), @intFromPtr(&host_dispatcher));
    _ = c.graal_tear_down_isolate(thread);
    return true;
}

fn testLoadAndCall() bool {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    if (c.graal_create_isolate(null, &isolate, &thread) != 0) return false;
    defer _ = c.graal_tear_down_isolate(thread);

    c.set_host_dispatcher(@intFromPtr(thread), @intFromPtr(&host_dispatcher));
    _ = c.load_script(thread, "(defn add [x y] (+ x y))");
    const r = std.mem.span(c.call_function(thread, "add", "3 4"));
    return std.mem.indexOf(u8, r, "\"status\":\"ok\"") != null
       and std.mem.indexOf(u8, r, "\"value\":\"7\"") != null;
}

fn testEvalInContext() bool {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    if (c.graal_create_isolate(null, &isolate, &thread) != 0) return false;
    defer _ = c.graal_tear_down_isolate(thread);

    c.set_host_dispatcher(@intFromPtr(thread), @intFromPtr(&host_dispatcher));
    _ = c.load_script(thread, "(def x 42)");
    const r = std.mem.span(c.eval_in_context(thread, "x"));
    return std.mem.indexOf(u8, r, "\"value\":\"42\"") != null;
}

fn testEvalFresh() bool {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    if (c.graal_create_isolate(null, &isolate, &thread) != 0) return false;
    defer _ = c.graal_tear_down_isolate(thread);

    c.set_host_dispatcher(@intFromPtr(thread), @intFromPtr(&host_dispatcher));
    const r1 = std.mem.span(c.eval(thread, "(def x 42)"));
    if (std.mem.indexOf(u8, r1, "#'user/x") == null) return false;

    const r2 = std.mem.span(c.eval(thread, "(try x (catch Exception e \"err\"))"));
    return std.mem.indexOf(u8, r2, "err") != null;
}

fn testResetContext() bool {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    if (c.graal_create_isolate(null, &isolate, &thread) != 0) return false;
    defer _ = c.graal_tear_down_isolate(thread);

    c.set_host_dispatcher(@intFromPtr(thread), @intFromPtr(&host_dispatcher));
    _ = c.load_script(thread, "(def x 1)");
    c.reset_context(thread);
    const r = std.mem.span(c.call_function(thread, "add", "1 2"));
    return std.mem.indexOf(u8, r, "\"status\":\"error\"") != null;
}

fn testHostCall() bool {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    if (c.graal_create_isolate(null, &isolate, &thread) != 0) return false;
    defer _ = c.graal_tear_down_isolate(thread);

    c.set_host_dispatcher(@intFromPtr(thread), @intFromPtr(&host_dispatcher));
    _ = c.load_script(thread, "(defn compute [x y] (host-call \"add\" x y))");
    const r = std.mem.span(c.call_function(thread, "compute", "3 4"));
    return std.mem.indexOf(u8, r, "\"status\":\"ok\"") != null
       and std.mem.indexOf(u8, r, ":value 7") != null;
}

fn testEdnKeyword() bool {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    if (c.graal_create_isolate(null, &isolate, &thread) != 0) return false;
    defer _ = c.graal_tear_down_isolate(thread);

    c.set_host_dispatcher(@intFromPtr(thread), @intFromPtr(&host_dispatcher));
    _ = c.load_script(thread, "(defn get-val [m k] (get m k))");
    const r = std.mem.span(c.call_function(thread, "get-val", "{:a 1 :b 2} :a"));
    return std.mem.indexOf(u8, r, "\"value\":\"1\"") != null;
}

fn testCrossNs() bool {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    if (c.graal_create_isolate(null, &isolate, &thread) != 0) return false;
    defer _ = c.graal_tear_down_isolate(thread);

    c.set_host_dispatcher(@intFromPtr(thread), @intFromPtr(&host_dispatcher));
    _ = c.load_script(thread, "(ns my.ns) (defn calc [x] (* x 2))");
    const r = std.mem.span(c.call_function(thread, "my.ns/calc", "21"));
    return std.mem.indexOf(u8, r, "\"value\":\"42\"") != null;
}

pub fn main() !void {
    defer _ = gpa.deinit();

    std.debug.print("libsci host bridge Zig integration tests\n", .{});
    std.debug.print("----------------------------------------\n", .{});

    run("set_host_dispatcher", testSetHostDispatcher);
    run("load_and_call", testLoadAndCall);
    run("eval_in_context", testEvalInContext);
    run("eval_fresh_context", testEvalFresh);
    run("reset_context", testResetContext);
    run("host_call", testHostCall);
    run("edn_keyword_args", testEdnKeyword);
    run("cross_ns_call", testCrossNs);

    std.debug.print("\n{d} / {d} tests passed\n", .{ pass_count, test_count });
    if (pass_count != test_count) std.process.exit(1);
}
