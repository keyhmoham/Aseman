#!/usr/bin/env python3
"""Contract check for the official Persian Rails Godot game.

    python3 tools/rails_forge.py check --dir games/persian-rails
"""

import argparse
import json
import os
import sys


REQUIRED = ["slug", "title", "version", "engine", "scene", "pack", "players", "mode"]


def check(dirpath):
    gpath = os.path.join(dirpath, "game.json")
    proj = os.path.join(dirpath, "project.godot")
    main = os.path.join(dirpath, "arena", "persian_rails", "main.gd")
    shell = os.path.join(dirpath, "arena", "persian_rails", "shell.gd")
    tests = os.path.join(dirpath, "tests", "run_tests.gd")
    data = os.path.join(dirpath, "arena", "persian_rails", "data", "cities.json")
    errors = []
    if not os.path.isfile(gpath):
        errors.append("missing game.json")
    else:
        g = json.load(open(gpath, encoding="utf-8"))
        for k in REQUIRED:
            if k not in g:
                errors.append("game.json missing " + k)
        if g.get("engine") != "godot-4.3":
            errors.append("engine must be godot-4.3")
        if "AI" not in g.get("mode", "") and "ai" not in g.get("mode", "").lower():
            errors.append("mode should be single-player vs AI")
        if not str(g.get("scene", "")).startswith("res://"):
            errors.append("scene must be res://…")
        if "shell.tscn" not in str(g.get("scene", "")):
            errors.append("scene must be the Godot shell (shell.tscn)")
    if not os.path.isfile(proj):
        errors.append("missing project.godot")
    else:
        txt = open(proj, encoding="utf-8").read()
        if "4.3" not in txt:
            errors.append("project.godot must declare 4.3")
        if "gl_compatibility" not in txt:
            errors.append("renderer must be gl_compatibility")
        if "shell.tscn" not in txt:
            errors.append("project.godot main scene must be shell.tscn")
    if not os.path.isfile(shell):
        errors.append("missing shell.gd (Godot UI replaces Flutter/Elpian tabs)")
    else:
        stxt = open(shell, encoding="utf-8").read()
        for needle in ("arena_start", "arena_stop", "arena_state", "arena_event", "_fill_home", "_fill_atlas", "_fill_ranks", "_fill_rules", "_fill_play"):
            if needle not in stxt:
                errors.append("shell.gd missing " + needle)
    if not os.path.isfile(main):
        errors.append("missing main.gd")
    else:
        txt = open(main, encoding="utf-8").read()
        for needle in ("arena_start", "arena_stop", "arena_state", "arena_event"):
            if needle not in txt:
                errors.append("main.gd missing " + needle)
        if "class_name" in txt:
            errors.append("no class_name allowed")
    if not os.path.isfile(tests):
        errors.append("missing tests/run_tests.gd")
    if not os.path.isfile(data):
        errors.append("missing cities.json data")
    else:
        cities = json.load(open(data, encoding="utf-8"))
        if len(cities) < 30:
            errors.append("need >= 30 cities")
    if errors:
        for e in errors:
            print("error:", e, file=sys.stderr)
        return 1
    print("forge-check-ok persian-rails")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["check"])
    ap.add_argument("--dir", required=True)
    a = ap.parse_args()
    return check(a.dir)


if __name__ == "__main__":
    sys.exit(main())
