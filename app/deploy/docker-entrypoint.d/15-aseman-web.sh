#!/bin/sh
# Runs before nginx starts (official image: /docker-entrypoint.d).
# - Listen on $PORT so Render (which injects PORT) and local compose (port 80)
#   share this image.
# - When DECILLION_API_URL is set, proxy /v1, /fed and /healthz to that node
#   on this origin. Unset: keep the baked local-node proxy (docker compose web).
set -eu

port="${PORT:-80}"
case "$port" in
  ''|*[!0-9]*)
    echo "PORT must be a number: $port" >&2
    exit 1
    ;;
esac
sed -i "s/listen 80;/listen ${port};/" /etc/nginx/conf.d/default.conf

if [ -z "${DECILLION_API_URL:-}" ]; then
  exit 0
fi

DECILLION_API_URL="${DECILLION_API_URL%/}"
case "$DECILLION_API_URL" in
  http://*|https://*) ;;
  *)
    echo "DECILLION_API_URL must be an http(s) URL: $DECILLION_API_URL" >&2
    exit 1
    ;;
esac

if [ -z "${DECILLION_API_HOST:-}" ]; then
  DECILLION_API_HOST="${DECILLION_API_URL#*://}"
  DECILLION_API_HOST="${DECILLION_API_HOST%%/*}"
  DECILLION_API_HOST="${DECILLION_API_HOST%%:*}"
fi

# Public resolvers: Render has no Docker DNS at 127.0.0.11. Override with
# DECILLION_API_RESOLVER (space-separated addresses) if needed.
DECILLION_API_RESOLVER="${DECILLION_API_RESOLVER:-1.1.1.1 8.8.8.8}"

export DECILLION_API_URL DECILLION_API_HOST DECILLION_API_RESOLVER
envsubst '${DECILLION_API_URL} ${DECILLION_API_HOST} ${DECILLION_API_RESOLVER}' \
  < /etc/nginx/aseman-api.decillion.template \
  > /etc/nginx/aseman-api.conf
