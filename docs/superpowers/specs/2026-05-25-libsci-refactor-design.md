# libsci 重构设计规格说明书

**日期**: 2026-05-25
**状态**: 草案
**项目**: libsci — 将 babashka/SCI 编译为可嵌入共享动态库

## 1. 概述

libsci 使用 GraalVM Native Image 将 babashka/SCI 编译为 C 可链接的共享
动态库。宿主应用（C、Zig、Rust、Swift、Go）通过简洁的 C ABI 嵌入完整的
Clojure/SCI 解释器，支持每线程独立 Isolate 执行上下文和双向宿主-脚本回调。

### 1.1 输出产物

| 平台 | 共享库 |
|------|--------|
| Linux x86_64 / arm64 | `libsci.so` |
| macOS x86_64 / arm64 | `libsci.dylib` |
| Windows x86_64 | `libsci.dll` |

公开头文件：`include/libsci.h`

### 1.2 关键设计决策

- **集成方式**：Git submodule 引用 babashka/SCI（不修改），所有项目代码放独立的 `src/` 目录
- **Isolate 模型**：每线程独立 GraalVM Isolate，通过 `sci_create_context` 创建，后续每次调用传入 `sci_ctx_t*`
- **数据交换**：基础类型（int64/float64/bool/nil）通过 tagged union 直接传递；复合类型（vector、map、set）序列化为 JSON 字符串
- **回调机制**：`@CFunctionPointer` + `@InvokeCFunctionPointer`。`sci_register_host_fn(ctx, ns, fn, ptr)` 逐个注入 SCI var，脚本直接使用自然语法 `(ns/fn args...)`
- **构建流程**：Leiningen uberjar → native-image --shared → libsci.so
- **命名约定**：所有 C API 使用 `sci_` 前缀；Java 类使用 `Libsci*` 前缀；Clojure 命名空间使用 `sci.impl.libsci-*`
- **不再使用 patch**：所有自定义代码在项目根 `src/` 目录，不修改 SCI 子模块

## 2. 目录结构

```
libsci/
├── sci/                              ← git submodule (babashka/SCI, 不修改)
│
├── src/
│   ├── java/libsci/
│   │   ├── LibsciStructs.java        ← @CStruct 映射 sci_val_t
│   │   └── LibsciAPI.java            ← @CEntryPoint 导出函数
│   │
│   └── clojure/libsci/
│       ├── core.clj                  ← SCI 上下文生命周期
│       ├── serialization.clj         ← JSON 序列化/反序列化 (cheshire)
│       └── callbacks.clj             ← 宿主回调注册与调用调度
│
├── include/
│   └── libsci.h                      ← 公开 C ABI 头文件
│
├── test/
│   ├── clojure/libsci/
│   │   ├── core_test.clj             ← 上下文创建/销毁/重置
│   │   ├── serialization_test.clj    ← 序列化测试
│   │   └── callbacks_test.clj        ← 宿主回调测试
│   │
│   └── integration/
│       ├── c/
│       │   ├── main.c                ← C 集成测试
│       │   └── Makefile
│       ├── zig/
│       │   ├── from_zig.zig          ← Zig 集成测试
│       │   └── build.zig
│       └── rust/
│           ├── src/main.rs           ← Rust 集成测试
│           └── Cargo.toml
│
├── project.clj                       ← Leiningen 构建配置
├── scripts/build.sh                  ← 构建入口脚本
├── Makefile                          ← 顶层快捷命令
└── CLAUDE.md                         ← 项目说明 + TDD 协议
```

### 2.1 文件职责说明

| 文件 | 职责 | 所属层 |
|------|------|--------|
| `LibsciStructs.java` | GraalVM `@CStruct` 注解，将 `sci_val_t` C 结构体映射为 Java 可操作的内存布局 | 类型系统 |
| `LibsciAPI.java` | 9 个 `@CEntryPoint` 方法：上下文生命周期、求值、回调注册、版本查询、内存释放 | C ABI 边界 |
| `core.clj` | Isolate 本地的 SCI 上下文管理、eval 逻辑 | 核心逻辑 |
| `serialization.clj` | JSON ↔ Clojure 数据结构转换、安全序列化 | 数据层 |
| `callbacks.clj` | 宿主函数注册表、C 函数指针 → SCI var 映射、host/invoke 调度 | 双向调用 |

## 3. C ABI 接口规范 (`libsci.h`)

### 3.1 类型定义

