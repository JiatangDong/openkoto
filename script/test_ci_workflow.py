#!/usr/bin/env python3

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


class CiWorkflowTests(unittest.TestCase):
    def test_backend_job_installs_linux_system_dependencies(self) -> None:
        content = CI_WORKFLOW.read_text()
        backend_job = content[content.index("  backend:"):content.index("  frontend:")]

        self.assertIn("name: Install Linux system dependencies", backend_job)
        for package in (
            "libglib2.0-dev",
            "libgtk-3-dev",
            "libsoup-3.0-dev",
            "libwebkit2gtk-4.1-dev",
            "libjavascriptcoregtk-4.1-dev",
            "libayatana-appindicator3-dev",
            "librsvg2-dev",
            "patchelf",
        ):
            self.assertIn(
                package,
                backend_job,
                f"ci backend must install `{package}` so Linux Tauri builds have the required system libraries",
            )

    def test_backend_job_builds_and_verifies_pdf_sidecar_before_rust_tests(self) -> None:
        content = CI_WORKFLOW.read_text()

        self.assertIn("name: setup python", content)
        self.assertIn("name: build bundled PDF sidecar", content)
        self.assertIn("name: verify bundled PDF sidecar", content)
        self.assertIn("bash script/verify_pdf_sidecar_binary.sh", content)

        rust_tests_index = content.index("name: Rust tests")
        build_index = content.index("name: build bundled PDF sidecar")
        verify_index = content.index("name: verify bundled PDF sidecar")
        executable_verify_index = content.index("bash script/verify_pdf_sidecar_binary.sh")

        self.assertLess(build_index, rust_tests_index)
        self.assertLess(verify_index, rust_tests_index)
        self.assertLess(executable_verify_index, rust_tests_index)

    def test_backend_job_stages_agent_worker_before_rust_tests(self) -> None:
        content = CI_WORKFLOW.read_text()
        backend_job = content[content.index("  backend:"):content.index("  frontend:")]

        self.assertIn("uses: actions/setup-node@v5", backend_job)
        self.assertIn("textlingo-desktop/agent-worker/package-lock.json", backend_job)
        self.assertIn("name: install agent worker dependencies", backend_job)
        self.assertIn("name: stage bundled agent worker", backend_job)
        self.assertIn("working-directory: ./textlingo-desktop/agent-worker", backend_job)

        rust_tests_index = backend_job.index("name: Rust tests")
        setup_node_index = backend_job.index("uses: actions/setup-node@v5")
        install_index = backend_job.index("name: install agent worker dependencies")
        stage_index = backend_job.index("name: stage bundled agent worker")

        self.assertLess(setup_node_index, install_index)
        self.assertLess(install_index, stage_index)
        self.assertLess(stage_index, rust_tests_index)


if __name__ == "__main__":
    unittest.main()
