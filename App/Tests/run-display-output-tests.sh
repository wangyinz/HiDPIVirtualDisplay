#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
G9_TEST_BUILD_DIR="${G9_TEST_BUILD_DIR:-build-output-tests}"
mkdir -p "$G9_TEST_BUILD_DIR"
xcrun swiftc -parse-as-library \
    Sources/DisplayOutputPreferences.swift \
    Tests/DisplayOutputPreferencesTests.swift \
    -o "$G9_TEST_BUILD_DIR/output-preference-tests"
"$G9_TEST_BUILD_DIR/output-preference-tests"