```c
/* 不透明上下文句柄 -- 封装 GraalVM graal_isolatet_t*。
   C 宿主在每次 API 调用中传入此指针，
   GraalVM 据此将调用路由到正确的 Isolate。 */
typedef struct sci_ctx sci_ctx_t;

/* 值类型标签 */
typedef enum {
    SCI_NIL     = 0,   /* 空值 */
    SCI_INT64   = 1,   /* 64 位有符号整数 */
    SCI_FLOAT64 = 2,   /* 64 位浮点数 */
    SCI_BOOLEAN = 3,   /* 布尔值 */
    SCI_STRING  = 4,   /* UTF-8 字符串 */
    SCI_JSON    = 5    /* 复合类型序列化为 JSON */
} sci_type_t;

/* 带标签的联合体返回值 */
typedef struct {
    sci_type_t type;
    union {
        int64_t  i64;       /* type == SCI_INT64 时有效 */
        double   f64;       /* type == SCI_FLOAT64 时有效 */
        int32_t  boolean;   /* type == SCI_BOOLEAN 时有效 */
        char    *string;    /* type == SCI_STRING 或 SCI_JSON 时有效 */
    } value;
} sci_val_t;

/* 宿主回调函数签名：JSON 参数入，JSON 结果出。
   返回的字符串必须由宿主用 malloc 分配。
   Java 层读取内容后立即调用 free() 释放该指针，
   因此宿主不得返回栈上或 static 缓冲区的指针。 */
typedef char *(*sci_host_fn_t)(const char *json_args);
```

### 3.2 API 函数

**生命周期管理：**
```c
/* 创建具备全部能力的 Isolate。
   返回的 Isolate thread 指针后续每次调用均需传入。
   失败返回 NULL。 */
sci_ctx_t *sci_create_context(void);

/* 销毁 Isolate。释放所有关联内存。
   传入 NULL 为无操作。 */
void       sci_destroy_context(sci_ctx_t *ctx);

/* 在现有 Isolate 内重置 SCI 状态，不销毁 Isolate。
   清空所有用户自定义 var、宿主函数注册，
   将 SCI 重新初始化到出厂状态。 */
void       sci_reset_context(sci_ctx_t *ctx);
```

**版本查询：**
```c
/* 返回库版本字符串（如 "0.1.0"）。 */
const char *sci_version(void);

/* 返回 ABI 版本号（单调递增）。
   宿主应在 dlopen 后调用此函数断言 ABI 兼容性。 */
uint32_t    sci_abi_version(void);
```

**脚本求值：**
```c
/* 在当前上下文中求值 Clojure 表达式字符串。
   成功返回对应类型的 tagged union，失败返回 type=SCI_JSON 的 {"error": "..."}。 */
sci_val_t  sci_eval_string(sci_ctx_t *ctx, const char *code);
```

**双向调用：**
```c
/* 宿主 → 脚本：调用脚本命名空间中的函数。
   json_args 是 JSON 编码的参数数组，如 "[1, \"hello\"]"。 */
sci_val_t  sci_call_script_fn(sci_ctx_t *ctx,
                              const char *ns, const char *fn_name,
                              const char *json_args);

/* 脚本 → 宿主：注册 C 函数供脚本调用。
   在 SCI 中动态创建命名空间并注入 var，脚本可直接使用自然语法调用。
   示例：
     sci_register_host_fn(ctx, "log", "debug", my_logger);
   注册后脚本可直接写：
     (log/debug "hello")
   参数自动序列化为 JSON，C 函数接收 JSON 字符串并返回 JSON 字符串。 */
void       sci_register_host_fn(sci_ctx_t *ctx,
                                const char *ns, const char *fn_name,
                                sci_host_fn_t fn_ptr);
```

**内存管理：**
```c
/* 释放 sci_val_t 中的堆分配内存。
   sci_eval_string、sci_call_script_fn 返回的每个非 NIL 值必须调用一次此函数。
   val 为 NULL 时无操作，可安全传入未初始化的返回值。 */
void       sci_free_value(sci_val_t *val);
```

### 3.3 类型路由

`sci_eval_string` 和 `sci_call_script_fn` 根据 Clojure 返回值类型自动选择：

| Clojure 返回值 | sci_val_t 填充方式 |
|---------------|-------------------|
| `nil` | `type=SCI_NIL` |
| `1`, `42` (Long) | `type=SCI_INT64`, `value.i64=v` |
| `3.14` (Double) | `type=SCI_FLOAT64`, `value.f64=v` |
| `true` / `false` | `type=SCI_BOOLEAN`, `value.boolean=v` |
| `"hello"` (String) | `type=SCI_STRING`, `value.string=copy` |
| `{:a 1}`, `[1 2 3]`, `#{x y}` 等复合类型 | `type=SCI_JSON`, `value.string=json` |
| 错误 | `type=SCI_JSON`, `value.string={"error":"..."}` |

