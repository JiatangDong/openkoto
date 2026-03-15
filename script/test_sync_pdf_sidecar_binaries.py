#!/usr/bin/env python3

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "script" / "sync_pdf_sidecar_binaries.sh"


class SyncPdfSidecarBinariesTests(unittest.TestCase):
    def run_sync(self, dist_dir: Path, target_dir: Path, target_triple: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT), str(dist_dir), str(target_dir), target_triple],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )

    def test_sync_copies_expected_binary_for_requested_target(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            dist_dir = temp_path / "dist"
            target_dir = temp_path / "target"
            dist_dir.mkdir()
            target_dir.mkdir()

            source = dist_dir / "openkoto-pdf-translator-linux-x64"
            source.write_text("fake sidecar")

            result = self.run_sync(dist_dir, target_dir, "x86_64-unknown-linux-gnu")

            self.assertEqual(result.returncode, 0, result.stderr)
            synced = target_dir / "openkoto-pdf-translator-x86_64-unknown-linux-gnu"
            self.assertTrue(synced.exists(), result.stdout)
            self.assertEqual(synced.read_text(), "fake sidecar")
            self.assertTrue(os.access(synced, os.X_OK))

    def test_sync_fails_when_required_target_binary_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            dist_dir = temp_path / "dist"
            target_dir = temp_path / "target"
            dist_dir.mkdir()
            target_dir.mkdir()

            result = self.run_sync(dist_dir, target_dir, "x86_64-unknown-linux-gnu")

            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("openkoto-pdf-translator-linux-x64", result.stderr)
            self.assertIn("x86_64-unknown-linux-gnu", result.stderr)


if __name__ == "__main__":
    unittest.main()
