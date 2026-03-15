#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIDECAR_DIST_DIR="${1:-$ROOT_DIR/textlingo-desktop/pdf-sidecar/dist}"
TARGET_DIR="${2:-$ROOT_DIR/textlingo-desktop/src-tauri/binaries}"
REQUIRED_TARGET_TRIPLE="${3:-}"

mkdir -p "$TARGET_DIR"

list_dir_contents() {
    local dir="$1"
    if [ -d "$dir" ]; then
        ls -la "$dir" >&2
    else
        echo "(missing directory)" >&2
    fi
}

detect_host_target_triple() {
    local os_type
    local arch_type

    os_type="$(uname -s)"
    arch_type="$(uname -m)"

    case "$os_type:$arch_type" in
        Darwin:arm64)
            echo "aarch64-apple-darwin"
            ;;
        Darwin:x86_64)
            echo "x86_64-apple-darwin"
            ;;
        Linux:x86_64)
            echo "x86_64-unknown-linux-gnu"
            ;;
        MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64)
            echo "x86_64-pc-windows-msvc"
            ;;
        *)
            echo "Unsupported host platform for PDF sidecar sync: $os_type/$arch_type" >&2
            return 1
            ;;
    esac
}

resolve_required_source_name() {
    case "$1" in
        aarch64-apple-darwin)
            echo "openkoto-pdf-translator-macos-arm64"
            ;;
        x86_64-apple-darwin)
            echo "openkoto-pdf-translator-macos-x64"
            ;;
        x86_64-unknown-linux-gnu)
            echo "openkoto-pdf-translator-linux-x64"
            ;;
        x86_64-pc-windows-msvc)
            echo "openkoto-pdf-translator-win-x64.exe"
            ;;
        *)
            echo "Unsupported target triple for PDF sidecar sync: $1" >&2
            return 1
            ;;
    esac
}

resolve_required_target_name() {
    case "$1" in
        x86_64-pc-windows-msvc)
            echo "openkoto-pdf-translator-$1.exe"
            ;;
        *)
            echo "openkoto-pdf-translator-$1"
            ;;
    esac
}

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

if [ -z "$REQUIRED_TARGET_TRIPLE" ]; then
    REQUIRED_TARGET_TRIPLE="$(detect_host_target_triple)"
fi

REQUIRED_SOURCE_NAME="$(resolve_required_source_name "$REQUIRED_TARGET_TRIPLE")"
REQUIRED_TARGET_NAME="$(resolve_required_target_name "$REQUIRED_TARGET_TRIPLE")"
REQUIRED_SOURCE_PATH="$SIDECAR_DIST_DIR/$REQUIRED_SOURCE_NAME"
REQUIRED_TARGET_PATH="$TARGET_DIR/$REQUIRED_TARGET_NAME"

if [ ! -f "$REQUIRED_SOURCE_PATH" ]; then
    {
        echo "Missing required PDF sidecar source binary for target $REQUIRED_TARGET_TRIPLE"
        echo "Expected source: $REQUIRED_SOURCE_PATH"
        echo "Sidecar dist contents:"
        list_dir_contents "$SIDECAR_DIST_DIR"
        echo "Tauri binaries contents:"
        list_dir_contents "$TARGET_DIR"
    } >&2
    exit 1
fi

if [ ! -f "$REQUIRED_TARGET_PATH" ]; then
    {
        echo "Missing required synced PDF sidecar binary for target $REQUIRED_TARGET_TRIPLE"
        echo "Expected target: $REQUIRED_TARGET_PATH"
        echo "Sidecar dist contents:"
        list_dir_contents "$SIDECAR_DIST_DIR"
        echo "Tauri binaries contents:"
        list_dir_contents "$TARGET_DIR"
    } >&2
    exit 1
fi

echo "Verified required PDF sidecar: $REQUIRED_TARGET_PATH"
