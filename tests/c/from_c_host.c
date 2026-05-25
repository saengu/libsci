/*
 * from_c_host.c -- Integration test for libsci host bridge API.
 *
 * Tests all C entry points:
 *   set_host_dispatcher, load_script, call_function,
 *   eval_in_context, reset_context, eval_string
 *
 * Host passes a raw function pointer to set_host_dispatcher.
 * libsci calls it directly via CFunctionPointer — no callPtr
 * bridge needed on the host side.
 *
 * Build: gcc -o from_c_host from_c_host.c -I../../sci/libsci/target \
 *        -L../../sci/libsci/target -lsci
 * Run:   LD_LIBRARY_PATH=../../sci/libsci/target ./from_c_host
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <libsci.h>

/* ------------------------------------------------------------------ */
/*  Forward declarations (exported from libsci.so via @CEntryPoint)   */
/* ------------------------------------------------------------------ */

void set_host_dispatcher(long long thread, long long fn_ptr);
char* load_script(long long thread, const char* script);
char* call_function(long long thread, const char* fn_name, const char* args_edn);
char* eval_in_context(long long thread, const char* expr);
void  reset_context(long long thread);
char* eval_string(long long thread, const char* expr);
char* register_namespaces(long long thread, const char* regs_json);

/* ------------------------------------------------------------------ */
/*  Host dispatcher callback                                          */
/* ------------------------------------------------------------------ */

static const char* host_dispatcher(const char* json_args) {
    if (strstr(json_args, "\"ns\"") != NULL) {
        /* Registered namespace call: {"ns":"math","fn":"add","args":[1,2]} */
        if (strstr(json_args, "\"math\"") != NULL &&
            strstr(json_args, "\"add\"") != NULL) {
            return "{\"status\":\"ok\",\"value\":7}";
        }
        if (strstr(json_args, "\"math\"") != NULL &&
            strstr(json_args, "\"subtract\"") != NULL) {
            return "{\"status\":\"ok\",\"value\":-1}";
        }
        return "{\"status\":\"error\",\"message\":\"unknown registered function\"}";
    }
    /* Direct host-call: {"fn":"add","args":[3,4]} */
    if (strstr(json_args, "\"add\"")) {
        return "{\"status\":\"ok\",\"value\":7}";
    }
    return "{\"status\":\"error\",\"message\":\"unknown host function\"}";
}

/* ------------------------------------------------------------------ */
/*  Test helpers                                                      */
/* ------------------------------------------------------------------ */

static int tests_run = 0;
static int tests_passed = 0;

#define TEST(name) do { tests_run++; if (test_##name()) { tests_passed++; printf("  PASS: %s\n", #name); } else { printf("  FAIL: %s\n", #name); } } while(0)
#define ASSERT(cond, msg) do { if (!(cond)) { fprintf(stderr, "    ASSERT FAIL: %s\n", msg); return 0; } } while(0)
#define ASSERT_JSON_OK(json, msg) do { if (strstr((json), "\"status\":\"ok\"") == NULL) { fprintf(stderr, "    ASSERT FAIL: %s -- expected ok, got [%s]\n", msg, (json)); return 0; } } while(0)

static int _test_setup(graal_isolatethread_t** t) {
    graal_isolate_t* isolate = NULL;
    if (graal_create_isolate(NULL, &isolate, t) != 0) return 0;
    set_host_dispatcher((long long)*t, (long long)&host_dispatcher);
    return 1;
}

/* ------------------------------------------------------------------ */
/*  Tests                                                             */
/* ------------------------------------------------------------------ */

static int test_set_host_dispatcher(void) {
    graal_isolate_t* isolate = NULL;
    graal_isolatethread_t* thread = NULL;
    if (graal_create_isolate(NULL, &isolate, &thread) != 0) return 0;
    set_host_dispatcher((long long)thread, (long long)&host_dispatcher);
    graal_tear_down_isolate(thread);
    return 1;
}

