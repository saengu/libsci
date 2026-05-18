//! ┌──────────────────────────────────────────────────────────────┐
//! │ main.zig — Zig host application for libsci                  │
//! ├──────────────────────────────────────────────────────────────┤
//! │                                                              │
//! │ ARCHITECTURE DIAGRAM                                         │
//! │ ────────────────────                                         │
//! │                                                              │
//! │  ┌─────────┐    ┌───────────────┐    ┌─────────────┐        │
//! │  │ SCI     │───▶│ Clojure       │───▶│ Java        │        │
//! │  │ script  │    │ bridge        │    │ LibSci.java │        │
//! │  │         │    │ libsci_       │    │              │        │
//! │  │(host-   │    │ context.clj   │    │dispatchHost- │        │
//! │  │ call    │    │               │    │ Call(json)   │        │
//! │  │ "add"   │    │ 1. [add,3,4]  │    │              │        │
//! │  │ 3 4)    │    │ 2. →JSON      │    │ 3. invoke(   │        │
//! │  │         │    │ 3. →Java      │    │    cString)  │        │
//! │  │   ▲     │    │               │    │         │    │        │
//! │  │   │     │    │ 6. parseJSON  │    │         │    │        │
//! │  │   │     │    │    ←JSON      │    │         │    │        │
//! │  │   │     │    │ 5. ←Java      │    │ 4. ←CChar │    │        │
//! │  └──┼─────┘    └───────────────┘    └──────┼──────┘    │        │
//! │     │                                       │              │        │
//! │     │              ONE function pointer      │              │        │
//! │     │                                       │              │        │
//! │  ┌──┴───────────────────────────────────────┘              │        │
//! │  │                                                         │        │
//! │  ▼                                                         │        │
//! │  ┌─────────────────────────────────────┐                   │        │
//! │  │ Zig host                            │                   │        │
//! │  │                                     │                   │        │
//! │  │ host_dispatcher(json_args)          │                   │        │
//! │  │   1. extract "add" from JSON[0]     │                   │        │
//! │  │   2. handlers.get("add")            │                   │        │
//! │  │   3. → host_add(json_args)          │                   │        │
//! │  │         parse [add, 3, 4]           │                   │        │
//! │  │         compute 3+4 → 7             │                   │        │
//! │  │         return {"status":"ok",...}   │                   │        │
//! │  │   4. ← result C string              │                   │        │
//! │  └─────────────────────────────────────┘                   │        │
//! │                                                              │
//! │ KEY DESIGN DECISIONS                                         │
//! │ ─────────────────────                                        │
//! │                                                              │
//! │ 1. SINGLE DISPATCHER (not per-function registration)         │
//! │    Java stores ONE function pointer.  Name-based routing     │
//! │    happens in this Zig code via a hashmap.  Adding a new     │
//! │    host function means: one `export fn` + one `register()`   │
//! │    call.  Zero changes to Java or Clojure.                   │
//! │                                                              │
//! │ 2. JSON WIRE FORMAT                                          │
//! │    Arguments go host→SCI as JSON arrays.  Results come back  │
//! │    SCI→host as JSON envelopes.  Every language has JSON,     │
//! │    so the FFI is language-agnostic.                          │
//! │                                                              │
//! │ 3. THREADLOCAL RESULT BUFFER                                 │
//! │    The C ABI returns a `const char*`.  We can't return a     │
//! │    stack address (destroyed on return).  We use a thread-    │
//! │    local buffer.  Java reads it immediately after the call   │
//! │    returns (before the next call could overwrite it), so     │
//! │    this is safe under the single-threaded-isolate model.     │
//! │                                                              │
//! │ DATA FLOW — ONE (host-call "add" 3 4) ROUND TRIP              │
//! │ ──────────────────────────────────────────────               │
//! │                                                              │
//! │   SCI:     (host-call "add" 3 4)                             │
//! │   Clojure: json/generate-string ["add" 3 4]                  │
//! │            → "[\"add\",3,4]" (Java String)                   │
//! │   Java:    CTypeConversion.toCString(str)                    │
//! │            → "[\"add\",3,4]" (null-terminated char*)         │
//! │            dispatcher.invoke(ptr)                              │
//! │   Zig:     host_dispatcher("[\"add\",3,4]")                  │
//! │              parse: name="add", a=3, b=4                     │
//! │              handlers.get("add") → host_add                  │
//! │              host_add computes 3+4=7                         │
//! │              bufPrintZ → "{\"status\":\"ok\",\"value\":7}"    │
//! │              return pointer to result_buf                    │
//! │   Java:    CTypeConversion.toJavaString(ptr)                 │
//! │            → "{\"status\":\"ok\",\"value\":7}" (Java String) │
//! │   Clojure: json/parse-string(str)                            │
//! │            → {:status "ok" :value 7}                         │
//! │   SCI:     ← 7                                               │
//! └──────────────────────────────────────────────────────────────┘

