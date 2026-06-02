#!/usr/bin/env python3

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "script" / "verify_pdf_sidecar_binary.sh"


class VerifyPdfSidecarBinaryTests(unittest.TestCase):
    def run_verify(self, target_dir: Path, target_triple: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT), str(target_dir), target_triple],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )

    def test_verify_executes_expected_binary_for_requested_target(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            target_dir = Path(temp_dir)
            sidecar = target_dir / "openkoto-pdf-translator-x86_64-unknown-linux-gnu"
            sidecar.write_text("#!/bin/sh\necho 'pdf2zh vtest'\n", encoding="utf-8")
            sidecar.chmod(0o755)

            result = self.run_verify(target_dir, "x86_64-unknown-linux-gnu")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("pdf2zh vtest", result.stdout)
            self.assertIn(str(sidecar), result.stdout)

    def test_verify_fails_when_binary_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_verify(Path(temp_dir), "x86_64-unknown-linux-gnu")

            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("Missing PDF sidecar binary", result.stderr)
            self.assertIn("openkoto-pdf-translator-x86_64-unknown-linux-gnu", result.stderr)


if __name__ == "__main__":
    unittest.main()
