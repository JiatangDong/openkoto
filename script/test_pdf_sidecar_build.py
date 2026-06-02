#!/usr/bin/env python3

import os
import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "textlingo-desktop" / "pdf-sidecar" / "build.py"
PYINSTALLER_ENTRY = ROOT / "textlingo-desktop" / "pdf-sidecar" / "pyinstaller_entry.py"


class PdfSidecarBuildScriptTests(unittest.TestCase):
    def run_build_with_captured_pyinstaller_args(self) -> list[str]:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            pyinstaller_package = temp_path / "PyInstaller"
            pyinstaller_package.mkdir()
            (pyinstaller_package / "__init__.py").write_text("", encoding="utf-8")
            args_path = temp_path / "pyinstaller_args.json"
            (pyinstaller_package / "__main__.py").write_text(
                textwrap.dedent(
                    f"""
                    import json

                    def run(args):
                        with open({str(args_path)!r}, "w", encoding="utf-8") as fh:
                            json.dump(args, fh)
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

            result = subprocess.run(
                [sys.executable, str(BUILD_SCRIPT)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(args_path.read_text(encoding="utf-8"))

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

    def test_build_script_includes_bitstring_dynamic_imports(self) -> None:
        args = self.run_build_with_captured_pyinstaller_args()
        required_hidden_imports = {
            "bitstring.bitstore_bitarray",
            "bitstring.bitstore_bitarray_helpers",
            "bitstring.bitstore_common_helpers",
        }
        missing = {
            module
            for module in required_hidden_imports
            if ("--hidden-import", module) not in zip(args, args[1:])
        }
        self.assertFalse(missing, f"Missing bitstring hidden imports: {sorted(missing)}")

    def test_build_script_does_not_exclude_required_scipy_dependency(self) -> None:
        args = self.run_build_with_captured_pyinstaller_args()
        self.assertNotIn(
            ("--exclude-module", "scipy"),
            zip(args, args[1:]),
            "babeldoc imports skimage.metrics at startup, which imports scipy",
        )

    def test_pyinstaller_entry_freezes_multiprocessing_before_pdf2zh_import(self) -> None:
        source = PYINSTALLER_ENTRY.read_text(encoding="utf-8")

        freeze_index = source.find("multiprocessing.freeze_support()")
        pdf2zh_import_index = source.find("from openkoto_pdf_translator.pdf2zh import main")

        self.assertNotEqual(freeze_index, -1, "PyInstaller entry must call multiprocessing.freeze_support()")
        self.assertNotEqual(pdf2zh_import_index, -1, "PyInstaller entry must import pdf2zh main")
        self.assertLess(
            freeze_index,
            pdf2zh_import_index,
            "freeze_support must run before importing pdf2zh so frozen multiprocessing children do not re-enter the CLI",
        )


if __name__ == "__main__":
    unittest.main()