const std = @import("std");
const c = @import("libsci");

// ====================================================================
//  RESULT BUFFER
// ====================================================================
///
/// Every host callback must return a `[*:0]const u8` — a pointer to a
/// null-terminated C string.  We can't return a pointer to the stack
/// (destroyed when the function returns), and we don't want to allocate
/// heap memory per call (slow, needs freeing by the caller — which is
/// Java code that doesn't know about Zig's allocator).
///
/// Solution: a threadlocal fixed-size buffer.  The callback formats
/// its JSON response into this buffer and returns a pointer to it.
///
/// threadlocal = one buffer per OS thread.  If the host uses multiple
/// threads to call into libsci, each thread gets its own buffer.
/// Single-threaded users get one buffer, period.
///
/// 4096 bytes = enough for a JSON envelope with a moderate result.
/// For larger results (file contents, database rows), the callback
/// should allocate heap memory and return that pointer.  The Java
/// side reads it immediately, but YOU are responsible for freeing
/// that memory later (register a cleanup callback, or accept the
/// memory leak).
///
/// @memset initializes the buffer to zero so the first byte is always
/// a null terminator, even before the first write.
threadlocal var result_buf: [4096]u8 = [_]u8{0} ** 4096;

/// Format a success response into result_buf and return a pointer.
///
/// Takes a comptime format string and args (same as std.fmt.bufPrintZ).
/// Comptime means the format is validated at compile time — typos in
/// field names or format specifiers are caught before the binary runs.
///
/// Example:
///   return resultOk("{{\"status\":\"ok\",\"value\":{d}}}", .{42});
///   → result_buf = "{\"status\":\"ok\",\"value\":42}\0"
///
/// Note the double braces {{ and }} — Zig's fmt escapes { as {{.
/// The outer pair is the JSON object, {d} is the placeholder for
/// the decimal integer argument 42.
///
/// unreachable on overflow: if the formatted string exceeds 4096 bytes,
/// std.fmt.bufPrintZ returns an error.  We .catch unreachable because
/// in normal use (JSON envelopes with modest values) this won't happen.
/// Production code should handle this gracefully (allocate, or truncate
/// with a warning).
fn resultOk(comptime fmt: []const u8, args: anytype) [*:0]const u8 {
    const s = std.fmt.bufPrintZ(&result_buf, fmt, args) catch unreachable;
    return s.ptr;
}

/// Format an error response into result_buf.
///
/// The message is a plain []const u8 (not a format string) because
/// error messages are typically simple: "parse error", "unknown table",
/// etc.  For more complex error messages, use resultOk with
/// {\"status\":\"error\",...} directly.
fn resultErr(msg: []const u8) [*:0]const u8 {
    return resultOk(
        "{{\"status\":\"error\",\"message\":\"{s}\"}}",
        .{msg},
    );
}

// ====================================================================
//  MINIMAL JSON ARRAY PARSER
// ====================================================================
///
/// Parses a JSON array like ["string", 42, true, null, 3.14] into
/// a list of typed values.
///
/// This is a MINIMAL parser for example purposes — it handles the
/// subset of JSON that our host functions receive (strings, numbers,
/// booleans, null, inside a flat array).  For production use, replace
/// with a full JSON library (std.json in Zig 0.16, or a third-party
/// library like zjson).
///
/// Limitations of this simple parser:
///   - No nested objects or arrays
///   - No escape sequences in strings (like \n, \t, \")
///   - No scientific notation for numbers (1e10)
///   - No negative numbers (easy to add, omitted for clarity)
///   - Assumes valid JSON (no error recovery)

const JsonArg = union(enum) {
    null_val,
    bool_val: bool,
    int_val: i64,
    float_val: f64,
    string_val: []const u8,
};