### 3.4 设计原理

- **基础类型直接传值，复合类型走 JSON**：避免跨 FFI 边界的复杂结构体映射。int64/float64/bool/nil 直接在 union 中传递；vector、map、set 序列化为 JSON 字符串，标记为 `SCI_JSON` 类型
- **字符串所有权归被调用方**：`sci_eval_string` / `sci_call_script_fn` 返回的字符串通过 `UnmanagedMemory.malloc()` 在 C 堆上分配，不受 JVM GC 管理。调用者必须调用 `sci_free_value` 释放
- **宿主回调返回值所有权**：`sci_host_fn_t` 返回的 `char*` 由宿主通过 `malloc` 分配。Java 层在 `@InvokeCFunctionPointer` 返回后立即调用 `CTypeConversion.toJavaString()` 拷贝内容，然后通过 `UnmanagedMemory.free()` 释放原指针。宿主不得返回栈上或 static 缓冲区地址
- **错误模型**：所有异常在内部捕获，以 `{"error": "..."}` JSON 格式返回。异常绝不跨 FFI 边界泄漏
- **每线程 Isolate**：`sci_ctx_t` 就是 GraalVM 的 `graal_isolatet_t*`。每个 `@CEntryPoint` 将其作为 `IsolateThread` 参数接收，GraalVM 自动路由到正确 Isolate

## 4. Java 层设计

### 4.1 `LibsciStructs.java` — C 类型映射

使用 GraalVM 的 `@CStruct`、`@CFieldGroup`、`@CField` 注解，将 C 的 `sci_val_t`
结构体映射为 Java 可直接操作的内存布局。

```java
@CStruct("sci_val_t")
public interface LibsciVal extends PointerBase {

    @CField("type")
    int getType();
    @CField("type")
    void setType(int type);

    @CFieldAddress("value.i64")
    LongPointer addressOfI64();
    @CField("value.i64")
    long getI64();
    @CField("value.i64")
    void setI64(long v);

    @CFieldAddress("value.f64")
    DoublePointer addressOfF64();
    @CField("value.f64")
    double getF64();
    @CField("value.f64")
    void setF64(double v);

    @CField("value.boolean")
    int getBoolean();
    @CField("value.boolean")
    void setBoolean(int v);

    @CFieldAddress("value.string")
    CCharPointerPointer addressOfString();
    @CField("value.string")
    CCharPointer getString();
    @CField("value.string")
    void setString(CCharPointer s);
}
```

### 4.2 `LibsciAPI.java` — C 入口点

所有 `@CEntryPoint` 方法以 `IsolateThread` 作为第一个参数。GraalVM 使用此指针
将调用路由到正确 Isolate 的堆和静态状态。

| 方法 | 对应 C 符号 | 职责 |
|------|------------|------|
| `createContext` | `sci_create_context` | 创建 Isolate，初始化 SCI，返回 `IsolateThread` |
| `destroyContext` | `sci_destroy_context` | 清理 SCI 状态、分离 Isolate |
| `resetContext` | `sci_reset_context` | 清空用户 var 和宿主函数注册，重新初始化 SCI |
| `evalString` | `sci_eval_string` | C 字符串 → Java → 委托 Clojure → 类型路由 → `LibsciVal` |
| `callScriptFn` | `sci_call_script_fn` | 查找 SCI 命名空间 fn，解析 JSON 参数，调用，序列化返回 |
| `registerHostFn` | `sci_register_host_fn` | 将 C 函数指针包装为 `@CFunctionPointer`，存入 Isolate 本地注册表 |
| `freeValue` | `sci_free_value` | 释放 STRING/JSON 的字符串内存和结构体，NULL 时无操作 |
| `version` | `sci_version` | 返回库版本字符串 |
| `abiVersion` | `sci_abi_version` | 返回 ABI 版本号 |

### 4.3 回调接口

```java
public interface LibsciHostFn extends CFunctionPointer {
    @InvokeCFunctionPointer
    CCharPointer invoke(CCharPointer jsonArgs);
}
```

当脚本调用已注册的宿主函数时，SCI 触发 `LibsciHostFn.invoke()`，GraalVM 通过
`@InvokeCFunctionPointer` 将调用路由回原始 C 函数指针。此方案与当前实现中
`HostDispatcher` 的 `@InvokeCFunctionPointer` 机制完全一致，已验证可行。

**宿主回调内存所有权合同**：`LibsciHostFn.invoke()` 返回的 `CCharPointer` 由宿主通过
`malloc` 分配。调用侧在获取 `CCharPointer` 后 (a) 调用 `CTypeConversion.toJavaString()`
拷贝内容到 Java String，(b) 调用 `UnmanagedMemory.free(result)` 释放该指针。

