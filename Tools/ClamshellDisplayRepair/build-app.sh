#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_NAME="Clamshell Display Repair.app"
APP_DIR="$REPO_ROOT/.build/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
MODULE_CACHE="$REPO_ROOT/.swift-module-cache"

mkdir -p "$MACOS_DIR" "$HELPERS_DIR" "$MODULE_CACHE"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"

swiftc \
    "$SCRIPT_DIR/main.swift" \
    -framework CoreGraphics \
    -framework IOKit \
    -o "$HELPERS_DIR/ClamshellDisplayRepair"

swiftc \
    -parse-as-library \
    "$SCRIPT_DIR/App.swift" \
    -framework SwiftUI \
    -o "$MACOS_DIR/ClamshellDisplayRepairApp"

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
codesign --force --sign - "$APP_DIR"

echo "$APP_DIR"