fn parseJsonArray(json: [:0]const u8, allocator: std.mem.Allocator) !std.ArrayList(JsonArg) {
    var args = std.ArrayList(JsonArg).init(allocator);
    // errdefer: if we return an error after adding some items, free them.
    // (Simplified — JsonArg contains no heap pointers, so deinit suffices.)
    errdefer args.deinit();

    var i: usize = 0;
    const len = json.len;

    // Skip leading whitespace and the opening '['
    while (i < len and (json[i] == ' ' or json[i] == '[')) : (i += 1) {}

    // Parse elements until we hit ']' or run out of input
    while (i < len and json[i] != ']') {
        // Skip whitespace and commas between elements
        while (i < len and (json[i] == ' ' or json[i] == ',')) : (i += 1) {}

        if (i >= len or json[i] == ']') break;

        // ── Dispatch on first character of value ──

        if (json[i] == '"') {
            // ── STRING ──
            i += 1; // skip opening quote
            const start = i;
            // Find closing quote.  This simplistic version doesn't
            // handle escaped quotes (\").  A real parser would track
            // backslash state.
            while (i < len and json[i] != '"') : (i += 1) {}
            const s = json[start..i];
            // A real JSON parser would unescape here:
            //   s = unescape(s)  — convert \" → ", \\ → \, etc.
            try args.append(.{ .string_val = s });
            i += 1; // skip closing quote

        } else if (json[i] == 't' or json[i] == 'f') {
            // ── BOOLEAN ──
            const is_true = json[i] == 't';
            try args.append(.{ .bool_val = is_true });
            // Skip past "true" (4 chars) or "false" (5 chars)
            i += if (is_true) 4 else 5;

        } else if (json[i] == 'n') {
            // ── NULL ──
            try args.append(.{ .null_val = {} });
            i += 4; // skip past "null"

        } else if (std.ascii.isDigit(json[i]) or json[i] == '-') {
            // ── NUMBER ──
            const start = i;
            var is_float = false;
            while (i < len and (std.ascii.isDigit(json[i]) or
                json[i] == '-' or json[i] == '.' or
                json[i] == 'e' or json[i] == 'E' or json[i] == '+'))
            {
                if (json[i] == '.' or json[i] == 'e' or json[i] == 'E')
                    is_float = true;
                i += 1;
            }
            const num_str = json[start..i];
            if (is_float) {
                try args.append(.{
                    .float_val = try std.fmt.parseFloat(f64, num_str),
                });
            } else {
                try args.append(.{
                    .int_val = try std.fmt.parseInt(i64, num_str, 10),
                });
            }

        } else {
            // Unknown token — skip one char and try to continue
            i += 1;
        }
    }
    return args;
}

// ====================================================================
//  HOST CALLBACK FUNCTIONS
// ====================================================================
///
/// Every host callback has the same C ABI signature:
///
///   export fn handler(args_json: [*:0]const u8) callconv(.c) [*:0]const u8
///
/// export    — makes the symbol visible to the dynamic linker so
///            GraalVM's CFunctionPointer can find it by address.
///            In C terms, this is like __attribute__((visibility("default"))).
///
/// args_json — pointer to a null-terminated C string containing a
///            JSON array.  Element [0] is always the function name
///            (used by the dispatcher for routing).  Elements [1..N]
///            are the arguments passed from the SCI script.
///
///            Example: (host-call "fetch" 42 "Alice")
///              → args_json = "[\"fetch\",42,\"Alice\"]"
///
/// callconv(.c) — use the C calling convention.  This ensures:
///   - Arguments go into the right registers/stack positions
///   - The caller (Java/GraalVM) and callee (Zig) agree on ABI
///   - Without this, Zig uses its own convention which won't match
///
/// Returns [*:0]const u8 — a pointer to a null-terminated C string
/// containing a JSON object:
///   Success: {"status":"ok","value":<result>}
///   Error:   {"status":"error","message":"<details>"}
///
/// The returned pointer must be valid when the caller reads it.
/// We use a threadlocal buffer (result_buf) for this.

// ── SIMPLE ARITHMETIC ──

