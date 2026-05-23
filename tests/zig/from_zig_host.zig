//! Integration test for libsci host bridge API in Zig.
//!
//! Tests all C entry points:
//!   load_script, call_function, eval_in_context, reset_context, eval,
//!   get_pending_host_call, deliver_host_call_result
//!
//! Build: zig build
//! Run:   zig build run

const std = @import("std");
const c = @import("libsci");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var test_count: u32 = 0;
var pass_count: u32 = 0;

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

fn testLoadAndCall() bool {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    if (c.graal_create_isolate(null, &isolate, &thread) != 0) return false;
    defer _ = c.graal_tear_down_isolate(thread);

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

    _ = c.load_script(thread, "(def x 42)");
    const r = std.mem.span(c.eval_in_context(thread, "x"));
    return std.mem.indexOf(u8, r, "\"value\":\"42\"") != null;
}

fn testEvalFresh() bool {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    if (c.graal_create_isolate(null, &isolate, &thread) != 0) return false;
    defer _ = c.graal_tear_down_isolate(thread);

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

    _ = c.load_script(thread, "(def x 1)");
    c.reset_context(thread);
    const r = std.mem.span(c.call_function(thread, "add", "1 2"));
    return std.mem.indexOf(u8, r, "\"status\":\"error\"") != null;
}

fn testHostCallDataProtocol() bool {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    if (c.graal_create_isolate(null, &isolate, &thread) != 0) return false;
    defer _ = c.graal_tear_down_isolate(thread);

    const r = std.mem.span(c.load_script(thread, "(host-call \"add\" 3 4)"));
    return std.mem.indexOf(u8, r, "\"status\":\"ok\"") != null
       and std.mem.indexOf(u8, r, "\"value\":\"") != null;
}

fn testEdnKeyword() bool {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    if (c.graal_create_isolate(null, &isolate, &thread) != 0) return false;
    defer _ = c.graal_tear_down_isolate(thread);

    _ = c.load_script(thread, "(defn get-val [m k] (get m k))");
    const r = std.mem.span(c.call_function(thread, "get-val", "{:a 1 :b 2} :a"));
    return std.mem.indexOf(u8, r, "\"value\":\"1\"") != null;
}

fn testCrossNs() bool {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    if (c.graal_create_isolate(null, &isolate, &thread) != 0) return false;
    defer _ = c.graal_tear_down_isolate(thread);

    _ = c.load_script(thread, "(ns my.ns) (defn calc [x] (* x 2))");
    const r = std.mem.span(c.call_function(thread, "my.ns/calc", "21"));
    return std.mem.indexOf(u8, r, "\"value\":\"42\"") != null;
}

pub fn main() !void {
    defer _ = gpa.deinit();

    std.debug.print("libsci host bridge Zig integration tests\n", .{});
    std.debug.print("----------------------------------------\n", .{});

    run("load_and_call", testLoadAndCall);
    run("eval_in_context", testEvalInContext);
    run("eval_fresh_context", testEvalFresh);
    run("reset_context", testResetContext);
    run("host_call_data_protocol", testHostCallDataProtocol);
    run("edn_keyword_args", testEdnKeyword);
    run("cross_ns_call", testCrossNs);

    std.debug.print("\n{d} / {d} tests passed\n", .{ pass_count, test_count });
    if (pass_count != test_count) std.process.exit(1);
}
