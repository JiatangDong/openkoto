"""Complementary static check for the issue #18 fix.

`test_lazy_optional_translators.py` proves that the 5 optional dependency
roots aren't imported at module scope. This test further proves that any
reference to those names inside translator.py is guarded by a local scope
(function body / method body) — never at class body, default-argument, or
decorator position. If one of those surface-level references survived, the
module would still fail to *load* on an environment lacking the dep, even
though the static-import check passed.
"""
import ast
from pathlib import Path


TRANSLATOR_PATH = (
    Path(__file__).resolve().parent.parent
    / "openkoto_pdf_translator"
    / "translator.py"
)

OPTIONAL_NAMES = {
    "deepl",
    "ollama",
    "xinference_client",
    # from `from azure.ai.translation.text import TextTranslationClient`
    "TextTranslationClient",
    "AzureKeyCredential",
    # from tencentcloud
    "credential",
    "TextTranslateRequest",
    "TextTranslateResponse",
    "TmtClient",
}


def _collect_names_at_module_or_class_scope(tree: ast.Module) -> set[str]:
    """Return every `ast.Name` referenced outside any function/method body."""
    seen: set[str] = set()

    class Visitor(ast.NodeVisitor):
        def visit_FunctionDef(self, node):  # noqa: N802
            # Don't descend into function bodies — local references are fine.
            # But DO inspect decorator list, default args, annotations,
            # since those are evaluated at class/module load.
            for dec in node.decorator_list:
                self.generic_visit(dec)
            for default in node.args.defaults + node.args.kw_defaults:
                if default is not None:
                    self.generic_visit(default)
            for arg in (
                list(node.args.args)
                + list(node.args.kwonlyargs)
                + list(node.args.posonlyargs)
            ):
                if arg.annotation is not None:
                    self.generic_visit(arg.annotation)
            if node.returns is not None:
                self.generic_visit(node.returns)

        visit_AsyncFunctionDef = visit_FunctionDef

        def visit_Name(self, node):  # noqa: N802
            seen.add(node.id)

    Visitor().visit(tree)
    return seen


def test_no_optional_symbol_referenced_outside_function_bodies() -> None:
    tree = ast.parse(TRANSLATOR_PATH.read_text(encoding="utf-8"))
    leaked = OPTIONAL_NAMES & _collect_names_at_module_or_class_scope(tree)
    assert not leaked, (
        "Optional translator symbols are still referenced outside function "
        f"bodies — will crash at module load without the extras: {sorted(leaked)}"
    )


if __name__ == "__main__":
    test_no_optional_symbol_referenced_outside_function_bodies()
    print("PASS: all optional symbols only used inside function bodies")