### 4.4 上下文存储（Isolate 本地）

每个 Isolate 拥有**私有的**状态 map，存储在 Java 静态字段中。由于 GraalVM `--shared`
模式下各 Isolate 的堆天然独立，Java 静态字段自然持有 Isolate 私有的值，无需
全局 `ConcurrentHashMap` 和 thread-id 查找。

每个 Isolate 的状态对象包含：
- `:sci-ctx` — SCI 解释器实例
- `:host-fns` — `Atom<Map{"ns/fn-name" -> LibsciHostFn}>`，宿主回调注册表
- `:base-opts` — SCI 初始化选项

```java
private static final AtomicReference<Object> STATE = new AtomicReference<>();

private static IPersistentMap getState() {
    IPersistentMap m = (IPersistentMap) STATE.get();
    if (m == null) {
        m = PersistentHashMap.EMPTY
            .assoc(KW_HOST_FNS, new Atom(PersistentHashMap.EMPTY));
        STATE.set(m);
    }
    return m;
}
```

### 4.5 sci_val_t 构造方法

```java
private static LibsciVal allocVal() {
    return UnmanagedMemory.calloc(SizeOf.get(LibsciVal.class));
}

private static LibsciVal buildIntVal(long v) {
    LibsciVal val = allocVal();
    val.setType(1); /* SCI_INT64 */
    val.setI64(v);
    return val;
}

private static LibsciVal buildJsonVal(String json) {
    LibsciVal val = allocVal();
    val.setType(5); /* SCI_JSON */
    CCharPointerHolder h = CTypeConversion.toCString(json);
    val.setString(h.get());
    return val;
}

// buildFloatVal, buildStringVal, buildBoolVal, buildNilVal 模式相同
```

### 4.6 错误处理

所有异常在 Java 层捕获，不允许向 C 侧泄漏：

```java
@CEntryPoint(name = "sci_eval_string")
public static LibsciVal evalString(IsolateThread thread, CCharPointer code) {
    try {
        String expr = CTypeConversion.toJavaString(code);
        String result = sci.impl.libsci_core.evalString(expr);
        return wrapEvalResult(result);
    } catch (Exception e) {
        StringWriter sw = new StringWriter();
        e.printStackTrace(new PrintWriter(sw));
        return buildJsonVal("{\"status\":\"error\",\"message\":\"" + escape(e) + "\"}");
    }
}
```

## 5. Clojure 层设计

### 5.1 `sci.impl.libsci-core` — 上下文管理

核心命名空间，管理 SCI 生命周期：

| 函数 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `create-context` | — | 上下文状态 map | 创建新 SCI 上下文，注入 cheshire + host/invoke 绑定 |
| `eval-string` | `s` | JSON 字符串 | 调用 `sci/eval-string*`，包装为 `{:status ... :value ...}` |

```clojure
(ns sci.impl.libsci-core
  (:require [cheshire.core :as json]
            [sci.core :as sci])
  (:gen-class
   :methods [^{:static true} [evalString [String] String]]))

(defn- build-base-opts []
  {:namespaces {'cheshire.core
                {'generate-string json/generate-string
                 'parse-string    json/parse-string}}
   :bindings {'host/invoke
              (fn [ns fn-name & args]
                (sci.impl.libsci-callbacks/dispatch-host-fn
                  (name ns) (name fn-name) (vec args)))}})

(defn create-context []
  {:sci-ctx (sci/init (build-base-opts))})

(defn -evalString [s]
  (sci/binding [sci/out *out*]
    (try
      (let [state  (LibsciAPI/getState)
            ctx    (:sci-ctx state)
            result (sci/eval-string* ctx s)]
        (json/generate-string {:status "ok" :value (str result)}))
      (catch Exception e
        (json/generate-string
          {:status "error"
           :error   (str (type e))
           :message (.getMessage e)})))))
```

### 5.2 `sci.impl.libsci-callbacks` — 宿主函数注册与调度

将 C 函数指针桥接为 SCI 可调用的 var。

| 函数 | 说明 |
|------|------|
| `register-host-fn [ns fn-name]` | 从 Java 注册表取 C 指针，包装为 SCI var，处理 JSON 序列化 |
| `dispatch-host-fn [ns fn-name args]` | `host/invoke` 底层调度原语 |

