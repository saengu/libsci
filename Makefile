.PHONY: build test test-clj test-c test-zig test-rust test-swift clean

# Build the shared library (requires GraalVM + Leiningen)
build:
	./scripts/build.sh

# Run Clojure unit tests (JVM, no .so needed)
test-clj:
	lein with-profiles +libsci test

# C integration tests (requires built .so)
test-c:
	$(MAKE) -C tests/c test

# Zig integration tests (requires built .so + zig)
test-zig:
	cd tests/zig && zig build run

# Rust integration tests (requires built .so + cargo)
test-rust:
	if which cargo >/dev/null 2>&1; then \
	    cd tests/rust/from_rust_host && \
	    LIBSCI_PATH=../../../target RUSTFLAGS="-C link-args=-Wl,-rpath,$(CURDIR)/target" \
	    cargo run; \
	else \
	    echo "  [SKIP] Rust not installed (cargo not found)"; \
	fi

# Swift integration tests (requires built .so + swift 6.3+)
test-swift:
	if which swift >/dev/null 2>&1; then \
	    cd tests/swift && swift run -Xlinker -L../../target -Xcc -I../../target \
	    -Xlinker -rpath -Xlinker ../../target; \
	else \
	    echo "  [SKIP] Swift 6.3 not installed (swift not found)"; \
	fi

# Run all available tests (requires built .so first)
test: test-clj
	$(MAKE) test-c
	$(MAKE) test-zig
	$(MAKE) test-rust
	$(MAKE) test-swift

# Clean build artifacts
clean:
	rm -rf target/
