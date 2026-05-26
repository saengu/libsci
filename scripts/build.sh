#!/usr/bin/env bash
# ── libsci build script ──────────────────────────────────────────
# Three-phase build:
#   1. Leiningen uberjar (compiles Clojure sources)
#   2. javac (compiles Java @CEntryPoint sources with svm.jar)
#   3. native-image --shared (produces libsci.so)
#
# Prerequisites:
#   - GRAALVM_HOME set, or native-image in PATH
#   - Leiningen installed (lein in PATH)
#   - BABASHKA_FEATURE_* env vars as needed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SCI_DIR="$PROJECT_ROOT/sci"

# ── Setup GraalVM ─────────────────────────────────────────────
NATIVE_IMAGE="$(which native-image 2>/dev/null || echo "")"
GRAALVM_HOME="${GRAALVM_HOME:-}"
if [ -z "$GRAALVM_HOME" ] && [ -n "$NATIVE_IMAGE" ]; then
    GRAALVM_HOME="$(dirname "$(dirname "$(readlink -f "$NATIVE_IMAGE")")")"
fi

if [ -z "$GRAALVM_HOME" ]; then
    echo "ERROR: GRAALVM_HOME not set and native-image not found in PATH"
    exit 1
fi

SVM_JAR="$GRAALVM_HOME/lib/svm/builder/svm.jar"
if [ ! -f "$SVM_JAR" ]; then
    echo "ERROR: svm.jar not found at $SVM_JAR"
    exit 1
fi

echo "GRAALVM_HOME: $GRAALVM_HOME"
echo "SVM_JAR: $SVM_JAR"

# ── Find lein (cross-platform) ─────────────────────────────────
LEIN="lein"
if command -v lein >/dev/null 2>&1; then
    LEIN="lein"
elif [ -n "${LEIN_HOME:-}" ] && [ -f "$LEIN_HOME/bin/lein" ]; then
    LEIN="$LEIN_HOME/bin/lein"
elif [ -n "${LEIN_HOME:-}" ] && [ -f "$LEIN_HOME/bin/lein.bat" ]; then
    LEIN="cmd //c $LEIN_HOME/bin/lein.bat"
elif [ -n "${LEIN_JAR:-}" ]; then
    LEIN="java -jar $LEIN_JAR"
elif [ -f "/usr/local/bin/lein" ]; then
    LEIN="/usr/local/bin/lein"
fi
echo "lein: $LEIN"

# ── Phase 1: Uberjar ──────────────────────────────────────────
echo "═══ Phase 1: Leiningen uberjar ═══"
cd "$PROJECT_ROOT"
$LEIN with-profiles +libsci do clean, uberjar
UBERJAR=$(ls -t target/sci-libsci-*-standalone.jar 2>/dev/null | head -1)
if [ -z "$UBERJAR" ]; then
    echo "ERROR: uberjar not found in target/"
    exit 1
fi
echo "Uberjar: $UBERJAR"

# ── Phase 2: javac compilation ─────────────────────────────────
echo "═══ Phase 2: Compile Java @CEntryPoint sources ═══"
JAVAC="$GRAALVM_HOME/bin/javac"
$JAVAC \
    -cp "$UBERJAR:$SVM_JAR" \
    --add-exports org.graalvm.nativeimage/org.graalvm.nativeimage.c.function=ALL-UNNAMED \
    --add-exports org.graalvm.nativeimage/org.graalvm.nativeimage.c.type=ALL-UNNAMED \
    --add-exports org.graalvm.nativeimage/org.graalvm.nativeimage=ALL-UNNAMED \
    --add-exports org.graalvm.word/org.graalvm.word=ALL-UNNAMED \
    -d target/java-classes \
    src/java/libsci/LibsciHostFn.java \
    src/java/libsci/LibsciAPI.java

echo "Java compilation successful"

# Add compiled @CEntryPoint classes to the uberjar for native-image discovery
jar uf "$UBERJAR" -C target/java-classes libsci

# ── Phase 3: Native Image ─────────────────────────────────────
echo "═══ Phase 3: native-image --shared ═══"
NATIVE_IMAGE_CMD="$GRAALVM_HOME/bin/native-image"
$NATIVE_IMAGE_CMD \
    -jar "$UBERJAR" \
    -cp "src/java:target/java-classes:src/clojure" \
    -H:Name=libsci \
    --shared \
    --no-fallback \
    -H:+ReportExceptionStackTraces \
    -J-Dclojure.spec.skip-macros=true \
    -J-Dclojure.compiler.direct-linking=true \
    -H:IncludeResources=SCI_VERSION \
    -H:ReflectionConfigurationFiles=reflection.json \
    --initialize-at-build-time \
    --enable-preview \
    -J-Xmx3g

# ── Copy artifacts ───────────────────────────────────────────
echo "═══ Copying artifacts ═══"
mkdir -p target

case "$(uname -s)" in
    Darwin)  LIB_EXT="dylib" ;;
    MINGW*|MSYS*|CYGWIN*) LIB_EXT="dll" ;;
    *)       LIB_EXT="so" ;;
esac

for f in "libsci.${LIB_EXT}" libsci.h graal_isolate.h graal_isolate_dynamic.h libsci_dynamic.h; do
    if [ -f "$f" ]; then
        mv "$f" target/
        echo "  target/$f"
    fi
done

# On Windows, native-image also produces a .lib import library
if [ -f "libsci.lib" ]; then
    mv libsci.lib target/
    echo "  target/libsci.lib"
fi

echo ""
echo "Build complete: target/libsci.${LIB_EXT}"
