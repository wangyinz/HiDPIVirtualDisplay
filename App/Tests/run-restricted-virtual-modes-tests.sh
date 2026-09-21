#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
G9_TEST_BUILD_DIR="${G9_TEST_BUILD_DIR:-build-restricted-virtual-modes-tests}"
mkdir -p "$G9_TEST_BUILD_DIR"
xcrun clang -fno-objc-arc -fobjc-arc-exceptions Tests/RestrictedVirtualModesTests.m \
    -framework Foundation -framework AppKit -framework CoreGraphics -framework IOKit \
    -o "$G9_TEST_BUILD_DIR/restricted-virtual-modes-tests"
"$G9_TEST_BUILD_DIR/restricted-virtual-modes-tests"
