#![allow(non_upper_case_globals)]
#![allow(non_camel_case_types)]

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

include!(concat!(env!("OUT_DIR"), "/bindings.rs"));

static mut TESTS_RUN: i32 = 0;
static mut TESTS_PASSED: i32 = 0;

macro_rules! test {
    ($name:expr, $body:block) => {{
        unsafe { TESTS_RUN += 1; }
        let passed = { $body };
        unsafe {
            if passed { TESTS_PASSED += 1; }
        }
        if passed {
            println!("  PASS: {}", $name);
        } else {
            println!("  FAIL: {}", $name);
        }
    }};
}

unsafe fn c_str(s: &str) -> *const c_char {
    CString::new(s).unwrap().into_raw()
}

unsafe fn from_c_str(ptr: *mut c_char) -> String {
    CStr::from_ptr(ptr).to_str().unwrap().to_string()
}

unsafe fn create_isolate() -> *mut graal_isolatethread_t {
    let mut isolate: *mut graal_isolate_t = ptr::null_mut();
    let mut thread: *mut graal_isolatethread_t = ptr::null_mut();
    graal_create_isolate(ptr::null_mut(), &mut isolate, &mut thread);
    thread
}

unsafe extern "C" fn host_dispatcher(json_args: *const c_char) -> *const c_char {
    let s = CStr::from_ptr(json_args).to_str().unwrap_or("");
    if s.contains("\"ns\"") {
        if s.contains("\"math\"") && s.contains("\"add\"") {
            return CString::new("{\"status\":\"ok\",\"value\":7}").unwrap().into_raw();
        }
        return CString::new("{\"status\":\"ok\",\"value\":0}").unwrap().into_raw();
    }
    CString::new("{\"status\":\"ok\",\"value\":7}").unwrap().into_raw()
}

fn main() {
    println!("libsci host bridge Rust integration tests");
    println!("-----------------------------------------");

    test!("set_host_dispatcher", {
        unsafe {
            let thread = create_isolate();
            set_host_dispatcher(thread as i64, &host_dispatcher as *const _ as i64);
            graal_tear_down_isolate(thread);
        }
        true
    });

    test!("load_and_call", {
        unsafe {
            let thread = create_isolate();
            set_host_dispatcher(thread as i64, &host_dispatcher as *const _ as i64);
            load_script(thread as i64, c_str("(defn add [x y] (+ x y))"));
            let r = from_c_str(call_function(thread as i64, c_str("add"), c_str("3 4")));
            graal_tear_down_isolate(thread);
            r.contains("\"status\":\"ok\"") && r.contains("\"value\":\"7\"")
        }
    });

    test!("eval_in_context", {
        unsafe {
            let thread = create_isolate();
            set_host_dispatcher(thread as i64, &host_dispatcher as *const _ as i64);
            load_script(thread as i64, c_str("(def x 42)"));
            let r = from_c_str(eval_in_context(thread as i64, c_str("x")));
            graal_tear_down_isolate(thread);
            r.contains("\"value\":\"42\"")
        }
    });

    test!("eval_fresh_context", {
        unsafe {
            let thread = create_isolate();
            set_host_dispatcher(thread as i64, &host_dispatcher as *const _ as i64);
            let r1 = from_c_str(eval_string(thread as i64, c_str("(def x 42)")));
            let r2 = from_c_str(eval_string(thread as i64,
                c_str("(try x (catch Exception e \"err\"))")));
            graal_tear_down_isolate(thread);
            r1.contains("#'user/x") && r2.contains("err")
        }
    });

    test!("reset_context", {
        unsafe {
            let thread = create_isolate();
            set_host_dispatcher(thread as i64, &host_dispatcher as *const _ as i64);
            load_script(thread as i64, c_str("(def x 1)"));
            reset_context(thread as i64);
            let r = from_c_str(call_function(thread as i64, c_str("add"), c_str("1 2")));
            graal_tear_down_isolate(thread);
            r.contains("\"status\":\"error\"")
        }
    });

    test!("host_call", {
        unsafe {
            let thread = create_isolate();
            set_host_dispatcher(thread as i64, &host_dispatcher as *const _ as i64);
            load_script(thread as i64,
                c_str("(defn compute [x y] (host-call \"add\" x y))"));
            let r = from_c_str(call_function(thread as i64, c_str("compute"), c_str("3 4")));
            graal_tear_down_isolate(thread);
            r.contains("\"status\":\"ok\"") && r.contains(":value 7")
        }
    });

    test!("edn_keyword_args", {
        unsafe {
            let thread = create_isolate();
            set_host_dispatcher(thread as i64, &host_dispatcher as *const _ as i64);
            load_script(thread as i64, c_str("(defn get-val [m k] (get m k))"));
            let r = from_c_str(call_function(
                thread as i64, c_str("get-val"), c_str("{:a 1 :b 2} :a")));
            graal_tear_down_isolate(thread);
            r.contains("\"value\":\"1\"")
        }
    });

    test!("cross_ns_call", {
        unsafe {
            let thread = create_isolate();
            set_host_dispatcher(thread as i64, &host_dispatcher as *const _ as i64);
            load_script(thread as i64,
                c_str("(ns my.ns) (defn calc [x] (* x 2))"));
            let r = from_c_str(call_function(
                thread as i64, c_str("my.ns/calc"), c_str("21")));
            graal_tear_down_isolate(thread);
            r.contains("\"value\":\"42\"")
        }
    });

    test!("register_namespaces", {
        unsafe {
            let thread = create_isolate();
            set_host_dispatcher(thread as i64, &host_dispatcher as *const _ as i64);
            let r1 = from_c_str(register_namespaces(thread as i64,
                c_str("{\"namespaces\":{\"math\":[\"add\",\"subtract\"]}}")));
            let ok = r1.contains("\"status\":\"ok\"");
            let r2 = from_c_str(load_script(thread as i64, c_str("(math/add 1 2)")));
            let ok2 = ok && r2.contains("\"status\":\"ok\"");
            graal_tear_down_isolate(thread);
            ok2
        }
    });

    test!("register_namespaces_after_load", {
        unsafe {
            let thread = create_isolate();
            set_host_dispatcher(thread as i64, &host_dispatcher as *const _ as i64);
            load_script(thread as i64, c_str("(def x 42)"));
            let r = from_c_str(register_namespaces(thread as i64,
                c_str("{\"namespaces\":{\"late\":[\"fn\"]}}")));
            graal_tear_down_isolate(thread);
            r.contains("\"status\":\"ok\"")
        }
    });

    test!("register_namespaces_error", {
        unsafe {
            let thread = create_isolate();
            set_host_dispatcher(thread as i64, &host_dispatcher as *const _ as i64);
            let r = from_c_str(register_namespaces(thread as i64, c_str("not-json")));
            graal_tear_down_isolate(thread);
            r.contains("\"status\":\"error\"")
        }
    });

    unsafe {
        println!("\n{} / {} tests passed\n", TESTS_PASSED, TESTS_RUN);
        if TESTS_PASSED != TESTS_RUN {
            std::process::exit(1);
        }
    }
}
