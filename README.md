# libsci-build

Prebuilt dynamic link libraries for [babashka/SCI](https://github.com/babashka/SCI) — a Clojure interpreter embeddable in any language with C FFI.

## Supported Platforms

| Platform | Architecture | Dynamic Library | Download |
|----------|-------------|-----------------|----------|
| Linux | x86_64 | `libsci.so` | `libsci-linux-x86_64.zip` |
| Linux | ARM64 (aarch64) | `libsci.so` | `libsci-linux-aarch64.zip` |
| macOS | x86_64 (Intel) | `libsci.dylib` | `libsci-macos-x86_64.zip` |
| macOS | ARM64 (Apple Silicon) | `libsci.dylib` | `libsci-macos-aarch64.zip` |
| Windows | x86_64 | `libsci.dll` + `sci.lib` | `libsci-windows-x86_64.zip` |

Each release zip contains:

```
libsci-<platform>.zip
├── lib/
│   └── <dynamic library + import library on Windows>
└── include/
    ├── libsci.h
    ├── libsci_dynamic.h
    ├── graal_isolate.h
    └── graal_isolate_dynamic.h
```

## API

The library exports a single evaluation function plus GraalVM isolate lifecycle management:

```c
// Create an execution context
int graal_create_isolate(graal_create_isolate_params_t* params,
                         graal_isolate_t** isolate,
                         graal_isolatethread_t** thread);

// Evaluate a Clojure expression, returns the result as a string
char* eval_string(graal_isolatethread_t* thread, const char* expr);

// Tear down the execution context
int graal_tear_down_isolate(graal_isolatethread_t* thread);
```

## Usage Examples

The prebuilt library uses `@rpath` as its install name on macOS (`@rpath/libsci.dylib`). On Linux the SONAME is `libsci.so`, and on Windows the DLL is loaded by filename. You can make the library discoverable either at **link time** (by embedding an rpath) or at **runtime** (via environment variables).

| OS | Link-time flag | Runtime env var |
|---|---|---|
| macOS | `-Wl,-rpath,./lib` | `DYLD_LIBRARY_PATH=./lib` |
| Linux | `-Wl,-rpath,./lib` | `LD_LIBRARY_PATH=./lib` |
| Windows | (link against `.lib`) | `PATH` (include DLL dir) |

### C (C99 or later)

```c
#include "libsci.h"

int main(int argc, char* argv[]) {
    graal_isolate_t *isolate = NULL;
    graal_isolatethread_t *thread = NULL;
    graal_create_isolate(NULL, &isolate, &thread);
    char *result = eval_string(thread, argv[1]);
    printf("%s\n", result);
    graal_tear_down_isolate(thread);
}
```

Build with rpath (recommended):

```bash
# macOS
gcc -o myapp main.c -L./lib -I./include -lsci -Wl,-rpath,./lib

# Linux
gcc -o myapp main.c -L./lib -I./include -lsci -Wl,-rpath,./lib
```

Or use the runtime env var:

```bash
# macOS
gcc -o myapp main.c -L./lib -I./include -lsci
DYLD_LIBRARY_PATH=./lib ./myapp "(+ 1 2)"

# Linux
gcc -o myapp main.c -L./lib -I./include -lsci
LD_LIBRARY_PATH=./lib ./myapp "(+ 1 2)"
```

### Rust (edition 2021)

```rust
// build.rs
println!("cargo:rustc-link-search=native=./lib");
println!("cargo:rustc-link-lib=sci");
// macOS/Linux: embed rpath so the library is found at runtime
println!("cargo:rustc-link-arg=-Wl,-rpath,./lib");

// src/main.rs — bindgen or manual FFI
extern "C" {
    fn graal_create_isolate(params: *const std::ffi::c_void, isolate: *mut *mut std::ffi::c_void, thread: *mut *mut std::ffi::c_void) -> i32;
    fn eval_string(thread: *mut std::ffi::c_void, expr: *const std::ffi::c_char) -> *const std::ffi::c_char;
    fn graal_tear_down_isolate(thread: *mut std::ffi::c_void) -> i32;
}
```

### Zig (0.16)

build.zig:

```zig
// Link against libsci and set rpath
exe.addLibraryPath(b.path("lib"));
exe.linkSystemLibrary("sci");
exe.addRPath(b.path("lib"));
```

```zig
// main.zig
const c = @import("libsci");

var isolate: ?*c.graal_isolate_t = null;
var thread: ?*c.graal_isolatethread_t = null;
_ = c.graal_create_isolate(null, &isolate, &thread);
const result = c.eval_string(thread, "(+ 1 2)");
defer _ = c.graal_tear_down_isolate(thread);
```

### Go (1.21+)

```go
/*
#cgo LDFLAGS: -L./lib -lsci -Wl,-rpath,./lib
#include "libsci.h"
*/
import "C"

func main() {
    var isolate *C.graal_isolate_t
    var thread *C.graal_isolatethread_t
    C.graal_create_isolate(nil, &isolate, &thread)
    defer C.graal_tear_down_isolate(thread)

    expr := C.CString("(+ 1 2)")
    result := C.GoString(C.eval_string(thread, expr))
    fmt.Println(result)
}
```

### Python (3.8+)

```python
import platform
from ctypes import CDLL, c_char_p, c_void_p, byref

# Platform-appropriate library name
lib_name = {"Darwin": "./lib/libsci.dylib", "Linux": "./lib/libsci.so", "Windows": "./lib/libsci.dll"}
dll = CDLL(lib_name[platform.system()])

isolate, thread = c_void_p(), c_void_p()
dll.graal_create_isolate(None, byref(isolate), byref(thread))
dll.eval_string.restype = c_char_p
print(dll.eval_string(thread, c_char_p(b"(+ 1 2)")))
```

### Swift (6.3)

Swift 6.3's `@c` block imports C headers directly in Swift source — no bridging header or module map needed.

```swift
// main.swift
@c { """
#include "libsci.h"
""" }

var isolate: UnsafeMutablePointer<graal_isolate_t>? = nil
var thread: UnsafeMutablePointer<graal_isolatethread_t>? = nil

graal_create_isolate(nil, &isolate, &thread)
defer { graal_tear_down_isolate(thread) }

let expr = "(+ 1 2)"
if let result = eval_string(thread, expr) {
    print(String(cString: result))
}
```

Build with `swiftc`:

```bash
# macOS
swiftc -o myapp main.swift -I./include -L./lib -lsci \
  -Xlinker -rpath -Xlinker @loader_path/lib

# Linux
swiftc -o myapp main.swift -I./include -L./lib -lsci \
  -Xlinker -rpath -Xlinker '$ORIGIN/lib'
```

Or with SwiftPM (`Package.swift`):

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "myapp",
    targets: [
        .executableTarget(
            name: "myapp",
            path: ".",
            sources: ["main.swift"],
            cSettings: [.headerSearchPath("include")],
            linkerSettings: [
                .linkedLibrary("sci"),
                .unsafeFlags(["-L", "lib"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/lib"])
            ]
        )
    ]
)
```

When implementing C callback interfaces (e.g., for the function pointer registry in the host functions section), use `@implement` to create a C-callable function pointer from a Swift struct:

```swift
@c { """
#include "libsci.h"
""" }

@implement(CFunctionPointer)
struct MyCallback {
    func call(x: Int64, y: Int64) -> Int64 { x + y }
}

// .pointer gives the C function pointer to pass across FFI
let cb = MyCallback()
register_host_fn(thread, "my-callback", UInt64(bitPattern: cb.pointer))
```

## How It Works

This project uses GitHub Actions and [GraalVM native-image](https://www.graalvm.org/) to compile [SCI](https://github.com/babashka/SCI) into platform-specific shared libraries. The build:

1. Compiles SCI into a JAR via Leiningen
2. Compiles the C bridge class (`LibSci.java`) with `@CEntryPoint` annotations
3. Runs `native-image --shared` to produce the dynamic library
4. Collects the `.so`/`.dylib`/`.dll` and C headers

## Triggering Builds

### Automatic (tag push)

Push a `v*` tag to trigger a release build for the current submodule pin:

```bash
git tag v0.1.0
git push --tags
```

### Manual (any SCI branch/tag/commit)

Go to **Actions → Build** or **Actions → Release → Run workflow** and fill in:

| Input | Build | Release |
|-------|-------|---------|
| `sci_ref` | SCI branch, tag, or commit hash | SCI branch, tag, or commit hash |
| `release_tag` | — | Release name, e.g. `v0.8.43` |

This triggers a build against the specified SCI version without changing the submodule pin. Useful for:

- Testing a specific SCI feature branch
- Building a release for an older SCI version
- One-off custom builds with third-party libraries patched in

### Update default SCI version

SCI is pinned as a git submodule. To persistently upgrade the default version:

```bash
cd sci
git fetch origin
git checkout v0.8.43   # or any ref
cd ..
git add sci
git commit -m "Pin SCI to v0.8.43"
git tag v0.8.43
git push --tags
```

## Integrating Third-Party Libraries

The prebuilt `.so`/`.dylib`/`.dll` is a **closed-world** native image — it cannot load JARs or classes at runtime. To use third-party Clojure or Java libraries, they must be compiled into the binary at build time.

### Approach Overview

| Method | Effort | Use Case |
|--------|--------|----------|
| **SCI `:namespaces` init** | Zero | Inject pure Clojure helpers in eval strings |
| **Build-time dependency** | Medium | Embed third-party Clojure libraries into libsci |
| **Build-time + GraalVM config** | High | Embed libraries that use Java interop or reflection |

### Method 1: SCI `:namespaces` (no rebuild needed)

Define utility functions inside the eval expression with `sci.core/init`:

```c
// C — inject a helper namespace and call it
eval_string(thread,
    "(let [ctx (sci.core/init {:namespaces "
    "  {'my.ns {'double (fn [x] (* x 2))}}})"
    "      result (sci.core/eval-string ctx \"(my.ns/double 21)\")]"
    "  (str result))");
// => "42"
```

This works with the prebuilt library and requires no rebuild. SCI's full Clojure core is available — `map`, `reduce`, `filter`, `comp`, `partial`, etc.

### Method 2: Fork and add dependencies (recommended for libraries)

Add third-party libraries to the SCI build and rebuild `.so`/`.dylib`/`.dll`:

**Step 1:** Fork the SCI submodule and add dependencies to `sci/project.clj`:

```clojure
:dependencies [[org.clojure/clojure "1.11.1"]
               [cheshire/cheshire "5.12.0"]   ;; JSON lib
               [clj-http/clj-http "3.12.3"]]  ;; HTTP client
```

**Step 2:** Create a bridge namespace that references the library code. This is critical — GraalVM tree-shakes unreachable code, so you must create a code path from the `@CEntryPoint` to the library:

```clojure
;; sci/libsci/src/sci/impl/my_bridge.clj
(ns sci.impl.my-bridge
  (:require [cheshire.core :as json]))

(defn parse-json [s]
  (json/parse-string s true))
```

**Step 3:** Wire the bridge into `LibSci.java`:

```java
@CEntryPoint(name = "parse_json")
public static @CConst CCharPointer parseJson(
    @CEntryPoint.IsolateThreadContext long isolateId,
    @CConst CCharPointer s) {
    String expr = CTypeConversion.toJavaString(s);
    String result = sci.impl.my_bridge.parseJson(expr);
    // ... return C string
}
```

**Step 4:** Use `workflow_dispatch` to trigger a build from your fork branch:

```
Actions → Release → Run workflow
  sci_ref: my-fork/my-branch
  release_tag: v0.8.43-custom
```

### Method 3: Java interop libraries (advanced)

Libraries that use Java reflection, dynamic classloading, or native code require additional GraalVM configuration:

```json
// reflection.json — declare reflective access
[
  {"name": "com.example.LibraryClass", "allPublicMethods": true}
]
```

Common GraalVM pitfalls and fixes:

| Problem | Solution |
|---------|----------|
| `ClassNotFoundException` | Add `-H:ReflectionConfigurationFiles=reflection.json` |
| `NoSuchMethodException` | Declare methods in `reflection.json` |
| Missing resource files | Add `-H:IncludeResources=path/to/resource` |
| `UnsatisfiedLinkError` (JNI) | JNI requires `-H:JNIConfigurationFiles` |
| Build-time initialization error | Add `--initialize-at-run-time=<package>` |

Not all Java libraries are GraalVM-compatible. Check [graalvm.org](https://www.graalvm.org/latest/reference-manual/native-image/metadata/) for the full metadata guide.

### Babashka Pods

Babashka's pod system relies on process-level IPC (stdin/stdout between the babashka binary and external processes). It is **not supported** in the libsci shared library — pods require the babashka runtime and its pod registry infrastructure.

### Summary: What's possible

| Feature | Prebuilt `.so` | Custom build |
|---------|:---:|:---:|
| Pure Clojure eval expressions | ✅ | ✅ |
| SCI `:namespaces` injection | ✅ | ✅ |
| Clojure libraries (pure code) | ❌ | ✅ |
| Clojure libraries (Java interop) | ❌ | ⚠️ needs GraalVM config |
| Babashka pods | ❌ | ❌ |
| Runtime JAR loading | ❌ | ❌ |

## Calling Host Functions from SCI Scripts

The prebuilt `.so` is a closed-world native image — SCI scripts running inside it cannot call arbitrary functions defined in the host application (Rust, Zig, Go, C, etc.). Below are three ways to bridge the gap.

### Approach Overview

| Method | Requires rebuild | Call style | Complex types | Best for |
|--------|:---:|------|:---:|------|
| **Data protocol** | ❌ No | Async (two-step eval) | Simple EDN/JSON | Occasional external calls |
| **Function pointer registry** | ✅ Yes | Sync (direct call) | Primitive types | Most use cases |
| **GraalVM C API** | ✅ Yes | Sync (direct call) | Structs, pointers | Complex host interaction |

---

### Method 1: Data protocol (no rebuild needed)

The SCI script returns a data structure describing what to do. The host parses it, executes, and passes the result back in the next eval. No modification to libsci required.

**Host side (Rust):**

```rust
// Step 1: eval a script that requests external action
let expr = r#"
    {:action :http-get
     :url    "https://api.example.com/data"
     :header {:accept "application/json"}}
"#;
let result = eval_string(thread, expr);
// result => "{:action :http-get, :url \"https://api.example.com/data\", ...}"

// Step 2: parse the EDN/JSON, perform the action
let response = http_get("https://api.example.com/data");

// Step 3: pass the result back into SCI
let expr2 = format!("(process-response {:data \"{}\"})", response);
let final_result = eval_string(thread, expr2);
```

**Host side (Zig):**

```zig
// build.zig — translate C header (Zig 0.16):
// const translate = b.addTranslateC(.{
//     .root_source_file = b.path("include/libsci.h"),
//     .target = target,
//     .optimize = optimize,
// });
// exe.root_module.addImport("libsci", translate.createModule());

const c = @import("libsci");

// Step 1: eval a script that requests external action
const expr =
    \\{:action :http-get
    \\ :url    "https://api.example.com/data"
    \\ :header {:accept "application/json"}}
;
const result = c.eval_string(thread, expr);
// result => "{:action :http-get, :url \"https://api.example.com/data\", ...}"

// Step 2: parse the EDN/JSON, perform the action
const response = httpGet("https://api.example.com/data");

// Step 3: pass the result back into SCI
var buf: [1024]u8 = undefined;
const expr2 = std.fmt.bufPrintZ(
    &buf,
    "(process-response {{:data \"{s}\"}})",
    .{response},
) catch unreachable;
const final_result = c.eval_string(thread, expr2);
```

**Host side (Go):**

```go
/*
#cgo LDFLAGS: -L./lib -lsci
#include "libsci.h"
*/
import "C"
import "unsafe"

// Step 1: eval a script that requests external action
expr := C.CString(`{:action :http-get
 :url    "https://api.example.com/data"
 :header {:accept "application/json"}}`)
defer C.free(unsafe.Pointer(expr))
result := C.GoString(C.eval_string(thread, expr))
// result => "{:action :http-get, :url ...}"

// Step 2: parse the EDN/JSON, perform the action
response := httpGet("https://api.example.com/data")

// Step 3: pass the result back into SCI
expr2 := C.CString(fmt.Sprintf("(process-response {:data \"%s\"})", response))
defer C.free(unsafe.Pointer(expr2))
finalResult := C.GoString(C.eval_string(thread, expr2))
```

**Host side (Swift 6.3):**

```swift
@c { """
#include "libsci.h"
""" }

// Step 1: eval a script that requests external action
let expr = """
{:action :http-get
 :url    "https://api.example.com/data"
 :header {:accept "application/json"}}
"""
let result = eval_string(thread, expr).map { String(cString: $0) }
// result => "{:action :http-get, :url \"https://api.example.com/data\", ...}"

// Step 2: parse the EDN/JSON, perform the action
let response = httpGet("https://api.example.com/data")

// Step 3: pass the result back into SCI
let expr2 = "(process-response {:data \"\(response)\"})"
let finalResult = eval_string(thread, expr2).map { String(cString: $0) }
```

```clojure
;; Define action dispatcher
(defn process-response [{:keys [data]}]
  (let [parsed (json/parse data)]
    (str "Got " (count parsed) " items")))
```

This works with the prebuilt library. The downside: each round-trip requires serializing across the C boundary, and it's inherently asynchronous — SCI cannot call `(http-get ...)` inline.

---

### Method 2: Function pointer registry (recommended)

Register host C function pointers into SCI, then SCI scripts call them as if they were local functions. Requires a custom build of libsci.

**Step 1:** Add a function registry to `LibSci.java`:

```java
// sci/libsci/src/sci/impl/LibSci.java
import java.util.concurrent.ConcurrentHashMap;

public final class LibSci {

    // Host-registered callbacks: function name → C function pointer (as long)
    private static final ConcurrentHashMap<String, Long> hostFns = 
        new ConcurrentHashMap<>();

    // Called from host side to register a callback
    @CEntryPoint(name = "register_host_fn")
    public static void registerHostFn(
        @CEntryPoint.IsolateThreadContext long isolateId,
        @CConst CCharPointer name,
        long fnPtr
    ) {
        hostFns.put(CTypeConversion.toJavaString(name), fnPtr);
    }

    // Called from SCI scripts via Java interop
    public static Object callHostFn(String name, Object... args) {
        Long ptr = hostFns.get(name);
        if (ptr == null) {
            throw new RuntimeException("Unknown host function: " + name);
        }
        return invokeCFunction(ptr, args);
    }

    private static native Object invokeCFunction(long ptr, Object... args);
}
```

**Step 2:** Define C callback signatures in SCI's reflection config and bridge namespace:

```clojure
;; sci/libsci/src/sci/impl/host_bridge.clj
(ns sci.impl.host-bridge)

(defn call [name & args]
  (apply sci.impl.LibSci/callHostFn name args))
```

**Step 3:** When initializing SCI, expose the bridge via `:bindings`:

```clojure
;; Inside your build or eval initialization
(def ctx
  (sci.core/init
    {:classes {'host-fn sci.impl.LibSci}
     :bindings {'host-call (fn [name & args]
                              (apply sci.impl.host-bridge/call name args))}}))
```

**Step 4:** Host side — define callbacks and register them.

Rust:

```rust
// C ABI callbacks
extern "C" fn my_add(a: i64, b: i64) -> i64 {
    a + b
}

extern "C" fn my_log(msg: *const c_char) {
    let s = unsafe { CStr::from_ptr(msg).to_str().unwrap() };
    eprintln!("[host] {}", s);
}

// Register with SCI
let name = CString::new("my-add").unwrap();
register_host_fn(thread, name.as_ptr(), my_add as u64);

let name = CString::new("my-log").unwrap();
register_host_fn(thread, name.as_ptr(), my_log as u64);
```

Zig:

```zig
// build.zig — translate C header (Zig 0.16):
// const translate = b.addTranslateC(.{
//     .root_source_file = b.path("include/libsci.h"),
//     .target = target,
//     .optimize = optimize,
// });
// exe.root_module.addImport("libsci", translate.createModule());

const c = @import("libsci");

// C ABI callbacks
export fn my_add(a: i64, b: i64) callconv(.c) i64 {
    return a + b;
}

export fn my_log(msg: [*:0]const u8) callconv(.c) void {
    const s = std.mem.span(msg);
    std.debug.print("[host] {s}\n", .{s});
}

// Register with SCI
const name = std.fmt.allocPrintZ(allocator, "my-add", .{}) catch unreachable;
defer allocator.free(name);
_ = c.register_host_fn(thread, name, @intFromPtr(&my_add));

const name2 = std.fmt.allocPrintZ(allocator, "my-log", .{}) catch unreachable;
defer allocator.free(name2);
_ = c.register_host_fn(thread, name2, @intFromPtr(&my_log));
```

Go:

```go
/*
#cgo LDFLAGS: -L./lib -lsci
#include "libsci.h"
*/
import "C"
import "unsafe"

// C ABI callbacks
//export my_add
func my_add(a C.long, b C.long) C.long {
    return a + b
}

//export my_log
func my_log(msg *C.char) {
    fmt.Fprintf(os.Stderr, "[host] %s\n", C.GoString(msg))
}

// Register with SCI
name := C.CString("my-add")
defer C.free(unsafe.Pointer(name))
C.register_host_fn(thread, name, C.long(uintptr(C.my_add)))

name2 := C.CString("my-log")
defer C.free(unsafe.Pointer(name2))
C.register_host_fn(thread, name2, C.long(uintptr(C.my_log)))
```

Swift (6.3):

```swift
@c { """
#include "libsci.h"
""" }

// Swift 6.3: @implement creates C-compatible function pointer types
@implement(CFunctionPointer)
struct AddCallback {
    func call(a: Int64, b: Int64) -> Int64 {
        return a + b
    }
}

@implement(CFunctionPointer)
struct LogCallback {
    func call(msg: UnsafePointer<CChar>?) {
        if let msg = msg {
            print("[host] \(String(cString: msg))", to: &stderr)
        }
    }
}

// Register with SCI
let addCb = AddCallback()
register_host_fn(thread, "my-add", UInt64(bitPattern: addCb.pointer))

let logCb = LogCallback()
register_host_fn(thread, "my-log", UInt64(bitPattern: logCb.pointer))
```

Note on Swift: `@implement(CFunctionPointer)` generates a C-callable function pointer from the struct's `call` method, with the raw pointer accessible via `.pointer`.

Note on Go: CGo `//export` functions must be defined in the Go package (not in an imported library), and the file must be compiled with `cgo` enabled. Use `C.long` as the function pointer carrier — it matches pointer width on all 64-bit platforms.

**Step 5:** SCI scripts now call host functions synchronously:

```clojure
(host-call "my-add" 3 4)        ;; => 7
(host-call "my-log" "hello!")   ;; prints [host] hello! in host process

;; Use host functions in SCI data pipelines
(->> [1 2 3 4 5]
     (map #(host-call "my-add" % 10)))
;; => (11 12 13 14 15)
```

**Step 6:** Build via workflow_dispatch pointing at your fork:

```
Actions → Release → Run workflow
  sci_ref: your-fork/my-branch
  release_tag: v0.8.43-hostfn
```

---

### Method 3: GraalVM C API (for complex types)

When callbacks involve structs, arrays, or custom C types beyond primitives, use GraalVM's `CFunctionPointer`:

```java
import org.graalvm.nativeimage.c.function.CFunction;
import org.graalvm.nativeimage.c.type.CFunctionPointer;
import org.graalvm.nativeimage.c.type.CCharPointer;
import org.graalvm.nativeimage.c.struct.CStruct;
import org.graalvm.nativeimage.c.struct.CField;

// Declare a struct mirroring the C side
@CStruct("my_point_t")
interface MyPoint extends PointerBase {
    @CField("x") double getX();
    @CField("x") void setX(double value);
    @CField("y") double getY();
    @CField("y") void setY(double value);
}

// Declare the callback signature
interface PointCallback extends CFunctionPointer {
    @CFunction
    double invoke(MyPoint point);
}
```

This gives full type safety but requires more GraalVM-specific boilerplate.

---

# About `libsci.h`

## `run_main`

`run_main` is not handwritten anywhere in this repo. It is auto-generated by GraalVM's native-image --shared when compiling the shared
library. GraalVM emits it as a wrapper around the Java main method of the configured main class (sci.impl.main).

The build pipeline is defined in sci/libsci/bb/libsci_tasks.clj (the compile-native function), which invokes:
native-image -jar sci-jar --shared -H:Name=libsci ...

The :main class is declared in sci/project.clj line 29:
:aot [sci.impl.main]
:main sci.impl.main

### What it does
`run_main(int argc, char** argv)`:
1. Initializes a GraalVM isolate internally if one isn't already active
2. Calls the Java main method of sci.impl.main/-main (sci/src/sci/impl/main.cljc:49), which parses args as Clojure expressions, evaluates
them via sci.core/eval-string, and prints the result
3. It is essentially a way to invoke the shared library like a standalone CLI: ./libsci.so "(+ 1 2)"

In practice

run_main is barely used by downstream consumers. All the example bindings (C, C++, Rust, Python, Go, Zig, Swift) use the explicit isolate
API instead:
graal_create_isolate(NULL, &isolate, &thread);
eval_string(thread, "(+ 1 2)");
graal_tear_down_isolate(thread);

The actual user-facing C API is eval_string, which comes from the @CEntryPoint annotation in sci/libsci/src/sci/impl/LibSci.java. run_main  
just rides along because GraalVM always generates it for any --shared build that has a main class. 

## `eval_string`

  Whether SCI state persists across `eval_string` calls, it doesn't — each call gets a fresh context.

  The critical code is in the bridge (sci/libsci/src/sci/impl/libsci.clj):

```
  (defn -evalString [s]
    (sci/binding [sci/out *out*]
      (str (try (sci/eval-string
                s
                {:namespaces {'cheshire.core {'generate-string
  cheshire/generate-string}}})
                ...))))
```

  Every call to eval_string passes a fresh options map to sci/eval-string. SCI's
   eval-string creates a new context from scratch each time, evaluates the
  expression, and throws the context away. So:

```
  eval_string(thread, "(def x 42)")     ;; => "#'user/x"
  eval_string(thread, "x")              ;; => ERROR: Unable to resolve symbol: x
  eval_string(thread, "(defn f [x] (* x 2))")  ;; => "#'user/f"
  eval_string(thread, "(f 3)")          ;; => ERROR: Unable to resolve symbol: f
```

  Each call is a blank slate. The only thing that persists across calls is the
  GraalVM isolate itself (Java-level static state), but SCI's evaluation context
   is recreated fresh every time.

  ---
  Building a Stateful REPL in Zig 0.16

  To get proper REPL behavior (where def and defn survive), you have two
  options:

  Option A: Accumulate manually in the host (works with prebuilt library)

  Keep a growing string of all definitions and re-evaluate everything:

```
  const std = @import("std");
  const c = @import("libsci");

  pub fn main() !void {
      var gpa = std.heap.GeneralPurposeAllocator(.{}){};
      defer _ = gpa.deinit();
      const allocator = gpa.allocator();

      var isolate: ?*c.graal_isolate_t = null;
      var thread: ?*c.graal_isolatethread_t = null;
      _ = c.graal_create_isolate(null, &isolate, &thread);
      defer _ = c.graal_tear_down_isolate(thread);

      const stdin = std.io.getStdIn().reader();
      const stdout = std.io.getStdOut().writer();

      // Accumulate all definitions here
      var preamble = std.ArrayList(u8).init(allocator);
      defer preamble.deinit();

      while (true) {
          try stdout.writeAll("user> ");
          const line = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n',
  4096) orelse break;
          defer allocator.free(line);

          if (line.len == 0) continue;

          // Append this expression to the preamble
          try preamble.appendSlice(line);

          // Evaluate: preamble (all state) + current expression
          const expr = try std.mem.concat(allocator, u8, &.{ "(do ",
  preamble.items, ") " });
          defer allocator.free(expr);

          // But wrap in try/catch — if the expression fails,
          // roll back the preamble
          const result = c.eval_string(thread, expr.ptr);
          if (std.mem.startsWith(u8, std.mem.span(result), "{:error")) {
              // Parse error — roll back
              preamble.shrinkRetainingCapacity(preamble.items.len - line.len);
              try stdout.print("{s}\n", .{std.mem.span(result)});
          } else {
              try stdout.print("{s}\n", .{std.mem.span(result)});
          }
      }
  }
```

  This works but is O(n^2) — every new expression re-evaluates all prior
  definitions.

  Option B: Persistent context (requires custom build)

  Modify the SCI bridge to hold a persistent context atom:

```
  ;; sci/libsci/src/sci/impl/libsci.clj
  (ns sci.impl.libsci
    (:require [cheshire.core :as cheshire]
              [sci.core :as sci])
    (:gen-class
     :methods [^{:static true} [evalString [String] String]
               ^{:static true} [createContext [] void]
               ^{:static true} [evalInContext [String] String]
               ^{:static true} [resetContext [] void]]))

  (def ctx (atom nil))

  (defn -createContext []
    (reset! ctx (sci/init {:namespaces {'cheshire.core {'generate-string
  cheshire/generate-string}}})
    nil)

  (defn -evalInContext [s]
    (sci/binding [sci/out *out*]
      (str (try (sci/eval-string* @ctx s)
                (catch Exception e
                  {:error (str (type e)) :message (.getMessage e)})))))

  (defn -resetContext []
    (reset! ctx nil))

  (defn -evalString [s]  ;; keep for backward compat
    (sci/binding [sci/out *out*]
      (str (try (sci/eval-string
                s
                {:namespaces {'cheshire.core {'generate-string
  cheshire/generate-string}}})
                (catch Exception e
                  {:error (str (type e)) :message (.getMessage e)})))))
```
  Then add corresponding @CEntryPoints in LibSci.java for create_context,
  eval_in_context, and reset_context. Then rebuild.

  ---
  Zig REPL shell (with Option B-style persistent context API)

  If you do a custom build with persistent context, the Zig REPL looks like:

```
  const std = @import("std");
  const c = @import("libsci");

  pub fn main() !void {
      var gpa = std.heap.GeneralPurposeAllocator(.{}){};
      defer _ = gpa.deinit();
      const allocator = gpa.allocator();

      var isolate: ?*c.graal_isolate_t = null;
      var thread: ?*c.graal_isolatethread_t = null;
      _ = c.graal_create_isolate(null, &isolate, &thread);
      defer _ = c.graal_tear_down_isolate(thread);

      // Create a persistent SCI context
      _ = c.create_context(thread);

      const stdin = std.io.getStdIn().reader();
      const stdout = std.io.getStdOut().writer();

      while (true) {
          try stdout.writeAll("user> ");
          const line = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n',
  4096) orelse break;
          defer allocator.free(line);
          if (line.len == 0) continue;

          const result = c.eval_in_context(thread, line.ptr);
          try stdout.print("{s}\n", .{std.mem.span(result)});
      }
  }
```

  build.zig
```
  const std = @import("std");

  pub fn build(b: *std.Build) void {
      const target = b.standardTargetOptions(.{});
      const optimize = b.standardOptimizeOption(.{});

      const exe = b.addExecutable(.{
          .name = "sci-repl",
          .root_source_file = b.path("main.zig"),
          .target = target,
          .optimize = optimize,
      });

      const translate = b.addTranslateC(.{
          .root_source_file = b.path("include/libsci.h"),
          .target = target,
          .optimize = optimize,
      });
      exe.root_module.addImport("libsci", translate.createModule());

      exe.addLibraryPath(b.path("lib"));
      exe.linkSystemLibrary("sci");
      exe.addRPath(b.path("lib"));

      b.installArtifact(exe);
  }
```
---

### Comparison

| Characteristic | Data protocol | Fn pointer registry | C API |
|---|---|---|---|
| Prebuilt `.so` | ✅ | ❌ | ❌ |
| SCI calls host inline | ❌ (two-step) | ✅ | ✅ |
| Primitives (int, long, pointer) | ✅ | ✅ | ✅ |
| C structs | ❌ | ❌ | ✅ |
| Sync return value | ❌ | ✅ | ✅ |
| Multiple callbacks | ✅ | ✅ | ✅ |
| Build complexity | None | Medium | High |

## License

- Build scripts: MIT (this project)
- SCI library: [MIT](https://github.com/babashka/SCI/blob/master/LICENSE)
- GraalVM runtime components: [GraalVM Free License](https://www.graalvm.org/downloads/license/)
