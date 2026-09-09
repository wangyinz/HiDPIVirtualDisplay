#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
G9_TEST_BUILD_DIR="${G9_TEST_BUILD_DIR:-build-connection-tests}"
mkdir -p "$G9_TEST_BUILD_DIR"
xcrun swiftc -parse-as-library \
    Sources/DisplayConnectionReadiness.swift \
    Tests/DisplayConnectionReadinessTests.swift \
    -o "$G9_TEST_BUILD_DIR/connection-readiness-tests"
"$G9_TEST_BUILD_DIR/connection-readiness-tests"
