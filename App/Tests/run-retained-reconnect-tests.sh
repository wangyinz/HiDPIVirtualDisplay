#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
G9_TEST_BUILD_DIR="${G9_TEST_BUILD_DIR:-build-retained-reconnect-tests}"
mkdir -p "$G9_TEST_BUILD_DIR"
xcrun swiftc -parse-as-library Sources/DisplayConnectionReadiness.swift Sources/RetainedDisplayReconnect.swift \
    Tests/RetainedDisplayReconnectTests.swift -o "$G9_TEST_BUILD_DIR/retained-reconnect-tests"
"$G9_TEST_BUILD_DIR/retained-reconnect-tests"
