#!/usr/bin/env bash
# Assembles the platform client into a buildable Flutter project: the client's
# own files plus the app sources it shares (tool/shared.txt: the Elpian
# engine, the UI kit, the Elpian host), the Elpian fonts and the sources of
# the Godot plugin (packages/elpian_godot_native: only a build that turns
# Godot on depends on it), copied from the Aseman app so the engine is always
# the app's own.
#
#   tool/assemble.sh                 # in place (lib/src, assets/elpian), for development
#   tool/assemble.sh <out-dir>       # a standalone copy at <out-dir>
#   DECILLION_APP=<app-dir> tool/assemble.sh <out-dir>   # the app is elsewhere
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${DECILLION_APP:-$(cd "$here/.." && pwd)}"
out="${1:-$here}"
list="$here/tool/shared.txt"
[ -f "$app/lib/src/elpian/elpian.dart" ] || { echo "assemble: no Aseman app at $app (set DECILLION_APP)" >&2; exit 1; }

if [ "$out" != "$here" ]; then
  mkdir -p "$out"
  # The client itself, without what a build or an earlier assembly left.
  (cd "$here" && tar --exclude=./build --exclude=./.dart_tool --exclude=./lib/src --exclude=./assets/elpian --exclude=./packages \
      --exclude=./android/.gradle --exclude=./android/app/build -cf - .) | (cd "$out" && tar -xf -)
fi
rm -rf "$out/lib/src" "$out/assets/elpian" "$out/packages"
count=0
while IFS= read -r rel; do
  case "$rel" in ''|'#'*) continue ;; esac
  mkdir -p "$out/lib/$(dirname "$rel")"
  # The app's own package imports name this package instead.
  sed 's#package:aseman/#package:aseman_platform_client/#g' "$app/lib/$rel" > "$out/lib/$rel"
  count=$((count + 1))
done < "$list"
# The engine keeps Elpian's analysis settings.
cp "$app/lib/src/elpian/analysis_options.yaml" "$out/lib/src/elpian/" 2>/dev/null || true
mkdir -p "$out/assets/elpian"
cp -R "$app/assets/elpian/fonts" "$out/assets/elpian/fonts"
# The Godot plugin's sources, without what a build or an artifact export left.
godot="$app/packages/elpian_godot_native"
if [ -f "$godot/pubspec.yaml" ]; then
  mkdir -p "$out/packages/elpian_godot_native"
  (cd "$godot" && tar --exclude=./android/.gradle --exclude=./android/build --exclude='./android/libs/*.aar' \
      --exclude=./android/src/main/assets/godot --exclude=./android/src/main/jniLibs \
      -cf - pubspec.yaml lib android) | (cd "$out/packages/elpian_godot_native" && tar -xf -)
fi
echo "assembled $count shared files into $out"
