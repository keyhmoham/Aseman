#!/bin/sh
# Builds Aseman Arena's games: fetches their models, imports the project,
# runs its tests, and exports
#   build/<slug>/<slug>.pck    the resource pack the Aseman client's Scene3D mounts
#   build/<slug>/web/          the browser build (Web, no threads)
#   build/<slug>/game.json     the store manifest, with sizes and checksums
#
#   games/build.sh [chess|city-strike|all] [--out DIR] [--no-web] [--no-tests] [--offline]
#
# GODOT names the Godot 4.3 editor; without it godot_setup.py installs one.
# --offline builds without downloading models (the games' own stand-ins).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
WHICH=all
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
    chess|city-strike|all) WHICH=$1 ;;
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
    for t in "$HERE/$dir"/tests/run_tests.gd "$HERE/$dir"/tests/test_scene.gd; do
      [ -f "$t" ] || continue
      name=$(basename "$t")
      timeout 900 "$GODOT" --headless --path "$HERE/$dir" --script "res://tests/$name" 2>&1 | quiet | tee "$OUT/$slug-$name.log" | tail -3
      grep -q " passed" "$OUT/$slug-$name.log" || { echo "tests failed: $dir/tests/$name" >&2; exit 1; }
    done
  fi
  mkdir -p "$OUT/$slug"
  "$GODOT" --headless --path "$HERE/$dir" --export-pack "Web" "$OUT/$slug/$slug.pck" 2>&1 | quiet | grep -i "error" || true
  test -s "$OUT/$slug/$slug.pck" || { echo "no pack for $slug" >&2; exit 1; }
  if [ "$WEB" = 1 ]; then
    rm -rf "$OUT/$slug/web" && mkdir -p "$OUT/$slug/web"
    "$GODOT" --headless --path "$HERE/$dir" --export-release "Web" "$OUT/$slug/web/index.html" 2>&1 | quiet | grep -i "error" || true
    test -s "$OUT/$slug/web/index.wasm" || { echo "no web build for $slug" >&2; exit 1; }
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
json.dump(g, open(os.path.join(out, "game.json"), "w"), indent=2)
print("built %s %s (%d KB pack)" % (g["slug"], g["version"], g["pack_bytes"] // 1024))
PY
  [ -f "$HERE/$dir/arena/"*/models/LICENSES.md ] 2>/dev/null && cp "$HERE/$dir"/arena/*/models/LICENSES.md "$OUT/$slug/" || true
}

case "$WHICH" in
  all) build_one chess; build_one city-strike ;;
  *) build_one "$WHICH" ;;
esac
echo "games-built $OUT"
