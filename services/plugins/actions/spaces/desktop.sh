#!/bin/bash
# tradera-desktop: the project's shared desktop (Xvfb + openbox + x11vnc +
# noVNC). People watch and drive it from Computer; agents drive it from their
# shell with the subcommands below, so both work on the very same screen.
#
#   tradera-desktop start        ensure the desktop is running (idempotent)
#   tradera-desktop restart      stop it and start it again
#   tradera-desktop stop         stop it and forget its password
#   tradera-desktop status       exit 0 when the VNC stream is up
#   tradera-desktop screenshot [file.png]   saves the screen (default /workspace/screenshot.png)
#   tradera-desktop open <url|app>          opens a URL in the browser, or runs an app
#   tradera-desktop click <x> <y> [button]  moves the mouse and clicks (1 left, 3 right)
#   tradera-desktop type <text>             types text into the focused window
#   tradera-desktop key <key>...            presses keys, e.g. Return ctrl+l
#
# The screen is 1440x900. `start` prints DESKTOP_PASSWORD:<secret> on success.
set -u
export DISPLAY=:99
export HOME="${HOME:-/root}"
STATE=/workspace/.desktop
LOG=/tmp/tradera-desktop.log
WEB_PORT=6080
VNC_PORT=5900
# Anchor to the actual proxy command; agent shell text can also mention websockify.
WEB_PROCESS="^([^ ]*/)?(python[0-9.]* +)?([^ ]*/)?websockify .*${WEB_PORT}"

have() { command -v "$1" >/dev/null 2>&1; }
detach() { setsid nohup "$@" >>"$LOG" 2>&1 </dev/null & }
novnc_dir() {
  for d in /usr/share/novnc /usr/share/novnc/noVNC /usr/local/share/novnc; do
    [ -f "$d/vnc.html" ] && { echo "$d"; return 0; }
  done
  return 1
}

# Starting the desktop only starts programs: it never downloads or installs
# anything. Everything it runs is baked into the computer's image
# (deploy/sandbox-computer), so a computer built from an older image says so
# instead of spending minutes on apt every time it wakes.
ensure_packages() {
  missing=""
  for c in Xvfb x11vnc openbox websockify xdotool xdpyinfo xprop xsetroot; do have "$c" || missing="$missing $c"; done
  novnc_dir >/dev/null || missing="$missing novnc"
  [ -z "$missing" ] && return 0
  echo "this computer's image is out of date and has no desktop (missing:$missing). Replace the computer from Manage computer to get the current image." >&2
  return 1
}

x_up() { have xdpyinfo && xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; }
wm_up() { xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q 'window id # 0x'; }
dock_up() { xdotool search --onlyvisible --class 'TraderaDock|tint2' >/dev/null 2>&1; }

