#!/usr/bin/env sh
# One-command launcher for the full Aseman stack.
#
#   ./aseman.sh up [--no-web] [config.yml]   build + start stack (detached)
#   ./aseman.sh down                         stop the stack (data volumes are kept)
#   ./aseman.sh logs [service]               follow logs
#   ./aseman.sh ps                           show service status
set -eu
cd "$(dirname "$0")"

cmd="${1:-up}"
[ $# -gt 0 ] && shift

case "$cmd" in
  up)
    no_web=false
    cfg=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --no-web|--api-only) no_web=true ;;
        *) cfg="$1" ;;
      esac
      shift
    done

    if [ -n "$cfg" ]; then
      [ -f "$cfg" ] || { echo "config file not found: $cfg" >&2; exit 1; }
      ASEMAN_CONFIG_FILE="$(cd "$(dirname "$cfg")" && pwd)/$(basename "$cfg")"
      export ASEMAN_CONFIG_FILE
    elif [ -f services/configs/config.yml ]; then
      ASEMAN_CONFIG_FILE="$(pwd)/services/configs/config.yml"
      export ASEMAN_CONFIG_FILE
    fi
    mkdir -p "${NOMAD_DATA_DIR:-/tmp/aseman-nomad}"
    # The agents' memory server (OpenViking) needs a root key: made once, kept in .env.
    if [ -z "${ASEMAN_OPENVIKING_ROOT_KEY:-}" ] && ! grep -qs '^ASEMAN_OPENVIKING_ROOT_KEY=.' .env; then
      printf '\nASEMAN_OPENVIKING_ROOT_KEY=%s\n' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" >> .env
      echo "generated ASEMAN_OPENVIKING_ROOT_KEY in .env"
    fi
    # The node's account in the timelines' server (Utopia): made once, kept in .env.
    if [ -z "${ASEMAN_TIMELINE_PASSWORD:-}" ] && ! grep -qs '^ASEMAN_TIMELINE_PASSWORD=.' .env; then
      printf '\nASEMAN_TIMELINE_PASSWORD=%s\n' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" >> .env
      echo "generated ASEMAN_TIMELINE_PASSWORD in .env"
    fi

    if [ "$no_web" = true ]; then
      docker compose up -d --build postgres nomad sandbox-computer deepagents openviking timeline-db timeline aseman
      echo
      echo "Aseman stack started without the web container."
    else
      docker compose up -d --build
      echo
      echo "Flutter client:   http://localhost:${WEB_PORT:-3000}"
    fi
    echo "Aseman API:      http://localhost:${ASEMAN_PORT:-8080}"
    echo "Admin login:      handle = node.name from the config, password = \${ASEMAN_ADMIN_PASSWORD:-changeme}"
    echo "Then open Admin console -> LLM to add LLM providers, models and prices."
    ;;
  down) docker compose down "$@" ;;
  logs) docker compose logs -f "$@" ;;
  ps)   docker compose ps "$@" ;;
  *)    echo "usage: $0 {up [--no-web] [config.yml]|down|logs [service]|ps}" >&2; exit 2 ;;
esac
