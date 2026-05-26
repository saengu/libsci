/* from_c_host.c — Integration test for the new libsci C API.
 *
 * Tests:
 *   sci_create_context, sci_destroy_context, sci_reset_context
 *   sci_eval_string, sci_call_script_fn, sci_register_host_fn
 *   sci_version, sci_abi_version
 *
 * Build: gcc -o from_c_host from_c_host.c -I../../target -L../../target -lsci -Wl,-rpath,../../target
 * Run:   ./from_c_host
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <libsci.h>

static int tests_run = 0;
static int tests_passed = 0;

#define TEST(name) do { tests_run++; if (test_##name()) { tests_passed++; printf("  PASS: %s\n", #name); } else { printf("  FAIL: %s\n", #name); } } while(0)
#define ASSERT(cond, msg) do { if (!(cond)) { fprintf(stderr, "    ASSERT FAIL: %s\n", msg); return 0; } } while(0)
#define ASSERT_OK(json) ASSERT(strstr((json), "\"status\":\"ok\"") != NULL, "expected ok status")
#define ASSERT_VAL(json, expected) ASSERT(strstr((json), "\"value\":\"" expected "\"") != NULL, "expected value")

/* ── Host dispatcher ── */

static const char* host_add(const char* json_args) {
    (void)json_args;
    return "{\"status\":\"ok\",\"value\":7}";
}

/* ── Tests ── */

static int test_version(void) {
    graal_isolatethread_t* thread = NULL;
    graal_isolate_t* iso = NULL;
    graal_create_isolate(NULL, &iso, &thread);

    const char* ver = sci_version(thread);
    ASSERT(strlen(ver) > 0, "version string non-empty");
    ASSERT(sci_abi_version(thread) > 0, "abi version > 0");

    graal_tear_down_isolate(thread);
    return 1;
}

static int test_create_destroy(void) {
    graal_isolatethread_t* thread = NULL;
    graal_isolate_t* iso = NULL;
    graal_create_isolate(NULL, &iso, &thread);
    sci_create_context(thread);
    sci_destroy_context(thread);
    graal_tear_down_isolate(thread);
    return 1;
}

static int test_eval_simple(void) {
    graal_isolatethread_t* thread = NULL;
    graal_isolate_t* iso = NULL;
    graal_create_isolate(NULL, &iso, &thread);
    sci_create_context(thread);

    char* r = sci_eval_string(thread, "(+ 1 2)");
    ASSERT_OK(r);
    ASSERT(strstr(r, "\"value\":\"3\"") != NULL, "(+ 1 2) = 3");

    sci_destroy_context(thread);
    graal_tear_down_isolate(thread);
    return 1;
}

static int test_eval_error(void) {
    graal_isolatethread_t* thread = NULL;
    graal_isolate_t* iso = NULL;
    graal_create_isolate(NULL, &iso, &thread);
    sci_create_context(thread);

    char* r = sci_eval_string(thread, "(+ 1");
    ASSERT(strstr(r, "\"status\":\"error\"") != NULL, "parse error returns error");

    sci_destroy_context(thread);
    graal_tear_down_isolate(thread);
    return 1;
}

static int test_persistent_context(void) {
    graal_isolatethread_t* thread = NULL;
    graal_isolate_t* iso = NULL;
    graal_create_isolate(NULL, &iso, &thread);
    sci_create_context(thread);

    sci_eval_string(thread, "(def x 42)");
    char* r = sci_eval_string(thread, "x");
    ASSERT_OK(r);
    ASSERT(strstr(r, "\"value\":\"42\"") != NULL, "x = 42");

    sci_destroy_context(thread);
    graal_tear_down_isolate(thread);
    return 1;
}

static int test_reset_context(void) {
    graal_isolatethread_t* thread = NULL;
    graal_isolate_t* iso = NULL;
    graal_create_isolate(NULL, &iso, &thread);
    sci_create_context(thread);

    sci_eval_string(thread, "(def x 1)");
    sci_reset_context(thread);

    char* r = sci_eval_string(thread, "(try x (catch Exception e \"err\"))");
    ASSERT(strstr(r, "err") != NULL, "x should be gone after reset");

    sci_destroy_context(thread);
    graal_tear_down_isolate(thread);
    return 1;
}

static int test_host_callback(void) {
    graal_isolatethread_t* thread = NULL;
    graal_isolate_t* iso = NULL;
    graal_create_isolate(NULL, &iso, &thread);
    sci_create_context(thread);

    sci_register_host_fn(thread, "test", "add", (long long)&host_add);

    /* Use host/invoke which is the dynamic dispatch path */
    char* r = sci_eval_string(thread, "(host/invoke \"test\" \"add\" 3 4)");
    ASSERT(strstr(r, "\"status\":\"ok\"") != NULL, "host callback returns ok");

    sci_destroy_context(thread);
    graal_tear_down_isolate(thread);
    return 1;
}

static int test_host_callback_sugar(void) {
    graal_isolatethread_t* thread = NULL;
    graal_isolate_t* iso = NULL;
    graal_create_isolate(NULL, &iso, &thread);
    sci_create_context(thread);

    /* Register host fn; should create SCI var for (test/add 3 4) syntax */
    sci_register_host_fn(thread, "test", "add", (long long)&host_add);

    /* Transparent call via SCI var — the "sugar" path */
    char* r = sci_eval_string(thread, "(test/add 3 4)");
    ASSERT(strstr(r, "\"status\":\"ok\"") != NULL, "sugar: test/add returns ok");
    ASSERT(strstr(r, "\"value\":\"7\"") != NULL, "sugar: test/add returns 7");

    sci_destroy_context(thread);
    graal_tear_down_isolate(thread);
    return 1;
}

static int test_call_script_fn(void) {
    graal_isolatethread_t* thread = NULL;
    graal_isolate_t* iso = NULL;
    graal_create_isolate(NULL, &iso, &thread);
    sci_create_context(thread);

    /* Define a fn that takes a vector argument and counts it */
    sci_eval_string(thread, "(defn count-items [v] (count v))");
    char* r = sci_call_script_fn(thread, "user", "count-items", "[1 2 3]");
    ASSERT(strstr(r, "\"status\":\"ok\"") != NULL, "call_script_fn ok");
    ASSERT(strstr(r, "\"value\":\"3\"") != NULL, "count of [1 2 3] = 3");

    sci_destroy_context(thread);
    graal_tear_down_isolate(thread);
    return 1;
}

int main(void) {
    printf("libsci C API integration tests\n");
    printf("-------------------------------\n");

    TEST(version);
    TEST(create_destroy);
    TEST(eval_simple);
    TEST(eval_error);
    TEST(persistent_context);
    TEST(reset_context);
    TEST(host_callback);
    TEST(host_callback_sugar);
    TEST(call_script_fn);

    printf("\n%d / %d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
