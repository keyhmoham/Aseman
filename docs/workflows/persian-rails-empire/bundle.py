"""Writes Persian Rails Empire source into ../persian-rails-empire.json assets.

Binary files (fonts) are stored as base64. Text files as plain content.

    python3 docs/workflows/persian-rails-empire/bundle.py
    python3 docs/workflows/persian-rails-empire/bundle.py --check
"""

import base64
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DOC = os.path.join(os.path.dirname(HERE), "persian-rails-empire.json")
ROOTS = ("app", "games")
SKIP_DIRS = {"__pycache__", ".data", "node_modules", ".aseman", ".godot", ".cache", "build", "models", ".deploy"}
SKIP_FILES = {"config.json", "READY.json", "APPS.json", "STATUS.json", "REPAIR.md", "WIRING.md", "verify.log", ".elpian-served.js"}
SKIP_PATHS = {"app/elpian/app.js", "app/elpian/widget.js"}
BINARY_EXT = {".ttf", ".otf", ".woff", ".woff2", ".png", ".jpg", ".jpeg", ".webp", ".glb", ".wasm", ".pck"}


def assets():
    out = {}
    for top in ROOTS:
        base = os.path.join(HERE, top)
        for root, dirs, files in os.walk(base):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not (d == "assets" and root.endswith("public")))
            for name in sorted(files):
                path = os.path.join(root, name)
                rel = os.path.relpath(path, HERE).replace(os.sep, "/")
                if name in SKIP_FILES or rel in SKIP_PATHS or name.endswith((".pyc", ".tmp", ".import", ".uid")):
                    continue
                ext = os.path.splitext(name)[1].lower()
                if ext in BINARY_EXT:
                    with open(path, "rb") as f:
                        raw = f.read()
                    entry = {"base64": base64.b64encode(raw).decode("ascii")}
                    if os.access(path, os.X_OK):
                        entry["mode"] = "0755"
                    out[rel] = entry
                else:
                    with open(path, encoding="utf-8") as f:
                        text = f.read()
                    out[rel] = {"mode": "0755", "content": text} if os.access(path, os.X_OK) else text
    return out


def main():
    with open(DOC, encoding="utf-8") as f:
        wf = json.load(f)
    fresh = assets()
    if "--check" in sys.argv:
        if wf.get("assets") != fresh:
            print("docs/workflows/persian-rails-empire.json is stale: run python3 docs/workflows/persian-rails-empire/bundle.py")
            return 1
        print("assets current: %d files" % len(fresh))
        return 0
    wf["assets"] = fresh
    with open(DOC, "w", encoding="utf-8") as f:
        json.dump(wf, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print("wrote %d assets into %s" % (len(fresh), os.path.relpath(DOC)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
