# Gadgets (compact App UI mode)

A gadget is **exactly the same as an App UI**, built with `appui_create` /
`appui_publish` (see `AGENTS.md`, `ELPIAN.md`), hosted in **gadget mode**.
Desk software uses **window mode** (`kind: "app"`). Gadgets use
`kind: "gadget"`.

## First rule of gadget mode

The generated app must be **compact like a mobile home-screen widget**:

1. **No window frame** — no title bar, chrome, or background pad. The screen
   may take any custom shape (not necessarily a square or rectangle).
2. **Very compact** — show only the necessary live facts and controls. Dense,
   glanceable layout. Do not take much space on screen. Do not ship a
   multi-pane window layout, navigation rail, or full-app chrome.
3. **Free positioning** — floats over the workspace (left panel, chat and
   desk share one layer) or as a page; `placement` is a size hint, not a
   cage. Made in the person's own Aseman it is a universal / platform gadget
   across every home tab and over workspaces.

Desk apps keep framed card windows; gadgets stay frameless compact widgets.

## How to build

```text
appui_create {
  "brief": "… (state that the UI must stay compact like a mobile widget)",
  "title": "…",
  "kind": "gadget",
  "placement": "chat" | "rail" | "desk" | "page",
  "ui": "elpian"          // or "web" only when the person asked for web / 3D
}
```

Or the shorthand `create_gadget` with the same fields. Then build, test and
drive the project end to end with `aseman-elpian` as `AGENTS.md` says, write
`READY.json`, and call `appui_publish` with the dir. The platform verifies
the app and registers the frameless gadget.

Desk software that should open as a framed card window uses the same tools
with `kind: "app"` (the default).

`list_gadgets` shows what is already registered. Only the person removes
gadgets from the gadgets handle on the right edge of the screen (home:
universal / platform gadgets; workspace: those plus the space's). Agents
create gadgets; they do not remove or restore them.
