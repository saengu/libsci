# Host Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent SCI context and host function dispatch to libsci so host languages can load scripts, call their functions, and receive callbacks -- all without rebuilding libsci.

**Architecture:** Three layers -- C @CEntryPoints (`LibSciHost.java`), Clojure bridge (`libsci_host.clj` with per-thread context map), and host-language dispatcher (single C function pointer registered once). JSON wire format for host-call, EDN for call_function args. CFunctionPointer via direct cast `(HostDispatcher) WordFactory.pointer(ptr)`.

**Tech Stack:** GraalVM 23 CE native-image --shared, babashka/sci, Cheshire JSON, Leiningen, Java, Clojure

**Context:** All SCI submodule changes go through patch file at `/root/libsci/patches/host_bridge.patch`. Do NOT commit to the sci submodule directly.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `sci/libsci/src/sci/impl/LibSciHost.java` | Create | @CEntryPoints + HostDispatcher interface + dispatchHostCall + returnCString |
| `sci/libsci/src/sci/impl/libsci_host.clj` | Create | Per-thread context registry + host-call JSON bridge + base-opts |
| `sci/project.clj` | Modify (line 34) | Add `sci.impl.libsci-host` to `:aot` in `:libsci` profile |
| `sci/libsci/bb/libsci_tasks.clj` | Modify (line 46) | Add `LibSciHost.java` to javac command |
| `/root/libsci/tests/libsci_host_test.clj` | Create | JVM unit tests (no GraalVM needed) |

---

### Task 1: Write failing tests

**Files:**
- Create: `/root/libsci/tests/libsci_host_test.clj`

- [ ] **Step 1: Create test directory and test file**

```clojure
;; /root/libsci/tests/libsci_host_test.clj
(ns libsci-host-test
  (:require [cheshire.core :as json]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [sci.impl.libsci-host :as host]))

(deftest load-and-call
  (testing "load a script and call a function defined in it"
    (host/-loadScript "(defn add [x y] (+ x y))")
    (let [result (host/-callFunction "add" "3 4")]
      (is (= "7" (-> result json/parse-string (get "value")))))))

(deftest eval-in-context
  (testing "eval an expression in the persistent context"
    (host/-resetContext)
    (host/-loadScript "(def x 42)")
    (let [result (host/-evalInContext "x")]
      (is (= "42" (-> result json/parse-string (get "value")))))))

(deftest host-call-error-no-dispatcher
  (testing "host-call returns error when no dispatcher registered"
    (host/-resetContext)
    (let [result (host/-loadScript "(host-call \"add\" 3 4)")]
      (is (= "error" (-> result json/parse-string (get "status")))))))

(deftest per-thread-isolation
  (testing "each thread gets an independent context"
    (host/-resetContext)
    (host/-loadScript "(def x 1)")
    (let [main-x (-> (host/-evalInContext "x") json/parse-string (get "value"))]
      (is (= "1" main-x))
      ;; Simulate another thread: reset + reload
      (host/-resetContext)
      (host/-loadScript "(def x 2)")
      (let [other-x (-> (host/-evalInContext "x") json/parse-string (get "value"))]
        (is (= "2" other-x))))))

(deftest load-script-error
  (testing "parse error returns JSON error, not throw"
    (host/-resetContext)
    (let [result (host/-loadScript "(+ 1")]
      (is (= "error" (-> result json/parse-string (get "status"))))
      (is (-> result json/parse-string (get "error") str/includes? "Exception")))))

(deftest call-function-with-keyword
  (testing "call_function supports EDN keywords"
    (host/-resetContext)
    (host/-loadScript "(defn get-val [m k] (get m k))")
    (let [result (host/-callFunction "get-val" "{:a 1 :b 2} :a")]
      (is (= "1" (-> result json/parse-string (get "value")))))))

(deftest cross-ns-call
  (testing "call_function supports namespace-qualified fns"
    (host/-resetContext)
    (host/-loadScript "(ns my.ns) (defn calc [x] (* x 2))")
    (let [result (host/-callFunction "my.ns/calc" "21")]
      (is (= "42" (-> result json/parse-string (get "value")))))))
```

- [ ] **Step 2: Run test to verify they fail**

Run from `/root/libsci/sci`:
```bash
lein with-profiles +libsci test libsci-host-test
```

Expected: FAIL -- `sci.impl.libsci-host` not found (not implemented yet).

---

### Task 2: Create LibSciHost.java

**Files:**
- Create: `sci/libsci/src/sci/impl/LibSciHost.java`

- [ ] **Step 1: Write LibSciHost.java with @CEntryPoints and HostDispatcher**

