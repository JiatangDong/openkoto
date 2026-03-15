#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIDECAR_DIST_DIR="${1:-$ROOT_DIR/textlingo-desktop/pdf-sidecar/dist}"
TARGET_DIR="${2:-$ROOT_DIR/textlingo-desktop/src-tauri/binaries}"

mkdir -p "$TARGET_DIR"

copy_if_exists() {
    local source_name="$1"
    local target_name="$2"
    local source_path="$SIDECAR_DIST_DIR/$source_name"
    local target_path="$TARGET_DIR/$target_name"

    if [ -f "$source_path" ]; then
        cp "$source_path" "$target_path"
        chmod +x "$target_path" || true
        echo "Synced $source_name -> $target_name"
    fi
}

copy_if_exists "openkoto-pdf-translator-macos-arm64" "openkoto-pdf-translator-aarch64-apple-darwin"
copy_if_exists "openkoto-pdf-translator-macos-x64" "openkoto-pdf-translator-x86_64-apple-darwin"
copy_if_exists "openkoto-pdf-translator-linux-x64" "openkoto-pdf-translator-x86_64-unknown-linux-gnu"
copy_if_exists "openkoto-pdf-translator-win-x64.exe" "openkoto-pdf-translator-x86_64-pc-windows-msvc.exe"