```clojure
(ns sci.impl.libsci-callbacks
  (:require [cheshire.core :as json]
            [sci.core :as sci]))

(defn register-host-fn [ns-name fn-name]
  (let [state    (LibsciAPI/getState)
        host-fns (:host-fns state)
        key      (str ns-name "/" fn-name)
        wrapper  (fn [& args]
                   (let [fn-ptr     (get @host-fns key)
                         arg-json   (json/generate-string (vec args))
                         raw-result (.invoke fn-ptr
                                    (CTypeConversion/toCString arg-json))
                         result-str (CTypeConversion/toJavaString raw-result)]
                     (try
                       (let [parsed (json/parse-string result-str)]
                         (if (= "ok" (get parsed "status"))
                           (get parsed "value")
                           (throw (ex-info (get parsed "message") parsed))))
                       (catch Exception e
                         (throw (ex-info (str "host fn error: " (.getMessage e)) {}))))))]
    (let [ctx  (:sci-ctx (LibsciAPI/getState))
          opts {:namespaces {(symbol ns-name) {(symbol fn-name) wrapper}}}]
      (LibsciAPI/updateSciCtx (sci/merge-opts ctx opts)))))

(defn dispatch-host-fn [ns-name fn-name args]
  (let [state    (LibsciAPI/getState)
        host-fns (:host-fns state)
        key      (str ns-name "/" fn-name)
        fn-ptr   (get @host-fns key)]
    (if fn-ptr
      (let [arg-json (json/generate-string args)
            raw-result (.invoke fn-ptr (CTypeConversion/toCString arg-json))
            result-str (CTypeConversion/toJavaString raw-result)]
        (try
          (let [parsed (json/parse-string result-str)]
            (if (= "ok" (get parsed "status"))
              (get parsed "value")
              {:status "error" :message (get parsed "message")}))
          (catch Exception e
            {:status "error"
             :message (str "Failed to parse host response: " (.getMessage e))})))
      {:status "error" :message (str "Unknown host fn: " key)})))
```

### 5.3 `sci.impl.libsci-serialization` — JSON 序列化

| 函数 | 说明 |
|------|------|
| `->json [v]` | Clojure 值 → JSON 字符串 |
| `<-json [s]` | JSON 字符串 → Clojure 数据结构（string keys） |
| `->json-safe [v]` | 后序遍历值树，将不可序列化的 SCI 类型转为字符串表示 |

**安全约束**：防止脚本返回无限流或超大数据导致 OOM：

```clojure
(ns sci.impl.libsci-serialization
  (:require [cheshire.core :as json]))

(def ^:dynamic *max-depth* 32)
(def ^:dynamic *max-string-length* (* 10 1024 1024))  ;; 10 MB

(defn ->json [v]
  (json/generate-string v {:max-depth *max-depth*}))

(defn <-json [s] (json/parse-string s))

(defn ->json-safe [v]
  (try
    (let [s (json/generate-string {:value v} {:max-depth *max-depth*})]
      ;; 截断过长结果——若序列化结果超过 max-string-length，
      ;; 截断并返回错误 envelope
      (if (> (count s) *max-string-length*)
        (json/generate-string {:status "error"
                               :message "Serialized result exceeds max length"})
        s))
    (catch Exception e
      (json/generate-string {:status "error"
                             :message (str "Serialization failed: " (.getMessage e))}))))
```

### 5.4 完整数据流

```
宿主 (C)                     Java (@CEntryPoint)               Clojure
───────                      ───────────────────               ───────
sci_create_context       →   createContext()              →    core/create-context
                                  ↓                               ↓
                              创建 Isolate                    sci/init + host/invoke 绑定
                                  ↓
                              返回 IsolateThread（即 sci_ctx_t*）

sci_eval_string          →   evalString(thread, ...)      →    core/evalString
                                  ↓                               ↓
                              路由到正确 Isolate              sci/eval-string*
                                  ↓                               ↓
                              ← JSON 字符串                 ←    {:status "ok" :value ...}
                                  ↓
                              类型路由 → sci_val_t → 返回给 C

sci_register_host_fn     →   registerHostFn(thread, ...)  →    callbacks/register-host-fn
                                  ↓                               ↓
                              WordFactory.pointer(fnPtr)       包装 fnPtr 为 wrapper fn
                                  ↓                               ↓
                              存入 host-fns atom               在 SCI 中 intern var
                                                                   ↓
(脚本直接调用 (log/debug "hello")) → wrapper fn → .invoke(fnPtr) → C 宿主函数执行
                                        ↑
                                   参数序列化为 JSON ["hello"]
                                        ↓
                                   返回值解析为 Clojure 数据
                                   C 返回 "true" → true
```

## 6. 构建流程

### 6.1 三阶段构建

**阶段一：Uberjar**

```bash
cd sci
lein with-profiles +libsci,+native-image do clean, uberjar
# 产出: target/sci-<version>-standalone.jar
```

