#!/usr/bin/env bash
# Installs a Godot web export (tool/build-web-export.sh) into a Flutter web
# directory — the app's `web/` before `flutter build web`, or `build/web` after
# it — and loads the page glue before Flutter boots, which is what turns
# Scene3D's placeholder into a live viewport on the web.
#
#   tool/install-web-export.sh EXPORT_DIR WEB_DIR
#
# The export goes beside index.html (the only layout Godot's loader and the
# GDExtension's dlopen support). Safe to run again.
set -euo pipefail
export_dir=${1:?usage: install-web-export.sh EXPORT_DIR WEB_DIR}
web=${2:?usage: install-web-export.sh EXPORT_DIR WEB_DIR}
here=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$export_dir/godot_config.json" ] || { echo "$export_dir has no godot_config.json (run tool/build-web-export.sh)" >&2; exit 1; }
[ -f "$web/index.html" ] || { echo "$web has no index.html" >&2; exit 1; }
cp "$export_dir"/* "$web/"
cp "$here/web/elpian_godot_web.js" "$web/"
tag='<script src="elpian_godot_web.js"></script>'
if ! grep -qF "$tag" "$web/index.html"; then
  # Before flutter_bootstrap.js: the glue installs its hooks synchronously.
  python3 - "$web/index.html" "$tag" <<'PY'
import sys
p, tag = sys.argv[1:]
s = open(p, encoding="utf-8").read()
needle = '<script src="flutter_bootstrap.js"'
if needle not in s:
    sys.exit("no flutter_bootstrap.js script tag in " + p)
open(p, "w", encoding="utf-8").write(s.replace(needle, tag + "\n  " + needle, 1))
PY
fi
echo "Godot web export installed in $web"
