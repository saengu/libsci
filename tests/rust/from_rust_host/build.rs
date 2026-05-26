extern crate bindgen;

use std::env;
use std::path::PathBuf;

fn main() {
    let libsci_path = env::var("LIBSCI_PATH")
        .unwrap_or_else(|_| "../../../target".to_string());

    println!("cargo:rustc-link-lib=sci");
    println!("cargo:rustc-link-search={}", libsci_path);

    let bindings = bindgen::Builder::default()
        .header(format!("{}/libsci.h", libsci_path))
        .clang_arg(format!("-I{}", libsci_path))
        .generate()
        .expect("Unable to generate bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write bindings!");
}
