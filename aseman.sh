#!/usr/bin/env sh
# One-command launcher for the Aseman Flutter client.
#
#   ./aseman.sh up [--local] [--hot-reload|--no-hot-reload]
#       build + start the client (detached).
#       Hot reload is on by default: the app is served in debug mode
#       (flutter run) and reloads when its source under app/ changes.
#       --no-hot-reload serves the release web build instead.
#       The app's API is a Decillion node: by default
#       https://preview.decillionai.com (or DECILLION_API_URL). --local
#       talks instead to a self-hosted Decillion stack on the host's own
#       localhost:8080.
#   ./aseman.sh down                stop the client
#   ./aseman.sh logs                follow its logs
#   ./aseman.sh ps                  show its status
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

# `docker compose up -d` returns as soon as the container starts, not once
# nginx is actually serving the app — the debug image still has `flutter pub
# get` and a web compile ahead of it (a few minutes cold, faster once
# flutter-pub-cache is warm). Block here so "up" only reports success once
# the client truly answers, instead of leaving people checking a blank page.
wait_for_web() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl not found; skipping the readiness check (it may still be compiling)." >&2
    return 0
  fi
  port="${WEB_PORT:-3000}"
  tries=0
  max_tries=180 # 180 * 2s = 6 minutes
  printf 'Waiting for the client to come up on http://localhost:%s ...' "$port"
  while [ "$tries" -lt "$max_tries" ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:$port/" 2>/dev/null) || code=""
    if [ "$code" = "200" ]; then
      echo " up."
      return 0
    fi
    tries=$((tries + 1))
    printf '.'
    sleep 2
  done
  echo " timed out."
  echo "It did not come up within $((max_tries * 2))s. Recent logs:" >&2
  docker compose logs --tail 40 web >&2
  return 1
}

case "$cmd" in
  up)
    hot_reload=true
    local_decillion=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --hot-reload) hot_reload=true ;;
        --no-hot-reload) hot_reload=false ;;
        --local) local_decillion=true ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) echo "unexpected argument: $1" >&2; exit 2 ;;
      esac
      shift
    done

    if [ "$local_decillion" = true ]; then
      DECILLION_API_URL="http://localhost:8080"
    else
      DECILLION_API_URL="${DECILLION_API_URL:-https://preview.decillionai.com}"
    fi
    export DECILLION_API_URL

    if [ "$hot_reload" = true ]; then
      # shellcheck disable=SC2086
      docker compose $hot_reload_files up -d --build
      case "$(web_container_image 2>/dev/null || true)" in
        *flutter-web:debug*) ;;
        "") ;;
        *) docker compose $hot_reload_files up -d --no-deps --force-recreate web ;;
      esac
      mode="debug mode, hot reload"
    else
      docker compose up -d --build
      case "$(web_container_image 2>/dev/null || true)" in
        *flutter-web:debug*) docker compose up -d --no-deps --force-recreate web ;;
      esac
      mode="release build"
    fi
    echo
    if ! wait_for_web; then
      echo "Container is still starting; ./aseman.sh logs follows it, ./aseman.sh ps shows its status." >&2
      exit 1
    fi
    echo
    echo "Flutter client:   http://localhost:${WEB_PORT:-3000} ($mode)"
    if [ "$hot_reload" = true ]; then
      echo "Edits under app/ reload the running app."
    fi
    echo "Decillion API:    $DECILLION_API_URL (through the client's own origin)"
    ;;
  down) docker compose down "$@" ;;
  logs) docker compose logs -f "$@" ;;
  ps)   docker compose ps "$@" ;;
  *)    echo "usage: $0 {up [--local] [--hot-reload|--no-hot-reload]|down|logs|ps}" >&2; exit 2 ;;
esac
