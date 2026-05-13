#!/usr/bin/env bash
# Build libsci shared library locally.
# Prerequisites:
#   - GRAALVM_HOME set to a GraalVM JDK 21+ installation with native-image
#   - Leiningen (lein) on PATH
#   - Babashka (bb) on PATH
set -euo pipefail

if [ -z "${GRAALVM_HOME:-}" ]; then
    echo "ERROR: GRAALVM_HOME is not set. Download GraalVM from https://www.graalvm.org/downloads/"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Initialize submodule if needed
if [ ! -f sci/pom.xml ] && [ ! -f sci/project.clj ]; then
    git submodule update --init --recursive
fi

cd sci
bb libsci:compile

echo ""
echo "Build complete. Artifacts in sci/libsci/target/:"
ls -la libsci/target/
