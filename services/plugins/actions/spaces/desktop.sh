#!/bin/bash
# tradera-desktop: the project's shared desktop (Xvfb + openbox + x11vnc +
# noVNC). People watch and drive it from Computer; agents drive it from their
# shell with the subcommands below, so both work on the very same screen.
#
#   tradera-desktop start        ensure the desktop is running (idempotent)
#   tradera-desktop restart      stop it and start it again
#   tradera-desktop stop         stop it and forget its password
#   tradera-desktop forget-logins   close the browser and erase its saved logins
#   tradera-desktop status       exit 0 when the VNC stream is up
#   tradera-desktop screenshot [file.png]   saves the screen (default /workspace/screenshot.png)
#   tradera-desktop open <url|file|app>     opens a URL or a file (image, PDF, ...) in the browser, a folder in Files, or runs an app
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
# The browser's profile (its cookies and logins) lives on the project's own disk,
# so a site stays signed in when the computer sleeps or is rebuilt. It holds
# live sessions: the file tools of people and agents never show it, and
# `tradera-desktop forget-logins` erases it. Not under $STATE, which `stop` removes.
BROWSER_PROFILE="${TRADERA_BROWSER_PROFILE:-/workspace/.tradera/browser-profile}"
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

# Everything the browser can show opens in it, from the dock's Files, from
# xdg-open and from agents: the image's default for images is ImageMagick's
# viewer, which shows no PDF. The desktop entry runs `tradera-desktop open`, so
# the browser gets the project's profile and the flags a root machine needs.
BROWSER_TYPES="text/html application/xhtml+xml x-scheme-handler/http x-scheme-handler/https application/pdf image/png image/jpeg image/gif image/webp image/svg+xml image/bmp image/avif image/x-icon video/mp4 video/webm video/ogg audio/mpeg audio/ogg audio/wav audio/webm audio/flac text/plain text/markdown text/csv application/json application/xml text/xml"
configure_default_apps() {
  local apps="$HOME/.local/share/applications" list="$HOME/.config/mimeapps.list" t
  mkdir -p "$apps" "$HOME/.config" 2>/dev/null || return 0
  {
    echo "[Desktop Entry]"
    echo "Type=Application"
    echo "Name=Browser"
    echo "Exec=/usr/local/bin/tradera-desktop open %U"
    echo "Icon=chromium"
    echo "Terminal=false"
    echo "Categories=Network;WebBrowser;"
    echo "MimeType=$(printf '%s;' $BROWSER_TYPES)"
  } >"$apps/tradera-browser.desktop"
  {
    echo "[Default Applications]"
    for t in $BROWSER_TYPES; do echo "$t=tradera-browser.desktop"; done
  } >"$list"
  update-desktop-database "$apps" >/dev/null 2>&1 || true
}

# A file or folder on this machine as the file: URL a browser opens.
file_url() { python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().as_uri())' "$1"; }