**阶段二：Native Image 编译为共享库**

```bash
javac -cp target/sci-standalone.jar:$GRAALVM_HOME/lib/svm/builder/svm.jar \
    src/java/libsci/LibsciStructs.java \
    src/java/libsci/LibsciAPI.java

native-image \
    -jar sci/target/sci-standalone.jar \
    -cp src/java:src/clojure \
    -H:Name=libsci \
    --shared \
    --no-fallback \
    -H:+ReportExceptionStackTraces \
    -J-Dclojure.spec.skip-macros=true \
    -J-Dclojure.compiler.direct-linking=true \
    -H:IncludeResources=SCI_VERSION \
    -H:ReflectionConfigurationFiles=sci/reflection.json \
    --initialize-at-build-time \
    --enable-preview \
    -J-Xmx3g

# 产出: libsci.so, libsci.h, graal_isolate*.h
```

**阶段三：复制产物**

```bash
mkdir -p target/
mv libsci.so libsci.h graal_isolate*.h target/
```

### 6.2 `scripts/build.sh` 构建脚本

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SCI_DIR="$PROJECT_ROOT/sci"

# 阶段 1: 构建 SCI uberjar
cd "$SCI_DIR"
lein with-profiles +libsci,+native-image do clean, uberjar
SCI_JAR=$(ls -t target/sci-*-standalone.jar | head -1)

# 阶段 2: Native Image 编译
cd "$PROJECT_ROOT"
GRAALVM_HOME="${GRAALVM_HOME:-$(dirname $(dirname $(which native-image)))}"
SVM_JAR="$GRAALVM_HOME/lib/svm/builder/svm.jar"

javac -cp "$SCI_JAR:$SVM_JAR" \
    src/java/libsci/LibsciStructs.java \
    src/java/libsci/LibsciAPI.java

native-image \
    -jar "$SCI_JAR" \
    -cp src/java:src/clojure \
    -H:Name=libsci \
    --shared \
    --no-fallback \
    -H:+ReportExceptionStackTraces \
    -J-Dclojure.spec.skip-macros=true \
    -J-Dclojure.compiler.direct-linking=true \
    -H:IncludeResources=SCI_VERSION \
    -H:ReflectionConfigurationFiles=sci/reflection.json \
    --initialize-at-build-time \
    --enable-preview \
    -J-Xmx3g

# 阶段 3: 复制产物
mkdir -p target
mv libsci.so libsci.h graal_isolate.h graal_isolate_dynamic.h libsci_dynamic.h target/

echo "构建完成: target/libsci.so"
```

### 6.3 `Makefile`

```makefile
.PHONY: build test test-clj test-c test-zig test-rust clean

build:
	./scripts/build.sh

test: test-clj
	$(MAKE) -C test/integration/c test
	cd test/integration/zig && zig build test
	cd test/integration/rust && cargo test

test-clj:
	cd sci && lein with-profiles +libsci test

clean:
	rm -rf target/
```

### 6.4 `project.clj` 关键配置

```clojure
(defproject org.babashka/sci "..."  ;; 继承 SCI 的 project
  :source-paths ["sci/src" "src/clojure"]
  :java-source-paths ["sci/src" "src/java"]
  :profiles {
    :libsci {
      :dependencies [[cheshire "5.10.0"]]
      :source-paths ["sci/src" "src/clojure"]
      :java-source-paths ["sci/src" "src/java"]
      :aot [sci.impl.libsci-core
            sci.impl.libsci-callbacks
            sci.impl.libsci-serialization]}})
