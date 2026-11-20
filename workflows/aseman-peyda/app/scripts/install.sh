#!/bin/sh
# Installs Peyda's Python environment on the project's computer, idempotently:
#   scripts/install.sh [--no-model] [--no-services]
# A CPU build of torch (no CUDA wheels), the server, GLiNER2, the iran-mcp
# servers (pinned in requirements-services.txt), and the model weights.
set -eu
cd "$(dirname "$0")/.."
VENV="${PEYDA_VENV:-/workspace/.venvs/peyda}"
# The iran-mcp servers get an environment of their own: they pin their own MCP SDK
# and are separate processes anyway, so the two sets never have to agree.
SVC="${PEYDA_SERVICES_VENV:-/workspace/.venvs/iran-mcp}"
export HF_HOME="${HF_HOME:-/workspace/.cache/huggingface}"
[ -s .peyda/hf_token ] && HF_TOKEN="$(cat .peyda/hf_token)" && export HF_TOKEN
# Settings the workflow wrote (HF_ENDPOINT: a Hugging Face mirror, when given).
if [ -f .peyda/env ]; then set -a; . ./.peyda/env; set +a; fi
[ -n "${HF_ENDPOINT:-}" ] || unset HF_ENDPOINT
MODEL="${PEYDA_GLINER_MODEL:-fastino/gliner2.5-multi-v1}"
[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
PIP="$VENV/bin/pip"
"$PIP" install --quiet --upgrade pip
"$VENV/bin/python" -c "import torch" 2>/dev/null || "$PIP" install --quiet torch --index-url https://download.pytorch.org/whl/cpu
"$PIP" install --quiet -r requirements-dev.txt
case " $* " in *" --no-services "*) ;; *)
  [ -x "$SVC/bin/python" ] || python3 -m venv "$SVC"
  "$SVC/bin/pip" install --quiet --upgrade pip
  "$SVC/bin/pip" install --quiet -r requirements-services.txt ;;
esac
case " $* " in *" --no-model "*) ;; *)
  # Plain HTTP downloads first: the xet store (cas-bridge.xethub.hf.co) is refused or
  # stalls on many networks, which shows up as a proxy 502 or a download stuck at 0 bytes.
  # Short timeouts make a stall fail in a minute instead of hanging; xet is the fallback.
  fetch() { "$VENV/bin/python" -c 'import sys; from gliner2 import AutoExtractor; AutoExtractor.from_pretrained(sys.argv[1]); print("model ready:", sys.argv[1])' "$MODEL"; }
  export HF_HUB_DOWNLOAD_TIMEOUT=60 HF_HUB_ETAG_TIMEOUT=30
  HF_HUB_DISABLE_XET=1 fetch || { echo "plain download failed; trying the xet store"; HF_HUB_DISABLE_XET=0 fetch; }
  ;;
esac
echo "peyda environment ready: $VENV"
