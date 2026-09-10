#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
G9_TEST_BUILD_DIR="${G9_TEST_BUILD_DIR:-build-virtual-render-tests}"
mkdir -p "$G9_TEST_BUILD_DIR"
xcrun swiftc -parse-as-library Sources/VirtualRenderScale.swift Sources/DisplayConnectionReadiness.swift \
    Sources/RetainedDisplayReconnect.swift Tests/VirtualRenderScaleTests.swift \
    -o "$G9_TEST_BUILD_DIR/virtual-render-tests"
"$G9_TEST_BUILD_DIR/virtual-render-tests"
