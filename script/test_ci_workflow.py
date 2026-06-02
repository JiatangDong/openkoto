#!/usr/bin/env python3

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


class CiWorkflowTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
