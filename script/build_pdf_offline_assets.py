#!/usr/bin/env python3
"""Stage a subset of babeldoc offline assets into the Tauri resources dir.

The desktop app ships the DocLayout layout model plus the CJK serif fonts so the
first PDF translation runs without a network download (which is slow/flaky and
made the app look frozen). We deliberately bundle only what the OpenKoto
translation path actually uses — the layout model (always) and one serif font
per CJK target language plus the GoNoto fallback — instead of babeldoc's full
~243 MB font set.

Run this AFTER `pip install -e ./textlingo-desktop/pdf-sidecar` (which installs
the pinned babeldoc), and BEFORE the Tauri bundle step.
"""

import shutil
import sys
from pathlib import Path

from babeldoc.assets.assets import (
    get_doclayout_onnx_model_path,
    get_font_and_metadata,
)

# Serif fonts matching high_level.download_remote_fonts() for zh-CN / zh-TW /
# ja / ko, plus the GoNoto fallback used for every other language.
FONTS = [
    "GoNotoKurrent-Regular.ttf",
    "SourceHanSerifCN-Regular.ttf",
    "SourceHanSerifTW-Regular.ttf",
    "SourceHanSerifJP-Regular.ttf",
    "SourceHanSerifKR-Regular.ttf",
]


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    stage = repo_root / "textlingo-desktop" / "src-tauri" / "resources" / "pdf-assets"
    (stage / "models").mkdir(parents=True, exist_ok=True)
    (stage / "fonts").mkdir(parents=True, exist_ok=True)

    model = Path(get_doclayout_onnx_model_path())
    shutil.copy2(model, stage / "models" / model.name)
    print(f"staged model: {model.name}")

    for font in FONTS:
        path, _ = get_font_and_metadata(font)
        shutil.copy2(Path(path), stage / "fonts" / font)
        print(f"staged font: {font}")

    total = sum(p.stat().st_size for p in stage.rglob("*") if p.is_file())
    print(f"offline assets staged at {stage} ({total / 1024 / 1024:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