```java
package sci.impl;

import org.graalvm.nativeimage.c.function.CEntryPoint;
import org.graalvm.nativeimage.c.function.CFunction;
import org.graalvm.nativeimage.c.function.CFunctionPointer;
import org.graalvm.nativeimage.c.type.CCharPointer;
import org.graalvm.nativeimage.c.type.CTypeConversion;
import org.graalvm.nativeimage.c.type.CConst;
import org.graalvm.word.WordFactory;

public final class LibSciHost {

    // -- Host dispatcher interface --
    // @CFunction tells GraalVM to generate the calling trampoline at build time.
    // Direct cast (HostDispatcher) WordFactory.pointer(ptr) replaces the runtime
    // toProxy() call that failed in native-image --shared builds.
    public interface HostDispatcher extends CFunctionPointer {
        @CFunction
        CCharPointer dispatch(CCharPointer jsonArgs);
    }

    // -- Static dispatcher pointer --
    // volatile guarantees visibility across threads.
    // WordFactory.nullPointer() = null pointer (isNull() returns true).
    private static volatile HostDispatcher dispatcher = WordFactory.nullPointer();

    // -- Set host dispatcher (C entry point) --
    // Called once by the host at startup with a C function pointer address.
    @CEntryPoint(name = "set_host_dispatcher")
    public static void setHostDispatcher(
            @CEntryPoint.IsolateThreadContext long isolateId,
            long fnPtr) {
        dispatcher = (HostDispatcher) WordFactory.pointer(fnPtr);
    }

    // -- Internal: dispatch a host-call from Clojure --
    // Called by sci.impl.libsci-host/-host-call-impl.
    // Returns a JSON string: {"status":"ok","value":...} or error envelope.
    public static String dispatchHostCall(String argsJson) {
        if (dispatcher.isNull()) {
            return "{\"status\":\"error\","
                 + "\"message\":\"No host dispatcher registered.\"}";
        }
        try {
            CTypeConversion.CCharPointerHolder holder =
                CTypeConversion.toCString(argsJson);
            CCharPointer result = dispatcher.dispatch(holder.get());
            return CTypeConversion.toJavaString(result);
        } catch (Exception e) {
            return "{\"status\":\"error\","
                 + "\"message\":\"dispatcher call failed: "
                 + e.getMessage() + "\"}";
        }
    }

    // -- Persistent context entry points --

    @CEntryPoint(name = "load_script")
    public static @CConst CCharPointer loadScript(
            @CEntryPoint.IsolateThreadContext long id,
            @CConst CCharPointer s) {
        String script = CTypeConversion.toJavaString(s);
        String result = sci.impl.libsci_host.loadScript(script);
        return returnCString(result);
    }

    @CEntryPoint(name = "call_function")
    public static @CConst CCharPointer callFunction(
            @CEntryPoint.IsolateThreadContext long id,
            @CConst CCharPointer fnName,
            @CConst CCharPointer argsEdn) {
        String name = CTypeConversion.toJavaString(fnName);
        String args = CTypeConversion.toJavaString(argsEdn);
        String result = sci.impl.libsci_host.callFunction(name, args);
        return returnCString(result);
    }

    @CEntryPoint(name = "eval_in_context")
    public static @CConst CCharPointer evalInContext(
            @CEntryPoint.IsolateThreadContext long id,
            @CConst CCharPointer s) {
        String expr = CTypeConversion.toJavaString(s);
        String result = sci.impl.libsci_host.evalInContext(expr);
        return returnCString(result);
    }

    @CEntryPoint(name = "reset_context")
    public static void resetContext(
            @CEntryPoint.IsolateThreadContext long id) {
        sci.impl.libsci_host.resetContext();
    }

    // -- Re-eval entry point (renamed from eval_string) --

    @CEntryPoint(name = "eval")
    public static @CConst CCharPointer eval(
            @CEntryPoint.IsolateThreadContext long id,
            @CConst CCharPointer s) {
        String expr = CTypeConversion.toJavaString(s);
        String result = sci.impl.libsci.evalString(expr);
        return returnCString(result);
    }

    // -- Helper: Java String -> CCharPointer --
    private static CCharPointer returnCString(String s) {
        CTypeConversion.CCharPointerHolder holder = CTypeConversion.toCString(s);
        return holder.get();
    }
}
```

- [ ] **Step 2: Verify no syntax errors**

```bash
cd /root/libsci/sci
lein with-profiles +libsci compile
```

---

### Task 3: Create libsci_host.clj

**Files:**
- Create: `sci/libsci/src/sci/impl/libsci_host.clj`

- [ ] **Step 1: Write libsci_host.clj with per-thread context registry**

