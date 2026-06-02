#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="${1:-$ROOT_DIR/textlingo-desktop/src-tauri/binaries}"
REQUIRED_TARGET_TRIPLE="${2:-}"

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
            echo "Unsupported host platform for PDF sidecar verification: $os_type/$arch_type" >&2
            return 1
            ;;
    esac
}

resolve_required_target_name() {
    case "$1" in
        x86_64-pc-windows-msvc)
            echo "openkoto-pdf-translator-$1.exe"
            ;;
        aarch64-apple-darwin|x86_64-apple-darwin|x86_64-unknown-linux-gnu)
            echo "openkoto-pdf-translator-$1"
            ;;
        *)
            echo "Unsupported target triple for PDF sidecar verification: $1" >&2
            return 1
            ;;
    esac
}

if [ -z "$REQUIRED_TARGET_TRIPLE" ]; then
    REQUIRED_TARGET_TRIPLE="$(detect_host_target_triple)"
fi

REQUIRED_TARGET_NAME="$(resolve_required_target_name "$REQUIRED_TARGET_TRIPLE")"
REQUIRED_TARGET_PATH="$TARGET_DIR/$REQUIRED_TARGET_NAME"

if [ ! -f "$REQUIRED_TARGET_PATH" ]; then
    {
        echo "Missing PDF sidecar binary for target $REQUIRED_TARGET_TRIPLE"
        echo "Expected target: $REQUIRED_TARGET_PATH"
        echo "Tauri binaries contents:"
        if [ -d "$TARGET_DIR" ]; then
            ls -la "$TARGET_DIR"
        else
            echo "(missing directory)"
        fi
    } >&2
    exit 1
fi

chmod +x "$REQUIRED_TARGET_PATH" || true

VERIFY_HOME="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/openkoto-pdf-sidecar-verify-home"
mkdir -p "$VERIFY_HOME"

echo "Verifying PDF sidecar executable: $REQUIRED_TARGET_PATH"
env HOME="$VERIFY_HOME" "$REQUIRED_TARGET_PATH" --version
