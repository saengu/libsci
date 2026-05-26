//! Zig integration test for the libsci C API.
//! Tests: sci_create_context, sci_destroy_context, sci_reset_context,
//!        sci_eval_string, sci_call_script_fn, sci_register_host_fn
//!        sci_version, sci_abi_version

const std = @import("std");
const c = @import("libsci");

threadlocal var result_buf: [4096]u8 = [_]u8{0} ** 4096;

fn resultOk(value: []const u8) [*:0]const u8 {
    const s = std.fmt.bufPrintZ(&result_buf, "{s}{s}{s}", .{
        "{\"status\":\"ok\",\"value\":",
        value,
        "}",
    }) catch unreachable;
    return s.ptr;
}

fn resultOkStr(value: []const u8) [*:0]const u8 {
    const s = std.fmt.bufPrintZ(&result_buf, "{s}{s}{s}", .{
        "{\"status\":\"ok\",\"value\":\"",
        value,
        "\"}",
    }) catch unreachable;
    return s.ptr;
}

fn resultErr(msg: []const u8) [*:0]const u8 {
    const s = std.fmt.bufPrintZ(&result_buf, "{s}{s}{s}", .{
        "{\"status\":\"error\",\"message\":\"",
        msg,
        "\"}",
    }) catch unreachable;
    return s.ptr;
}

// ── Test harness ──

var tests_run: i32 = 0;
var tests_passed: i32 = 0;

fn runTest(name: []const u8, body: *const fn () bool) void {
    tests_run += 1;
    const passed = body();
    if (passed) tests_passed += 1;
    std.debug.print("  {s}: {s}\n", .{ if (passed) "PASS" else "FAIL", name });
}

fn assert(ok: bool, msg: []const u8) bool {
    if (!ok) std.debug.print("    ASSERT FAIL: {s}\n", .{msg});
    return ok;
}

fn jsonOk(r: [*:0]const u8) bool {
    return std.mem.indexOf(u8, std.mem.span(r), "\"status\":\"ok\"") != null;
}

fn setup() *c.graal_isolatethread_t {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    _ = c.graal_create_isolate(null, &isolate, &thread);
    c.sci_create_context(thread);
    return thread.?;
}

// ── Host dispatcher callback ──

export fn host_add(_: [*:0]const u8) callconv(.c) [*:0]const u8 {
    return resultOk("7");
}

// ── Tests ──

fn testVersion() bool {
    const thread = setup();
    defer {
        c.sci_destroy_context(thread);
        _ = c.graal_tear_down_isolate(thread);
    }
    const ver = c.sci_version(thread);
    _ = assert(std.mem.len(ver) > 0, "version non-empty");
    return c.sci_abi_version(thread) > 0;
}

fn testCreateDestroy() bool {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    _ = c.graal_create_isolate(null, &isolate, &thread);
    c.sci_create_context(thread);
    c.sci_destroy_context(thread);
    _ = c.graal_tear_down_isolate(thread);
    return true;
}

fn testEvalSimple() bool {
    const thread = setup();
    defer {
        c.sci_destroy_context(thread);
        _ = c.graal_tear_down_isolate(thread);
    }
    const r = c.sci_eval_string(thread, "(+ 1 2)");
    return jsonOk(r) and std.mem.indexOf(u8, std.mem.span(r), "\"value\":\"3\"") != null;
}

fn testEvalError() bool {
    const thread = setup();
    defer {
        c.sci_destroy_context(thread);
        _ = c.graal_tear_down_isolate(thread);
    }
    const r = c.sci_eval_string(thread, "(+ 1");
    return std.mem.indexOf(u8, std.mem.span(r), "\"status\":\"error\"") != null;
}

fn testPersistentContext() bool {
    const thread = setup();
    defer {
        c.sci_destroy_context(thread);
        _ = c.graal_tear_down_isolate(thread);
    }
    _ = c.sci_eval_string(thread, "(def x 42)");
    const r = c.sci_eval_string(thread, "x");
    return jsonOk(r) and std.mem.indexOf(u8, std.mem.span(r), "\"value\":\"42\"") != null;
}

fn testResetContext() bool {
    const thread = setup();
    defer {
        c.sci_destroy_context(thread);
        _ = c.graal_tear_down_isolate(thread);
    }
    _ = c.sci_eval_string(thread, "(def x 1)");
    c.sci_reset_context(thread);
    const r = c.sci_eval_string(thread, "(try x (catch Exception e \"err\"))");
    return std.mem.indexOf(u8, std.mem.span(r), "err") != null;
}

fn testHostCallback() bool {
    const thread = setup();
    defer {
        c.sci_destroy_context(thread);
        _ = c.graal_tear_down_isolate(thread);
    }
    c.sci_register_host_fn(thread, "test", "add", @intCast(@intFromPtr(&host_add)));
    const r = c.sci_eval_string(thread, "(host/invoke \"test\" \"add\" 3 4)");
    return jsonOk(r);
}

fn testHostCallbackSugar() bool {
    const thread = setup();
    defer {
        c.sci_destroy_context(thread);
        _ = c.graal_tear_down_isolate(thread);
    }
    c.sci_register_host_fn(thread, "test", "add", @intCast(@intFromPtr(&host_add)));
    const r = c.sci_eval_string(thread, "(test/add 3 4)");
    return jsonOk(r) and std.mem.indexOf(u8, std.mem.span(r), "\"value\":\"7\"") != null;
}

fn testCallScriptFn() bool {
    const thread = setup();
    defer {
        c.sci_destroy_context(thread);
        _ = c.graal_tear_down_isolate(thread);
    }
    _ = c.sci_eval_string(thread, "(defn count-items [v] (count v))");
    const r = c.sci_call_script_fn(thread, "user", "count-items", "[1 2 3]");
    return jsonOk(r) and std.mem.indexOf(u8, std.mem.span(r), "\"value\":\"3\"") != null;
}

// ── Main ──

pub fn main() void {
    std.debug.print("libsci Zig API integration tests\n", .{});
    std.debug.print("-------------------------------\n", .{});

    runTest("version", testVersion);
    runTest("create_destroy", testCreateDestroy);
    runTest("eval_simple", testEvalSimple);
    runTest("eval_error", testEvalError);
    runTest("persistent_context", testPersistentContext);
    runTest("reset_context", testResetContext);
    runTest("host_callback", testHostCallback);
    runTest("host_callback_sugar", testHostCallbackSugar);
    runTest("call_script_fn", testCallScriptFn);

    std.debug.print("\n{d} / {d} tests passed\n", .{ tests_passed, tests_run });
    if (tests_passed != tests_run) std.process.exit(1);
}
