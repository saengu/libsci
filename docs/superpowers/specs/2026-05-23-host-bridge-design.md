# Host Bridge Design -- Persistent Context + Host Function Dispatch

- **Date**: 2026-05-23
- **Status**: Draft (reviewed)

## Summary

Add persistent SCI context and host function dispatch to libsci, enabling
bidirectional calls between host language and Clojure scripts without
rebuilding the shared library for new host functions.

## Architecture

Three layers:

```
Host Language (Zig/C/Rust/Go/...)
  +----------------------------------+
  | host_dispatcher(json_args)       |  <- C function pointer
  |   - parse JSON array             |     registered once at startup
  |   - dispatch by name (hashmap)   |
  |   - return JSON envelope         |
  +--------------+-------------------+
                 | C function pointer
                 v
libsci shared library (GraalVM native-image)
  +-------------------------------------+
  | LibSciHost.java   (@CEntryPoints)   |
  |   - HostDispatcher interface        |  <- direct cast, not toProxy()
  |   - set_host_dispatcher / load_     |
  |     script / call_function /        |
  |     eval_in_context /               |
  |     reset_context                   |
  +-------------------------------------+
  | libsci_host.clj   (Clojure bridge)  |
  |   - ctx atom (persistent state)     |
  |   - host-call JSON protocol         |
  |   - base-init (cheshire + binding)  |
  +-------------------------------------+
```

## C API

```
void     set_host_dispatcher(thread, fn_ptr);   // one-time registration
char*    load_script(thread, script);            // load into persistent ctx
char*    call_function(thread, fn_name, edn_args); // call function in ctx
char*    eval_in_context(thread, expr);                  // eval in persistent ctx
void     reset_context(thread);                       // destroy ctx
char*    eval(thread, expr);                      // eval in fresh ctx (renamed from eval_string)
```

All `char*` returns are JSON envelopes:
```json
{"status":"ok",    "value":"<result>"}
{"status":"error", "error":"<class>", "message":"<detail>"}
```

## JSON Wire Protocol (host-call)

Direction: SCI script -> Host language.

```
SCI: (host-call "add" 3 4)
  -> Clojure: json/generate-string ["add", 3, 4]
  -> Java: HostDispatcher.dispatch(cString)
  -> Host C function: parse JSON, hashmap lookup, execute
  -> Returns: {"status":"ok","value":7}
  -> Clojure: json/parse-string, return :value
```

### Single round-trip cost breakdown

| Operation | Approx time |
|---|---|
| C function pointer jump | ~10-30ns |
| toCString / toJavaString (small) | ~100-500ns |
| json/generate-string (small) | ~500-2000ns |
| json/parse-string (small) | ~500-2000ns |
| SCI eval-string* (single call) | ~5000-50000ns |

Total ~1-5us per host-call for typical payloads. JSON serialization is the
dominant cost; acceptable for most use cases where script logic dominates FFI
call frequency.

`call_function` uses EDN for arguments (supports keywords, ratios, sets,
symbols, and other Clojure-native types). The host constructs the EDN string;
this is not a security risk since call_function is only invoked by the host,
not by untrusted script input.

### EDN call_function examples

```c
// Cross-namespace call
call_function(thread, "clojure.core/map", "inc [1 2 3]");

// Keywords
call_function(thread, "assoc", "{:a 1} :b 2 :c 3");

// Special types (ratio, set, symbol)
call_function(thread, "clojure.set/union", "#{1 2} #{2 3}");
call_function(thread, "resolve", "'my.ns/my-var");

// Real-world mix
call_function(thread, "my-app/process-order",
    "{:id 42 :items [{:sku \"A-1\" :qty 3}]} :premium true");
```

## Key Implementation Detail: CFunctionPointer

**Root cause of patch failure**: `WordFactory.pointer(fnPtr).toProxy(iface)`
generates a dynamic proxy at runtime, which is forbidden in GraalVM native-image
(closed world, no runtime code generation).

**Fix**: Use direct cast instead:

