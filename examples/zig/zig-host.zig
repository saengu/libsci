//! Zig host application for libsci — demonstrates host-call round-trips.

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

fn resultErr(msg: []const u8) [*:0]const u8 {
    const s = std.fmt.bufPrintZ(&result_buf, "{s}{s}{s}", .{
        "{\"status\":\"error\",\"message\":\"",
        msg,
        "\"}",
    }) catch unreachable;
    return s.ptr;
}

// ── JSON array parser ──────────────────────────────────────────
const JsonArg = union(enum) {
    null_val,
    bool_val: bool,
    int_val: i64,
    float_val: f64,
    string_val: []const u8,
};

fn parseJsonArray(json: [:0]const u8, allocator: std.mem.Allocator) !std.ArrayList(JsonArg) {
    var args: std.ArrayList(JsonArg) = .empty;
    errdefer args.deinit(allocator);

    var i: usize = 0;
    while (i < json.len and (json[i] == ' ' or json[i] == '[')) : (i += 1) {}
    while (i < json.len and json[i] != ']') {
        while (i < json.len and (json[i] == ' ' or json[i] == ',')) : (i += 1) {}
        if (i >= json.len or json[i] == ']') break;

        if (json[i] == '"') {
            i += 1;
            const start = i;
            while (i < json.len and json[i] != '"') : (i += 1) {}
            try args.append(allocator, .{ .string_val = json[start..i] });
            i += 1;
        } else if (json[i] == 't' or json[i] == 'f') {
            try args.append(allocator, .{ .bool_val = json[i] == 't' });
            i += if (json[i] == 't') @as(usize, 4) else 5;
        } else if (json[i] == 'n') {
            try args.append(allocator, .{ .null_val = {} });
            i += 4;
        } else if (std.ascii.isDigit(json[i]) or json[i] == '-') {
            const start = i;
            var is_float = false;
            while (i < json.len and (std.ascii.isDigit(json[i]) or
                json[i] == '-' or json[i] == '.' or
                json[i] == 'e' or json[i] == 'E' or json[i] == '+'))
            {
                if (json[i] == '.' or json[i] == 'e' or json[i] == 'E') is_float = true;
                i += 1;
            }
            if (is_float)
                try args.append(allocator, .{ .float_val = try std.fmt.parseFloat(f64, json[start..i]) })
            else
                try args.append(allocator, .{ .int_val = try std.fmt.parseInt(i64, json[start..i], 10) });
        } else {
            i += 1;
        }
    }
    return args;
}

// ── Host callback handlers ─────────────────────────────────────
export fn host_add(args_json: [*:0]const u8) callconv(.c) [*:0]const u8 {
    const parsed = parseJsonArray(std.mem.span(args_json), std.heap.page_allocator)
        catch return resultErr("parse error");
    defer @constCast(&parsed).deinit(std.heap.page_allocator);
    if (parsed.items.len < 3) return resultErr("expected 2 numbers");
    var buf: [64]u8 = undefined;
    const val = std.fmt.bufPrint(&buf, "{d}", .{ parsed.items[1].int_val + parsed.items[2].int_val })
        catch "overflow";
    return resultOk(val);
}

export fn host_greet(args_json: [*:0]const u8) callconv(.c) [*:0]const u8 {
    const parsed = parseJsonArray(std.mem.span(args_json), std.heap.page_allocator)
        catch return resultErr("parse error");
    defer @constCast(&parsed).deinit(std.heap.page_allocator);
    if (parsed.items.len < 2) return resultErr("expected 1 argument");
    var buf: [128]u8 = undefined;
    const val = std.fmt.bufPrint(&buf, "\"Hello, {s}!\"", .{ parsed.items[1].string_val })
        catch "\"overflow\"";
    return resultOk(val);
}

// ── Host dispatcher ────────────────────────────────────────────
var handlers: std.StringHashMap(*const fn ([*:0]const u8) callconv(.c) [*:0]const u8) = undefined;

fn register(comptime name: []const u8, handler: *const fn ([*:0]const u8) callconv(.c) [*:0]const u8) !void {
    try handlers.put(name, handler);
}

export fn host_dispatcher(args_json: [*:0]const u8) callconv(.c) [*:0]const u8 {
    const s = std.mem.span(args_json);
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

    c.set_host_dispatcher(@intCast(@intFromPtr(thread)), @intCast(@intFromPtr(&host_dispatcher)));

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
}
