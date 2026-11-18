#!/bin/sh
# Writes /etc/nginx/aseman-api.conf: proxies /v1, /fed and /healthz to the
# app's Decillion node, on the app's own origin.
#
# Default: https://preview.decillionai.com, or DECILLION_API_URL.
# `./aseman.sh up --local` sets DECILLION_API_URL=http://localhost:8080 (a
# self-hosted Decillion stack on the host), which this renders as the static
# aseman-api.local.conf instead of the template below: nginx's own `resolver`
# only speaks real DNS and cannot resolve "localhost".
#
# Run before nginx starts: the release entrypoint
# (docker-entrypoint.d/15-aseman-web.sh) and the debug server
# (tool/debug_server.sh) both call this.
set -eu

DECILLION_API_URL="${DECILLION_API_URL:-https://preview.decillionai.com}"
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

case "$DECILLION_API_HOST" in
  localhost|127.0.0.1)
    cp /etc/nginx/aseman-api.local.conf /etc/nginx/aseman-api.conf
    ;;
  *)
    # Public resolvers: Render has no Docker DNS at 127.0.0.11. Override with
    # DECILLION_API_RESOLVER (space-separated addresses) if needed.
    DECILLION_API_RESOLVER="${DECILLION_API_RESOLVER:-1.1.1.1 8.8.8.8}"
    export DECILLION_API_URL DECILLION_API_HOST DECILLION_API_RESOLVER
    envsubst '${DECILLION_API_URL} ${DECILLION_API_HOST} ${DECILLION_API_RESOLVER}' \
      < /etc/nginx/aseman-api.decillion.template \
      > /etc/nginx/aseman-api.conf
    ;;
esac