/// (host-call "host-add" 3 4) → 7
///
/// Parses two numbers from the JSON args array, adds them, returns the sum.
/// args_json = "[\"host-add\",3,4]"
///   items[0] = "host-add"  (function name, used by dispatcher)
///   items[1] = 3           (first argument from SCI)
///   items[2] = 4           (second argument from SCI)
export fn host_add(args_json: [*:0]const u8) callconv(.c) [*:0]const u8 {
    // std.mem.span converts a null-terminated pointer to a Zig slice.
    // [*:0]const u8 → []const u8 (length determined by strlen).
    const args = parseJsonArray(
        std.mem.span(args_json),
        std.heap.page_allocator,
    ) catch return resultErr("host-add: failed to parse arguments");
    defer args.deinit(); // free the ArrayList when this function returns

    // We expect 3 elements: function name + 2 numeric args
    if (args.items.len < 3) return resultErr("host-add: expected 2 numbers");

    // .int_val reads the i64 value from the JsonArg tagged union.
    // parseJsonArray sets .int_val for integer-format JSON numbers.
    const a = args.items[1].int_val;
    const b = args.items[2].int_val;
    return resultOk("{{\"status\":\"ok\",\"value\":{d}}}", .{a + b});
}

// ── STRING PROCESSING ──

/// (host-call "host-greet" "Alice") → "Hello, Alice!"
///
/// Takes one string argument, formats a greeting.
export fn host_greet(args_json: [*:0]const u8) callconv(.c) [*:0]const u8 {
    const args = parseJsonArray(
        std.mem.span(args_json),
        std.heap.page_allocator,
    ) catch return resultErr("host-greet: failed to parse arguments");
    defer args.deinit();

    if (args.items.len < 2) return resultErr("host-greet: expected 1 argument");

    const name = args.items[1].string_val;
    return resultOk(
        "{{\"status\":\"ok\",\"value\":\"Hello, {s}!\"}}",
        .{name},
    );
}

// ── DATABASE QUERY (simulated) ──

/// (host-call "host-query-db" "users" 42)
///   → {"id":42,"name":"User 42","email":"user42@example.com"}
///
/// Demonstrates a callback that takes a string + number and returns
/// a JSON object (nested inside the envelope's :value field).
export fn host_query_db(args_json: [*:0]const u8) callconv(.c) [*:0]const u8 {
    const args = parseJsonArray(
        std.mem.span(args_json),
        std.heap.page_allocator,
    ) catch return resultErr("host-query-db: failed to parse arguments");
    defer args.deinit();

    if (args.items.len < 3)
        return resultErr("host-query-db: expected table name and id");

    const table = args.items[1].string_val;
    const id = args.items[2].int_val;

    // In production, this would do an actual database call.
    // Here we simulate with a hardcoded response.
    if (std.mem.eql(u8, table, "users")) {
        return resultOk(
            \\{"status":"ok",
            \\ "value":{"id":{d},
            \\          "name":"User {d}",
            \\          "email":"user{d}@example.com"}}
        , .{ id, id, id });
    }
    return resultErr("unknown table");
}

// ── FIRE-AND-FORGET NOTIFICATION ──

/// (host-call "host-notify" "file processed") → null
///
/// Logs a message from SCI to the host's stderr.  Returns null
/// (the SCI script doesn't need a meaningful return value).
export fn host_notify(args_json: [*:0]const u8) callconv(.c) [*:0]const u8 {
    const args = parseJsonArray(
        std.mem.span(args_json),
        std.heap.page_allocator,
    ) catch return resultErr("host-notify: parse error");
    defer args.deinit();

    if (args.items.len > 1) {
        const msg = args.items[1].string_val;
        // Write to stderr so it's visible even if stdout is redirected.
        // This is a side effect — the function's real "return" is just
        // an acknowledgement.
        std.debug.print("[host] {s}\n", .{msg});
    }
    return resultOk("{{\"status\":\"ok\",\"value\":null}}", .{});
}

// ──────────────────────────────────────────────────────────────────
//  HOST DISPATCHER
// ──────────────────────────────────────────────────────────────────

/// The callback registry.  Maps function name (as a Zig string) to
/// the corresponding handler function pointer.
///
/// std.StringHashMap hashes by key and stores values.  Lookup is O(1).
/// We use the page allocator for the hashmap's internal structures
/// since it lives for the entire program lifetime.
///
/// Type: HostHandler = *const fn([*:0]const u8) callconv(.c) [*:0]const u8
///   - *const fn        — pointer to a function
///   - callconv(.c)     — that uses the C calling convention
///   - returns [*:0]const u8 — null-terminated C string
var handlers: std.StringHashMap(
    *const fn ([*:0]const u8) callconv(.c) [*:0]const u8,
) = undefined;

