#!/usr/bin/env python3
import argparse
import re
import subprocess
from pathlib import Path
from urllib.parse import quote

from project_version import read_version


def patch_web_cache_bust(web_root: Path, version: str) -> None:
    encoded = quote(version.strip(), safe="")
    if not encoded:
        raise SystemExit("Cannot patch Web cache busting with an empty version.")

    index_html = web_root / "index.html"
    index_js = web_root / "index.js"
    for path in (index_html, index_js):
        if not path.exists():
            raise SystemExit(f"Missing Web export file: {path}")

    html = index_html.read_text(encoding="utf-8")
    html = re.sub(r'src="index\.js(?:\?v=[^"]*)?"', f'src="index.js?v={encoded}"', html)
    if f"index.js?v={encoded}" not in html:
        raise SystemExit(f"Could not patch Web HTML script tag with build version {version}")
    index_html.write_text(html, encoding="utf-8", newline="")

    js = index_js.read_text(encoding="utf-8")
    cache_bust_line = f'const GODOT_CACHE_BUST = "?v={encoded}";'
    if re.search(r'const GODOT_CACHE_BUST = "[^"]*";', js):
        js = re.sub(r'const GODOT_CACHE_BUST = "[^"]*";', cache_bust_line, js, count=1)
    else:
        js = re.sub(r"^var Godot=", f"{cache_bust_line}\nvar Godot=", js, count=1)
    if cache_bust_line not in js:
        raise SystemExit("Could not patch Web loader cache-bust constant.")

    replacements = {
        "return `${loadPath}.audio.worklet.js`;": "return `${loadPath}.audio.worklet.js${GODOT_CACHE_BUST}`;",
        "return `${loadPath}.audio.position.worklet.js`;": "return `${loadPath}.audio.position.worklet.js${GODOT_CACHE_BUST}`;",
        "return `${loadPath}.js`;": "return `${loadPath}.js${GODOT_CACHE_BUST}`;",
        "return `${loadPath}.side.wasm`;": "return `${loadPath}.side.wasm${GODOT_CACHE_BUST}`;",
        "return `${loadPath}.wasm`;": "return `${loadPath}.wasm${GODOT_CACHE_BUST}`;",
        "loadPromise = preloader.loadPromise(`${loadPath}.wasm`, size, true);": "loadPromise = preloader.loadPromise(`${loadPath}.wasm${GODOT_CACHE_BUST}`, size, true);",
        "this.preloadFile(pack, pack),": "this.preloadFile(packUrl, pack),",
    }
    for old, new in replacements.items():
        if old not in js and new not in js:
            raise SystemExit(f"Could not patch expected Web loader fragment: {old}")
        js = js.replace(old, new)

    pack_pattern = re.compile(
        r"const pack = this\.config\.mainPack \|\| `\$\{exe\}\.pck`;"
        r"(\r?\n\s*const packUrl = `\$\{pack\}\$\{GODOT_CACHE_BUST\}`;)*"
    )
    if not pack_pattern.search(js):
        raise SystemExit("Could not patch expected Web loader pack fragment.")
    js = pack_pattern.sub(
        "const pack = this.config.mainPack || `${exe}.pck`;\n\t\t\t\tconst packUrl = `${pack}${GODOT_CACHE_BUST}`;",
        js,
        count=1,
    )
    for fragment in (
        "return `${loadPath}.wasm${GODOT_CACHE_BUST}`;",
        "loadPromise = preloader.loadPromise(`${loadPath}.wasm${GODOT_CACHE_BUST}`, size, true);",
        "const packUrl = `${pack}${GODOT_CACHE_BUST}`;",
        "this.preloadFile(packUrl, pack),",
    ):
        if fragment not in js:
            raise SystemExit(f"Web loader cache-bust fragment is missing after patch: {fragment}")

    index_js.write_text(js, encoding="utf-8", newline="")
    try:
        subprocess.run(["node", "--check", str(index_js)], check=True)
    except FileNotFoundError:
        pass

    print(f"WEB_CACHE_BUST_PATCHED version={version} root={web_root}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--web-root", required=True)
    parser.add_argument("--version", default="")
    args = parser.parse_args()
    version = args.version.strip() or read_version()
    patch_web_cache_bust(Path(args.web_root).resolve(), version)


if __name__ == "__main__":
    main()
