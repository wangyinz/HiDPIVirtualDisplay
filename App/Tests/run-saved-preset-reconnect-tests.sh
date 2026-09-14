#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
G9_TEST_BUILD_DIR="${G9_TEST_BUILD_DIR:-build-saved-preset-reconnect-tests}"
mkdir -p "$G9_TEST_BUILD_DIR"
xcrun swiftc -parse-as-library Sources/SavedPresetReconnect.swift Sources/VirtualRenderScale.swift \
    Sources/PresetCatalog.swift Sources/DisplayConnectionReadiness.swift \
    Tests/SavedPresetReconnectTests.swift -o "$G9_TEST_BUILD_DIR/saved-preset-reconnect-tests"
"$G9_TEST_BUILD_DIR/saved-preset-reconnect-tests"