/// Register a handler under a name.  Called once per function at startup.
///
/// Example: try register("host-add", &host_add);
///
/// The name must match what SCI scripts pass to host-call:
///   (host-call "host-add" 3 4)    ← "host-add" matches the registered name
fn register(
    comptime name: []const u8,
    handler: *const fn ([*:0]const u8) callconv(.c) [*:0]const u8,
) !void {
    try handlers.put(name, handler);
}

/// THE DISPATCHER — the ONE function Java knows about.
///
/// This function is passed to libsci via set_host_dispatcher(@intFromPtr(&host_dispatcher)).
/// Every (host-call ...) in SCI eventually reaches this function.
///
/// WHAT IT DOES, STEP BY STEP:
///
/// 1. Receives args_json = "[\"host-add\",3,4]"
///    The first element is always the function name (the first arg
///    to host-call in the SCI script).
///
/// 2. Extracts the function name from the JSON array.
///    Scans for the opening quote, reads until the closing quote.
///    This parse is deliberately minimal — we're pulling out one
///    known-position string, not parsing the full JSON.
///
/// 3. Looks up the name in the handlers hashmap.
///    If found → call the handler with the original args_json
///    If not found → return a JSON error: "unknown host function"
///
/// 4. Returns whatever the handler returned — a pointer to a
///    null-terminated JSON string in result_buf.
///
/// WHY PASS THE FULL args_json TO THE HANDLER INSTEAD OF PRE-PARSING?
///
/// Each handler expects different argument types (int, string, bool,
/// etc.).  The dispatcher doesn't know what types a function expects.
/// Passing the full JSON lets each handler parse the args the way it
/// needs to.  The handler re-parses the function name (at index 0)
/// but that cost is negligible compared to the FFI boundary crossing
/// and JSON serialization.
///
/// Alternative: dispatcher parses into a generic Value tree, then
/// passes that.  Pro: handlers get typed args.  Con: allocates a
/// tree on every call.  For now, re-parsing in each handler is simpler.

export fn host_dispatcher(args_json: [*:0]const u8) callconv(.c) [*:0]const u8 {
    // Convert null-terminated pointer to a sized slice.  std.mem.span
    // counts bytes until the null terminator by calling strlen.
    const s = std.mem.span(args_json);

    // ── Extract the function name from the JSON array ──
    //
    // The JSON array always starts with: ["<name>",
    // We find the opening quote, then read until the closing quote.
    // This is intentionally simple — we know the format.

    var i: usize = 0;
    // Find the first double-quote character (start of function name)
    while (i < s.len and s[i] != '"') : (i += 1) {}
    if (i >= s.len)
        return resultErr("malformed args JSON — no opening quote");

    i += 1; // Move past the opening quote to the first char of the name
    const name_start = i;

    // Find the closing quote (end of function name)
    while (i < s.len and s[i] != '"') : (i += 1) {}
    const name = s[name_start..i]; // Zig slice: start..end (end is exclusive)

    // ── Lookup and dispatch ──
    if (handlers.get(name)) |handler| {
        // Found it — call the handler with the full JSON args string.
        // The handler will parse the arguments it needs from the array.
        return handler(args_json);
    }

    // Not found — return a JSON error.  SCI scripts see this as the
    // return value of (host-call ...) and can check :status.
    return resultErr("unknown host function");
}

// ====================================================================
//  MAIN — put it all together
// ====================================================================