```clojure
(ns sci.impl.libsci-host
  (:require [cheshire.core :as json]
            [sci.core :as sci])
  (:gen-class
   :methods [^{:static true} [loadScript     [String] String]
             ^{:static true} [callFunction   [String String] String]
             ^{:static true} [evalInContext  [String] String]
             ^{:static true} [resetContext   [] void]]))

;; -- Per-thread context registry --
;; Each OS thread gets its own SCI context. Thread A's defs are invisible to
;; Thread B, and vice versa. Keyed by JVM thread ID (.getId on Thread).

(defonce contexts (atom {}))

(defn- get-ctx
  "Get the current thread's SCI context, or nil if not yet initialized."
  []
  (get @contexts (.getId (Thread/currentThread))))

(defn- set-ctx!
  "Store the current thread's SCI context."
  [ctx]
  (swap! contexts assoc (.getId (Thread/currentThread)) ctx))

(defn- get-or-init-ctx
  "Return current thread's context, creating one with base-opts if needed."
  []
  (if-let [ctx (get-ctx)]
    ctx
    (let [new-ctx (sci/init base-opts)]
      (set-ctx! new-ctx)
      new-ctx)))

;; -- Base SCI options --
;; defonce ensures the map and closure are created once at load time, not on
;; every call. The closure captures no mutable external state.

(defonce base-opts
  {:namespaces {'cheshire.core
                {'generate-string json/generate-string
                 'parse-string    json/parse-string}}
   :bindings {'host-call
              (fn [& args]
                (let [args-json  (json/generate-string (vec args))
                      raw-result (sci.impl.LibSciHost/dispatchHostCall args-json)]
                  (if (string? raw-result)
                    (try (json/parse-string raw-result true)
                         (catch Exception e
                           {:status "error"
                            :message (str "Failed to parse host response: "
                                          (.getMessage e))}))
                    raw-result)))}})

;; -- Public API --

(defn -loadScript
  "Load a Clojure script into the current thread's persistent SCI context.
  First call per thread initializes the context via sci/init.
  Subsequent calls reuse the existing context."
  [s]
  (sci/binding [sci/out *out*]
    (try
      (let [c      (get-or-init-ctx)
            result (sci/eval-string* c s)]
        (json/generate-string {:status "ok" :value (str result)}))
      (catch Exception e
        (json/generate-string
          {:status "error" :error (str (type e)) :message (.getMessage e)})))))

(defn -callFunction
  "Call a named function in the current thread's context with EDN arguments.
  Builds an S-expression: (fn-name edn-args...) and evaluates it."
  [fn-name args-edn]
  (sci/binding [sci/out *out*]
    (if-let [c (get-ctx)]
      (try
        (let [expr   (str "(" fn-name " " args-edn ")")
              result (sci/eval-string* c expr)]
          (json/generate-string {:status "ok" :value (str result)}))
        (catch Exception e
          (json/generate-string
            {:status "error" :error (str (type e)) :message (.getMessage e)})))
      (json/generate-string
        {:status "error" :message "No context. Call load_script first."}))))

(defn -evalInContext
  "Evaluate a complete Clojure expression in the current thread's context."
  [s]
  (sci/binding [sci/out *out*]
    (if-let [c (get-ctx)]
      (try
        (let [result (sci/eval-string* c s)]
          (json/generate-string {:status "ok" :value (str result)}))
        (catch Exception e
          (json/generate-string
            {:status "error" :error (str (type e)) :message (.getMessage e)})))
      (json/generate-string
        {:status "error" :message "No context. Call load_script first."}))))

(defn -resetContext
  "Remove the current thread's context. Next load_script creates a fresh one."
  []
  (swap! contexts dissoc (.getId (Thread/currentThread))))
```

- [ ] **Step 2: Verify compilation**

```bash
cd /root/libsci/sci
lein with-profiles +libsci compile
```

Expected: Compilation succeeds including both `sci.impl.libsci` and `sci.impl.libsci-host`.

---

### Task 4: Modify project.clj -- AOT config

**Files:**
- Modify: `sci/project.clj` line 34

- [ ] **Step 1: Add sci.impl.libsci-host to :aot**

```clojure
;; OLD line 34:
                      :aot [sci.impl.libsci]}}

;; NEW:
                      :aot [sci.impl.libsci sci.impl.libsci-host]}}
```

- [ ] **Step 2: Verify compilation still works**

```bash
cd /root/libsci/sci
lein with-profiles +libsci compile
```

---

### Task 5: Modify libsci_tasks.clj -- javac command

**Files:**
- Modify: `sci/libsci/bb/libsci_tasks.clj` lines 44-46

- [ ] **Step 1: Add LibSciHost.java to javac command**

```clojure
;; OLD:
    (p/shell javac
             "-cp" (str/join fs/path-separator [sci-jar svm-jar])
             "libsci/src/sci/impl/LibSci.java")

;; NEW:
    (p/shell javac
             "-cp" (str/join fs/path-separator [sci-jar svm-jar])
             "libsci/src/sci/impl/LibSci.java"
             "libsci/src/sci/impl/LibSciHost.java")
```

---

### Task 6: Run tests and generate patch

- [ ] **Step 1: Run JVM tests**

```bash
cd /root/libsci/sci
lein with-profiles +libsci test libsci-host-test
```

Expected: All tests pass.

- [ ] **Step 2: Generate the patch file**

From `/root/libsci`:
```bash
cd sci
git diff > ../patches/host_bridge.patch
```

Verify the patch contains:
```bash
grep "^diff --git" ../patches/host_bridge.patch
```
Expected:
```
diff --git a/libsci/bb/libsci_tasks.clj b/libsci/bb/libsci_tasks.clj
diff --git a/libsci/src/sci/impl/LibSciHost.java b/libsci/src/sci/impl/LibSciHost.java
diff --git a/libsci/src/sci/impl/libsci_host.clj b/libsci/src/sci/impl/libsci_host.clj
diff --git a/project.clj b/project.clj
```
