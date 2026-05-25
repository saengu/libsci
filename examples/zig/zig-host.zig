//! Zig host application for libsci — demonstrates:
//! 1. host-call round-trips (explicit dispatch)
//! 2. register_namespaces (transparent function calls)

const std = @import("std");
const c = @import("libsci");

// ── Result buffer ──────────────────────────────────────────────
threadlocal var result_buf: [4096]u8 = [_]u8{0} ** 4096;

fn resultOk(value: []const u8) [*:0]const u8 {
    const s = std.fmt.bufPrintZ(&result_buf, "{s}{s}{s}", .{
        "{\"status\":\"ok\",\"value\":",
        value,
        "}",
    }) catch unreachable;
    return s.ptr;
}

fn resultOkRaw(value: []const u8) [*:0]const u8 {
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

// ── Simple JSON object parser ────────────────────────────────
// Returns value for a top-level key in a flat JSON object.
fn getJsonValue(json: []const u8, key: []const u8) ?[]const u8 {
    const search = try std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key});
    defer std.heap.page_allocator.free(search);
    const pos = (std.mem.indexOf(u8, json, search) orelse return null) + search.len;
    var end = pos;
    if (json[pos] == '"') {
        end += 1;
        while (end < json.len and json[end] != '"') : (end += 1) {}
        return json[pos + 1 .. end];
    }
    return null;
}

// ── Host callback handlers (legacy host-call style) ──────────

export fn host_add(args_json: [*:0]const u8) callconv(.c) [*:0]const u8 {
    // With unified JSON format, args_json is:
    // {"fn":"host-add","args":[3,4]}
    // Extract the args array and sum the numbers.
    const s = std.mem.span(args_json);
    var i: usize = 0;
    var a: i64 = 0;
    var b: i64 = 0;
    var found: u2 = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '-' or std.ascii.isDigit(s[i])) {
            const start = i;
            while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '-')) : (i += 1) {}
            const val = std.fmt.parseInt(i64, s[start..i], 10) catch 0;
            if (found == 0) { a = val; found = 1; }
            else if (found == 1) { b = val; found = 2; }
        }
    }
    var buf: [32]u8 = undefined;
    const val = std.fmt.bufPrint(&buf, "{d}", .{a + b}) catch "overflow";
    return resultOk(val);
}

export fn host_greet(args_json: [*:0]const u8) callconv(.c) [*:0]const u8 {
    const s = std.mem.span(args_json);
    var i: usize = 0;
    while (i < s.len and s[i] != '"') : (i += 1) {}
    if (i >= s.len) return resultErr("no string arg");
    i += 1;
    const start = i;
    while (i < s.len and s[i] != '"') : (i += 1) {}
    var buf: [128]u8 = undefined;
    const val = std.fmt.bufPrint(&buf, "\"Hello, {s}!\"", .{s[start..i]}) catch "\"overflow\"";
    return resultOkRaw(val);
}

// ── Host dispatcher (handles both legacy and registered calls) ─

var handlers: std.StringHashMap(*const fn ([*:0]const u8) callconv(.c) [*:0]const u8) = undefined;

fn register(comptime name: []const u8, handler: *const fn ([*:0]const u8) callconv(.c) [*:0]const u8) !void {
    try handlers.put(name, handler);
}

export fn host_dispatcher(args_json: [*:0]const u8) callconv(.c) [*:0]const u8 {
    const s = std.mem.span(args_json);

    // Check if this is a registered namespace call (has "ns" field)
    if (std.mem.indexOf(u8, s, "\"ns\"") != null) {
        // Registered namespace calls come from create-host-binding closures.
        // Format: {"ns":"math","fn":"add","args":[1,2]}
        if (std.mem.indexOf(u8, s, "\"math\"") != null and
            std.mem.indexOf(u8, s, "\"add\"") != null)
        {
            // Extract the args and compute the result
            var i: usize = 0;
            var a: i64 = 0;
            var b: i64 = 0;
            var found: u2 = 0;
            while (i < s.len) : (i += 1) {
                if (s[i] == '-' or std.ascii.isDigit(s[i])) {
                    const start = i;
                    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '-')) : (i += 1) {}
                    const val = std.fmt.parseInt(i64, s[start..i], 10) catch 0;
                    if (found == 0) { a = val; found = 1; }
                    else if (found == 1) { b = val; found = 2; }
                }
            }
            var buf: [32]u8 = undefined;
            const val = std.fmt.bufPrint(&buf, "{d}", .{a + b}) catch "overflow";
            return resultOk(val);
        }
        return resultErr("unknown registered function");
    }

    // Legacy host-call: {"fn":"host-add","args":[3,4]}
    // Extract the function name from the "fn" field
    var i: usize = 0;
    while (i < s.len and s[i] != '"') : (i += 1) {}
    if (i >= s.len) return resultErr("no opening quote");
    i += 1;
    const start = i;
    while (i < s.len and s[i] != '"') : (i += 1) {}
    if (handlers.get(s[start..i])) |handler| return handler(args_json);
    return resultErr("unknown host function");
}

// ── Main ───────────────────────────────────────────────────────
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer _ = arena.deinit();

    handlers = std.StringHashMap(*const fn ([*:0]const u8) callconv(.c) [*:0]const u8).init(arena.allocator());
    try register("host-add", &host_add);
    try register("host-greet", &host_greet);

    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    _ = c.graal_create_isolate(null, &isolate, &thread);
    defer _ = c.graal_tear_down_isolate(thread);

    // Register the dispatcher
    c.set_host_dispatcher(@intCast(@intFromPtr(thread)), @intCast(@intFromPtr(&host_dispatcher)));

    // ── Example 1: host-call (explicit dispatch) ─────────────
    // Scripts call (host-call "host-add" x y) which goes through the dispatcher.
    std.debug.print("=== Example 1: host-call ===\n", .{});

    _ = c.load_script(@intCast(@intFromPtr(thread)),
        \\(defn compute [x y]
        \\  (let [sum (host-call "host-add" x y)]
        \\    {:sum sum}))
    );

    const r1 = c.call_function(@intCast(@intFromPtr(thread)), "compute", "3 4");
    std.debug.print("compute(3,4): {s}\n", .{ std.mem.span(r1) });

    const r2 = c.eval_in_context(@intCast(@intFromPtr(thread)),
        \\(let [r (compute 10 20)] (str "got " (:sum r)))
    );
    std.debug.print("eval: {s}\n", .{ std.mem.span(r2) });

    // ── Example 2: register_namespaces (transparent calls) ──
    // Register a "math" namespace, then call (math/add 1 2) directly.
    std.debug.print("\n=== Example 2: register_namespaces ===\n", .{});

    _ = c.register_namespaces(@intCast(@intFromPtr(thread)),
        "{\"namespaces\":{\"math\":[\"add\",\"subtract\"]}}"
    );

    const r3 = c.eval_in_context(@intCast(@intFromPtr(thread)), "(math/add 1 2)");
    std.debug.print("(math/add 1 2): {s}\n", .{ std.mem.span(r3) });

    // Mix registered and host-call
    _ = c.load_script(@intCast(@intFromPtr(thread)),
        \\(defn double-and-add [x y]
        \\  (let [doubled (* 2 (math/add x y))]
        \\    (host-call "host-greet" (str "result: " doubled))))
    );

    const r4 = c.call_function(@intCast(@intFromPtr(thread)), "double-and-add", "5 7");
    std.debug.print("double-and-add(5,7): {s}\n", .{ std.mem.span(r4) });
}