# The dock: Terminal, Browser and Files as three icons in a small floating pill,
# macOS style (hover to magnify, a dot under what is open). It is a Tk program;
# a computer whose image has no Tk gets a plain tint2 panel instead.
write_dock() {
  mkdir -p "$STATE"
  cat >"$STATE/dock.py.new" <<'PY'
#!/usr/bin/env python3
"""tradera dock: Terminal, Browser (Chrome), Files."""
import subprocess
import tkinter as tk

BG = "#203a34"      # the wallpaper, so the pill's rounded corners read as cut out
PILL = "#2d423b"
EDGE = "#4b6b60"
ICON, GAP, PAD, RISE = 40, 10, 9, 36
ITEMS = [
    ("terminal", "Terminal", r"^xterm|^uxterm"),
    ("browser", "Browser", r"chromium|chrome"),
    ("files", "Files", r"^thunar|^pcmanfm"),
]
N = len(ITEMS)
PILL_W = N * ICON + (N - 1) * GAP + 2 * PAD
PILL_H = ICON + 2 * PAD
WIN_W, WIN_H = PILL_W + 40, PILL_H + RISE + 12

root = tk.Tk(className="TraderaDock")
root.title("Dock")
root.overrideredirect(True)
root.configure(bg=BG)
sw, sh = root.winfo_screenwidth(), root.winfo_screenheight()
canvas = tk.Canvas(root, width=WIN_W, height=WIN_H, bg=BG, highlightthickness=0, bd=0)
canvas.pack()
state = {"open": set(), "pointer": None, "scale": [1.0] * N, "press": None, "big": False}


def geometry(big):
    if big:
        root.geometry("%dx%d+%d+%d" % (WIN_W, WIN_H, (sw - WIN_W) // 2, sh - WIN_H - 8))
    else:
        root.geometry("%dx%d+%d+%d" % (WIN_W, PILL_H + 4, (sw - WIN_W) // 2, sh - PILL_H - 12))
    state["big"] = big


def rrect(x1, y1, x2, y2, r, **kw):
    pts = [x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r, x2, y2 - r, x2, y2, x2 - r, y2,
           x1 + r, y2, x1, y2, x1, y2 - r, x1, y1 + r, x1, y1]
    return canvas.create_polygon(pts, smooth=True, **kw)


def tile(cx, bottom, size, fill):
    return rrect(cx - size / 2, bottom - size, cx + size / 2, bottom, size * 0.24, fill=fill, outline="")


def draw_terminal(cx, bottom, size):
    tile(cx, bottom, size, "#1c1f1e")
    u, cy = size / 40.0, bottom - size / 2
    canvas.create_line(cx - 10 * u, cy - 6 * u, cx - 3 * u, cy, cx - 10 * u, cy + 6 * u,
                       fill="#7be0a6", width=max(2, 2.4 * u), capstyle="round", joinstyle="round")
    canvas.create_line(cx + 1 * u, cy + 8 * u, cx + 10 * u, cy + 8 * u, fill="#7be0a6", width=max(2, 2.4 * u), capstyle="round")


def draw_browser(cx, bottom, size):
    u, cy = size / 40.0, bottom - size / 2
    r = size * 0.47
    for start, color in ((30, "#ea4335"), (150, "#34a853"), (270, "#fbbc04")):
        canvas.create_arc(cx - r, cy - r, cx + r, cy + r, start=start, extent=120, fill=color, outline=color)
    for rad, color in ((0.52, "#ffffff"), (0.38, "#4285f4")):
        canvas.create_oval(cx - r * rad, cy - r * rad, cx + r * rad, cy + r * rad, fill=color, outline=color)


def draw_files(cx, bottom, size):
    tile(cx, bottom, size, "#3b8bf5")
    u, cy = size / 40.0, bottom - size / 2
    canvas.create_polygon(cx - 12 * u, cy - 8 * u, cx - 3 * u, cy - 8 * u, cx, cy - 5 * u, cx + 12 * u, cy - 5 * u,
                          cx + 12 * u, cy + 10 * u, cx - 12 * u, cy + 10 * u, fill="#ffffff", outline="#ffffff", smooth=False)
    canvas.create_rectangle(cx - 12 * u, cy - 3 * u, cx + 12 * u, cy + 10 * u, fill="#cfe3ff", outline="#cfe3ff")


DRAW = {"terminal": draw_terminal, "browser": draw_browser, "files": draw_files}


def centers():
    left = (WIN_W - PILL_W) / 2 + PAD + ICON / 2
    return [left + i * (ICON + GAP) for i in range(N)]


def render():
    canvas.delete("all")
    base = WIN_H - 10 if state["big"] else PILL_H + 2
    rrect((WIN_W - PILL_W) / 2, base - PILL_H, (WIN_W + PILL_W) / 2, base, 20, fill=PILL, outline=EDGE)
    px = state["pointer"]
    for i, cx in enumerate(centers()):
        s = state["scale"][i]
        if state["press"] == i:
            s *= 0.9
        DRAW[ITEMS[i][0]](cx, base - PAD, ICON * s)
        if ITEMS[i][0] in state["open"]:
            canvas.create_oval(cx - 2, base - 6, cx + 2, base - 2, fill="#e8f1ed", outline="")
    if px is not None and state["big"]:
        for i, cx in enumerate(centers()):
            if state["scale"][i] > 1.18:
                label = ITEMS[i][1]
                w = 14 + 7 * len(label)
                y = base - PAD - ICON * state["scale"][i] - 8
                rrect(cx - w / 2, y - 20, cx + w / 2, y, 7, fill="#111917", outline=EDGE)
                canvas.create_text(cx, y - 10, text=label, fill="#eef5f1", font=("DejaVu Sans", 9))


def animate():
    px, moving = state["pointer"], False
    for i, cx in enumerate(centers()):
        target = 1.0 if px is None else 1.0 + 0.4 * max(0.0, 1.0 - abs(px - cx) / (ICON * 1.7))
        cur = state["scale"][i]
        nxt = cur + (target - cur) * 0.35
        if abs(nxt - target) < 0.01:
            nxt = target
        else:
            moving = True
        state["scale"][i] = nxt
    render()
    if moving:
        root.after(16, animate)
    elif px is None and state["big"]:
        geometry(False)
        render()


def on_move(e):
    if not state["big"]:
        geometry(True)
    state["pointer"] = e.x
    animate()


def on_leave(_e):
    state["pointer"] = None
    state["press"] = None
    animate()


def hit(e):
    for i, cx in enumerate(centers()):
        if abs(e.x - cx) <= ICON * state["scale"][i] / 2 + GAP / 2:
            return i
    return None


def on_press(e):
    state["press"] = hit(e)
    render()


def on_release(e):
    i, state["press"] = hit(e), None
    render()
    if i is not None:
        subprocess.Popen(["/usr/local/bin/tradera-desktop", "launch", ITEMS[i][0]], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)


def poll():
    # Keep above newly mapped windows, and mark what is open.
    try:
        root.lift()
        found = set()
        for key, _label, pattern in ITEMS:
            out = subprocess.run(["xdotool", "search", "--onlyvisible", "--classname", pattern], capture_output=True, timeout=3)
            if out.stdout.strip():
                found.add(key)
        if found != state["open"]:
            state["open"] = found
            render()
    except Exception:
        pass
    root.after(2000, poll)


canvas.bind("<Motion>", on_move)
canvas.bind("<Leave>", on_leave)
canvas.bind("<ButtonPress-1>", on_press)
canvas.bind("<ButtonRelease-1>", on_release)
geometry(False)
render()
root.after(1500, poll)
root.mainloop()
PY
  if ! cmp -s "$STATE/dock.py.new" "$STATE/dock.py" 2>/dev/null; then
    mv -f "$STATE/dock.py.new" "$STATE/dock.py"
    pkill -f "$STATE/dock.py" 2>/dev/null
  else
    rm -f "$STATE/dock.py.new"
  fi
}

start_dock() {
  if python3 -c 'import tkinter' >/dev/null 2>&1; then
    write_dock
    pkill -x tint2 2>/dev/null
    pgrep -f "$STATE/dock.py" >/dev/null || detach python3 "$STATE/dock.py"
  elif have tint2; then
    configure_tint2
    pgrep -x tint2 >/dev/null || detach tint2 -c "$STATE/tint2rc"
  else
    return 0
  fi
}

# Fallback panel for a machine whose image has no Tk yet.
configure_tint2() {
  mkdir -p "$STATE/launchers"
  for app in browser terminal files; do
    case "$app" in
      browser) label=Browser; icon=chromium ;;
      terminal) label=Terminal; icon=utilities-terminal ;;
      files) label=Files; icon=system-file-manager ;;
    esac
    cat >"$STATE/launchers/$app.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$label
Exec=/usr/local/bin/tradera-desktop launch $app
Icon=$icon
Terminal=false
EOF
  done
  cat >"$STATE/tint2rc" <<EOF
rounded = 12
border_width = 1
background_color = #152b25 95
border_color = #7cac98 30
rounded = 6
border_width = 0
background_color = #527f6e 80
panel_items = LT
panel_size = 40% 52
panel_position = bottom center horizontal
panel_margin = 0 10
panel_padding = 10 5 10
panel_background_id = 1
panel_layer = top
autohide = 0
launcher_padding = 5 2 8
launcher_icon_size = 32
launcher_icon_theme = Adwaita
launcher_item_app = $STATE/launchers/browser.desktop
launcher_item_app = $STATE/launchers/terminal.desktop
launcher_item_app = $STATE/launchers/files.desktop
taskbar_mode = single_desktop
task_text = 0
task_maximum_size = 40 40
EOF
}

# The stream is only "up" when the WebSocket upgrade through noVNC's proxy
# reaches x11vnc and its RFB greeting comes back. A page that merely loads
# (GET /vnc.html) proves a file server, not a desktop.
stream_ok() {
  python3 - "$WEB_PORT" <<'PY' >/dev/null 2>&1
import base64, os, socket, sys
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), 3)
s.settimeout(4)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(("GET /websockify HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n" % key).encode())
buf = b""
while b"RFB " not in buf:
    chunk = s.recv(4096)
    if not chunk:
        sys.exit(1)
    buf += chunk
    if len(buf) > 65536:
        sys.exit(1)