# The look of the desktop: a soft dark wallpaper, flat dark window frames in the
# dock's colours, dark Files. All of it is drawn once (no gradients, shadows or
# animations to repaint over VNC), so it costs nothing while the desktop is idle.
THEME_DIR="$HOME/.themes/Tradera/openbox-3"
write_theme() {
  mkdir -p "$THEME_DIR" "$HOME/.config/openbox" 2>/dev/null || return 0
  cat >"$THEME_DIR/themerc.new" <<'THEME'
# Tradera: flat, dark, quiet.
border.width: 3
padding.width: 14
padding.height: 8
window.handle.width: 0
window.client.padding.width: 0
menu.overlap: 2
menu.border.width: 1
menu.border.color: #0f1a17
*.justify: center

window.active.border.color: #243b34
window.inactive.border.color: #1a2a25
window.active.title.bg: Flat Solid
window.active.title.bg.color: #243b34
window.active.title.separator.color: #243b34
window.inactive.title.bg: Flat Solid
window.inactive.title.bg.color: #1a2a25
window.inactive.title.separator.color: #1a2a25
window.active.label.bg: Parentrelative
window.inactive.label.bg: Parentrelative
window.active.label.text.color: #e8f2ee
window.inactive.label.text.color: #7f968c
window.active.handle.bg: Flat Solid
window.active.handle.bg.color: #243b34
window.inactive.handle.bg: Flat Solid
window.inactive.handle.bg.color: #1a2a25
window.active.grip.bg: Flat Solid
window.active.grip.bg.color: #243b34
window.inactive.grip.bg: Flat Solid
window.inactive.grip.bg.color: #1a2a25

window.active.button.unpressed.bg: Parentrelative
window.active.button.unpressed.image.color: #aac3b9
window.active.button.hover.bg: Flat Solid
window.active.button.hover.bg.color: #36564b
window.active.button.hover.image.color: #ffffff
window.active.button.pressed.bg: Flat Solid
window.active.button.pressed.bg.color: #4a7567
window.active.button.pressed.image.color: #ffffff
window.active.button.disabled.bg: Parentrelative
window.active.button.disabled.image.color: #4f6a5f
window.active.button.toggled.unpressed.bg: Parentrelative
window.active.button.toggled.unpressed.image.color: #7be0a6
window.active.button.toggled.hover.bg: Flat Solid
window.active.button.toggled.hover.bg.color: #36564b
window.active.button.toggled.hover.image.color: #ffffff
window.active.button.toggled.pressed.bg: Flat Solid
window.active.button.toggled.pressed.bg.color: #4a7567
window.active.button.toggled.pressed.image.color: #ffffff
window.inactive.button.unpressed.bg: Parentrelative
window.inactive.button.unpressed.image.color: #6e857b
window.inactive.button.hover.bg: Flat Solid
window.inactive.button.hover.bg.color: #2a423a
window.inactive.button.hover.image.color: #e8f2ee
window.inactive.button.pressed.bg: Flat Solid
window.inactive.button.pressed.bg.color: #36564b
window.inactive.button.pressed.image.color: #ffffff
window.inactive.button.disabled.bg: Parentrelative
window.inactive.button.disabled.image.color: #46594f
window.inactive.button.toggled.unpressed.bg: Parentrelative
window.inactive.button.toggled.unpressed.image.color: #6e857b
window.inactive.button.toggled.hover.bg: Flat Solid
window.inactive.button.toggled.hover.bg.color: #2a423a
window.inactive.button.toggled.hover.image.color: #e8f2ee
window.inactive.button.toggled.pressed.bg: Flat Solid
window.inactive.button.toggled.pressed.bg.color: #36564b
window.inactive.button.toggled.pressed.image.color: #ffffff

menu.title.bg: Flat Solid
menu.title.bg.color: #243b34
menu.title.text.color: #e8f2ee
menu.title.text.justify: Left
menu.items.bg: Flat Solid
menu.items.bg.color: #1a2a25
menu.items.text.color: #dbe8e2
menu.items.disabled.text.color: #5f776c
menu.items.active.bg: Flat Solid
menu.items.active.bg.color: #36564b
menu.items.active.text.color: #ffffff
menu.separator.color: #36564b

osd.border.width: 1
osd.border.color: #0f1a17
osd.bg: Flat Solid
osd.bg.color: #1a2a25
osd.label.bg: Parentrelative
osd.label.text.color: #e8f2ee
osd.hilight.bg: Flat Solid
osd.hilight.bg.color: #36564b
osd.unhilight.bg: Flat Solid
osd.unhilight.bg.color: #243b34
THEME
  if ! cmp -s "$THEME_DIR/themerc.new" "$THEME_DIR/themerc" 2>/dev/null; then
    mv -f "$THEME_DIR/themerc.new" "$THEME_DIR/themerc"
  else
    rm -f "$THEME_DIR/themerc.new"
  fi
}

# Openbox's own settings: the packaged defaults with this theme, calm fonts, no
# window icon and no iconify animation. A window being resized is redrawn when it is let go.
write_openbox_config() {
  local base=/etc/xdg/openbox/rc.xml out="$HOME/.config/openbox/rc.xml"
  [ -f "$base" ] || return 0
  python3 - "$base" "$out.new" <<'PYRC' || { rm -f "$out.new"; return 0; }
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r"(<theme>\s*<name>)[^<]*(</name>)", r"\1Tradera\2", s, count=1)
s = s.replace("<titleLayout>NLIMC</titleLayout>", "<titleLayout>LIMC</titleLayout>")
s = s.replace("<animateIconify>yes</animateIconify>", "<animateIconify>no</animateIconify>")
s = re.sub(r"(<resize>\s*<drawContents>)yes(</drawContents>)", r"\1no\2", s, count=1)
# The window buttons are as tall as the title's text, so a larger title font is
# what makes them easier to hit with a finger (9 points gave 12 px buttons).
for place, size in (("ActiveWindow", 13), ("InactiveWindow", 13), ("MenuHeader", 10), ("MenuItem", 10)):
    s = re.sub(r'(<font place="%s">\s*<name>)[^<]*(</name>\s*<size>)[^<]*(</size>.*?<weight>)[^<]*(</weight>)' % place,
               r"\g<1>DejaVu Sans\g<2>%d\g<3>normal\g<4>" % size, s, count=1, flags=re.S)
open(sys.argv[2], "w").write(s)
PYRC
  if ! cmp -s "$out.new" "$out" 2>/dev/null; then
    mv -f "$out.new" "$out"
    pgrep -x openbox >/dev/null && openbox --reconfigure >/dev/null 2>&1
  else
    rm -f "$out.new"
  fi
}

