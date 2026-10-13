#!/bin/sh
# Renders ov.conf from the environment and starts the server. The config is
# rendered to a file rather than left to OpenViking's own ${VAR} expansion:
# its storage engine reads the file as it is.
#
# OpenViking has no model settings of its own here: it calls its chat and
# embedding models through the node (OPENVIKING_NODE_URL), which uses the
# models the admin picked under Admin → Memory models. The node fits every
# vector to the size ov.conf declares (1536, deepagents.MemoryDimension).
set -eu

if [ -z "${OPENVIKING_ROOT_API_KEY:-}" ]; then
  echo "openviking: set OPENVIKING_ROOT_API_KEY (the runtime and the node authenticate with it)" >&2
  exit 1
fi
export OPENVIKING_NODE_URL="${OPENVIKING_NODE_URL:-http://tradera:8080}"

rendered="${OPENVIKING_RENDERED_CONFIG:-/tmp/ov.conf}"
python - "${OPENVIKING_CONFIG:-/etc/openviking/ov.conf}" "$rendered" <<'PY'
import json, os, re, sys

text = open(sys.argv[1]).read()


def value(match):
    name = match.group(1)
    if name not in os.environ:
        sys.exit(f"openviking: {name} is not set")
    in_string = match.start() > 0 and text[match.start() - 1] == '"'
    # Inside a JSON string: escaped for it; bare (a number): as it is.
    return json.dumps(os.environ[name])[1:-1] if in_string else os.environ[name]


out = re.sub(r"\$\{([A-Z0-9_]+)\}", value, text)
json.loads(out)  # fail here, with the line, rather than inside the server
with open(sys.argv[2], "w") as f:
    f.write(out)
os.chmod(sys.argv[2], 0o600)
PY

exec openviking-server --config "$rendered" "$@"
