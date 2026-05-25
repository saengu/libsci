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

fn resultErr(msg: []const u8) [*:0]const u8 {
    const s = std.fmt.bufPrintZ(&result_buf, "{s}{s}{s}", .{
        "{\"status\":\"error\",\"message\":\"",
        msg,
        "\"}",
    }) catch unreachable;
    return s.ptr;
}

var tests_run: i32 = 0;
var tests_passed: i32 = 0;

fn test(name: []const u8, body: *const fn () bool) void {
    tests_run += 1;
    const passed = body();
    if (passed) tests_passed += 1;
    std.debug.print("  {s}: {s}\n", .{ if (passed) "PASS" else "FAIL", name });
}

fn check(ok: bool, msg: []const u8) bool {
    if (!ok) std.debug.print("    ASSERT FAIL: {s}\n", .{msg});
    return ok;
}

fn createIsolate() *c.graal_isolatethread_t {
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    _ = c.graal_create_isolate(null, &isolate, &thread);
    return thread.?;
}

fn jsonOk(result: [*:0]const u8) bool {
    return std.mem.indexOf(u8, std.mem.span(result), "\"status\":\"ok\"") != null;
}

export fn host_dispatcher(json_args: [*:0]const u8) callconv(.c) [*:0]const u8 {
    const s = std.mem.span(json_args);
    if (std.mem.indexOf(u8, s, "\"ns\"") != null) {
        if (std.mem.indexOf(u8, s, "\"math\"") != null and
            std.mem.indexOf(u8, s, "\"add\"") != null)
        {
            return resultOk("7");
        }
        return resultOk("0");
    }
    if (std.mem.indexOf(u8, s, "\"add\"") != null) {
        return resultOk("7");
    }
    return resultErr("unknown host function");
}

fn testSetHostDispatcher() bool {
    const thread = createIsolate();
    c.set_host_dispatcher(@intCast(@intFromPtr(thread)), @intCast(@intFromPtr(&host_dispatcher)));
    c.graal_tear_down_isolate(thread);
    return true;
}

fn testLoadAndCall() bool {
    const thread = createIsolate();
    c.set_host_dispatcher(@intCast(@intFromPtr(thread)), @intCast(@intFromPtr(&host_dispatcher)));
    _ = c.load_script(@intCast(@intFromPtr(thread)), "(defn add [x y] (+ x y))");
    const r = c.call_function(@intCast(@intFromPtr(thread)), "add", "3 4");
    c.graal_tear_down_isolate(thread);
    const s = std.mem.span(r);
    return jsonOk(r) and std.mem.indexOf(u8, s, "\"value\":\"7\"") != null;
}

fn testEvalInContext() bool {
    const thread = createIsolate();
    c.set_host_dispatcher(@intCast(@intFromPtr(thread)), @intCast(@intFromPtr(&host_dispatcher)));
    _ = c.load_script(@intCast(@intFromPtr(thread)), "(def x 42)");
    const r = c.eval_in_context(@intCast(@intFromPtr(thread)), "x");
    c.graal_tear_down_isolate(thread);
    return std.mem.indexOf(u8, std.mem.span(r), "\"value\":\"42\"") != null;
}

fn testEvalFresh() bool {
    const thread = createIsolate();
    c.set_host_dispatcher(@intCast(@intFromPtr(thread)), @intCast(@intFromPtr(&host_dispatcher)));
    const r1 = c.eval_string(@intCast(@intFromPtr(thread)), "(def x 42)");
    const r2 = c.eval_string(@intCast(@intFromPtr(thread)),
        "(try x (catch Exception e \"err\"))");
    c.graal_tear_down_isolate(thread);
    const s1 = std.mem.span(r1);
    const s2 = std.mem.span(r2);
    return std.mem.indexOf(u8, s1, "#'user/x") != null and
           std.mem.indexOf(u8, s2, "err") != null;
}

fn testResetContext() bool {
    const thread = createIsolate();
    c.set_host_dispatcher(@intCast(@intFromPtr(thread)), @intCast(@intFromPtr(&host_dispatcher)));
    _ = c.load_script(@intCast(@intFromPtr(thread)), "(def x 1)");
    c.reset_context(@intCast(@intFromPtr(thread)));
    const r = c.call_function(@intCast(@intFromPtr(thread)), "add", "1 2");
    c.graal_tear_down_isolate(thread);
    return std.mem.indexOf(u8, std.mem.span(r), "\"status\":\"error\"") != null;
}