```

## 7. 测试策略

### 7.1 三层测试金字塔

| 层 | 位置 | 范围 | 占比 |
|----|------|------|------|
| Clojure 单元测试 | `test/clojure/libsci/` | 上下文生命周期、序列化、回调注册 | 55-60% |
| 集成测试 | `test/integration/{c,zig,rust}/` | dlopen 真实 .so，端到端场景 | 15-20% |
| Java 层 | 通过 Clojure + 集成测试间接验证 | @CEntryPoint 正确性 | 20-25% |

### 7.2 Clojure 单元测试

| 测试文件 | 测试内容 |
|----------|---------|
| `core_test.clj` | 上下文创建/销毁；`eval-string` 基本求值；异常捕获；多上下文隔离 |
| `serialization_test.clj` | Clojure ↔ JSON 双向转换；SCI 特殊类型安全处理；nil/数字/字符串/嵌套结构正确性 |
| `callbacks_test.clj` | 宿主函数注册；脚本调宿主流；参数传递；返回值回传；未注册函数错误处理 |

### 7.3 集成测试

每种语言覆盖 8 个场景：

| # | 测试场景 | 验证点 |
|---|---------|--------|
| 1 | `test_create_destroy` | 上下文创建返回非 NULL，销毁不崩溃 |
| 2 | `test_eval_simple` | `(+ 1 2)` 返回 `type=SCI_INT64, value.i64=3` |
| 3 | `test_eval_error` | 语法错误返回 `type=SCI_JSON, status=error` |
| 4 | `test_multi_contexts` | 两个独立上下文，变量互不污染 |
| 5 | `test_host_callback` | 注册 C 函数，脚本调用返回正确结果 |
| 6 | `test_call_script_fn` | 宿主调用脚本定义的函数 |
| 7 | `test_reset_context` | 重置上下文，验证状态清空 |
| 8 | `test_memory_leak` | 循环 create/destroy 100 次，内存不增长 |

### 7.4 TDD 执行顺序

**第一阶段 — Clojure 层（纯 JVM，不依赖 native-image）：**

```
1. RED:   编写 core_test.clj → 失败（文件/函数不存在）
2. GREEN: 实现 libsci.core → 通过
3. RED:   编写 serialization_test.clj → 失败
4. GREEN: 实现 libsci.serialization → 通过
5. RED:   编写 callbacks_test.clj → 失败
6. GREEN: 实现 libsci.callbacks → 通过
```

**第二阶段 — Java @CEntryPoint + 集成测试（需先编译 .so）：**

```
7. BUILD: scripts/build.sh → libsci.so + libsci.h
8. RED:   编写 test/integration/c/main.c → 编译通过，运行测试失败
9. GREEN: 编译 + 链接 .so → 全部 8 个场景通过
10. 同样流程 for Zig, Rust
```

## 8. 线程安全与隔离

### 8.1 每线程 Isolate 模型

- Isolate 之间**不共享任何可变状态** — 各有独立堆、SCI 上下文和宿主函数注册表
- GraalVM 的 `--shared` 模式内置 `graal_create_isolate()`
- Isolate 绑定到创建它的线程（GraalVM 约束）
- Java 静态字段在 Isolate 间天然隔离 — 无需全局 `ConcurrentHashMap`

### 8.2 跨线程调用约束

GraalVM Isolate 与创建它的线程绑定。虽然 GraalVM 支持通过
`graal_attach_thread()` 将另一个线程附加到已有 Isolate，但 libsci 的
v1 不暴露此机制——调用者必须保证每个 `sci_ctx_t*` 始终从创建它的同一线程传入。

如果从其他线程传入已有 `sci_ctx_t*`，`@CEntryPoint` 可能触发未定义行为或 JVM
致命错误。此约束在 `include/libsci.h` 头文件的注释中明确标注。

### 8.3 宿主语言线程固定要求

对于使用 M:N 线程调度的宿主语言：

- **Go**：必须在每个 FFI 调用 goroutine 中调用 `runtime.LockOSThread()`，
  防止 goroutine 在执行中途被调度到不同 OS 线程
- **Rust (Tokio)**：必须使用 `spawn_blocking` 或专用 `std::thread` 执行
  libsci FFI 调用，不得在 async task 中直接调用
- **Python / Node.js**：受 GIL/事件循环限制，天然单线程安全

### 8.4 资源约束

- GraalVM Isolate 创建有固定内存开销（约数 MB）
- 高频 create/destroy 场景使用 `sci_reset_context` 复用已有 Isolate

## 9. 与当前实现的关系

| 当前实现的组件 (patch 模式) | 重构后对应物 | 变化 |
|---|---|---|
| `sci/libsci/src/sci/impl/LibSci.java` | `src/java/libsci/LibsciAPI.java` | 新目录，新入口点名称 |
| `sci/libsci/src/sci/impl/LibSciHost.java` | 合并到 `LibsciAPI.java` | HostFn 接口内嵌 |
| `sci/libsci/src/sci/impl/libsci_host.clj` | `src/clojure/libsci/core.clj` + `callbacks.clj` | 拆分为两个独立模块 |
| `dispatchHostCall(argsJson)` | `LibsciHostFn.invoke(jsonArgs)` | 接口不变，从单一路由 → 按 key 查找 |
| `host-call` binding | `host/invoke` binding | 命名简化 |
| `create-host-binding` 闭包 | `register-host-fn` wrapper | 每函数独立注册，不再批量 |
| `registered-nss` atom | `host-fns` atom | key 改为 `"ns/fn-name"` |
| `contexts` thread-id map | GraalVM Isolate 堆隔离 | 不再需要 thread-id 查找 |
| `register_namespaces(thread, json)` | `sci_register_host_fn(ctx, ns, fn, ptr)` | 逐个注册而非批量 JSON |
| `set_host_dispatcher(thread, ptr)` | 纳入 `sci_register_host_fn` | 每个函数独立 C 指针 |

## 10. 文件变更清单

| 操作 | 文件 | 说明 |
|------|------|------|
| **删除** | `patches/host_bridge.patch` | 不再使用 patch |
| **删除** | `sci/libsci/src/sci/impl/LibSci.java` | 回退 submodule，代码移到 src/ |
| **删除** | `sci/libsci/src/sci/impl/LibSciHost.java` | 回退 submodule |
| **删除** | `sci/libsci/src/sci/impl/libsci_host.clj` | 回退 submodule |
| **删除** | `sci/libsci/bb/libsci_tasks.clj` | bb 任务不再需要 |
| **删除** | `sci/reflection.json` | 回退到 SCI 原始版本 |
| **新建** | `src/java/libsci/LibsciStructs.java` | C type mapping |
| **新建** | `src/java/libsci/LibsciAPI.java` | 9 个 @CEntryPoint |
| **新建** | `src/clojure/libsci/core.clj` | SCI 上下文 + eval |
| **新建** | `src/clojure/libsci/serialization.clj` | JSON 序列化 |
| **新建** | `src/clojure/libsci/callbacks.clj` | 宿主回调注册 |
| **新建** | `include/libsci.h` | 公开 C ABI 头文件 |
| **迁移** | `tests/` → `test/clojure/libsci/core_test.clj` | 重写适配新 API |
| **迁移** | `tests/` → `test/clojure/libsci/serialization_test.clj` | 重写 |
| **迁移** | `tests/` → `test/clojure/libsci/callbacks_test.clj` | 重写 |
| **迁移** | `tests/c/` → `test/integration/c/` | 重写适配新 API |
| **迁移** | `tests/zig/` → `test/integration/zig/` | 重写 |
| **迁移** | `tests/rust/` → `test/integration/rust/` | 重写 |
| **修改** | `sci/project.clj` | 新增 source-paths、AOT |
| **新建** | `scripts/build.sh` | 构建脚本 |
| **新建** | `Makefile` | 顶层命令 |
| **更新** | `CLAUDE.md` | 反映新架构 |

## 11. 依赖关系

### 11.1 构建时依赖

| 依赖 | 用途 | 版本要求 |
|------|------|---------|
| GraalVM | native-image 编译器 | JDK 21+，含 `native-image` |
| Leiningen | uberjar + 测试 | 继承自 SCI |
| GCC | C 集成测试 | 任意 |
| Zig | Zig 集成测试 | 0.11+ |
| Rust | Rust 集成测试 | stable |

### 11.2 运行时依赖

**无。** 编译后的 `.so` / `.dylib` / `.dll` 是独立的原生二进制文件。

## 12. 后续规划（本阶段不实现）

- Pod 支持（需 `babashka/babashka` 子模块替换 `babashka/sci`）
- GitHub Actions 矩阵构建（所有平台 × 架构组合）
- 预编译二进制发布（GitHub Releases）
- 能力模型（bitmask sandbox）
- `SCI_BINARY` 类型标签（Transit、MessagePack 二进制序列化）
- Isolate 池化

## 13. 已知限制与风险

### 13.1 信号处理器

共享库通过 `BABASHKA_DISABLE_SIGNAL_HANDLERS=true` 禁止接管宿主进程的信号，
这使得库本身不会干扰宿主应用的 SIGINT/SIGTERM 处理。

**宿主影响**：Clojure 脚本内的 Ctrl-C 捕获、`future-cancel` 的超时中断、
以及依赖信号机制的 Clojure 特性在共享库环境下不会触发。宿主应用必须自行
捕获进程信号并手动调用 `sci_destroy_context` 或 `sci_reset_context` 进行清理。

### 13.2 序列化深度限制

`->json-safe` 强制最大递归深度 32 和最大结果字符串 10MB。超过限制会导致
序列化失败并返回 `{"status":"error",...}`。如有特殊需求，宿主可在注册
命名空间时覆盖 `*max-depth*` 和 `*max-string-length*` 动态变量。

### 13.3 JSON 编解码性能

基础类型（int64/float64/bool/nil）直接通过 tagged union 传递，无 JSON 开销。
复合类型（vector、map、set）和宿主回调每次都经过 JSON 序列化/反序列化，
约 2-4μs/次（由 cheshire 主导）。对高频调用场景（>10K 次/秒），可在 v2
阶段启用 `SCI_BINARY` 标签接入 Transit 或 MessagePack 以降低开销。
