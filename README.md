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

SCI is pinned as a git submodule — update it to build newer versions:

```bash
git submodule update --remote sci
git commit -m "Bump SCI to latest"
git tag v0.1.0
git push --tags
```

## License

- Build scripts: MIT (this project)
- SCI library: [MIT](https://github.com/babashka/SCI/blob/master/LICENSE)
- GraalVM runtime components: [GraalVM Free License](https://www.graalvm.org/downloads/license/)
