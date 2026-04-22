"""Regression test for the PDF translator optional-dependency loading bug.

Context: `openkoto_pdf_translator.translator` is packaged via PyInstaller and
shipped without the `[extra-translators]` optional dependency group. If any of
those optional libraries (deepl, ollama, xinference_client, azure-ai-translation,
tencentcloud-sdk) is imported at module load time, the whole sidecar crashes
at `ModuleNotFoundError` before the user has a chance to pick an actually
installed translator — see https://github.com/hikariming/openkoto/issues/18 .

This test parses translator.py statically and asserts that none of those
optional modules are imported at module scope. The corresponding classes must
import them lazily inside `__init__` (the `ArgosTranslator` class is the
existing reference pattern in the same file).
"""
import ast
from pathlib import Path


TRANSLATOR_PATH = (
    Path(__file__).resolve().parent.parent
    / "openkoto_pdf_translator"
    / "translator.py"
)

# Modules listed under `[project.optional-dependencies.extra-translators]` in
# pyproject.toml. None of these should be required to merely import the module.
OPTIONAL_DEP_ROOTS = {
    "deepl",
    "ollama",
    "xinference_client",
    "azure",
    "tencentcloud",
}


def collect_module_level_import_roots(source: str) -> set[str]:
    tree = ast.parse(source)
    roots: set[str] = set()
    for node in tree.body:
        if isinstance(node, ast.Import):
            for alias in node.names:
                roots.add(alias.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom) and node.module:
            # treat `from a.b import c` as importing root `a`
            roots.add(node.module.split(".")[0])
    return roots


def test_optional_deps_are_not_imported_at_module_level() -> None:
    source = TRANSLATOR_PATH.read_text(encoding="utf-8")
    top_level = collect_module_level_import_roots(source)
    leaked = OPTIONAL_DEP_ROOTS & top_level
    assert not leaked, (
        f"Optional dependencies imported at module level (will crash when the "
        f"user hasn't installed the `extra-translators` group): {sorted(leaked)}"
    )


if __name__ == "__main__":
    test_optional_deps_are_not_imported_at_module_level()
    print("PASS: no optional deps at module level")
