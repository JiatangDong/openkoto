#!/usr/bin/env python3

from pathlib import Path
import re
import sys


REQUIRED_SNIPPETS = (
    'name: setup python',
    'name: build bundled PDF sidecar',
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

    if missing:
        print("\n".join(missing))
        return 1

    print("release workflows contain ci-gate python + pdf sidecar steps")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
