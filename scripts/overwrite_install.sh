#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Bar"
EXECUTABLE_NAME="CodexBar"
DEST_DIR="/Applications"
OPEN_AFTER_INSTALL=1
BUILD_APP=1

usage() {
  cat <<'EOF'
Usage: ./scripts/overwrite_install.sh [--dest DIR] [--no-open] [--no-build]

Builds Codex Bar, quits the running app, replaces the installed .app bundle,
and opens the installed app.

Options:
  --dest DIR     Install destination directory. Default: /Applications
  --no-open      Do not open the app after installing.
  --no-build     Reuse dist/Codex Bar.app instead of building first.
  -h, --help     Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      DEST_DIR="${2:?Missing value for --dest}"
      shift 2
      ;;
    --no-open)
      OPEN_AFTER_INSTALL=0
      shift
      ;;
    --no-build)
      BUILD_APP=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$BUILD_APP" -eq 1 ]]; then
  APP_PATH="$("$ROOT_DIR/scripts/build_app.sh")"
else
  APP_PATH="$ROOT_DIR/dist/$APP_NAME.app"
  if [[ ! -d "$APP_PATH" ]]; then
    echo "Missing $APP_PATH. Run without --no-build first." >&2
    exit 1
  fi
fi

DEST_APP="$DEST_DIR/$APP_NAME.app"

if pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in {1..30}; do
    if ! pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  if pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
    killall "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
  fi
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
ditto "$APP_PATH" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" >/dev/null 2>&1 || true

echo "Installed: $DEST_APP"

if [[ "$OPEN_AFTER_INSTALL" -eq 1 ]]; then
  open "$DEST_APP"
fi
