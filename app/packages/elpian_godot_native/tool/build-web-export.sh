#!/usr/bin/env bash
# Builds the HTML5 export that makes `Scene3D` a live Godot viewport on the
# web (Aseman's web build, and — through the Elpian engine page — the Expo
# client on the web and on phones).
#
#   tool/build-web-export.sh [OUT_DIR]        (default: ../web-export)
#
# What it does, all in Docker (only Docker and curl are needed on the host):
#   1. downloads Godot 4.3-stable (editor + export templates) and godot-cpp
#      4.3, checking the editor and templates against Godot's published sums;
#   2. builds the GDExtension for wasm32 (emscripten 3.1.62, no threads —
#      what Godot 4.3's dlink web template needs);
#   3. exports godot-project with the "Web" preset (extensions support, no
#      threads);
#   4. writes OUT_DIR: the export's files (no .html) and godot_config.json,
#      the engine config the page glue boots from (taken from the export).
#
# Then either `tool/install-web-export.sh OUT_DIR app/web` (Aseman) or give
# OUT_DIR to the Expo client's build (ELPIAN_GODOT_EXPORT=OUT_DIR, or copy it
# to elpian-engine/vendor/godot).
set -euo pipefail

GODOT_VERSION=4.3-stable
EMSDK_IMAGE=emscripten/emsdk:3.1.62
RELEASE=https://github.com/godotengine/godot-builds/releases/download/$GODOT_VERSION

here=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$here/web-export}
cache=${ELPIAN_GODOT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/elpian-godot}
mkdir -p "$cache" "$out"
out=$(cd "$out" && pwd)

fetch() { # name
  local f=$cache/$1
  if [ ! -s "$f" ]; then curl -fSL --retry 3 -o "$f.part" "$RELEASE/$1" && mv "$f.part" "$f"; fi
}
sums=$cache/SHA512-SUMS-$GODOT_VERSION.txt
[ -s "$sums" ] || curl -fSL --retry 3 -o "$sums" "$RELEASE/SHA512-SUMS.txt"
editor_zip=Godot_v${GODOT_VERSION}_linux.x86_64.zip
fetch "$editor_zip"
want=$(grep " $editor_zip\$" "$sums" | cut -d' ' -f1)
have=$(sha512sum "$cache/$editor_zip" | cut -d' ' -f1)
[ -n "$want" ] && [ "$want" = "$have" ] || { echo "checksum mismatch: $editor_zip" >&2; rm -f "$cache/$editor_zip"; exit 1; }
# The export templates are a 1 GB archive of which the web ones are ~20 MB:
# read just those members with HTTP range requests (each member is CRC-checked).
tpl_zip=$cache/web_templates-$GODOT_VERSION.zip
if [ ! -s "$tpl_zip" ]; then
  PYTHONDONTWRITEBYTECODE=1 python3 "$here/tool/fetch_zip_members.py" "$RELEASE/Godot_v${GODOT_VERSION}_export_templates.tpz" "$tpl_zip.part" \
    templates/version.txt 'templates/web_dlink_nothreads_*.zip'
  mv "$tpl_zip.part" "$tpl_zip"
fi
if [ ! -d "$cache/godot-cpp/.git" ]; then
  git clone --depth 1 -b godot-$GODOT_VERSION https://github.com/godotengine/godot-cpp "$cache/godot-cpp"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$here/extension" "$here/godot-project" "$work/"
rm -rf "$work/extension/godot-cpp" "$work/extension/gen" "$work/godot-project/.godot" "$work/godot-project/bin"
cp -r "$cache/godot-cpp" "$work/extension/godot-cpp"
mkdir -p "$work/editor" "$work/export"
unzip -q "$cache/Godot_v${GODOT_VERSION}_linux.x86_64.zip" -d "$work/editor"
tpl="$work/home/.local/share/godot/export_templates/${GODOT_VERSION/-/.}"
mkdir -p "$tpl"
unzip -q -j "$tpl_zip" -d "$tpl"

docker run --rm --user "$(id -u):$(id -g)" -e HOME=/work/home -v "$work:/work" -w /work "$EMSDK_IMAGE" bash -euo pipefail -c '
  python3 -m pip install -q --target /work/pylib scons
  export PYTHONPATH=/work/pylib PATH=/work/pylib/bin:$PATH
  (cd extension && scons -j"$(nproc)" platform=web target=template_release threads=no)
  editor=$(ls /work/editor/Godot_v*_linux.x86_64)
  "$editor" --headless --path godot-project --import || true   # first import; exits non-zero on a fresh project
  "$editor" --headless --path godot-project --export-release Web /work/export/elpian_godot.html
'

rm -rf "${out:?}"/*
for f in "$work"/export/*; do case "$f" in *.html) ;; *) cp "$f" "$out/";; esac; done
# The engine config the page glue boots from: the export's own.
python3 - "$work/export/elpian_godot.html" "$out/godot_config.json" <<'PY'
import json, re, sys
html = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"const GODOT_CONFIG = (\{.*?\});\s*const GODOT_THREADS_ENABLED", html, re.S)
if not m:
    sys.exit("GODOT_CONFIG not found in the export's html")
cfg = json.loads(m.group(1))
json.dump(cfg, open(sys.argv[2], "w"))
PY
echo "Godot web export → $out"
ls -la "$out"