# Files and other GTK apps: dark, and no animations to redraw over VNC.
write_gtk_settings() {
  mkdir -p "$HOME/.config/gtk-3.0" 2>/dev/null || return 0
  cat >"$HOME/.config/gtk-3.0/settings.ini" <<'GTK'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-enable-animations=false
gtk-font-name=DejaVu Sans 10
GTK
}

# The wallpaper is made once per computer (a soft teal glow on deep green) and
# painted onto the root window, where it costs nothing to keep.
WALLPAPER=/tmp/tradera-wallpaper-v2.png
set_wallpaper() {
  if have convert && have display; then
    [ -s "$WALLPAPER" ] || convert -size 1440x900 gradient:"#143630-#0a1514" \
      \( -size 1800x1300 radial-gradient:"#3f9a86-black" -crop 1440x900+0+0 +repage -evaluate multiply 0.42 \) -compose screen -composite \
      \( -size 1800x1300 radial-gradient:"#2f6f9f-black" -crop 1440x900+360+400 +repage -evaluate multiply 0.34 \) -compose screen -composite \
      -depth 8 "$WALLPAPER" 2>/dev/null
    if [ -s "$WALLPAPER" ]; then
      # `display -window root` paints the root and then exits with status 1.
      display -window root "$WALLPAPER" >/dev/null 2>&1
      return 0
    fi
  fi
  xsetroot -solid '#14302b'
}

# Files (Thunar) is made for a person's own computer. On this one, everything runs
# as root, so it would greet every window with "you are using the root account",
# and it ends its status line with the free space of whatever disk the machine
# sits on, which is not the project's storage and only confuses. A small preload
# (loaded into Files alone, not into anything else) leaves both out; copying and
# moving files are unaffected.
FILES_SHIM=/tmp/tradera-files.so
FILES_LAUNCHER=/usr/local/bin/tradera-thunar
# The app's viewer of the desktop (DESKTOP_VIEWER): the screen alone, scaled
# to fit its window, reconnecting by itself. Its fragment carries the
# password (#password=…) and, for a live preview, view=1 (no input). Written
# next to noVNC on every start, so older images get it too; best effort.
VIEWER_PAGE=tradera-view.html
write_viewer() {
  cat >"$1/$VIEWER_PAGE.tmp" <<'HTML' && mv -f "$1/$VIEWER_PAGE.tmp" "$1/$VIEWER_PAGE"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>Computer</title>
<style>
  :root { --bg: #0b0d10; --fg: #e8ecef; --muted: #9aa4ad; --accent: #7be0a6; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--fg);
    font: 13px/1.4 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; overflow: hidden;
    -webkit-user-select: none; user-select: none; -webkit-tap-highlight-color: transparent; }
  #screen { position: absolute; inset: 0; }
  #screen > div { background: transparent !important; }
  #veil { position: absolute; inset: 0; display: flex; flex-direction: column; gap: 12px;
    align-items: center; justify-content: center; background: var(--bg); transition: opacity .25s; }
  #veil.gone { opacity: 0; pointer-events: none; }
  .spin { width: 26px; height: 26px; border-radius: 50%; border: 2.5px solid #ffffff22;
    border-top-color: var(--accent); animation: r .8s linear infinite; }
  @keyframes r { to { transform: rotate(360deg); } }
  #msg { color: var(--muted); text-align: center; max-width: 80%; }
  button { font: inherit; color: var(--bg); background: var(--accent); border: 0; border-radius: 999px;
    padding: 7px 16px; font-weight: 600; cursor: pointer; }
  #keys { position: absolute; right: 12px; bottom: 12px; display: none; width: 42px; height: 42px;
    border-radius: 50%; background: #1d2228cc; color: var(--fg); padding: 0; backdrop-filter: blur(8px);
    box-shadow: 0 4px 16px #0006; font-size: 18px; }
  body.touch:not(.view) #keys { display: block; }
  #kbd { position: absolute; left: -100px; top: 0; width: 1px; height: 1px; opacity: 0; }
  body.view, body.view * { cursor: default !important; }
