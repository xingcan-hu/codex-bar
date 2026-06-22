#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
TEST_DIR="$BUILD_DIR/tests"

cd "$ROOT_DIR"

mkdir -p "$TEST_DIR"

clang \
  -fobjc-arc \
  -Wall \
  -Wextra \
  -Werror \
  -mmacosx-version-min=13.0 \
  -I Sources/CodexBarCore \
  -framework Foundation \
  Sources/CodexBarCore/*.m \
  Tests/TestRunner/main.m \
  -o "$TEST_DIR/CodexBarCoreTests"

"$TEST_DIR/CodexBarCoreTests"
