#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
G9_TEST_BUILD_DIR="${G9_TEST_BUILD_DIR:-build-virtual-refresh-tests}"
mkdir -p "$G9_TEST_BUILD_DIR"
xcrun swiftc -parse-as-library Sources/VirtualRefreshPolicy.swift Sources/DisplayConnectionReadiness.swift \
    Tests/VirtualRefreshPolicyTests.swift -o "$G9_TEST_BUILD_DIR/virtual-refresh-tests"
"$G9_TEST_BUILD_DIR/virtual-refresh-tests"