</style>
</head>
<body>
<div id="screen"></div>
<div id="veil"><div class="spin" id="spin"></div><div id="msg">Connecting to the desktop…</div><button id="retry" hidden>Reconnect</button></div>
<button id="keys" title="Keyboard" aria-label="Keyboard">⌨</button>
<input id="kbd" autocapitalize="off" autocomplete="off" autocorrect="off" spellcheck="false">
<script type="module">
import RFB from './core/rfb.js';
const params = new URLSearchParams(location.hash.slice(1));
const password = params.get('password') || '';
const view = params.get('view') === '1';
document.body.classList.toggle('view', view);
document.body.classList.toggle('touch', matchMedia('(pointer: coarse)').matches);
const veil = document.getElementById('veil'), msg = document.getElementById('msg');
const spin = document.getElementById('spin'), retry = document.getElementById('retry');
const ws = new URL('websockify', location.href);
ws.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
const token = new URLSearchParams(location.search).get('token');
ws.search = token ? '?token=' + encodeURIComponent(token) : '';
ws.hash = '';
let rfb = null, tries = 0, timer = 0, refused = false;
function show(text, failed) {
  msg.textContent = text; spin.hidden = !!failed; retry.hidden = !failed || view;
  veil.classList.remove('gone');
}
function connect() {
  clearTimeout(timer);
  show(tries ? 'Reconnecting…' : 'Connecting to the desktop…');
  try {
    rfb = new RFB(document.getElementById('screen'), ws.href, { credentials: { password }, shared: true });
  } catch (e) { return later(); }
  rfb.scaleViewport = true; rfb.resizeSession = false; rfb.clipViewport = false;
  rfb.viewOnly = view; rfb.showDotCursor = !view; rfb.focusOnClick = !view;
  rfb.qualityLevel = view ? 4 : 7; rfb.compressionLevel = view ? 6 : 2;
  rfb.background = getComputedStyle(document.body).backgroundColor;
  rfb.addEventListener('connect', () => { tries = 0; veil.classList.add('gone'); if (!view) rfb.focus(); });
  rfb.addEventListener('disconnect', () => { rfb = null; later(); });
  rfb.addEventListener('securityfailure', () => { refused = true; });
  rfb.addEventListener('credentialsrequired', () => rfb.sendCredentials({ password }));
  rfb.addEventListener('clipboard', (e) => { if (!view && navigator.clipboard) navigator.clipboard.writeText(e.detail.text).catch(() => {}); });
}
function later() {
  tries++;
  // A new password (the desktop was restarted): the app opens it afresh.
  if (refused) return show('The desktop asked for a new password. Close and open the computer again.', true);
  if (tries > 8 && !view) return show('The desktop is not answering.', true);
  show('Reconnecting…');
  timer = setTimeout(connect, Math.min(8000, 600 * 2 ** Math.min(tries, 4)));
}
retry.onclick = () => { tries = 0; refused = false; connect(); };
document.addEventListener('visibilitychange', () => { if (!document.hidden && !rfb) { tries = 0; connect(); } });
// Pasting into the page types into the desktop's clipboard.
document.addEventListener('paste', (e) => {
  const text = e.clipboardData && e.clipboardData.getData('text/plain');
  if (rfb && !view && text) rfb.clipboardPasteFrom(text);
});
// Phones have no keyboard to press: a hidden field brings up theirs and
// sends what is typed as key presses.
const kbd = document.getElementById('kbd');
document.getElementById('keys').onclick = () => kbd.focus();
const KEYS = { Backspace: 0xff08, Enter: 0xff0d, Tab: 0xff09, Escape: 0xff1b,
  ArrowLeft: 0xff51, ArrowUp: 0xff52, ArrowRight: 0xff53, ArrowDown: 0xff54 };
kbd.addEventListener('keydown', (e) => {
  if (rfb && KEYS[e.key]) { rfb.sendKey(KEYS[e.key], e.key); e.preventDefault(); }
});
kbd.addEventListener('input', () => {
  if (rfb) for (const ch of kbd.value) {
    const cp = ch.codePointAt(0);
    rfb.sendKey(cp < 0x100 ? cp : 0x1000000 + cp);
  }
  kbd.value = '';
});
// Theme messages of the app are not needed: the screen is the screen.
window.__traderaSetTheme = () => {};
connect();
</script>
</body>
</html>
HTML
}

write_files_launcher() {
  have thunar || return 0
  if [ ! -s "$FILES_SHIM" ]; then
    local cc src=/tmp/tradera-files.c
    cc=$(command -v cc || command -v gcc) || cc=""
    if [ -n "$cc" ]; then
      cat >"$src" <<'CSHIM'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <sys/types.h>

/* Files shows its root warning to a root process only. */
uid_t geteuid(void) { return 1000; }

/* Files adds "Free space" to its status line when the disk reports it. */
typedef int (*has_attribute_fn)(void *, const char *);
int g_file_info_has_attribute(void *info, const char *attribute) {
  static has_attribute_fn real;
  if (!real) real = (has_attribute_fn)dlsym(RTLD_NEXT, "g_file_info_has_attribute");
  if (attribute && strcmp(attribute, "filesystem::free") == 0) return 0;
  return real(info, attribute);
}
CSHIM
      "$cc" -shared -fPIC -O1 -o "$FILES_SHIM.new" "$src" -ldl 2>/dev/null && mv -f "$FILES_SHIM.new" "$FILES_SHIM"
      rm -f "$src" "$FILES_SHIM.new"
    fi
  fi
  {
    echo '#!/bin/sh'
    echo "[ -s $FILES_SHIM ] && export LD_PRELOAD=\"$FILES_SHIM\${LD_PRELOAD:+:\$LD_PRELOAD}\""
    # In the background, so a program that opens a folder is not kept waiting for the window to close.
    echo "setsid -f $(command -v thunar | grep -v "^$FILES_LAUNCHER\$" || echo /usr/bin/thunar) \"\$@\" >/dev/null 2>&1 </dev/null"
  } >"$FILES_LAUNCHER" 2>/dev/null && chmod +x "$FILES_LAUNCHER"
  # Files opened from other programs (xdg-open, a double-click) start through it too.
  local entry=/usr/share/applications/thunar.desktop apps="$HOME/.local/share/applications"
  if [ -f "$entry" ] && mkdir -p "$apps" 2>/dev/null; then
    sed "s#^Exec=thunar#Exec=$FILES_LAUNCHER#" "$entry" >"$apps/thunar.desktop"
  fi
}
# The file manager's command: the launcher once it is written.
files_manager() { if [ -x "$FILES_LAUNCHER" ]; then echo "$FILES_LAUNCHER"; elif have thunar; then echo thunar; fi; }

