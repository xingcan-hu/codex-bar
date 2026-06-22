#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Bar"
DEST_DIR="${1:-/Applications}"

APP_PATH="$("$ROOT_DIR/scripts/build_app.sh")"
mkdir -p "$DEST_DIR"
ditto "$APP_PATH" "$DEST_DIR/$APP_NAME.app"

echo "$DEST_DIR/$APP_NAME.app"
