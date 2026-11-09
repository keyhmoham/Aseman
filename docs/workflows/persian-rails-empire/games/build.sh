#!/bin/sh
# Builds Persian Rails Empire: fetch models, import, test, export pack + Web.
#
#   games/build.sh [persian-rails|all] [--out DIR] [--no-web] [--no-tests] [--offline]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
WHICH=persian-rails
OUT="$HERE/build"
WEB=1
TESTS=1
OFFLINE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=$2; shift ;;
    --no-web) WEB=0 ;;
    --no-tests) TESTS=0 ;;
    --offline) OFFLINE=1 ;;
    persian-rails|all) WHICH=persian-rails ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
if [ -z "${GODOT:-}" ]; then
  if [ "$WEB" = 1 ]; then GODOT=$(python3 "$HERE/godot_setup.py"); else GODOT=$(python3 "$HERE/godot_setup.py" --no-web); fi
elif [ "$WEB" = 1 ]; then
  python3 "$HERE/godot_setup.py" >/dev/null
fi
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

quiet() { grep -v "mesh_get_surface_count\|Parameter \"m\" is null\|leaked at exit\|still in use at exit\|in use exist at exit\|^   at: \|^     at: \|ObjectDB instances\|^Godot Engine\|^$\|UVs are required" || true; }

build_one() {
  dir=$1
  slug=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['slug'])" "$HERE/$dir/game.json")
  echo "== $slug"
  if [ "$OFFLINE" = 0 ]; then python3 "$HERE/fetch_assets.py" "$dir" | tail -1; fi
  "$GODOT" --headless --path "$HERE/$dir" --import 2>&1 | quiet | grep -i "error" || true
  if [ "$TESTS" = 1 ]; then
    timeout 900 "$GODOT" --headless --path "$HERE/$dir" --script "res://tests/run_tests.gd" 2>&1 | quiet | tee "$OUT/$slug-run_tests.gd.log" | tail -5
    grep -q " passed" "$OUT/$slug-run_tests.gd.log" || { echo "tests failed: $dir/tests/run_tests.gd" >&2; exit 1; }
  fi
  mkdir -p "$OUT/$slug"
  cp "$HERE/$dir"/arena/*/icon.svg "$OUT/$slug/icon.svg"
  "$GODOT" --headless --path "$HERE/$dir" --export-pack "Web" "$OUT/$slug/$slug.pck" 2>&1 | quiet | grep -i "error" || true
  test -s "$OUT/$slug/$slug.pck" || { echo "no pack for $slug" >&2; exit 1; }
  if [ "$WEB" = 1 ]; then
    rm -rf "$OUT/$slug/web" && mkdir -p "$OUT/$slug/web"
    "$GODOT" --headless --path "$HERE/$dir" --export-release "Web" "$OUT/$slug/web/index.html" 2>&1 | quiet | grep -i "error" || true
    test -s "$OUT/$slug/web/index.wasm" || { echo "no web build for $slug" >&2; exit 1; }
    # Fill the Elpian/Scene3D iframe — default Godot shell CSS leaves the canvas
    # at project size in the top-left of a larger brown host.
    python3 - "$OUT/$slug/web/index.html" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
snip = """
html, body { width: 100%; height: 100%; }
#canvas { width: 100% !important; height: 100% !important; }
#status { width: 100%; height: 100%; }
"""
if "width: 100% !important" not in t:
    t = t.replace("</style>", snip + "\t\t</style>", 1)
    p.write_text(t, encoding="utf-8")
PY
  fi
  python3 - "$HERE/$dir/game.json" "$OUT/$slug" "$WEB" <<'PY'
import hashlib, json, os, sys, time
src, out, web = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
g = json.load(open(src))
pck = os.path.join(out, g["pack"])
g["pack_bytes"] = os.path.getsize(pck)
g["pack_sha256"] = hashlib.sha256(open(pck, "rb").read()).hexdigest()
if not web:
    g.pop("web", None)
g["built_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
json.dump(g, open(os.path.join(out, "game.json"), "w"), indent=2, ensure_ascii=False)
print("built %s %s (%d KB pack)" % (g["slug"], g["version"], g["pack_bytes"] // 1024))
PY
  [ -f "$HERE/$dir"/arena/*/models/LICENSES.md ] && cp "$HERE/$dir"/arena/*/models/LICENSES.md "$OUT/$slug/" || true
}

build_one persian-rails
echo "games-built $OUT"
