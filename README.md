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

### C

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

### Rust

```rust
// build.rs
println!("cargo:rustc-link-search=native=./lib");
println!("cargo:rustc-link-lib=sci");

// src/main.rs — bindgen or manual FFI
extern "C" {
    fn graal_create_isolate(params: *const std::ffi::c_void, isolate: *mut *mut std::ffi::c_void, thread: *mut *mut std::ffi::c_void) -> i32;
    fn eval_string(thread: *mut std::ffi::c_void, expr: *const std::ffi::c_char) -> *const std::ffi::c_char;
    fn graal_tear_down_isolate(thread: *mut std::ffi::c_void) -> i32;
}
```

### Zig

```zig
const c = @cImport({
    @cInclude("libsci.h");
});

var isolate: ?*c.graal_isolate_t = null;
var thread: ?*c.graal_isolatethread_t = null;
_ = c.graal_create_isolate(null, &isolate, &thread);
const result = c.eval_string(thread, "(+ 1 2)");
defer _ = c.graal_tear_down_isolate(thread);
```

### Go

```go
/*
#cgo LDFLAGS: -L./lib -lsci
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

### Python

```python
from ctypes import CDLL, c_char_p, c_void_p, byref

dll = CDLL("./lib/libsci.so")   # or .dylib / .dll
isolate, thread = c_void_p(), c_void_p()
dll.graal_create_isolate(None, byref(isolate), byref(thread))
dll.eval_string.restype = c_char_p
print(dll.eval_string(thread, c_char_p(b"(+ 1 2)")))
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

**SCI script side:**

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

**Step 4:** Host side — define callbacks and register them (Rust example):

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