fn testHostCall() bool {
    const thread = createIsolate();
    c.set_host_dispatcher(@intCast(@intFromPtr(thread)), @intCast(@intFromPtr(&host_dispatcher)));
    _ = c.load_script(@intCast(@intFromPtr(thread)),
        "(defn compute [x y] (host-call \"add\" x y))");
    const r = c.call_function(@intCast(@intFromPtr(thread)), "compute", "3 4");
    c.graal_tear_down_isolate(thread);
    const s = std.mem.span(r);
    return jsonOk(r) and std.mem.indexOf(u8, s, ":value 7") != null;
}

fn testEdnKeywordArgs() bool {
    const thread = createIsolate();
    c.set_host_dispatcher(@intCast(@intFromPtr(thread)), @intCast(@intFromPtr(&host_dispatcher)));
    _ = c.load_script(@intCast(@intFromPtr(thread)), "(defn get-val [m k] (get m k))");
    const r = c.call_function(@intCast(@intFromPtr(thread)), "get-val", "{:a 1 :b 2} :a");
    c.graal_tear_down_isolate(thread);
    return std.mem.indexOf(u8, std.mem.span(r), "\"value\":\"1\"") != null;
}

fn testCrossNsCall() bool {
    const thread = createIsolate();
    c.set_host_dispatcher(@intCast(@intFromPtr(thread)), @intCast(@intFromPtr(&host_dispatcher)));
    _ = c.load_script(@intCast(@intFromPtr(thread)),
        "(ns my.ns) (defn calc [x] (* x 2))");
    const r = c.call_function(@intCast(@intFromPtr(thread)), "my.ns/calc", "21");
    c.graal_tear_down_isolate(thread);
    return std.mem.indexOf(u8, std.mem.span(r), "\"value\":\"42\"") != null;
}

fn testRegisterNamespaces() bool {
    const thread = createIsolate();
    c.set_host_dispatcher(@intCast(@intFromPtr(thread)), @intCast(@intFromPtr(&host_dispatcher)));
    const r1 = c.register_namespaces(@intCast(@intFromPtr(thread)),
        "{\"namespaces\":{\"math\":[\"add\",\"subtract\"]}}");
    _ = check(jsonOk(r1), "register_namespaces should succeed");
    const r2 = c.load_script(@intCast(@intFromPtr(thread)), "(math/add 1 2)");
    _ = check(jsonOk(r2), "math/add call should succeed");
    c.graal_tear_down_isolate(thread);
    return jsonOk(r1) and jsonOk(r2);
}

fn testRegisterNamespacesAfterLoad() bool {
    const thread = createIsolate();
    c.set_host_dispatcher(@intCast(@intFromPtr(thread)), @intCast(@intFromPtr(&host_dispatcher)));
    _ = c.load_script(@intCast(@intFromPtr(thread)), "(def x 42)");
    const r = c.register_namespaces(@intCast(@intFromPtr(thread)),
        "{\"namespaces\":{\"late\":[\"fn\"]}}");
    c.graal_tear_down_isolate(thread);
    return jsonOk(r);
}

fn testRegisterNamespacesError() bool {
    const thread = createIsolate();
    c.set_host_dispatcher(@intCast(@intFromPtr(thread)), @intCast(@intFromPtr(&host_dispatcher)));
    const r = c.register_namespaces(@intCast(@intFromPtr(thread)), "not-json");
    c.graal_tear_down_isolate(thread);
    return std.mem.indexOf(u8, std.mem.span(r), "\"status\":\"error\"") != null;
}

pub fn main() void {
    std.debug.print("libsci host bridge Zig integration tests\n", .{});
    std.debug.print("----------------------------------------\n", .{});

    test("set_host_dispatcher", testSetHostDispatcher);
    test("load_and_call", testLoadAndCall);
    test("eval_in_context", testEvalInContext);
    test("eval_fresh", testEvalFresh);
    test("reset_context", testResetContext);
    test("host_call", testHostCall);
    test("edn_keyword_args", testEdnKeywordArgs);
    test("cross_ns_call", testCrossNsCall);
    test("register_namespaces", testRegisterNamespaces);
    test("register_namespaces_after_load", testRegisterNamespacesAfterLoad);
    test("register_namespaces_error", testRegisterNamespacesError);

    std.debug.print("\n{d} / {d} tests passed\n", .{ tests_passed, tests_run });
    if (tests_passed != tests_run) std.process.exit(1);
}
