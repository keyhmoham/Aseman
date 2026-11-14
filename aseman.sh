#!/usr/bin/env sh
# One-command launcher for the full Aseman stack.
#
#   ./aseman.sh up [--no-web] [--hot-reload|--no-hot-reload] [--decillion] [config.yml]
#       build + start the stack (detached).
#       Hot reload is on by default: the Flutter app is served in debug mode
#       and reloads when its source changes. --no-hot-reload serves the
#       release web image instead. --no-web skips the Flutter client.
#       --decillion builds and starts the Flutter web app alone (release
#       build; no Aseman node, database or other containers) on a Decillion
#       node as its API: https://preview.decillionai.com, or DECILLION_API_URL.
#   ./aseman.sh down                         stop the stack (data volumes are kept)
#   ./aseman.sh logs [service]               follow logs
#   ./aseman.sh ps                           show service status
set -eu
cd "$(dirname "$0")"

cmd="${1:-up}"
[ $# -gt 0 ] && shift

# Debug client (docker-compose.hotreload.yml). Release mode uses the base file only.
hot_reload_files="-f docker-compose.yml -f docker-compose.hotreload.yml"

# Image of the running (or stopped) web container, if compose has created one.
web_container_image() {
  cid=$(docker ps -aq \
    --filter label=com.docker.compose.project=aseman \
    --filter label=com.docker.compose.service=web | head -n 1)
  if [ -n "$cid" ]; then
    docker inspect -f '{{.Config.Image}}' "$cid"
  fi
}

case "$cmd" in
  up)
    no_web=false
    hot_reload=true
    decillion=false
    cfg=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --no-web|--api-only) no_web=true ;;
        --hot-reload) hot_reload=true ;;
        --no-hot-reload) hot_reload=false ;;
        --decillion) decillion=true ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)
          if [ -n "$cfg" ]; then
            echo "unexpected argument: $1" >&2
            exit 2
          fi
          cfg="$1"
          ;;
      esac
      shift
    done

    if [ "$decillion" = true ]; then
      if [ "$no_web" = true ] || [ -n "$cfg" ]; then
        echo "--decillion starts only the web app: it takes no --no-web or config file" >&2
        exit 2
      fi
      DECILLION_API_URL="${DECILLION_API_URL:-https://preview.decillionai.com}"
      DECILLION_API_URL="${DECILLION_API_URL%/}"
      case "$DECILLION_API_URL" in
        http://*|https://*) ;;
        *) echo "DECILLION_API_URL must be an http(s) URL: $DECILLION_API_URL" >&2; exit 2 ;;
      esac
      DECILLION_API_HOST="${DECILLION_API_URL#*://}"
      DECILLION_API_HOST="${DECILLION_API_HOST%%/*}"
      DECILLION_API_HOST="${DECILLION_API_HOST%%:*}"
      export DECILLION_API_URL DECILLION_API_HOST
      # One app on the web port: this stack's own client steps aside.
      # --force-recreate: compose otherwise keeps a running web-decillion even
      # after --build when its config hash is unchanged (and a container that
      # lost its network endpoint would never get a host port again).
      docker compose stop web >/dev/null 2>&1 || true
      docker compose --profile decillion up -d --build --force-recreate web-decillion
      echo
      echo "Flutter client:   http://localhost:${WEB_PORT:-3000} (release build)"
      echo "Decillion API:    $DECILLION_API_URL (through the client's own origin)"
      echo "Sign in with an account of that node. ./aseman.sh down stops it."
      exit 0
    fi
    # The stack's own client takes the web port back from a --decillion one.
    docker compose --profile decillion stop web-decillion >/dev/null 2>&1 || true

    if [ -n "$cfg" ]; then
      [ -f "$cfg" ] || { echo "config file not found: $cfg" >&2; exit 1; }
      ASEMAN_CONFIG_FILE="$(cd "$(dirname "$cfg")" && pwd)/$(basename "$cfg")"
      export ASEMAN_CONFIG_FILE
    elif [ -f services/configs/config.yml ]; then
      ASEMAN_CONFIG_FILE="$(pwd)/services/configs/config.yml"
      export ASEMAN_CONFIG_FILE
    fi
    mkdir -p "${NOMAD_DATA_DIR:-/tmp/aseman-nomad}"
    # So the debug container can hand generated plugin files back to this user.
    ASEMAN_UID=$(id -u)
    ASEMAN_GID=$(id -g)
    export ASEMAN_UID ASEMAN_GID

    if [ "$no_web" = true ]; then
      docker compose stop web >/dev/null 2>&1 || true
      docker compose up -d --build postgres nomad sandbox-computer harness aseman
      echo
      echo "Aseman stack started without the web container."
    elif [ "$hot_reload" = true ]; then
      # shellcheck disable=SC2086
      docker compose $hot_reload_files up -d --build
      case "$(web_container_image 2>/dev/null || true)" in
        *flutter-web:debug*) ;;
        "") ;;
        *) docker compose $hot_reload_files up -d --no-deps --force-recreate web ;;
      esac
      echo
      echo "Flutter client:   http://localhost:${WEB_PORT:-3000} (debug mode, hot reload)"
      echo "Edits under app/ reload the running app. The first launch compiles it; ./aseman.sh logs web shows progress."
    else
      docker compose up -d --build
      case "$(web_container_image 2>/dev/null || true)" in
        *flutter-web:debug*) docker compose up -d --no-deps --force-recreate web ;;
      esac
      echo
      echo "Flutter client:   http://localhost:${WEB_PORT:-3000} (release build)"
    fi
    echo "Aseman API:      http://localhost:${ASEMAN_PORT:-8080}"
    echo "Admin login:      handle = node.name from the config, password = \${ASEMAN_ADMIN_PASSWORD:-changeme}"
    echo "Then open Admin console -> LLM to add LLM providers, models and prices."
    ;;
  # --profile decillion: the --decillion web app (web-decillion) too.
  down) docker compose --profile decillion down "$@" ;;
  logs) docker compose --profile decillion logs -f "$@" ;;
  ps)   docker compose --profile decillion ps "$@" ;;
  *)    echo "usage: $0 {up [--no-web] [--hot-reload|--no-hot-reload] [--decillion] [config.yml]|down|logs [service]|ps}" >&2; exit 2 ;;
esac
