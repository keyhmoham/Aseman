#!/bin/sh
# Serves the Flutter app in debug mode and hot-reloads it when source changes.
# nginx (see deploy/nginx.debug.conf) publishes the app and proxies the API.
set -eu

cd /src
mkdir -p /tmp/nginx-client /tmp/nginx-proxy /tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi
/usr/local/bin/aseman-render-api-conf

# The SDK image runs git against the mounted tree, which is owned by the host user.
git config --global --replace-all safe.directory /src
flutter config --no-analytics >/dev/null

# Generated plugin files land on the bind mount. Hand them back to the host user.
own_generated() {
  uid=${ASEMAN_UID:-}
  gid=${ASEMAN_GID:-$uid}
  [ -n "$uid" ] && [ "$uid" != 0 ] || return 0
  for f in .flutter-plugins .flutter-plugins-dependencies pubspec.lock; do
    if [ -e "$f" ]; then
      chown "$uid:$gid" "$f" 2>/dev/null || true
    fi
  done
}

: > /tmp/nginx-error.log
tail -n 0 -F /tmp/nginx-error.log >&2 &
nginx -c /etc/nginx/aseman-debug.conf &
nginx_pid=$!
sleep 0.3
if ! kill -0 "$nginx_pid" 2>/dev/null; then
  echo "nginx failed to start" >&2
  exit 1
fi

echo "Flutter debug server: resolving packages."
flutter pub get
own_generated

PIDFILE=/tmp/flutter.pid
PENDING=/tmp/flutter-reload-pending
rm -f "$PIDFILE" "$PENDING"

# inotifywait exits 0 when an event arrives, 2 when -t times out (the watch
# is working), and 1 on a real error.
status=0
inotifywait -t 1 -e attrib /src/pubspec.yaml >/tmp/inotify-probe.err 2>&1 || status=$?
if [ "$status" -ne 0 ] && [ "$status" -ne 2 ]; then
  echo "hot reload: cannot watch the Flutter sources" >&2
  cat /tmp/inotify-probe.err >&2 || true
  exit 1
fi
rm -f /tmp/inotify-probe.err

# Queue a reload or a restart. Dart sources hot-reload; assets, web files and
# pubspecs need a restart (and pub get) for the running app to pick them up.
inotifywait -m -r -q \
  --format '%w%f|%e' \
  --exclude '(\.dart_tool|/build/|\.git|~$|\.swp$|\.swx$)' \
  -e close_write,create,delete,move \
  /src/lib /src/web /src/assets /src/packages /src/pubspec.yaml |
while IFS='|' read -r path event; do
  case "$event" in
    *ISDIR*) continue ;;
  esac
  case "$path" in
    */pubspec.yaml) echo pub >> "$PENDING" ;;
    *.dart) echo reload >> "$PENDING" ;;
    *) echo restart >> "$PENDING" ;;
  esac
done &

(
  while true; do
    if [ -s "$PENDING" ]; then
      # Coalesce a burst of writes from one save into a single reload.
      sleep 0.6
      [ -s "$PENDING" ] || continue
      mv "$PENDING" "$PENDING.work" || continue
      if [ ! -f "$PIDFILE" ]; then
        cat "$PENDING.work" >> "$PENDING"
        rm -f "$PENDING.work"
        sleep 1
        continue
      fi
      pid=$(cat "$PIDFILE")
      if grep -q '^pub$' "$PENDING.work"; then
        echo "pubspec changed; updating packages and hot restarting"
        (cd /src && flutter pub get && own_generated) || true
        kill -USR2 "$pid" 2>/dev/null || true
      elif grep -q '^restart$' "$PENDING.work"; then
        echo "source changed; hot restarting"
        kill -USR2 "$pid" 2>/dev/null || true
      else
        echo "source changed; hot reloading"
        kill -USR1 "$pid" 2>/dev/null || true
      fi
      rm -f "$PENDING.work"
    else
      sleep 0.3
    fi
  done
) &

echo "Hot reload watches app/lib, app/web, app/assets and app/packages."
exec flutter run -d web-server \
  --web-hostname 127.0.0.1 \
  --web-port 7357 \
  --no-web-resources-cdn \
  --dart-define=API_BASE_URL=same-origin \
  --dart-define=DEVELOPER_API_BASE="${DEVELOPER_API_BASE:-}" \
  --pid-file "$PIDFILE"
