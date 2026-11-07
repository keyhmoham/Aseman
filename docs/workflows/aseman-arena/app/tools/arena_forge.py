#!/usr/bin/env python3
"""The Forge agent's tool: checks a game it built, tests and exports it, and
hands the build to the Arena.

    arena_forge.py check  --dir PROJECT              # the contract only
    arena_forge.py submit --project ID --dir PROJECT # check, test, export, hand over
    arena_forge.py contract                          # what a game must be

A game passes when:
  * game.json is a valid store manifest (single-player, AI declared, a res://
    scene, Godot 4.3) — arena.validate_manifest;
  * project.godot is a Godot 4.3 project with the "Web" export preset (no
    threads) and ETC2/ASTC import on;
  * the scene exists and its root script declares `signal arena_event`,
    `arena_start`, `arena_stop` and `arena_state`, and uses no class_name and
    no autoloads (the game is mounted as a pack in another Godot world);
  * its headless tests (tests/run_tests.gd) print "passed" and exit 0;
  * the pack (and the Web build when game.json names one) export.

Prints "forge-check-ok" / "forge-submitted <slug> <version>" or what to fix.
Standard library only; Godot comes from games/godot_setup.py.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)
sys.path.insert(0, APP)

import arena  # noqa: E402


def fail(msg):
    print("forge-check-failed: " + msg)
    sys.exit(1)


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def check(project):
    problems = []
    raw = read(os.path.join(project, "game.json"))
    if raw is None:
        return None, ["game.json is missing (the store manifest)"]
    try:
        m = json.loads(raw)
    except ValueError as e:
        return None, ["game.json is not JSON: %s" % e]
    problems += arena.validate_manifest(m)
    pg = read(os.path.join(project, "project.godot"))
    if pg is None:
        problems.append("project.godot is missing")
    else:
        if '"4.3"' not in pg:
            problems.append('project.godot: config/features must include "4.3"')
        if "[autoload]" in pg:
            problems.append("project.godot: no autoloads (the game is mounted as a pack in another project)")
        if "import_etc2_astc=true" not in pg:
            problems.append("project.godot: set rendering/textures/vram_compression/import_etc2_astc=true (phones need ETC2)")
    ep = read(os.path.join(project, "export_presets.cfg"))
    if ep is None or 'name="Web"' not in ep:
        problems.append('export_presets.cfg needs a preset named "Web"')
    elif "variant/thread_support=true" in ep:
        problems.append("the Web preset must not use threads (variant/thread_support=false)")
    scene = str(m.get("scene", ""))
    scene_path = os.path.join(project, scene[len("res://"):]) if scene.startswith("res://") else ""
    tscn = read(scene_path) if scene_path else None
    if tscn is None:
        problems.append("the scene %s is not in the project" % scene)
    else:
        mm = re.search(r'\[ext_resource type="Script" path="res://([^"]+)"', tscn)
        script = read(os.path.join(project, mm.group(1))) if mm else None
        if script is None:
            problems.append("the scene's root has no script")
        else:
            for need, what in ((r"signal\s+arena_event\b", "signal arena_event(json: String)"), (r"func\s+arena_start\s*\(", "func arena_start(params)"),
                               (r"func\s+arena_stop\s*\(", "func arena_stop()"), (r"func\s+arena_state\s*\(", "func arena_state()"),
                               (r'"result"', 'a {"type": "result", …} event')):
                if not re.search(need, script):
                    problems.append("the root script needs " + what)
    for root, _, files in os.walk(project):
        if "/.godot" in root or "/tests" in root:
            continue
        for f in files:
            if f.endswith(".gd") and re.search(r"^class_name\s", read(os.path.join(root, f)) or "", re.M):
                problems.append("%s uses class_name: preload scripts instead (packs bring no global classes)" % os.path.relpath(os.path.join(root, f), project))
    if not os.path.isfile(os.path.join(project, "tests", "run_tests.gd")):
        problems.append("tests/run_tests.gd is missing (headless tests that play a match and check its result)")
    return m, problems


def godot():
    exe = os.environ.get("GODOT")
    if exe:
        return exe
    setup = os.path.join(APP, "games", "godot_setup.py")
    out = subprocess.run([sys.executable, setup], capture_output=True, text=True, timeout=1800)
    if out.returncode != 0:
        fail("Godot could not be installed: " + out.stderr[-400:])
    return out.stdout.strip().splitlines()[-1]


def run(cmd, timeout, cwd=None):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd)
    return p.returncode, (p.stdout + p.stderr)


def build(project, m, out_dir):
    exe = godot()
    code, log = run([exe, "--headless", "--path", project, "--import"], 1800)
    code, log = run([exe, "--headless", "--path", project, "--script", "res://tests/run_tests.gd"], 1800)
    if code != 0 or " passed" not in log:
        fail("the tests did not pass:\n" + "\n".join(l for l in log.splitlines() if "mesh_get_surface" not in l and "Parameter \"m\"" not in l)[-2500:])
    os.makedirs(out_dir, exist_ok=True)
    pck = os.path.join(out_dir, m["pack"])
    code, log = run([exe, "--headless", "--path", project, "--export-pack", "Web", pck], 1800)
    if not os.path.isfile(pck) or os.path.getsize(pck) < 64:
        fail("the pack did not export:\n" + log[-1500:])
    if m.get("web"):
        web = os.path.join(out_dir, os.path.dirname(m["web"]))
        shutil.rmtree(web, ignore_errors=True)
        os.makedirs(web, exist_ok=True)
        code, log = run([exe, "--headless", "--path", project, "--export-release", "Web", os.path.join(out_dir, m["web"])], 1800)
        if not os.path.isfile(os.path.join(web, "index.wasm")):
            fail("the Web build did not export:\n" + log[-1500:])
    for icon in ("icon.svg",):
        for root, _, files in os.walk(os.path.join(project, "arena")):
            if icon in files:
                shutil.copy(os.path.join(root, icon), os.path.join(out_dir, icon))
                break
    m = dict(m, pack_bytes=os.path.getsize(pck), pack_sha256=hashlib.sha256(open(pck, "rb").read()).hexdigest(),
             built_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    json.dump(m, open(os.path.join(out_dir, "game.json"), "w"), indent=2)
    return m


def config():
    cfg = {}
    try:
        cfg = json.load(open(os.path.join(APP, "config.json")))
    except (OSError, ValueError):
        pass
    secrets = {}
    path = cfg.get("secrets_file") or ""
    for line in (read(path) or "").splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            secrets[k.strip()] = v.strip()
    return cfg, secrets


def hand_over(pid, m, out_dir):
    cfg, secrets = config()
    port = int(os.environ.get("PORT") or cfg.get("port") or 8080)
    token = os.environ.get("ARENA_INTERNAL_TOKEN") or secrets.get("ARENA_INTERNAL_TOKEN", "")
    if not token:
        fail("no internal token: the Arena's secrets file is not readable here")
    req = urllib.request.Request("http://127.0.0.1:%d/internal/forge/%s/build" % (port, pid), data=json.dumps({"manifest": m, "dir": out_dir}).encode(),
                                 method="POST", headers={"Content-Type": "application/json", "Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        fail("the Arena refused the build (%d): %s" % (e.code, e.read().decode(errors="replace")[:500]))
    except (urllib.error.URLError, OSError) as e:
        fail("the Arena server is not answering on :%d (%s)" % (port, e))


def main(argv=None):
    ap = argparse.ArgumentParser(description="The Forge's game checker and submitter")
    ap.add_argument("command", choices=["check", "submit", "contract"])
    ap.add_argument("--dir", help="the Godot project")
    ap.add_argument("--project", help="the Forge project id (submit)")
    ap.add_argument("--out", help="where the build goes (submit)")
    a = ap.parse_args(argv)
    if a.command == "contract":
        print(__doc__)
        return 0
    if not a.dir or not os.path.isdir(a.dir):
        fail("--dir must be the game's Godot project folder")
    m, problems = check(os.path.abspath(a.dir))
    if problems:
        fail("\n- " + "\n- ".join(problems))
    if a.command == "check":
        print("forge-check-ok %s %s" % (m["slug"], m["version"]))
        return 0
    if not a.project or not re.match(r"^fp_[0-9a-f]{12}$", a.project):
        fail("--project must be the Forge project id (fp_…)")
    cfg, _ = config()
    data = cfg.get("data_dir") or os.path.join(APP, ".data")
    out_dir = a.out or os.path.join(data, "forge", a.project, "build", m["slug"])
    m = build(os.path.abspath(a.dir), m, out_dir)
    res = hand_over(a.project, m, out_dir)
    print("forge-submitted %s %s (%s)" % (m["slug"], m["version"], res.get("status")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
