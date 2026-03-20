#!/usr/bin/env python3

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RELEASE_WORKFLOWS = (
    ROOT / ".github" / "workflows" / "release.yml",
    ROOT / ".github" / "workflows" / "release-dev.yml",
)

EXPECTED_MACOS_ARGS = (
    'args: "--target aarch64-apple-darwin --bundles app,dmg"',
    'args: "--target x86_64-apple-darwin --bundles app,dmg"',
)

LEGACY_MACOS_ARGS = (
    'args: "--target aarch64-apple-darwin --bundles app"',
    'args: "--target x86_64-apple-darwin --bundles app"',
)


class ReleaseWorkflowTests(unittest.TestCase):
    def test_release_workflows_publish_app_and_dmg_for_macos(self) -> None:
        for workflow in RELEASE_WORKFLOWS:
            content = workflow.read_text()

            for expected_arg in EXPECTED_MACOS_ARGS:
                self.assertIn(expected_arg, content, f"{workflow} missing `{expected_arg}`")

            for legacy_arg in LEGACY_MACOS_ARGS:
                self.assertNotIn(legacy_arg, content, f"{workflow} still contains `{legacy_arg}`")


if __name__ == "__main__":
    unittest.main()
