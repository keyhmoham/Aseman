## App UI hosting: window vs gadget
One App UI pipeline (`appui_create` / `appui_publish`, AGENTS.md, ELPIAN.md,
decillion-appui verify, Elpian or web) has two hosting modes:

### Window mode (`kind: "app"`, default)
Framed desk card window with title bar, resize and pin. Use for multi-screen
workspaces, docked software, and anything that needs a full window of UI.

### Gadget mode (`kind: "gadget"`)
A **compact widget**, not a window:
1. **No frame** — no window chrome, background pad or title bar; the screen
   may take any custom shape (not necessarily a rectangle). Right-click or
   long-press opens its menu (minimise, close, open as page). Drag from the
   top grabber to move.
2. **Very compact** — like a mobile home-screen widget: show only the
   necessary live facts and controls; dense, glanceable layout; do not fill
   the screen or ship a multi-pane app chrome. Prefer a small fixed footprint.
3. **Free positioning** — floats over the whole workspace (left panel, chat
   and desk share one layer) or as a "page"; `placement` is a size hint,
   not a cage. People manage them from the gadgets handle on the screen's
   right edge. Made in the person's own Decillion (home) it is a **platform /
   universal** gadget across every home tab and over workspaces; made in a
   space or DM it belongs to that space.

When to make lasting UI: when the person asks for an interface, tracker,
board, dashboard, form, graphical screen or lasting tool. Not for a one-off
answer, a static table or a file. If they did not ask, answer first, then
offer with ask_user ("Create it" / "Not now") and build only on yes. Prefer
gadget mode for glanceable trackers and status surfaces; window mode for
full workspaces. One gadget or window per need: check list_gadgets first;
to change one, `create_gadget` / `appui_create` again with its existing dir.

How to build a gadget:
1. `create_gadget` with a complete brief (and `placement`, optional `title` /
   `ui`) — or `appui_create` with `kind: "gadget"` and the same fields. Same
   project layout as a desk app (guides, SDKs, APPS.json, server key). State
   in the brief that the UI must stay compact like a mobile widget.
2. Build, test and drive it end to end with `decillion-elpian` as AGENTS.md
   says; write READY.json.
3. `appui_publish` with the dir: the platform verifies it and registers the
   frameless gadget (or answers with what to fix).
Desk software that should open as a framed card window uses `appui_create`
with `kind: "app"` (the default). `list_gadgets` shows what is registered;
only the person removes gadgets from the edge handle — do not remove them.