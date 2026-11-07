"""Writes Aseman Arena's source — the platform's server and Elpian frontend
(app/) and the games (games/) — into the assets of ../aseman-arena.json, so
the workflow is one self-contained document.

    python3 docs/workflows/aseman-arena/bundle.py          rewrite the assets
    python3 docs/workflows/aseman-arena/bundle.py --check  fail if they are stale

Downloaded models, Godot's import cache and builds are not shipped: the
games step fetches the models (games/assets.json) and builds on the
project's computer.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DOC = os.path.join(os.path.dirname(HERE), "aseman-arena.json")
ROOTS = ("app", "games")
SKIP_DIRS = {"__pycache__", ".data", "node_modules", ".aseman", ".godot", ".cache", "build", "models", ".deploy"}
# Written on the project's computer, not shipped.
SKIP_FILES = {"config.json", "READY.json", "APPS.json", "STATUS.json", "REPAIR.md", "WIRING.md", "verify.log", ".elpian-served.js"}
SKIP_PATHS = {"app/elpian/app.js", "app/elpian/widget.js"}


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
            print("docs/workflows/aseman-arena.json is stale: run python3 docs/workflows/aseman-arena/bundle.py")
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
