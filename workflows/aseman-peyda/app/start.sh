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
exec "$VENV/bin/python" server.py
