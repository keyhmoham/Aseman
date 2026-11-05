"""Writes the app's source (app/) into the assets of ../study-planner.json,
so the workflow is one self-contained document.

    python3 docs/workflows/study-planner/bundle.py          rewrite the assets
    python3 docs/workflows/study-planner/bundle.py --check  fail if they are stale
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "app")
DOC = os.path.join(os.path.dirname(HERE), "study-planner.json")
SKIP_DIRS = {"__pycache__", ".data", "node_modules", ".aseman"}
# Written on the project's computer, not shipped: the workflow writes the
# settings (config.json, READY.json, APPS.json), the install step builds the
# Elpian bundle, and the platform's checks leave their reports.
SKIP_FILES = {"config.json", "READY.json", "APPS.json", "STATUS.json", "REPAIR.md", "WIRING.md", "verify.log", ".elpian-served.js"}
SKIP_PATHS = {"elpian/app.js", "elpian/widget.js"}


def assets():
    out = {}
    for root, dirs, files in os.walk(APP):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            path = os.path.join(root, name)
            inner = os.path.relpath(path, APP).replace(os.sep, "/")
            if name in SKIP_FILES or inner in SKIP_PATHS or name.endswith((".pyc", ".tmp")):
                continue
            rel = "app/" + inner
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
            print("docs/workflows/study-planner.json is stale: run python3 docs/workflows/study-planner/bundle.py")
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
