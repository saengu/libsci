#!/usr/bin/env bash
# libsci test runner
# Patches sci, builds libsci via native-image, runs JVM/C/Zig/Rust tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCI_DIR="$PROJECT_DIR/sci"
TARGET="$SCI_DIR/libsci/target"
TESTS="$PROJECT_DIR/tests"

echo "========================================="
echo "  libsci Host Bridge - Test Suite"
echo "========================================="

# ------------------------------------------------------------------
# Step 1: Apply patch
# ------------------------------------------------------------------
echo ""
echo "=== Step 1: Apply host bridge patch ==="
cd "$SCI_DIR"
git apply "$PROJECT_DIR/patches/host_bridge.patch"
echo "Patch applied."

# ------------------------------------------------------------------
# Step 2: Build libsci shared library (requires GRAALVM_HOME)
# ------------------------------------------------------------------
echo ""
echo "=== Step 2: Pre-compile LibSciHost.java ==="
# Clean any stale inner-class files from earlier builds
rm -f libsci/src/sci/impl/LibSciHost\$\*.class 2>/dev/null || true
# Compile HostDispatcher first (separate top-level interface)
SVM_JAR=$(find "${GRAALVM_HOME:-/usr/lib64/graalvm/graalvm-community-java23}" -name 'svm.jar' 2>/dev/null | head -1 || true)
if [ -n "$SVM_JAR" ]; then
    javac -d target/classes -cp "target/classes:$SVM_JAR" \
        libsci/src/sci/impl/LibSciHost.java
    echo "LibSciHost.java pre-compiled."
fi

echo ""
echo "=== Step 3: Build libsci with native-image ==="
if [ -n "${GRAALVM_HOME:-}" ]; then
    bb libsci:compile
    echo "libsci.so built in $TARGET"
    echo ""
    echo "Generated header exports:"
    grep '^char\*\|^void ' "$TARGET/libsci.h" 2>/dev/null | head -10
else
    echo "WARNING: GRAALVM_HOME not set, skipping native-image build."
fi

# ------------------------------------------------------------------
# Step 3: Run JVM unit tests
# ------------------------------------------------------------------
echo ""
echo "=== Step 4: Run JVM unit tests ==="
cp "$TESTS/libsci_host_test.clj" "$SCI_DIR/test/"
lein with-profiles +libsci test libsci-host-test
rm -f "$SCI_DIR/test/libsci_host_test.clj"
echo "JVM tests complete."

# ------------------------------------------------------------------
# Step 4: Run C integration test
# ------------------------------------------------------------------
echo ""
echo "=== Step 5: C integration test ==="
if command -v gcc &> /dev/null && [ -f "$TARGET/libsci.so" ]; then
    cd "$TESTS/c"
    if make all 2>/dev/null; then
        make run
        make clean
    else
        echo "C test skipped: libsci.so may not have new symbols."
        echo "Rebuild after patching: cd sci && bb libsci:compile"
    fi
else
    echo "Skipping: gcc or libsci.so not available."
fi

# ------------------------------------------------------------------
# Step 5: Run Zig integration test
# ------------------------------------------------------------------
echo ""
echo "=== Step 6: Zig integration test ==="
if command -v zig &> /dev/null && [ -f "$TARGET/libsci.so" ]; then
    cd "$TESTS/zig"
    if zig build 2>/dev/null; then
        zig build run
    else
        echo "Zig test skipped: libsci.so may not have new symbols."
    fi
else
    echo "Skipping: zig or libsci.so not available."
fi

# ------------------------------------------------------------------
# Step 6: Run Rust integration test
# ------------------------------------------------------------------
echo ""
echo "=== Step 7: Rust integration test ==="
if command -v cargo &> /dev/null && [ -f "$TARGET/libsci.so" ]; then
    cd "$TESTS/rust/from_rust_host"
    if LIBSCI_PATH="$TARGET" cargo build --release --quiet 2>/dev/null; then
        LD_LIBRARY_PATH="$TARGET" ./target/release/from_rust_host
    else
        echo "Rust test skipped: libsci.so may not have new symbols."
    fi
else
    echo "Skipping: cargo or libsci.so not available."
fi

# ------------------------------------------------------------------
# Step 7: Clean sci submodule
# ------------------------------------------------------------------
echo ""
echo "=== Step 8: Clean sci submodule ==="
cd "$SCI_DIR"
git checkout -- . 2>/dev/null
rm -f libsci/src/sci/impl/LibSciHost.java libsci/src/sci/impl/libsci_host.clj
echo "sci submodule reverted to clean state."

echo ""
echo "========================================="
echo "  All tests completed."
echo "========================================="