sys.exit(0 if buf.startswith(b"HTTP/1.1 101") else 1)
PY
}

password() {
  mkdir -p "$STATE"
  if [ ! -s "$STATE/secret" ]; then
    head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$STATE/secret"
  fi
  cat "$STATE/secret"
}

do_stop() {
  pkill -f "$WEB_PROCESS" 2>/dev/null
  pkill -x x11vnc 2>/dev/null
  pkill -x tint2 2>/dev/null
  pkill -f "$STATE/dock.py" 2>/dev/null
  pkill -x openbox 2>/dev/null
  pkill -x Xvfb 2>/dev/null
  rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
  return 0
}

do_start() {
  ensure_packages || return 1
  web=$(novnc_dir) || { echo "noVNC files are missing" >&2; return 1; }
  pw=$(password)
  mkdir -p "$STATE" /tmp/runtime-desktop
  chmod 700 /tmp/runtime-desktop
  export XDG_RUNTIME_DIR=/tmp/runtime-desktop

  x_up || { rm -f /tmp/.X99-lock /tmp/.X11-unix/X99; detach Xvfb "$DISPLAY" -screen 0 1440x900x24 -nolisten tcp; }
  for _ in $(seq 1 40); do x_up && break; sleep 0.25; done
  x_up || { echo "the X server did not start:" >&2; tail -n 15 "$LOG" >&2; return 1; }

  pgrep -x openbox >/dev/null || detach openbox
  for _ in $(seq 1 40); do wm_up && break; sleep 0.25; done
  wm_up || { echo "the desktop window manager did not start" >&2; tail -n 15 "$LOG" >&2; return 1; }
  xsetroot -solid '#203a34' -cursor_name left_ptr
  # VNC, its web proxy and the dock only need the X server, so they come up
  # together instead of one after the other.
  if ! pgrep -f "^([^ ]*/)?x11vnc .* -ncache 0( |$)" >/dev/null; then
    # Upgrade the stream on existing sessions too; keep the X session and apps.
    pkill -x x11vnc 2>/dev/null
    for _ in $(seq 1 40); do pgrep -x x11vnc >/dev/null || break; sleep 0.1; done
    x11vnc -storepasswd "$pw" "$STATE/passwd" >/dev/null 2>&1
    # Shared-memory X reads fail on sandboxes with isolated/disabled SysV IPC.
    # Listen on IPv4 loopback explicitly (-localhost can bind ::1 only), poll
    # X damage instead of the whole screen, and avoid noVNC's black-tile bug.
    detach x11vnc -display "$DISPLAY" -rfbauth "$STATE/passwd" -rfbport "$VNC_PORT" -listen 127.0.0.1 -forever -shared -noshm -ncache 0 -repeat -cursor arrow -wait 10 -defer 10
  fi
  pgrep -f "$WEB_PROCESS" >/dev/null || detach websockify --web="$web" "$WEB_PORT" "127.0.0.1:$VNC_PORT"
  start_dock
  for _ in $(seq 1 40); do stream_ok && break; sleep 0.25; done
  if stream_ok; then
    # The dock is a nicety: give it a moment, never fail the desktop for it.
    for _ in $(seq 1 12); do dock_up && break; sleep 0.25; done
    echo "DESKTOP_PASSWORD:$pw"
    return 0
  fi
  echo "the desktop page is up but the VNC stream is not:" >&2
  tail -n 15 "$LOG" >&2
  return 1
}