static int test_load_and_call(void) {
    graal_isolatethread_t* thread = NULL;
    if (!_test_setup(&thread)) return 0;

    char* r = load_script((long long)thread, "(defn add [x y] (+ x y))");
    ASSERT_JSON_OK(r, "load script");

    r = call_function((long long)thread, "add", "3 4");
    ASSERT_JSON_OK(r, "call add");
    ASSERT(strstr(r, "\"value\":\"7\"") != NULL, "add result should be 7");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_eval_in_context(void) {
    graal_isolatethread_t* thread = NULL;
    if (!_test_setup(&thread)) return 0;

    load_script((long long)thread, "(def x 42)");
    char* r = eval_in_context((long long)thread, "x");
    ASSERT_JSON_OK(r, "eval in context");
    ASSERT(strstr(r, "\"value\":\"42\"") != NULL, "x should be 42");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_eval_fresh(void) {
    graal_isolatethread_t* thread = NULL;
    if (!_test_setup(&thread)) return 0;

    char* r = eval_string((long long)thread, "(def x 42)");
    ASSERT(strstr(r, "#'user/x") != NULL, "def should succeed in eval_string");

    r = eval_string((long long)thread, "(try x (catch Exception e \"err\"))");
    ASSERT(strstr(r, "err") != NULL, "x should not be visible after fresh eval_string");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_reset_context(void) {
    graal_isolatethread_t* thread = NULL;
    if (!_test_setup(&thread)) return 0;

    load_script((long long)thread, "(def x 1)");
    reset_context((long long)thread);

    char* r = call_function((long long)thread, "add", "1 2");
    ASSERT(strstr(r, "\"status\":\"error\"") != NULL, "call should fail after reset");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_host_call(void) {
    graal_isolatethread_t* thread = NULL;
    if (!_test_setup(&thread)) return 0;

    char* r = load_script((long long)thread,
        "(defn compute [x y] (host-call \"add\" x y))");
    ASSERT_JSON_OK(r, "load compute");

    r = call_function((long long)thread, "compute", "3 4");
    ASSERT_JSON_OK(r, "host-call via compute");
    ASSERT(strstr(r, ":value 7") != NULL, "result value should contain :value 7");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_edn_keyword_args(void) {
    graal_isolatethread_t* thread = NULL;
    if (!_test_setup(&thread)) return 0;

    load_script((long long)thread, "(defn get-val [m k] (get m k))");
    char* r = call_function((long long)thread, "get-val", "{:a 1 :b 2} :a");
    ASSERT_JSON_OK(r, "EDN keyword arg");
    ASSERT(strstr(r, "\"value\":\"1\"") != NULL, "should return 1");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_cross_ns_call(void) {
    graal_isolatethread_t* thread = NULL;
    if (!_test_setup(&thread)) return 0;

    load_script((long long)thread, "(ns my.ns) (defn calc [x] (* x 2))");
    char* r = call_function((long long)thread, "my.ns/calc", "21");
    ASSERT_JSON_OK(r, "cross-ns call");
    ASSERT(strstr(r, "\"value\":\"42\"") != NULL, "should return 42");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_register_namespaces(void) {
    graal_isolatethread_t* thread = NULL;
    if (!_test_setup(&thread)) return 0;

    char* r = register_namespaces((long long)thread,
        "{\"namespaces\":{\"math\":[\"add\",\"subtract\"]}}");
    ASSERT_JSON_OK(r, "register math namespace");

    /* Test calling the registered function directly via eval */
    r = load_script((long long)thread, "(math/add 1 2)");
    ASSERT_JSON_OK(r, "call registered math/add");
    ASSERT(strstr(r, "\"value\":\"7\"") != NULL, "math/add result should be 7");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_register_namespaces_after_load(void) {
    graal_isolatethread_t* thread = NULL;
    if (!_test_setup(&thread)) return 0;

    load_script((long long)thread, "(def x 42)");

    char* r = register_namespaces((long long)thread,
        "{\"namespaces\":{\"late\":[\"fn\"]}}");
    ASSERT_JSON_OK(r, "register after load");

    r = load_script((long long)thread, "(defn use-late [y] (late/fn y))");
    ASSERT_JSON_OK(r, "load script using late-registered ns");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_register_namespaces_error(void) {
    graal_isolatethread_t* thread = NULL;
    if (!_test_setup(&thread)) return 0;

    char* r = register_namespaces((long long)thread, "not-json");
    ASSERT(strstr(r, "\"status\":\"error\"") != NULL,
           "bad JSON should return error");

    graal_tear_down_isolate(thread);
    return 1;
}

/* ------------------------------------------------------------------ */
/*  Main                                                              */
/* ------------------------------------------------------------------ */

int main(void) {
    printf("libsci host bridge integration tests\n");
    printf("------------------------------------\n");

    TEST(set_host_dispatcher);
    TEST(load_and_call);
    TEST(eval_in_context);
    TEST(eval_fresh);
    TEST(reset_context);
    TEST(host_call);
    TEST(edn_keyword_args);
    TEST(cross_ns_call);
    TEST(register_namespaces);
    TEST(register_namespaces_after_load);
    TEST(register_namespaces_error);

    printf("\n%d / %d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
