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

EXPECTED_LINUX_MATRIX_ROW = (
    '- platform: "ubuntu-22.04"\n'
    '            args: "--target x86_64-unknown-linux-gnu --bundles deb"'
)

LINUX_SYSTEM_DEPENDENCIES = (
    "libglib2.0-dev",
    "libgtk-3-dev",
    "libsoup-3.0-dev",
    "libwebkit2gtk-4.1-dev",
    "libjavascriptcoregtk-4.1-dev",
    "libayatana-appindicator3-dev",
    "librsvg2-dev",
    "patchelf",
)

LEGACY_MACOS_ARGS = (
    'args: "--target aarch64-apple-darwin --bundles app"',
    'args: "--target x86_64-apple-darwin --bundles app"',
)


class ReleaseWorkflowTests(unittest.TestCase):
    def test_release_workflows_declare_contents_write_permission(self) -> None:
        for workflow in RELEASE_WORKFLOWS:
            content = workflow.read_text()
            self.assertIn(
                "permissions:\n  contents: write",
                content,
                f"{workflow} must declare top-level `contents: write` so tauri-action can create the GitHub release",
            )

    def test_release_workflows_publish_app_and_dmg_for_macos(self) -> None:
        for workflow in RELEASE_WORKFLOWS:
            content = workflow.read_text()

            for expected_arg in EXPECTED_MACOS_ARGS:
                self.assertIn(expected_arg, content, f"{workflow} missing `{expected_arg}`")

            for legacy_arg in LEGACY_MACOS_ARGS:
                self.assertNotIn(legacy_arg, content, f"{workflow} still contains `{legacy_arg}`")

    def test_release_workflows_execute_pdf_sidecar_verification(self) -> None:
        for workflow in RELEASE_WORKFLOWS:
            content = workflow.read_text()
            self.assertIn(
                "bash script/verify_pdf_sidecar_binary.sh",
                content,
                f"{workflow} must execute the bundled PDF sidecar, not just list it",
            )

    def test_release_workflows_stage_agent_worker_before_builds(self) -> None:
        for workflow in RELEASE_WORKFLOWS:
            content = workflow.read_text()
            self.assertIn(
                "textlingo-desktop/agent-worker/package-lock.json",
                content,
                f"{workflow} must include the agent worker lockfile in the npm cache key",
            )

            ci_stage_index = content.index("- name: Stage bundled agent worker")
            rust_tests_index = content.index("- name: Rust tests")
            self.assertLess(
                ci_stage_index,
                rust_tests_index,
                f"{workflow} must stage worker resources before Rust validates Tauri config",
            )

            publish_job_index = content.index("  publish-tauri:")
            publish_stage_index = content.index(
                "- name: stage bundled agent worker",
                publish_job_index,
            )
            tauri_build_index = content.index(
                "- uses: tauri-apps/tauri-action@v0",
                publish_job_index,
            )
            self.assertLess(
                publish_stage_index,
                tauri_build_index,
                f"{workflow} must stage worker resources before building release packages",
            )

    def test_release_workflows_assert_packaged_worker_on_macos(self) -> None:
        expected_paths = (
            'AGENT_NODE="$APP/Contents/MacOS/openkoto-agent-node"',
            'AGENT_WORKER="$APP/Contents/Resources/resources/agent-worker/dist/index.js"',
            'OPENCODE="$APP/Contents/MacOS/opencode"',
        )
        for workflow in RELEASE_WORKFLOWS:
            content = workflow.read_text()
            for expected_path in expected_paths:
                self.assertIn(
                    expected_path,
                    content,
                    f"{workflow} must verify packaged agent worker artifact `{expected_path}`",
                )
            self.assertIn(
                '"$AGENT_NODE" --version',
                content,
                f"{workflow} must execute the packaged Node runtime",
            )
            self.assertIn(
                """grep -q '"event":"worker.ready"'""",
                content,
                f"{workflow} must smoke-test the packaged worker entry",
            )

    def test_release_workflows_assert_packaged_worker_on_windows(self) -> None:
        expected_paths = (
            'AGENT_NODE="$TARGET_DIR/openkoto-agent-node.exe"',
            'AGENT_WORKER="$TARGET_DIR/resources/agent-worker/dist/index.js"',
            'OPENCODE="$TARGET_DIR/opencode.exe"',
        )
        for workflow in RELEASE_WORKFLOWS:
            content = workflow.read_text()
            self.assertIn(
                "if: startsWith(matrix.platform, 'windows-')",
                content,
                f"{workflow} must gate the Windows assertion on the windows matrix platform",
            )
            for expected_path in expected_paths:
                self.assertIn(
                    expected_path,
                    content,
                    f"{workflow} must verify packaged agent worker artifact `{expected_path}`",
                )

    def test_release_workflows_include_linux_matrix_entry(self) -> None:
        for workflow in RELEASE_WORKFLOWS:
            content = workflow.read_text()
            self.assertIn(
                EXPECTED_LINUX_MATRIX_ROW,
                content,
                f"{workflow} must include an ubuntu-22.04 matrix row building the deb bundle",
            )
            self.assertNotIn(
                "--bundles appimage",
                content,
                f"{workflow} must not build AppImage bundles (linuxdeploy fails for GTK/WebKitGTK apps in CI)",
            )

    def test_release_workflows_install_linux_system_dependencies_on_linux_only(self) -> None:
        for workflow in RELEASE_WORKFLOWS:
            content = workflow.read_text()
            publish_job_index = content.index("  publish-tauri:")
            publish_body = content[publish_job_index:]

            step_index = publish_body.index("- name: install system dependencies (linux only)")
            step_body = publish_body[step_index:]
            self.assertIn(
                "if: startsWith(matrix.platform, 'ubuntu-')",
                step_body,
                f"{workflow} must gate the Linux system dependency install on the ubuntu matrix platform",
            )
            for package in LINUX_SYSTEM_DEPENDENCIES:
                self.assertIn(
                    package,
                    step_body,
                    f"{workflow} must install `{package}` for Linux Tauri builds",
                )

    def test_release_workflows_assert_packaged_runtimes_and_bundles_on_linux(self) -> None:
        expected_snippets = (
            'AGENT_NODE="$TARGET_DIR/openkoto-agent-node"',
            'OPENCODE="$TARGET_DIR/opencode"',
            'SIDECAR="$TARGET_DIR/openkoto-pdf-translator"',
            '"$AGENT_NODE" --version',
        )
        for workflow in RELEASE_WORKFLOWS:
            content = workflow.read_text()
            self.assertIn(
                "if: startsWith(matrix.platform, 'ubuntu-')",
                content,
                f"{workflow} must gate the Linux assertion on the ubuntu matrix platform",
            )
            self.assertIn(
                'find textlingo-desktop/src-tauri/target -type f -name "*.deb"',
                content,
                f"{workflow} must assert the .deb bundle exists",
            )
            self.assertIn(
                'dpkg-deb -c "$DEB"',
                content,
                f"{workflow} must inspect the .deb contents for packaged runtimes",
            )
            for snippet in expected_snippets:
                self.assertIn(
                    snippet,
                    content,
                    f"{workflow} must verify packaged Linux runtime `{snippet}`",
                )
            self.assertIn(
                """grep -q '"event":"worker.ready"'""",
                content,
                f"{workflow} must smoke-test the packaged worker entry on Linux",
            )


if __name__ == "__main__":
    unittest.main()
