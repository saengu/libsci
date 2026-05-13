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

## License

- Build scripts: MIT (this project)
- SCI library: [MIT](https://github.com/babashka/SCI/blob/master/LICENSE)
- GraalVM runtime components: [GraalVM Free License](https://www.graalvm.org/downloads/license/)
