#!/usr/bin/env python3

from pathlib import Path
import re
import sys


REQUIRED_SNIPPETS = (
    'name: setup python',
    'name: build bundled PDF sidecar',
)

REQUIRED_MACOS_MATRIX_ROWS = (
    '- platform: "macos-14"\n            args: "--target aarch64-apple-darwin --bundles app"',
    '- platform: "macos-13"\n            args: "--target x86_64-apple-darwin --bundles app"',
)

LEGACY_MACOS_PLATFORM_SNIPPETS = (
    'matrix.platform == \'macos-latest\'',
    'matrix.platform == "macos-latest"',
)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    workflow_paths = (
        root / ".github/workflows/release.yml",
        root / ".github/workflows/release-dev.yml",
    )

    missing = []
    for workflow_path in workflow_paths:
        content = workflow_path.read_text()
        ci_gate_match = re.search(r"(?ms)^  ci-gate:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", content)
        if ci_gate_match is None:
            missing.append(f"{workflow_path}: missing `ci-gate` job")
            continue
        ci_gate_body = ci_gate_match.group("body")
        for snippet in REQUIRED_SNIPPETS:
            if snippet not in ci_gate_body:
                missing.append(f"{workflow_path}: ci-gate missing `{snippet}`")

        publish_tauri_match = re.search(
            r"(?ms)^  publish-tauri:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
            content,
        )
        if publish_tauri_match is None:
            missing.append(f"{workflow_path}: missing `publish-tauri` job")
            continue

        publish_tauri_body = publish_tauri_match.group("body")
        for row in REQUIRED_MACOS_MATRIX_ROWS:
            if row not in publish_tauri_body:
                missing.append(f"{workflow_path}: publish-tauri missing macOS matrix row `{row}`")

        for legacy_snippet in LEGACY_MACOS_PLATFORM_SNIPPETS:
            if legacy_snippet in publish_tauri_body:
                missing.append(
                    f"{workflow_path}: publish-tauri still references legacy macOS runner snippet `{legacy_snippet}`"
                )

    if missing:
        print("\n".join(missing))
        return 1

    print("release workflows contain ci-gate python + pdf sidecar steps and correct macOS publish matrix")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