pub fn main() !void {
    // ── Set up Zig allocator ──
    //
    // GeneralPurposeAllocator is Zig's standard allocator.  It tracks
    // leaks and detects use-after-free in debug mode.  In release
    // mode, it's a thin wrapper around the system allocator.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit(); // Check for leaks at exit
    const allocator = gpa.allocator();

    // ── Initialize handler registry ──
    //
    // The hashmap holds function pointers indexed by name string.
    // It must be initialized BEFORE set_host_dispatcher is called
    // because the dispatcher reads from it.
    handlers = std.StringHashMap(
        *const fn ([*:0]const u8) callconv(.c) [*:0]const u8,
    ).init(allocator);

    // Register each callback.  The name string must match exactly
    // what SCI scripts pass to (host-call ...).
    try register("host-add",      &host_add);
    try register("host-greet",    &host_greet);
    try register("host-query-db", &host_query_db);
    try register("host-notify",   &host_notify);

    // ── Create GraalVM isolate ──
    //
    // An isolate is GraalVM's execution unit — it owns the heap,
    // the JIT-compiled code, and all static state.  You create one,
    // use it, then tear it down.
    //
    // isolate_t  — the isolate (the "VM instance")
    // thread_t   — a thread attached to the isolate (you need this
    //              to call any other entry point)
    //
    // Both start as null; graal_create_isolate fills them in.
    var isolate: ?*c.graal_isolate_t = null;
    var thread: ?*c.graal_isolatethread_t = null;
    _ = c.graal_create_isolate(null, &isolate, &thread);
    // defer ensures tear_down runs even if we return early (error, etc.)
    defer _ = c.graal_tear_down_isolate(thread);

    // ── Register the dispatcher with libsci ──
    //
    // This passes the address of our host_dispatcher function into
    // the Java world.  @intFromPtr converts a pointer to a usize
    // (which matches the long parameter in Java's setHostDispatcher).
    //
    // After this call, any (host-call ...) in a SCI script will
    // route through host_dispatcher above.
    c.set_host_dispatcher(thread, @intFromPtr(&host_dispatcher));

    // ── Load the SCI script ──
    //
    // This creates the persistent SCI context and evaluates our
    // Clojure code into it.  The functions defined here can call
    // back into Zig via (host-call ...).
    //
    // The script defines:
    //   compute      — arithmetic via host-call
    //   lookup-user  — database query via host-call
    //   notify-done  — fire-and-forget notification via host-call
    _ = c.load_script(thread,
        \\(defn compute [x y]
        \\  (let [sum  (host-call "host-add" x y)
        \\        msg  (host-call "host-greet" (str "sum = " sum))]
        \\    {:sum sum :greeting msg}))
        \\
        \\(defn lookup-user [id]
        \\  (host-call "host-query-db" "users" id))
        \\
        \\(defn notify-done [task]
        \\  (host-call "host-notify" (str "completed: " task))
        \\  :ok)
    );

    const stdout = std.io.getStdOut().writer();

    // ── Example 1: compute 3+4 via SCI → host → SCI ──
    const r1 = c.call_function(thread, "compute", "3 4");
    try stdout.print("compute(3, 4): {s}\n", .{std.mem.span(r1)});

    // ── Example 2: "database" query ──
    const r2 = c.call_function(thread, "lookup-user", "42");
    try stdout.print("lookup-user(42): {s}\n", .{std.mem.span(r2)});

    // ── Example 3: fire-and-forget notification ──
    const r3 = c.call_function(thread, "notify-done", "\"data-sync\"");
    try stdout.print("notify-done: {s}\n", .{std.mem.span(r3)});

    // ── Example 4: ad-hoc eval referencing loaded defs ──
    const r4 = c.eval_in_context(thread,
        \\(let [result  (compute 10 20)
        \\       user    (lookup-user (:sum result))
        \\       _       (notify-done "adhoc")]
        \\  {:result result :user user})
    );
    try stdout.print("adhoc: {s}\n", .{std.mem.span(r4)});
}

// ====================================================================
//  BUILD INSTRUCTIONS (build.zig)
// ====================================================================
///
/// To build this example, create a sibling build.zig:
///
/// ```
/// const std = @import("std");
///
/// pub fn build(b: *std.Build) void {
///     const target = b.standardTargetOptions(.{});
///     const optimize = b.standardOptimizeOption(.{});
///
///     const exe = b.addExecutable(.{
///         .name = "sci-host",
///         .root_source_file = b.path("main.zig"),
///         .target = target,
///         .optimize = optimize,
///     });
///
///     // Translate the C header so @import("libsci") works
///     const translate = b.addTranslateC(.{
///         .root_source_file = b.path("include/libsci.h"),
///         .target = target,
///         .optimize = optimize,
///     });
///     exe.root_module.addImport("libsci", translate.createModule());
///
///     // Link against the libsci shared library
///     exe.addLibraryPath(b.path("lib"));
///     exe.linkSystemLibrary("sci");
///     exe.addRPath(b.path("lib"));
///
///     b.installArtifact(exe);
/// }
/// ```
///
/// Directory layout expected:
/// ```
/// project/
/// ├── build.zig
/// ├── main.zig        (this file)
/// ├── include/
/// │   ├── libsci.h
/// │   ├── libsci_dynamic.h
/// │   ├── graal_isolate.h
/// │   └── graal_isolate_dynamic.h
/// └── lib/
///     └── libsci.dylib   (macOS) or libsci.so (Linux) or libsci.dll (Windows)
/// ```
///
/// Build:  zig build
/// Run:    ./zig-out/bin/sci-host
