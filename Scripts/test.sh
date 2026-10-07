#!/usr/bin/env bash
# Runs the Swift Testing suite. With only the Command Line Tools installed (no Xcode), SwiftPM
# doesn't add the Testing framework's search path or its runtime library directory on its own,
# so both are passed explicitly here.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_DIR="$(xcode-select -p)"
FRAMEWORKS="$DEV_DIR/Library/Developer/Frameworks"
TESTING_LIBS="$DEV_DIR/Library/Developer/usr/lib"

swift test --package-path "$ROOT_DIR" --disable-xctest \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$TESTING_LIBS" \
    "$@"