cmd="${1:-start}"
[ $# -gt 0 ] && shift
case "$cmd" in
  start) do_start ;;
  restart) do_stop; sleep 0.5; do_start ;;
  stop) do_stop; rm -rf "$STATE" ;;
  status) x_up && wm_up && stream_ok ;;
  screenshot)
    out="${1:-/workspace/screenshot.png}"
    x_up || { echo "the desktop is not running; run: tradera-desktop start" >&2; exit 1; }
    mkdir -p "$(dirname "$out")"
    scrot -o "$out" && echo "$out"
    ;;
  launch)
    # What the dock runs: an app on the running desktop, nothing is repaired.
    x_up || exit 1
    case "${1:-}" in
      terminal) detach xterm -fa 'DejaVu Sans Mono' -fs 11 -bg '#16201d' -fg '#e3eee9' -cr '#7be0a6' -geometry 100x28 -e bash -l ;;
      files) for f in thunar pcmanfm; do have "$f" && { detach "$f" /workspace; exit 0; }; done; exit 1 ;;
      browser) exec "$0" open browser "${2:-about:blank}" ;;
      *) exit 2 ;;
    esac
    ;;
  open)
    # Repair old bare sessions too, without closing their running apps.
    do_start >/dev/null || exit 1
    target="${1:-about:blank}"
    [ $# -gt 0 ] && shift
    case "$target" in
      chrome|chromium|chromium-browser|google-chrome|browser) target="${1:-about:blank}"; [ $# -gt 0 ] && shift ;;
      terminal) exec "$0" launch terminal ;;
      files) exec "$0" launch files ;;
    esac
    case "$target" in
      http://*|https://*|about:*|file:*)
        for b in chromium chromium-browser google-chrome firefox-esr firefox; do
          have "$b" || continue
          mkdir -p /tmp/tradera-browser
          case "$b" in
            chromium*|google-chrome) detach "$b" --user-data-dir=/tmp/tradera-browser --no-sandbox --disable-dev-shm-usage --disable-gpu --no-first-run --no-default-browser-check --password-store=basic --start-maximized "$target" ;;
            *) detach "$b" "$target" ;;
          esac
          # A spawned process is not proof that a browser opened a window.
          for _ in $(seq 1 60); do
            if xdotool search --onlyvisible --class 'chromium|chrome|firefox' >/dev/null 2>&1; then
              echo "opened $target"; exit 0
            fi
            sleep 0.25
          done
          echo "the browser did not open a desktop window:" >&2
          tail -n 15 "$LOG" >&2
          exit 1
        done
        echo "no browser is installed on this computer: its image is out of date. Replace the computer from Manage computer." >&2; exit 1 ;;
      *)
        have "$target" || { echo "application not found: $target" >&2; exit 1; }
        detach "$target" "$@"; echo "started $target" ;;
    esac
    ;;
  click)
    x_up || { echo "the desktop is not running" >&2; exit 1; }
    xdotool mousemove "${1:?x}" "${2:?y}" click "${3:-1}"
    ;;
  type)
    x_up || { echo "the desktop is not running" >&2; exit 1; }
    xdotool type --delay 20 -- "$*"
    ;;
  key)
    x_up || { echo "the desktop is not running" >&2; exit 1; }
    xdotool key -- "$@"
    ;;
  *) echo "usage: tradera-desktop start|restart|stop|status|screenshot|open|click|type|key" >&2; exit 2 ;;
esac
