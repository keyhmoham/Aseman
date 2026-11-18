#!/bin/sh
# Runs before nginx starts (official image: /docker-entrypoint.d).
# Listen on $PORT so Render (which injects PORT) and local compose (port 80)
# share this image. The API proxy itself is rendered by render-api-conf.sh.
set -eu

port="${PORT:-80}"
case "$port" in
  ''|*[!0-9]*)
    echo "PORT must be a number: $port" >&2
    exit 1
    ;;
esac
sed -i "s/listen 80;/listen ${port};/" /etc/nginx/conf.d/default.conf

/usr/local/bin/aseman-render-api-conf