```java
public interface HostDispatcher extends CFunctionPointer {
    @CFunction
    CCharPointer dispatch(CCharPointer jsonArgs);
}

private static HostDispatcher dispatcher = WordFactory.nullPointer();

@CEntryPoint(name = "set_host_dispatcher")
public static void setHostDispatcher(long isolateId, long fnPtr) {
    dispatcher = (HostDispatcher) WordFactory.pointer(fnPtr);
}
```

The `@CFunction` annotation lets GraalVM generate the calling trampoline at
**build time**. `(HostDispatcher) WordFactory.pointer(ptr)` is a Word type cast,
not a proxy -- it requires no runtime code generation. This is the same Word type
system used in the existing working code (`CCharPointer value = holder.get()`).

## C String Lifetime Contract

This is critical for correctness across the FFI boundary.

### Input (host -> libsci)

`CTypeConversion.toJavaString(s)` copies the C string content into a Java String
at the entry point. The original C string can be freed immediately after the
@CEntryPoint returns.

### Output (libsci -> host)

`CTypeConversion.toCString(result)` allocates off-heap native memory managed by
GraalVM. The returned `CCharPointer` points to this memory. The native memory is
freed when the `CCharPointerHolder` is garbage collected (via finalizer).

In practice GC only runs during Java code execution (inside `@CEntryPoint`
calls), so the pointer remains valid from when the `@CEntryPoint` returns until
the NEXT `@CEntryPoint` call triggers GC. This gives the host a safe window of
at least one full "host code -> libsci call -> return" cycle.

