#!/bin/sh
# Ensure Kokoro ONNX weights exist (not shipped in the pip package).
set -eu
DIR="${KOKORO_DIR:-/models}"
mkdir -p "$DIR"
MODEL="${KOKORO_MODEL:-$DIR/kokoro-v1.0.int8.onnx}"
VOICES="${KOKORO_VOICES:-$DIR/voices-v1.0.bin}"
BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1"

if [ ! -f "$MODEL" ]; then
  echo "voice: downloading Kokoro model → $MODEL"
  curl -fsSL -o "$MODEL.partial" "$BASE/kokoro-v1.0.int8.onnx"
  mv "$MODEL.partial" "$MODEL"
fi
if [ ! -f "$VOICES" ]; then
  echo "voice: downloading Kokoro voices → $VOICES"
  curl -fsSL -o "$VOICES.partial" "$BASE/voices-v1.0.bin"
  mv "$VOICES.partial" "$VOICES"
fi

export KOKORO_MODEL="$MODEL"
export KOKORO_VOICES="$VOICES"
exec python server.py