# Windows with rounded corners (X Shape), done by a small helper that only wakes
# when a window opens or is resized.
write_corners() {
  mkdir -p "$STATE"
  cat >"$STATE/corners.py.new" <<'PYCORNERS'
#!/usr/bin/env python3
"""tradera corners: rounds the corners of the desktop's windows (X Shape).

It only reacts to windows being mapped or resized, so it costs nothing while the
desktop is idle. A window that fills the screen keeps square corners."""
import ctypes
import select
import sys
import time

RADIUS = 10
MIN_W, MIN_H = 80, 50

x11 = ctypes.CDLL("libX11.so.6")
xext = ctypes.CDLL("libXext.so.6")
vp, ul, ci, cu = ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_uint


class Attrs(ctypes.Structure):
    _fields_ = [("x", ci), ("y", ci), ("width", ci), ("height", ci), ("border_width", ci), ("depth", ci),
                ("visual", vp), ("root", ul), ("cls", ci), ("bit_gravity", ci), ("win_gravity", ci),
                ("backing_store", ci), ("backing_planes", ul), ("backing_pixel", ul), ("save_under", ci),
                ("colormap", ul), ("map_installed", ci), ("map_state", ci), ("all_event_masks", ctypes.c_long),
                ("your_event_mask", ctypes.c_long), ("do_not_propagate_mask", ctypes.c_long),
                ("override_redirect", ci), ("screen", vp)]


class Configure(ctypes.Structure):
    _fields_ = [("type", ci), ("serial", ul), ("send_event", ci), ("display", vp), ("event", ul), ("window", ul),
                ("x", ci), ("y", ci), ("width", ci), ("height", ci), ("border_width", ci), ("above", ul),
                ("override_redirect", ci)]


class MapEvent(ctypes.Structure):
    _fields_ = [("type", ci), ("serial", ul), ("send_event", ci), ("display", vp), ("event", ul), ("window", ul),
                ("override_redirect", ci)]


x11.XOpenDisplay.restype, x11.XOpenDisplay.argtypes = vp, [ctypes.c_char_p]
x11.XDefaultRootWindow.restype, x11.XDefaultRootWindow.argtypes = ul, [vp]
x11.XSelectInput.argtypes = [vp, ul, ctypes.c_long]
x11.XNextEvent.argtypes = [vp, vp]
x11.XCreatePixmap.restype, x11.XCreatePixmap.argtypes = ul, [vp, ul, cu, cu, cu]
x11.XCreateGC.restype, x11.XCreateGC.argtypes = vp, [vp, ul, ul, vp]
x11.XSetForeground.argtypes = [vp, vp, ul]
x11.XFillRectangle.argtypes = [vp, ul, vp, ci, ci, cu, cu]
x11.XFillArc.argtypes = [vp, ul, vp, ci, ci, cu, cu, ci, ci]
x11.XFreePixmap.argtypes = [vp, ul]
x11.XFreeGC.argtypes = [vp, vp]
x11.XFlush.argtypes = [vp]
x11.XPending.argtypes = [vp]
x11.XConnectionNumber.argtypes = [vp]
x11.XGetWindowAttributes.argtypes = [vp, ul, ctypes.POINTER(Attrs)]
x11.XQueryTree.argtypes = [vp, ul, ctypes.POINTER(ul), ctypes.POINTER(ul), ctypes.POINTER(vp), ctypes.POINTER(cu)]
x11.XFree.argtypes = [vp]
x11.XDisplayWidth.argtypes = x11.XDisplayHeight.argtypes = [vp, ci]
xext.XShapeCombineMask.argtypes = [vp, ul, ci, ci, ci, ul, ci]

ERRHANDLER = ctypes.CFUNCTYPE(ci, vp, vp)
x11.XSetErrorHandler.argtypes = [ERRHANDLER]
ignore_errors = ERRHANDLER(lambda _d, _e: 0)  # a window can vanish between an event and our reply
x11.XSetErrorHandler(ignore_errors)

dpy = x11.XOpenDisplay(None)
if not dpy:
    sys.exit(1)
root = x11.XDefaultRootWindow(dpy)
SW, SH = x11.XDisplayWidth(dpy, 0), x11.XDisplayHeight(dpy, 0)


def mask(w, h):
    r = min(RADIUS, w // 2, h // 2)
    pix = x11.XCreatePixmap(dpy, root, w, h, 1)
    gc = x11.XCreateGC(dpy, pix, 0, None)
    x11.XSetForeground(dpy, gc, 0)
    x11.XFillRectangle(dpy, pix, gc, 0, 0, w, h)
    x11.XSetForeground(dpy, gc, 1)
    x11.XFillRectangle(dpy, pix, gc, r, 0, w - 2 * r, h)
    x11.XFillRectangle(dpy, pix, gc, 0, r, w, h - 2 * r)
    for ax in (0, w - 2 * r):
        for ay in (0, h - 2 * r):
            x11.XFillArc(dpy, pix, gc, ax, ay, 2 * r, 2 * r, 0, 360 * 64)
    x11.XFreeGC(dpy, gc)
    return pix


def shape(win, x, y, w, h):
    """Round a window, or give it square corners when it fills the screen."""
    if w < MIN_W or h < MIN_H:
        return
    if x <= 0 and y <= 0 and x + w >= SW and y + h >= SH - 1:
        xext.XShapeCombineMask(dpy, win, 0, 0, 0, 0, 0)  # no mask: the whole window again
        return
    pix = mask(w, h)
    xext.XShapeCombineMask(dpy, win, 0, 0, 0, pix, 0)
    x11.XFreePixmap(dpy, pix)


def on_desktop(win):
    """True for a window that is a direct child of the root: a frame, not a client inside one."""
    top, parent, kids, n = ul(0), ul(0), vp(), cu(0)
    if not x11.XQueryTree(dpy, win, ctypes.byref(top), ctypes.byref(parent), ctypes.byref(kids), ctypes.byref(n)):
        return False
    if kids:
        x11.XFree(kids)
    return parent.value == root


def apply(win):
    a = Attrs()
    if on_desktop(win) and x11.XGetWindowAttributes(dpy, win, ctypes.byref(a)) and not a.override_redirect and a.map_state == 2 and a.cls == 1:
        shape(win, a.x, a.y, a.width + 2 * a.border_width, a.height + 2 * a.border_width)


# The window manager resets a frame's shape each time it lays the frame out, just
# after telling us about it. So a window is shaped once things have settled.
SETTLE = 0.05
due = {}  # window -> when to shape it


def adopt(win):
    due[win] = time.monotonic() + SETTLE


x11.XSelectInput(dpy, root, 1 << 19)  # SubstructureNotify: the windows on the desktop
top, parent, kids, n = ul(0), ul(0), vp(), cu(0)
if x11.XQueryTree(dpy, root, ctypes.byref(top), ctypes.byref(parent), ctypes.byref(kids), ctypes.byref(n)) and kids:
    for win in (ul * n.value).from_address(kids.value):
        apply(win)
    x11.XFree(kids)
x11.XFlush(dpy)

fd = x11.XConnectionNumber(dpy)
event = ctypes.create_string_buffer(192)
while True:
    while x11.XPending(dpy):
        x11.XNextEvent(dpy, event)
        kind = ctypes.cast(event, ctypes.POINTER(ci))[0]
        if kind == 22:  # ConfigureNotify
            e = Configure.from_buffer(event)
            if e.event == root and e.window != root and not e.override_redirect:
                adopt(e.window)
        elif kind == 19:  # MapNotify
            e = MapEvent.from_buffer(event)
            if e.event == root and not e.override_redirect:
                adopt(e.window)
        elif kind == 17:  # DestroyNotify
            due.pop(Configure.from_buffer(event).window, None)
    now = time.monotonic()
    for win in [w for w, t in due.items() if t <= now]:
        del due[win]
        apply(win)
    x11.XFlush(dpy)
    wait = max(0.0, min(due.values()) - time.monotonic()) if due else None
    select.select([fd], [], [], wait)
PYCORNERS
  if ! cmp -s "$STATE/corners.py.new" "$STATE/corners.py" 2>/dev/null; then
    mv -f "$STATE/corners.py.new" "$STATE/corners.py"
    pkill -f "$STATE/corners.py" 2>/dev/null
  else
    rm -f "$STATE/corners.py.new"
  fi
}
start_corners() {
  have python3 || return 0
  write_corners
  pgrep -f "$STATE/corners.py" >/dev/null || detach python3 "$STATE/corners.py"
}

# The dock: Terminal, Browser and Files as three icons in a small rounded bar at
# the bottom (the hovered icon is highlighted, a dot under what is open). It is
# part of the desktop, not of the apps: windows cover it, and it shows again when
# they are closed or minimized. It never animates or changes size. It is a Tk
# program; a computer whose image has no Tk gets a plain tint2 panel instead.
write_dock() {
  mkdir -p "$STATE"
  cat >"$STATE/dock.py.new" <<'PY'
#!/usr/bin/env python3
"""tradera dock: Terminal, Browser (Chrome), Files."""
import ctypes
import subprocess
import tkinter as tk

BG = "#1b4a43"      # roughly the wallpaper: what shows in the corners where the window is not shaped
PILL = "#243b34"
HOVER = "#36564b"
ICON, GAP, PAD, RADIUS = 40, 10, 9, 18
ITEMS = [
    ("terminal", "Terminal", r"^xterm|^uxterm"),
    ("browser", "Browser", r"chromium|chrome"),
    ("files", "Files", r"^thunar|^pcmanfm"),
]
N = len(ITEMS)
PILL_W = N * ICON + (N - 1) * GAP + 2 * PAD
PILL_H = ICON + 2 * PAD
WIN_W, WIN_H = PILL_W, PILL_H   # the window is exactly the bar: no margin, no wallpaper around it

root = tk.Tk(className="TraderaDock")
root.title("Dock")
root.overrideredirect(True)
root.configure(bg=BG)
sw, sh = root.winfo_screenwidth(), root.winfo_screenheight()
canvas = tk.Canvas(root, width=WIN_W, height=WIN_H, bg=BG, highlightthickness=0, bd=0)
canvas.pack()
state = {"open": set(), "hover": None, "press": None}
root.geometry("%dx%d+%d+%d" % (WIN_W, WIN_H, (sw - WIN_W) // 2, sh - WIN_H - 8))


def round_window():
    """Cut the window's corners away (X Shape extension), so they are not drawn at all."""
    try:
        x11 = ctypes.CDLL("libX11.so.6")
        xext = ctypes.CDLL("libXext.so.6")
        vp, ul, ci = ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int
        x11.XOpenDisplay.restype, x11.XOpenDisplay.argtypes = vp, [ctypes.c_char_p]
        x11.XCreatePixmap.restype, x11.XCreatePixmap.argtypes = ul, [vp, ul, ctypes.c_uint, ctypes.c_uint, ctypes.c_uint]
        x11.XCreateGC.restype, x11.XCreateGC.argtypes = vp, [vp, ul, ul, vp]
        x11.XSetForeground.argtypes = [vp, vp, ul]
        x11.XFillRectangle.argtypes = [vp, ul, vp, ci, ci, ctypes.c_uint, ctypes.c_uint]
        x11.XFillArc.argtypes = [vp, ul, vp, ci, ci, ctypes.c_uint, ctypes.c_uint, ci, ci]
        x11.XQueryTree.argtypes = [vp, ul, ctypes.POINTER(ul), ctypes.POINTER(ul), ctypes.POINTER(vp), ctypes.POINTER(ctypes.c_uint)]
        x11.XFree.argtypes = [vp]
        xext.XShapeCombineMask.argtypes = [vp, ul, ci, ci, ci, ul, ci]
        dpy = x11.XOpenDisplay(None)
        if not dpy:
            return
        root.update()
        w, h, r = WIN_W, WIN_H, RADIUS
        pix = x11.XCreatePixmap(dpy, root.winfo_id(), w, h, 1)
        gc = x11.XCreateGC(dpy, pix, 0, None)
        x11.XSetForeground(dpy, gc, 0)
        x11.XFillRectangle(dpy, pix, gc, 0, 0, w, h)
        x11.XSetForeground(dpy, gc, 1)
        x11.XFillRectangle(dpy, pix, gc, r, 0, w - 2 * r, h)
        x11.XFillRectangle(dpy, pix, gc, 0, r, w, h - 2 * r)
        for ax in (0, w - 2 * r):
            for ay in (0, h - 2 * r):
                x11.XFillArc(dpy, pix, gc, ax, ay, 2 * r, 2 * r, 0, 360 * 64)
        # Shape the window and the frame Tk wraps around it.
        win = root.winfo_id()
        while win:
            xext.XShapeCombineMask(dpy, win, 0, 0, 0, pix, 0)
            top, parent, kids, n = ul(0), ul(0), vp(), ctypes.c_uint(0)
            if not x11.XQueryTree(dpy, win, ctypes.byref(top), ctypes.byref(parent), ctypes.byref(kids), ctypes.byref(n)):
                break
            if kids:
                x11.XFree(kids)
            if not parent.value or parent.value == top.value:
                break
            win = parent.value
        x11.XFlush.argtypes = [vp]
        x11.XFlush(dpy)
    except Exception:
        pass  # without the extension the corners are the wallpaper's colour


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
    left = PAD + ICON / 2
    return [left + i * (ICON + GAP) for i in range(N)]


def render():
    canvas.delete("all")
    rrect(0, 0, WIN_W, WIN_H, RADIUS, fill=PILL, outline="")
    for i, cx in enumerate(centers()):
        if state["hover"] == i:
            rrect(cx - ICON / 2 - 4, PAD - 4, cx + ICON / 2 + 4, WIN_H - PAD + 4, 8, fill=HOVER, outline="")
        size = ICON * 0.9 if state["press"] == i else ICON
        DRAW[ITEMS[i][0]](cx, WIN_H - PAD - (ICON - size) / 2, size)
        if ITEMS[i][0] in state["open"]:
            canvas.create_oval(cx - 2, WIN_H - 6, cx + 2, WIN_H - 2, fill="#e8f1ed", outline="")


def hit(e):
    for i, cx in enumerate(centers()):
        if abs(e.x - cx) <= ICON / 2 + GAP / 2:
            return i
    return None


def on_move(e):
    i = hit(e)
    if i != state["hover"]:
        state["hover"] = i
        render()


def on_leave(_e):
    state["hover"] = None
    state["press"] = None
    render()


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
    # Stay beneath the apps, and mark what is open.
    try:
        root.lower()  # part of the desktop: apps cover it
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
render()
round_window()
root.lower()
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
  pkill -f "$STATE/corners.py" 2>/dev/null
  rm -f /tmp/tradera-wallpaper.set
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
  configure_default_apps
  write_theme
  write_openbox_config
  write_gtk_settings
  write_files_launcher
  chmod 700 /tmp/runtime-desktop
  export XDG_RUNTIME_DIR=/tmp/runtime-desktop

  fresh_x=0
  x_up || fresh_x=1
  x_up || { rm -f /tmp/.X99-lock /tmp/.X11-unix/X99; detach Xvfb "$DISPLAY" -screen 0 1440x900x24 -nolisten tcp; }
  for _ in $(seq 1 40); do x_up && break; sleep 0.25; done
  x_up || { echo "the X server did not start:" >&2; tail -n 15 "$LOG" >&2; return 1; }

  pgrep -x openbox >/dev/null || detach openbox
  for _ in $(seq 1 40); do wm_up && break; sleep 0.25; done
  wm_up || { echo "the desktop window manager did not start" >&2; tail -n 15 "$LOG" >&2; return 1; }
  xsetroot -cursor_name left_ptr
  if [ "$fresh_x" = 1 ] || [ ! -e /tmp/tradera-wallpaper.set ]; then
    set_wallpaper && touch /tmp/tradera-wallpaper.set
  fi
  start_corners
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
    write_viewer "$web" 2>/dev/null && echo "DESKTOP_VIEWER:$VIEWER_PAGE"
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
  forget-logins)
    # Closes the browser first, so it cannot write the sessions back.
    pkill -f -- "--user-data-dir=$BROWSER_PROFILE" 2>/dev/null
    sleep 1
    rm -rf "$BROWSER_PROFILE" /tmp/tradera-browser
    echo "the browser's saved logins are erased"
    ;;
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
      files)
        fm=$(files_manager); [ -n "$fm" ] && { detach "$fm" /workspace; exit 0; }
        have pcmanfm && { detach pcmanfm /workspace; exit 0; }
        exit 1 ;;
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
      http://*|https://*|about:*|file:*) ;;
      *)
        # A folder opens in Files; any other file opens in the browser.
        if [ -d "$target" ]; then
          fm=$(files_manager); [ -n "$fm" ] || { echo "no file manager is installed on this computer" >&2; exit 1; }
          detach "$fm" "$target"; echo "opened $target"; exit 0
        fi
        [ -f "$target" ] && target=$(file_url "$target") ;;
    esac
    case "$target" in
      http://*|https://*|about:*|file:*)
        more=()
        for a in "$@"; do if [ -e "$a" ]; then more+=("$(file_url "$a")"); else more+=("$a"); fi; done
        for b in chromium chromium-browser google-chrome firefox-esr firefox; do
          have "$b" || continue
          profile="$BROWSER_PROFILE"
          if ! { mkdir -p "$profile" && chmod 700 "$profile" "$(dirname "$profile")"; } 2>/dev/null; then
            profile=/tmp/tradera-browser
            mkdir -p "$profile"
          fi
          # A machine that slept or was rebuilt leaves the old browser's lock
          # behind, and Chromium refuses a profile that looks in use elsewhere.
          pgrep -f -- "--user-data-dir=$profile" >/dev/null 2>&1 || rm -f "$profile"/SingletonLock "$profile"/SingletonSocket "$profile"/SingletonCookie
          case "$b" in
            chromium*|google-chrome) detach "$b" --user-data-dir="$profile" --no-sandbox --disable-dev-shm-usage --disable-gpu --no-first-run --no-default-browser-check --password-store=basic --start-maximized "$target" ${more[@]+"${more[@]}"} ;;
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
