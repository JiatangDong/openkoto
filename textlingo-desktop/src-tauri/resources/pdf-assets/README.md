# PDF offline assets

This folder ships the babeldoc assets the PDF translator needs so the **first**
translation does not have to download them (DocLayout layout model + CJK serif
fonts). It exists so packaged builds can run PDF translation offline.

The actual `models/*.onnx` and `fonts/*.ttf` files are **generated in CI**, not
committed (they are ~95 MB). They are produced by:

```
python script/build_pdf_offline_assets.py
```

which must run after `pip install -e ./textlingo-desktop/pdf-sidecar` and before
the Tauri bundle step. The Rust side points the sidecar at this folder via the
`OPENKOTO_OFFLINE_ASSETS_DIR` env var; the sidecar copies the files into
babeldoc's cache on first run (see `_seed_offline_assets` in `pdf2zh.py`).

In local dev builds where these files are absent, the sidecar simply falls back
to babeldoc's normal on-demand download.
