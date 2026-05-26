//! Rust integration test for the libsci C API (edition 2024).
//! Tests: sci_create_context, sci_destroy_context, sci_reset_context,
//!        sci_eval_string, sci_call_script_fn, sci_register_host_fn
//!        sci_version, sci_abi_version

#![allow(non_upper_case_globals)]
#![allow(non_camel_case_types)]

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;
use std::sync::atomic::{AtomicI32, Ordering};

include!(concat!(env!("OUT_DIR"), "/bindings.rs"));

static TESTS_RUN: AtomicI32 = AtomicI32::new(0);
static TESTS_PASSED: AtomicI32 = AtomicI32::new(0);

macro_rules! test {
    ($name:expr, $body:block) => {{
        TESTS_RUN.fetch_add(1, Ordering::Relaxed);
        let passed = { $body };
        if passed {
            TESTS_PASSED.fetch_add(1, Ordering::Relaxed);
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
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr).to_str().unwrap().to_string() }
}

unsafe fn create_context() -> *mut graal_isolatethread_t {
    let mut isolate: *mut graal_isolate_t = ptr::null_mut();
    let mut thread: *mut graal_isolatethread_t = ptr::null_mut();
    unsafe {
        let _ = graal_create_isolate(ptr::null_mut(), &mut isolate, &mut thread);
        sci_create_context(thread);
    }
    thread
}

/// Host callback — registered via sci_register_host_fn.
/// Signature must match `typedef char *(*sci_host_fn_t)(const char *json_args)`.
unsafe extern "C" fn host_add(_json_args: *const c_char) -> *mut c_char {
    CString::new("{\"status\":\"ok\",\"value\":7}").unwrap().into_raw()
}

fn main() {
    println!("libsci Rust API integration tests");
    println!("-------------------------------");

    test!("version", {
        unsafe {
            let thread = create_context();
            let ver = from_c_str(sci_version(thread) as *mut c_char);
            let abi = sci_abi_version(thread);
            sci_destroy_context(thread);
            let _ = graal_tear_down_isolate(thread);
            !ver.is_empty() && abi > 0
        }
    });

    test!("create_destroy", {
        unsafe {
            let thread = create_context();
            sci_destroy_context(thread);
            let _ = graal_tear_down_isolate(thread);
        }
        true
    });

    test!("eval_simple", {
        unsafe {
            let thread = create_context();
            let r = from_c_str(sci_eval_string(thread, c_str("(+ 1 2)")));
            sci_destroy_context(thread);
            let _ = graal_tear_down_isolate(thread);
            r.contains("\"status\":\"ok\"") && r.contains("\"value\":\"3\"")
        }
    });

    test!("eval_error", {
        unsafe {
            let thread = create_context();
            let r = from_c_str(sci_eval_string(thread, c_str("(+ 1")));
            sci_destroy_context(thread);
            let _ = graal_tear_down_isolate(thread);
            r.contains("\"status\":\"error\"")
        }
    });

    test!("persistent_context", {
        unsafe {
            let thread = create_context();
            sci_eval_string(thread, c_str("(def x 42)"));
            let r = from_c_str(sci_eval_string(thread, c_str("x")));
            sci_destroy_context(thread);
            let _ = graal_tear_down_isolate(thread);
            r.contains("\"value\":\"42\"")
        }
    });

    test!("reset_context", {
        unsafe {
            let thread = create_context();
            sci_eval_string(thread, c_str("(def x 1)"));
            sci_reset_context(thread);
            let r = from_c_str(sci_eval_string(thread,
                c_str("(try x (catch Exception e \"err\"))")));
            sci_destroy_context(thread);
            let _ = graal_tear_down_isolate(thread);
            r.contains("err")
        }
    });

    test!("host_callback", {
        unsafe {
            let thread = create_context();
            let fn_ptr = host_add as *const () as usize as i64;
            sci_register_host_fn(thread, c_str("test"), c_str("add"), fn_ptr);
            let r = from_c_str(sci_eval_string(thread,
                c_str("(host/invoke \"test\" \"add\" 3 4)")));
            sci_destroy_context(thread);
            let _ = graal_tear_down_isolate(thread);
            r.contains("\"status\":\"ok\"")
        }
    });

    test!("host_callback_sugar", {
        unsafe {
            let thread = create_context();
            let fn_ptr = host_add as *const () as usize as i64;
            sci_register_host_fn(thread, c_str("test"), c_str("add"), fn_ptr);
            let r = from_c_str(sci_eval_string(thread, c_str("(test/add 3 4)")));
            sci_destroy_context(thread);
            let _ = graal_tear_down_isolate(thread);
            r.contains("\"status\":\"ok\"") && r.contains("\"value\":\"7\"")
        }
    });

    test!("call_script_fn", {
        unsafe {
            let thread = create_context();
            sci_eval_string(thread, c_str("(defn count-items [v] (count v))"));
            let r = from_c_str(sci_call_script_fn(
                thread, c_str("user"), c_str("count-items"), c_str("[1 2 3]")));
            sci_destroy_context(thread);
            let _ = graal_tear_down_isolate(thread);
            r.contains("\"status\":\"ok\"") && r.contains("\"value\":\"3\"")
        }
    });

    let passed = TESTS_PASSED.load(Ordering::Relaxed);
    let total = TESTS_RUN.load(Ordering::Relaxed);
    println!("\n{} / {} tests passed\n", passed, total);
    if passed != total {
        std::process::exit(1);
    }
}