**But relying on this window is fragile.** The host should copy the string
content into its own memory immediately after every `@CEntryPoint` call. See
[Best practice: host should immediately copy](#best-practice-host-should-immediately-copy)
for language-specific examples.

### host-call return value

When the host dispatcher returns a `const char*`, it points to memory owned by
the **host**. Java calls `CTypeConversion.toJavaString(result)` immediately
(synchronous call), so the pointer must remain valid until that call returns.

**Contract**: The host MUST ensure the returned pointer is:
- A thread-local or statically allocated buffer (not freed on return)
- Readable until the dispatcher function returns to Java
- **NOT** heap allocated memory that the host expects Java to free
  (Java has no mechanism to free host heap memory)

The recommended pattern for the dispatcher is a thread-local fixed-size buffer
(as shown in the Zig example: `threadlocal var result_buf: [4096]u8`).

### Best practice: host should immediately copy

Even though the `CConst` return pointer is safe until the next libsci call,
the **host language should copy the string into its own memory immediately**
after every `@CEntryPoint` call. This eliminates any lifecycle coupling
between Java's GC timing and the host's string usage:

```
@CEntryPoint return -> host reads CCharPointer -> host copies to own string -> host uses string

The copy creates an independent string that:
  [OK] Lives as long as the host needs it
  [OK] Doesn't depend on isolate's GC timing
  [OK] Can be safely passed across threads in the host
  [OK] Lets libsci's native memory be reused/GC'd freely
```

Copy overhead (100-500ns for typical <1KB strings) is negligible compared to
SCI eval time (several microseconds to milliseconds).

#### Example: Zig -- immediate copy via allocator

```zig
pub fn callFunction(thread: anytype, allocator: std.mem.Allocator, name: []const u8, args: []const u8) ![]const u8 {
    const raw = c.call_function(thread, name.ptr, args.ptr);
    // immediately copy to own memory
    return try allocator.dupe(u8, std.mem.span(raw));
}
```

#### Example: C -- immediate copy via strdup

```c
const char* raw = eval_in_context(thread, "(+ 1 2)");
char* result = strdup(raw);      // immediately copy
// ... use result, no longer depends on raw pointer ...
free(result);                     // host controls lifecycle
```

#### Example: Go -- GoString copies automatically

```go
// GoString already performs an internal copy
result := C.GoString(C.eval_in_context(thread, expr))
// result is an independent Go string with no lifecycle coupling
```

#### Example: Rust -- immediate copy

```rust
let raw = eval_in_context(thread, cstr_ptr);
let result = unsafe { CStr::from_ptr(raw).to_str()?.to_string() };
// result is an owned Rust String, no raw pointer coupling
```

#### Example: Python -- ctypes returns copied bytes

```python
lib.eval_in_context.restype = ctypes.c_char_p
raw = lib.eval_in_context(thread, ctypes.c_char_p(b"(+ 1 2)"))
# c_char_p returns a Python bytes object (copied)
result = raw.decode("utf-8")
```

#### Example: Swift -- String(cString:) copies

```swift
let raw = eval_in_context(thread, expr)
let result = raw.map { String(cString: $0) }
// String(cString:) copies the C string content
```

The copy pattern is especially important in multi-threaded hosts where the
raw pointer's owning buffer (thread-local or GraalVM-managed) may be
invalidated by concurrent operations.

## Multi-threading

### Isolate constraint

The current native-image build uses default single-threaded isolate mode
(no `-H:+AllowVMInspection` flag). In this mode:

- Only one thread can call into the isolate at a time
- The host **must serialize** all @CEntryPoint calls with a mutex
- `host-call` dispatcher callbacks run on the same thread as the calling
  @CEntryPoint -- the dispatcher's result buffer has no concurrent access

### Per-thread context model

Each thread independently calls `load_script` to create its own SCI context.
The Clojure bridge uses a per-thread atom map instead of a single global atom:

```clojure
(defonce contexts (atom {}))  ;; {thread-id -> ctx}

(defn- get-ctx []
  (get @contexts (.getId (Thread/currentThread))))

(defn- set-ctx! [ctx]
  (swap! contexts assoc (.getId (Thread/currentThread)) ctx))
```

**`load_script` per-call behavior** (replaces the old global-ctx approach):

```clojure
(defn -loadScript [s]
  (sci/binding [sci/out *out*]
    (try
      (let [ctx (get-ctx)
            c   (if ctx
                  (do (reset! (get-ctx) (sci/merge-opts ctx {}))
                      ctx)
                  (let [c (sci/init base-opts)]
                    (set-ctx! c)
                    c))]
        (let [result (sci/eval-string* c s)]
          (json/generate-string {:status "ok" :value (str result)})))
      (catch Exception e
        (json/generate-string
          {:status "error" :error (str (type e)) :message (.getMessage e)})))))
```

Wait -- this still calls `merge-opts` every time. Better: use a flag to track
whether init has happened, and avoid merging empty opts:

```clojure
(defn- get-or-init-ctx []
  (if-let [ctx (get-ctx)]
    ctx
    (let [new-ctx (sci/init base-opts)]
      (set-ctx! new-ctx)
      new-ctx)))

(defn -loadScript [s]
  (sci/binding [sci/out *out*]
    (try
      (let [c      (get-or-init-ctx)
            result (sci/eval-string* c s)]
        (json/generate-string {:status "ok" :value (str result)}))
      (catch Exception e
        (json/generate-string
          {:status "error" :error (str (type e)) :message (.getMessage e)})))))
```

First call on each thread -> init -> subsequent calls on same thread reuse.

### Thread safety summary

| Component | Mechanism | Safety |
|---|---|---|
| `dispatcher` field | `volatile`, write-once | [OK] All threads see same value |
| `contexts` atom | CAS swap per-thread key | [OK] Per-thread key prevents races |
| `CCharPointerHolder` | Stack-local | [OK] Thread-isolated |
| Host dispatcher buffer | Synchronous callback on calling thread | [OK] No concurrent access |
| SCI eval state | Isolated per-thread context | [OK] No shared SCI state

## Clojure Bridge Implementation Notes

The bridge maintains a per-thread context registry (not a single global atom as
in earlier drafts). Each OS thread independently calls `load_script` to create
its own SCI context.

### gen-class declaration

```clojure
(ns sci.impl.libsci-host
  (:require [cheshire.core :as json]
            [sci.core :as sci])
  (:gen-class
   :methods [^{:static true} [loadScript     [String] String]
             ^{:static true} [callFunction   [String String] String]
             ^{:static true} [evalInContext  [String] String]
             ^{:static true} [resetContext   [] void]]))
```

Note: `fork_context` is NOT in the first iteration. Per-thread context isolation
is achieved by having each thread independently call `load_script`.

### Per-thread context model

```clojure
(defonce contexts (atom {}))  ;; {thread-id -> ctx}

(defn- get-ctx []
  (get @contexts (.getId (Thread/currentThread))))

(defn- set-ctx! [ctx]
  (swap! contexts assoc (.getId (Thread/currentThread)) ctx))
```

### Lazy context initialization

```clojure
(defn- get-or-init-ctx []
  (if-let [ctx (get-ctx)]
    ctx
    (let [new-ctx (sci/init base-opts)]
      (set-ctx! new-ctx)
      new-ctx)))

(defn -loadScript [s]
  (sci/binding [sci/out *out*]
    (try
      (let [c      (get-or-init-ctx)
            result (sci/eval-string* c s)]
        (json/generate-string {:status "ok" :value (str result)}))
      (catch Exception e
        (json/generate-string
          {:status "error" :error (str (type e)) :message (.getMessage e)})))))

(defn -resetContext []
  (swap! contexts dissoc (.getId (Thread/currentThread))))
```

First call on each thread -> `sci/init` -> subsequent calls reuse. No unnecessary
`merge-opts {}` on every call.

### fixed: JSON parse error returns structured envelope

```clojure
;; BAD -- returns raw string on parse failure:
(try (json/parse-string raw-result true)
     (catch Exception _ raw-result))

;; GOOD -- structured error that SCI scripts can handle:
(try (json/parse-string raw-result true)
     (catch Exception e
       {:status "error"
        :message (str "Failed to parse host response: " (.getMessage e))}))
```

### `defonce` base options

```clojure
(defonce base-opts
  {:namespaces {'cheshire.core
                {'generate-string json/generate-string
                 'parse-string    json/parse-string}}
   :bindings {'host-call (fn [& args]
                          (let [args-json  (json/generate-string (vec args))
                                raw-result (sci.impl.LibSciHost/dispatchHostCall args-json)]
                            (if (string? raw-result)
                              (try (json/parse-string raw-result true)
                                   (catch Exception e
                                     {:status "error"
                                      :message (str "Failed to parse host response: "
                                                    (.getMessage e))}))
                              raw-result)))}})
```

The closure captures no mutable external state, so `defonce` is safe.

### Performance note: batch host calls

Avoid calling `(host-call ...)` in tight SCI loops. Each call incurs JSON
serialization overhead (~2-4us). For bulk operations, define batch functions:

```clojure
;; BAD -- 10,000 individual host-calls:
(doseq [i (range 10000)]
  (host-call "process" i))

;; GOOD -- one call with a vector argument:
(host-call "process-batch" (vec (range 10000)))
```

The host-side batch handler iterates and returns aggregated results.

## Files

### New
- `libsci/src/sci/impl/LibSciHost.java` -- @CEntryPoints + HostDispatcher
- `libsci/src/sci/impl/libsci_host.clj` -- Clojure bridge
- `tests/` -- test directory
- `docs/superpowers/specs/` -- this document

### Modified
- `project.clj` -- add `sci.impl.libsci-host` to `:aot`
- `libsci/bb/libsci_tasks.clj` -- add `LibSciHost.java` to javac command

## Testing

Three-level test strategy:

### Level 1: JVM Unit Tests
Run without GraalVM, test Clojure bridge logic directly:

```clojure
;; tests/libsci_host_test.clj
(deftest load-and-call
  (libsci_host/-loadScript "(defn add [x y] (+ x y))")
  (let [result (-callFunction "add" "3 4")]
    (is (= "7" (-> result json/parse-string (get "value"))))))

(deftest host-call-error-no-dispatcher
  (let [result (libsci_host/-loadScript "(host-call \"add\" 3 4)")]
    (is (= "error" (-> result json/parse-string (get "status"))))))

(deftest per-thread-isolation
  (testing "each thread has independent context"
    (libsci_host/-loadScript "(def x 1)")
    (let [main-x (-> (-evalInContext "x") json/parse-string (get "value"))]
      (is (= "1" main-x)))
    ;; Simulate another thread: reset and load different def
    (libsci_host/-resetContext)
    (libsci_host/-loadScript "(def x 2)")
    (let [other-x (-> (-evalInContext "x") json/parse-string (get "value"))]
      (is (= "2" other-x)))))

(deftest load-script-error
  (let [result (libsci_host/-loadScript "(+ 1")]
    (is (= "error" (-> result json/parse-string (get "status"))))
    (is (-> result json/parse-string (get "error") str/includes? "Exception"))))
```

### Level 2: Native-image Build Verification
Compile libsci with `bb libsci:compile` to verify @CEntryPoint + @CFunction
compile correctly in GraalVM 23 CE --shared build.

### Level 3: C Integration Test
A minimal C program that:
1. Creates isolate
2. Calls `set_host_dispatcher` with a simple callback
3. Loads a script that uses `(host-call ...)`
4. Verifies the round-trip returns the expected value
5. Tests `call_function` with EDN args
6. Tests `per-thread load_script` isolation (simulated with two sequential `reset_context` + `load_script` cycles)

## Security

| Surface | Risk | Mitigation |
|---|---|---|
| host-call injection | Low | Only loaded scripts can call it; host dispatcher controls routing |
| call_function EDN injection | Low | Caller is the host language, not untrusted input |
| Dispatcher null pointer | Low | `.isNull()` check before dispatch, returns JSON error |
| Clojure eval exception | Low | All eval wrapped in `try/catch`, returns JSON error envelope |
| C string buffer overflow | Medium | Host responsibility; documented contract for thread-local buffer |
| Per-thread context race | Low | `contexts` map indexed by thread-id; no cross-thread writes |

## Performance Guidelines

### Batch host calls when in loops

Each `(host-call ...)` adds ~2-4us for JSON serialization. For scripts that
call host functions in tight loops, define batch handlers:

```clojure
;; PREFER: single batch call
(host-call "process-batch" [item1 item2 ... itemN])

;; AVOID: per-item host-call in loop
(doseq [item items]
  (host-call "process" item))
```

### String copy overhead

The recommended "immediate copy" pattern (see SC String Lifetime Contract) adds
~100-500ns per call for typical <1KB strings. Relative to SCI eval time
(microseconds to milliseconds), this is negligible.

## Review History

### First review (2026-05-23)

- **Architecture**: Three-layer separation is clean. Single-dispatcher pattern
  correctly solves the no-rebuild requirement.
- **CFunctionPointer**: Direct cast replaces `toProxy()`, avoiding runtime code
  generation. Requires native-image build verification.
- **Perf**: ~1-5us per host-call, JSON serialization is the dominant cost.
- **Multi-threading**: volatile dispatcher + per-thread context map + thread-ID-keyed
  atom provide correct isolation.

### Second review (2026-05-23) -- critical fix

- **Removed `fork_context`**: Original design replaced global ctx on fork,
  breaking multi-thread isolation. Replaced with per-thread `load_script` model:
  each thread independently initializes its own context via the `contexts` map
  keyed by thread ID. No need for explicit fork -- isolation is automatic.
- **Isolate constraint documented**: Single-threaded isolate requires host
  serialization of @CEntryPoint calls via mutex; host-call dispatcher runs on
  calling thread (no concurrent buffer access).
- **JSON parse error**: Changed from returning raw string to returning structured
  error envelope; SCI scripts can now uniformly handle host dispatcher errors.
- **Batch processing**: Added guidance to avoid per-item `host-call` in tight
  loops; recommended pattern is single batch call with vector argument.

### Alternatives considered and rejected

1. **Data protocol (no CFunctionPointer)**: Requires async continuation-passing
   style, degrades programming model too much.
2. **@CEntryPoint parameter**: Passes dispatcher on every call instead of
   storing it; API verbosity not justified by benefits.
3. **`fork_context` with shared global ctx**: Replaces global on fork, breaking
   multi-thread isolation -- replaced by per-thread load_script model.
