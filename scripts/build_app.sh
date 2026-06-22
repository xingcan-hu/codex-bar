#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Bar"
EXECUTABLE_NAME="CodexBar"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/.build"
RELEASE_DIR="$BUILD_DIR/release"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"

mkdir -p "$RELEASE_DIR"

clang \
  -fobjc-arc \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -mmacosx-version-min=13.0 \
  -I Sources/CodexBarCore \
  -framework Cocoa \
  Sources/CodexBarCore/*.m \
  Sources/CodexBar/*.m \
  -o "$RELEASE_DIR/$EXECUTABLE_NAME"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$RELEASE_DIR/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

echo "$APP_DIR"
