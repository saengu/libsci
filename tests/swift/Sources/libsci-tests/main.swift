// libsci Swift 6.3 integration tests (Linux/x86_64)

import Clibsci
#if canImport(Glibc)
import Glibc
#endif

// ── Test harness ────────────────────────────────────────────────

nonisolated(unsafe) var testsRun = 0
nonisolated(unsafe) var testsPassed = 0

private func test(_ name: String, body: () -> Bool) {
    testsRun += 1
    let passed = body()
    if passed { testsPassed += 1 }
    print("  \(passed ? "PASS" : "FAIL"): \(name)")
}

private func jsonOk(_ ptr: UnsafeMutablePointer<CChar>?) -> Bool {
    guard let p = ptr else { return false }
    return String(cString: p).contains("\"status\":\"ok\"")
}

/// Create GraalVM Isolate + SCI context.
/// GraalVM types are opaque pointers — use OpaquePointer? throughout.
private func createContext() -> OpaquePointer? {
    var isolate: OpaquePointer?
    var thread: OpaquePointer?
    guard graal_create_isolate(nil, &isolate, &thread) == 0 else { return nil }
    sci_create_context(thread)
    return thread
}

private func destroyContext(_ thread: OpaquePointer?) {
    guard let t = thread else { return }
    sci_destroy_context(t)
    _ = graal_tear_down_isolate(t)
}

// ── Host callback ───────────────────────────────────────────────
//
// @_cdecl exports the function with C calling convention matching
// the sci_host_fn_t typedef: char *(*)(const char *).
// The returned pointer is passed through CCharPointerHolder
// (no extra free needed from Swift side).

@_cdecl("hostAdd")
func hostAdd(_ jsonArgs: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    return strdup("{\"status\":\"ok\",\"value\":7}")
}

// ── Tests ───────────────────────────────────────────────────────

func testVersion() -> Bool {
    guard let thread = createContext() else { return false }
    defer { destroyContext(thread) }

    guard let ver = sci_version(thread) else { return false }
    guard !String(cString: ver).isEmpty else { return false }
    return sci_abi_version(thread) > 0
}

func testCreateDestroy() -> Bool {
    guard let thread = createContext() else { return false }
    destroyContext(thread)
    return true
}

func testEvalSimple() -> Bool {
    guard let thread = createContext() else { return false }
    defer { destroyContext(thread) }

    let r = "(+ 1 2)".withCString { sci_eval_string(thread, $0) }
    guard let s = r.map({ String(cString: $0) }) else { return false }
    return s.contains("\"status\":\"ok\"") && s.contains("\"value\":\"3\"")
}

func testEvalError() -> Bool {
    guard let thread = createContext() else { return false }
    defer { destroyContext(thread) }

    let r = "(+ 1".withCString { sci_eval_string(thread, $0) }
    return r.map({ String(cString: $0) })?.contains("\"status\":\"error\"") ?? false
}

func testPersistentContext() -> Bool {
    guard let thread = createContext() else { return false }
    defer { destroyContext(thread) }

    "(def x 42)".withCString { _ = sci_eval_string(thread, $0) }
    let r = "x".withCString { sci_eval_string(thread, $0) }
    return r.map({ String(cString: $0) })?.contains("\"value\":\"42\"") ?? false
}

func testResetContext() -> Bool {
    guard let thread = createContext() else { return false }
    defer { destroyContext(thread) }

    "(def x 1)".withCString { _ = sci_eval_string(thread, $0) }
    sci_reset_context(thread)

    let r = "(try x (catch Exception e \"err\"))".withCString { sci_eval_string(thread, $0) }
    return r.map({ String(cString: $0) })?.contains("err") ?? false
}

func testHostCallback() -> Bool {
    guard let thread = createContext() else { return false }
    defer { destroyContext(thread) }

    "test".withCString { ns in
        "add".withCString { fn in
            // Convert to @convention(c) thin function value, then cast to integer.
            let cb: @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? = hostAdd
            let addr = unsafeBitCast(cb, to: UInt.self)
            sci_register_host_fn(thread, ns, fn, Int64(addr))
        }
    }

    let r = "(host/invoke \"test\" \"add\" 3 4)".withCString { sci_eval_string(thread, $0) }
    return jsonOk(r)
}

func testHostCallbackSugar() -> Bool {
    guard let thread = createContext() else { return false }
    defer { destroyContext(thread) }

    "test".withCString { ns in
        "add".withCString { fn in
            let cb: @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? = hostAdd
            let addr = unsafeBitCast(cb, to: UInt.self)
            sci_register_host_fn(thread, ns, fn, Int64(addr))
        }
    }

    let r = "(test/add 3 4)".withCString { sci_eval_string(thread, $0) }
    return String(cString: r!).contains("\"value\":\"7\"")
}

func testCallScriptFn() -> Bool {
    guard let thread = createContext() else { return false }
    defer { destroyContext(thread) }

    "(defn count-items [v] (count v))".withCString { _ = sci_eval_string(thread, $0) }

    let r = "user".withCString { ns in
        "count-items".withCString { fn in
            "[1 2 3]".withCString { args in
                sci_call_script_fn(thread, ns, fn, args)
            }
        }
    }
    return String(cString: r!).contains("\"value\":\"3\"")
}

// ── Main ────────────────────────────────────────────────────────

print("libsci Swift API integration tests")
print("-------------------------------")

test("version", body: testVersion)
test("create_destroy", body: testCreateDestroy)
test("eval_simple", body: testEvalSimple)
test("eval_error", body: testEvalError)
test("persistent_context", body: testPersistentContext)
test("reset_context", body: testResetContext)
test("host_callback", body: testHostCallback)
test("host_callback_sugar", body: testHostCallbackSugar)
test("call_script_fn", body: testCallScriptFn)

print("\n\(testsPassed) / \(testsRun) tests passed")
if testsPassed != testsRun { exit(1) }
