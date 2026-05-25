# Host Namespace Registration Design

- **Date**: 2026-05-25
- **Status**: Implemented
- **Supersedes**: `2026-05-23-host-bridge-design.md` (extends with namespace registration)

## Summary

Add `register_namespaces` C API to libsci, enabling host languages to register
namespaces and functions into SCI that scripts can call transparently --
`(math/add 1 2)` instead of `(host-call "add" 1 2)`.

This builds on the existing host bridge (`set_host_dispatcher`, `host-call`)
and unifies the JSON wire protocol for both call paths.

## Architecture

Two-layer stack reusing the existing FFI gateway:

```
┌──────────────────────────────────────────────────┐
│  Clojure 脚本层                                    │
│  (my-ns/my-fn arg1 arg2)  (host-call "f" args)    │
│       ↑ transparent            ↑ explicit         │
├──────────────────────────────────────────────────┤
│  映射层 — Host Registration (new)                  │
│  register_namespaces(thread, ns_json)              │
│    → parse JSON → create-host-binding closures    │
│    → merge into per-thread SCI :namespaces         │
│    → each closure calls dispatchHostCall()         │
├──────────────────────────────────────────────────┤
│  传输层 — set_host_dispatcher (existing)            │
│  HostDispatcher.execute(CCharPointer)              │
│    → C function pointer → host language            │
└──────────────────────────────────────────────────┘
```

## C API

### Existing (unchanged)

```c
void     set_host_dispatcher(thread, fn_ptr);
char*    load_script(thread, script);
char*    call_function(thread, fn_name, edn_args);
char*    eval_in_context(thread, expr);
void     reset_context(thread);
char*    eval_string(thread, expr);
```

### New

```c
// Register host-provided namespaces and functions into SCI.
// ns_json format:
//   {"namespaces": {"ns-name": ["fn1", "fn2", ...]}}
// After registration, scripts call directly:
//   (ns-name/fn1 args...)
// Returns JSON envelope.
char*    register_namespaces(thread, ns_json);
```

## Unified JSON Wire Protocol

All dispatcher calls now use a JSON object format. The `ns` field
distinguishes registered calls from direct host-calls.

| Source | Input JSON | ns field |
|--------|-----------|----------|
| Registered call | `{"ns":"math","fn":"add","args":[1,2]}` | present |
| `host-call` | `{"fn":"add","args":[3,4]}` | absent |

Host dispatcher checks for `"ns"` key to determine routing:

```c
if (json_has_field("ns"))
    route_by_ns(ns, fn, args);    // registered namespace
else
    route_by_fn(fn, args);         // host-call
```

## Registration JSON Format

```json
{"namespaces": {"math": ["add", "subtract"], "io": ["read", "write"]}}
```

Each function name is expanded into a SCI namespace binding -- a Clojure
closure that captures `ns-name` and `fn-name` at registration time (static
binding). When called, the closure constructs the JSON and dispatches
through `dispatchHostCall`.

## Performance

Registered function calls match `host-call` performance (~1-5us per call)
since both go through the same `dispatchHostCall` FFI channel. The extra
closure dispatch is negligible (~0.1us) compared to JSON serialization.

## Per-thread Context Integration

Registered namespaces are stored in a shared `registered-nss` atom:

```clojure
(defonce registered-nss (atom {}))  ;; {"math" ["add"]}
```

**New threads**: `get-or-init-ctx` reads `@registered-nss` and merges
bindings into the initial `sci/init` opts.

**Existing threads**: `-registerNamespaces` iterates all active contexts
and applies `sci/merge-opts` with the new namespace bindings.

## Host Dispatcher Routing Example (C)

```c
static const char* host_dispatcher(const char* json_args) {
    if (strstr(json_args, "\"ns\"") != NULL) {
        /* {"ns":"math","fn":"add","args":[1,2]} */
        return handle_ns_call(json_args);
    }
    /* {"fn":"add","args":[3,4]} — legacy host-call */
    return handle_legacy_call(json_args);
}
```

## Files

### New
- `sci/libsci/src/sci/impl/LibSciHost.java` — HostDispatcher interface,
  `set_host_dispatcher`, `dispatchHostCall`
- `sci/libsci/src/sci/impl/libsci_host.clj` — Clojure bridge: per-thread
  context, host-call, registered-nss, create-host-binding

### Modified
- `sci/libsci/src/sci/impl/LibSci.java` — adds `register_namespaces`
  @CEntryPoint
- `sci/project.clj` — adds `sci.impl.libsci-host` to `:aot`
- `sci/libsci/bb/libsci_tasks.clj` — adds `LibSciHost.java` to javac,
  adds `test-jvm` task
- `sci/reflection.json` — adds `sci.impl.LibSciHost.dispatchHostCall`

## Verification

| Level | Command | Tests |
|-------|---------|-------|
| JVM unit | `bb libsci:test-jvm` | 12 tests (load/call, context, host-call, registration) |
| Native-image build | `bb libsci:compile` | Compilation succeeds |
| C integration | `tests/c/from_c_host` | 11 tests incl. register + host-call round-trip |

## Security

| Surface | Risk | Mitigation |
|---------|------|------------|
| Namespace registration | Low | Only host can register; JSON format validated |
| Function name injection | Low | Names/symbols checked during parse |
| Dispatcher null pointer | Low | `ptr == 0` check in `dispatchHostCall` |
| Per-thread context race | Low | Thread-ID-keyed atom map |
