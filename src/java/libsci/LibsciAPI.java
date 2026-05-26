package libsci;

import org.graalvm.nativeimage.IsolateThread;
import org.graalvm.nativeimage.c.function.CEntryPoint;
import org.graalvm.nativeimage.c.type.CCharPointer;
import org.graalvm.nativeimage.c.type.CTypeConversion;
import org.graalvm.nativeimage.c.type.CConst;
import org.graalvm.nativeimage.UnmanagedMemory;
import org.graalvm.word.WordFactory;
import java.io.PrintWriter;
import java.io.StringWriter;

/** libsci shared library C entry points.
 *
 *  All @CEntryPoint methods return JSON strings (char*).
 *  The sci_val_t tagged union is parsed on the C side by inline
 *  functions defined in include/libsci.h.
 *
 *  9 exported C functions:
 *    sci_create_context, sci_destroy_context, sci_reset_context
 *    sci_eval_string, sci_call_script_fn, sci_register_host_fn
 *    sci_version, sci_abi_version
 *    sci_free_value */
public final class LibsciAPI {

    // ── Isolate-local state ─────────────────────────────────────────
    // In --shared mode, static fields are per-Isolate (no ConcurrentHashMap).

    // In --shared mode, static fields are per-Isolate (no ConcurrentHashMap needed).
    // Store host fn pointers in a simple Java map to avoid Object->Word cast issues.

    private static volatile Object SCI_CTX = null;
    private static volatile java.util.HashMap<String, Long> HOST_FNS = null;

    public static Object getSciCtx() { return SCI_CTX; }
    public static void setSciCtx(Object ctx) { SCI_CTX = ctx; }

    private static java.util.HashMap<String, Long> getHostFns() {
        if (HOST_FNS == null) HOST_FNS = new java.util.HashMap<>();
        return HOST_FNS;
    }

    public static String invokeHostFn(String ns, String fnName, String argsJson) {
        String key = ns + "/" + fnName;
        Long ptr = getHostFns().get(key);
        if (ptr == null) {
            return "{\"status\":\"error\",\"message\":\"Host function not found: " + key + "\"}";
        }
        try {
            LibsciHostFn fn = (LibsciHostFn) WordFactory.pointer(ptr);
            CTypeConversion.CCharPointerHolder holder = CTypeConversion.toCString(argsJson);
            CCharPointer rawResult = fn.invoke(holder.get());
            String result = CTypeConversion.toJavaString(rawResult);
            return result;
        } catch (Exception e) {
            return "{\"status\":\"error\",\"message\":\"Host fn invoke failed: " + e.getMessage() + "\"}";
        }
    }

    // ── Lifecycle ───────────────────────────────────────────────────

    @CEntryPoint(name = "sci_create_context")
    public static void createContext(
            @CEntryPoint.IsolateThreadContext IsolateThread thread) {
        try {
            Class<?> c = Class.forName("libsci.core");
            c.getMethod("createContext").invoke(null);
        } catch (Exception e) {
            // Clojure initialization failed; context will handle errors on eval
        }
    }

    @CEntryPoint(name = "sci_destroy_context")
    public static void destroyContext(
            @CEntryPoint.IsolateThreadContext IsolateThread thread) {
        SCI_CTX = null;
        HOST_FNS = null;
    }

    @CEntryPoint(name = "sci_reset_context")
    public static void resetContext(
            @CEntryPoint.IsolateThreadContext IsolateThread thread) {
        SCI_CTX = null;
        HOST_FNS = null;
    }

    // ── Script evaluation ──

    @CEntryPoint(name = "sci_eval_string")
    public static @CConst CCharPointer evalString(
            @CEntryPoint.IsolateThreadContext IsolateThread thread,
            @CConst CCharPointer code) {
        try {
            String expr = CTypeConversion.toJavaString(code);
            Class<?> c = Class.forName("libsci.core");
            String result = (String) c.getMethod("evalString", String.class).invoke(null, expr);
            CTypeConversion.CCharPointerHolder h = CTypeConversion.toCString(result);
            return h.get();
        } catch (Exception e) {
            CTypeConversion.CCharPointerHolder h = CTypeConversion.toCString(
                "{\"status\":\"error\",\"message\":\"" + escape(e.getMessage()) + "\"}");
            return h.get();
        }
    }

    @CEntryPoint(name = "sci_call_script_fn")
    public static @CConst CCharPointer callScriptFn(
            @CEntryPoint.IsolateThreadContext IsolateThread thread,
            @CConst CCharPointer ns,
            @CConst CCharPointer fnName,
            @CConst CCharPointer jsonArgs) {
        try {
            String r = (String) Class.forName("libsci.core")
                .getMethod("callScriptFn", String.class, String.class, String.class)
                .invoke(null, CTypeConversion.toJavaString(ns),
                        CTypeConversion.toJavaString(fnName),
                        CTypeConversion.toJavaString(jsonArgs));
            CTypeConversion.CCharPointerHolder h = CTypeConversion.toCString(r);
            return h.get();
        } catch (Exception e) {
            StringWriter sw = new StringWriter();
            e.printStackTrace(new PrintWriter(sw));
            CTypeConversion.CCharPointerHolder h = CTypeConversion.toCString(
                "{\"status\":\"error\",\"message\":\"" + escape(sw.toString()) + "\"}");
            return h.get();
        }
    }

    @CEntryPoint(name = "sci_register_host_fn")
    public static void registerHostFn(
            @CEntryPoint.IsolateThreadContext IsolateThread thread,
            @CConst CCharPointer ns,
            @CConst CCharPointer fnName,
            long fnPtr) {
        String nsStr = CTypeConversion.toJavaString(ns);
        String fnStr = CTypeConversion.toJavaString(fnName);
        String key = nsStr + "/" + fnStr;
        getHostFns().put(key, fnPtr);

        // Create SCI namespace var for transparent (test/add 3 4) syntax.
        try {
            clojure.lang.Var regFn = clojure.lang.RT.var("libsci.callbacks", "register-host-fn");
            regFn.invoke(nsStr, fnStr);
        } catch (Exception e) {
            System.err.println("[libsci] SCI var registration failed: " + e.getMessage());
        }
    }

    // ── Version ──

    private static final String VERSION = "0.1.0";

    @CEntryPoint(name = "sci_version")
    public static @CConst CCharPointer version(
            @CEntryPoint.IsolateThreadContext IsolateThread thread) {
        CTypeConversion.CCharPointerHolder h = CTypeConversion.toCString(VERSION);
        return h.get();
    }

    @CEntryPoint(name = "sci_abi_version")
    public static int abiVersion(
            @CEntryPoint.IsolateThreadContext IsolateThread thread) {
        return 1;
    }

    // ── Memory ──

    @CEntryPoint(name = "sci_free_value")
    public static void freeValue(
            @CEntryPoint.IsolateThreadContext IsolateThread thread,
            @CConst CCharPointer str) {
        if (str.isNonNull()) UnmanagedMemory.free(str);
    }

    private static String escape(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n");
    }
}
