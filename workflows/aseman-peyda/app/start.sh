#!/bin/sh
# Starts Peyda from the project's files. The Python environment, the model and
# the chat database live on the computer's disk outside this folder (/workspace),
# so a woken computer is serving in seconds and an update never loses a chat.
cd "$(dirname "$0")" || exit 1
VENV="${PEYDA_VENV:-/workspace/.venvs/peyda}"
export HF_HOME="${HF_HOME:-/workspace/.cache/huggingface}"
export PEYDA_MCP_BIN_DIR="${PEYDA_MCP_BIN_DIR:-${PEYDA_SERVICES_VENV:-/workspace/.venvs/iran-mcp}/bin}"
export PEYDA_DB="${PEYDA_DB:-/workspace/data/peyda/peyda.sqlite3}"
# Settings the installer wrote (PEYDA_GLINER_MODEL, PEYDA_MAX_ROUNDS, …).
if [ -f .peyda/env ]; then set -a; . ./.peyda/env; set +a; fi
[ -n "${HF_ENDPOINT:-}" ] || unset HF_ENDPOINT
# An HTTP proxy with an Iranian address, for the sites that refuse other countries.
if [ -s .peyda/iran_proxy ]; then PEYDA_IRAN_PROXY="$(cat .peyda/iran_proxy)"; export PEYDA_IRAN_PROXY; fi
# The Google Maps service: the kit's engine, started now (it detaches) so the first search
# does not wait for it; the service starts it itself if it is not running.
export PEYDA_GMAPS_KIT="${PEYDA_GMAPS_KIT:-/workspace/.gmaps-kit}" PEYDA_GMAPS_PORT="${PEYDA_GMAPS_PORT:-8765}"
if [ -s .peyda/gmaps_proxy ]; then PEYDA_GMAPS_PROXY="$(cat .peyda/gmaps_proxy)"; export PEYDA_GMAPS_PROXY; fi
if [ "${PEYDA_GMAPS:-1}" != 0 ] && [ -f "$PEYDA_GMAPS_KIT/scripts/engine.py" ]; then
  SCRAPER_PORT="$PEYDA_GMAPS_PORT" SCRAPER_NO_UPDATE_CHECK=1 "$VENV/bin/python" "$PEYDA_GMAPS_KIT/scripts/engine.py" start \
    </dev/null >/dev/null 2>&1 &
fi
exec "$VENV/bin/python" server.py
