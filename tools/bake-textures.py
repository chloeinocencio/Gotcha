#!/usr/bin/env python3
"""Render the shared textures (web/textures.js) to PNGs for the iOS app.

    pip install playwright && playwright install chromium
    python3 tools/bake-textures.py

Writes ios/Gotcha/Textures/tex-*.png. Run it again whenever web/textures.js changes.
Optional: --font-css path/to/fonts.css to supply Zen Maru Gothic offline.
"""
import argparse, base64, pathlib
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "ios" / "Gotcha" / "Textures"

ap = argparse.ArgumentParser()
ap.add_argument("--font-css")
ap.add_argument("--chrome", help="path to a Chrome/Chromium binary (optional)")
args = ap.parse_args()

OUT.mkdir(parents=True, exist_ok=True)
with sync_playwright() as p:
    browser = p.chromium.launch(executable_path=args.chrome, args=["--allow-file-access-from-files"]) if args.chrome \
        else p.chromium.launch(args=["--allow-file-access-from-files"])
    page = browser.new_page()
    if args.font_css:
        css = pathlib.Path(args.font_css).read_text()
        page.route("https://fonts.googleapis.com/**", lambda r: r.fulfill(body=css, content_type="text/css"))
    page.goto((ROOT / "tools" / "bake.html").as_uri())
    page.wait_for_function("window.BAKED !== undefined", timeout=60000)
    baked = page.evaluate("window.BAKED")
    browser.close()

for name, url in baked.items():
    (OUT / f"tex-{name}.png").write_bytes(base64.b64decode(url.split(",", 1)[1]))
    print("wrote", f"tex-{name}.png")
