#!/usr/bin/env python3

import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "textlingo-desktop" / "pdf-sidecar" / "build.py"


class PdfSidecarBuildScriptTests(unittest.TestCase):
    def test_build_script_succeeds_with_cp1252_stdout(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            pyinstaller_package = temp_path / "PyInstaller"
            pyinstaller_package.mkdir()
            (pyinstaller_package / "__init__.py").write_text("", encoding="utf-8")
            (pyinstaller_package / "__main__.py").write_text(
                textwrap.dedent(
                    """
                    def run(args):
                        return None
                    """
                ),
                encoding="utf-8",
            )

            env = os.environ.copy()
            existing_pythonpath = env.get("PYTHONPATH")
            env["PYTHONPATH"] = (
                f"{temp_path}{os.pathsep}{existing_pythonpath}"
                if existing_pythonpath
                else str(temp_path)
            )
            env["PYTHONIOENCODING"] = "cp1252"

            result = subprocess.run(
                [sys.executable, str(BUILD_SCRIPT)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Build complete! Executable: dist/openkoto-pdf-translator-", result.stdout)


if __name__ == "__main__":
    unittest.main()
