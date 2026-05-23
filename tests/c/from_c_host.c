/*
 * from_c_host.c -- Integration test for libsci host bridge API.
 *
 * Tests all C entry points:
 *   load_script, call_function, eval_in_context, reset_context, eval,
 *   get_pending_host_call, deliver_host_call_result
 *
 * Each test returns 0 on success, 1 on failure.
 * Prints PASS/FAIL per test.
 *
 * Build: gcc -o from_c_host from_c_host.c -I../../sci/libsci/target \
 *        -L../../sci/libsci/target -lsci
 * Run:   LD_LIBRARY_PATH=../../sci/libsci/target ./from_c_host
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <libsci.h>

/* ------------------------------------------------------------------ */
/*  Forward declarations                                              */
/* ------------------------------------------------------------------ */

char* load_script(long long thread, const char* script);
char* call_function(long long thread, const char* fn_name, const char* args_edn);
char* eval_in_context(long long thread, const char* expr);
void  reset_context(long long thread);
char* eval(long long thread, const char* expr);
char* get_pending_host_call(long long thread, const char* id);
char* deliver_host_call_result(long long thread, const char* id, const char* result);

/* ------------------------------------------------------------------ */
/*  Test helpers                                                      */
/* ------------------------------------------------------------------ */

static int tests_run = 0;
static int tests_passed = 0;

#define TEST(name) do { tests_run++; if (test_##name()) { tests_passed++; printf("  PASS: %s\n", #name); } else { printf("  FAIL: %s\n", #name); } } while(0)
#define ASSERT(cond, msg) do { if (!(cond)) { fprintf(stderr, "    ASSERT FAIL: %s\n", msg); return 0; } } while(0)
#define ASSERT_JSON_OK(json, msg) do { if (strstr((json), "\"status\":\"ok\"") == NULL) { fprintf(stderr, "    ASSERT FAIL: %s -- expected ok, got [%s]\n", msg, (json)); return 0; } } while(0)

/* ------------------------------------------------------------------ */
/*  Tests                                                             */
/* ------------------------------------------------------------------ */

static int test_load_and_call(void) {
    graal_isolate_t* isolate = NULL;
    graal_isolatethread_t* thread = NULL;
    if (graal_create_isolate(NULL, &isolate, &thread) != 0) return 0;

    char* r = load_script((long long)thread, "(defn add [x y] (+ x y))");
    ASSERT_JSON_OK(r, "load script");

    r = call_function((long long)thread, "add", "3 4");
    ASSERT_JSON_OK(r, "call add");
    ASSERT(strstr(r, "\"value\":\"7\"") != NULL, "add result should be 7");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_eval_in_context(void) {
    graal_isolate_t* isolate = NULL;
    graal_isolatethread_t* thread = NULL;
    if (graal_create_isolate(NULL, &isolate, &thread) != 0) return 0;

    load_script((long long)thread, "(def x 42)");
    char* r = eval_in_context((long long)thread, "x");
    ASSERT_JSON_OK(r, "eval in context");
    ASSERT(strstr(r, "\"value\":\"42\"") != NULL, "x should be 42");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_eval_fresh(void) {
    graal_isolate_t* isolate = NULL;
    graal_isolatethread_t* thread = NULL;
    if (graal_create_isolate(NULL, &isolate, &thread) != 0) return 0;

    /* eval creates a fresh context each time, defs don't persist */
    char* r = eval((long long)thread, "(def x 42)");
    ASSERT(strstr(r, "#'user/x") != NULL, "def should succeed in eval");

    r = eval((long long)thread, "(try x (catch Exception e \"err\"))");
    ASSERT(strstr(r, "err") != NULL, "x should not be visible after fresh eval");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_reset_context(void) {
    graal_isolate_t* isolate = NULL;
    graal_isolatethread_t* thread = NULL;
    if (graal_create_isolate(NULL, &isolate, &thread) != 0) return 0;

    load_script((long long)thread, "(def x 1)");
    reset_context((long long)thread);

    /* After reset, context is gone -- call_function should return error */
    char* r = call_function((long long)thread, "add", "1 2");
    ASSERT(strstr(r, "\"status\":\"error\"") != NULL, "call should fail after reset");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_host_call_data_protocol(void) {
    graal_isolate_t* isolate = NULL;
    graal_isolatethread_t* thread = NULL;
    if (graal_create_isolate(NULL, &isolate, &thread) != 0) return 0;

    /* Call host-call, get back correlation ID */
    char* r = load_script((long long)thread, "(host-call \"add\" 3 4)");
    ASSERT_JSON_OK(r, "host-call should succeed");
    ASSERT(strstr(r, "\"value\":\"") != NULL, "value should be a UUID string");

    /* Extract UUID from response */
    const char* r2 = load_script((long long)thread, "(host-call \"add\" 3 4)");
    ASSERT(strstr(r2, "\"value\":\"") != NULL, "should have UUID");
    /* Skip to the value field */
    const char* val_start = strstr(r2, "\"value\":\"") + 9;
    char uuid[37];
    int i = 0;
    while (i < 36 && val_start[i] != '\"') {
        uuid[i] = val_start[i];
        i++;
    }
    uuid[i] = '\0';

    /* Get the pending call data by UUID */
    char* call_data = get_pending_host_call((long long)thread, uuid);
    ASSERT(strstr(call_data, "add") != NULL, "call data should contain fn name");

    /* Deliver the result */
    char* deliver = deliver_host_call_result((long long)thread, uuid,
        "{\"status\":\"ok\",\"value\":7}");
    ASSERT_JSON_OK(deliver, "deliver should succeed");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_edn_keyword_args(void) {
    graal_isolate_t* isolate = NULL;
    graal_isolatethread_t* thread = NULL;
    if (graal_create_isolate(NULL, &isolate, &thread) != 0) return 0;

    load_script((long long)thread, "(defn get-val [m k] (get m k))");
    char* r = call_function((long long)thread, "get-val", "{:a 1 :b 2} :a");
    ASSERT_JSON_OK(r, "EDN keyword arg");
    ASSERT(strstr(r, "\"value\":\"1\"") != NULL, "should return 1");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_cross_ns_call(void) {
    graal_isolate_t* isolate = NULL;
    graal_isolatethread_t* thread = NULL;
    if (graal_create_isolate(NULL, &isolate, &thread) != 0) return 0;

    load_script((long long)thread, "(ns my.ns) (defn calc [x] (* x 2))");
    char* r = call_function((long long)thread, "my.ns/calc", "21");
    ASSERT_JSON_OK(r, "cross-ns call");
    ASSERT(strstr(r, "\"value\":\"42\"") != NULL, "should return 42");

    graal_tear_down_isolate(thread);
    return 1;
}

/* ------------------------------------------------------------------ */
/*  Main                                                              */
/* ------------------------------------------------------------------ */

int main(void) {
    printf("libsci host bridge integration tests\n");
    printf("------------------------------------\n");

    TEST(load_and_call);
    TEST(eval_in_context);
    TEST(eval_fresh);
    TEST(reset_context);
    TEST(host_call_data_protocol);
    TEST(edn_keyword_args);
    TEST(cross_ns_call);

    printf("\n%d / %d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
