# Plugins (frameless App UIs)

A plugin is **exactly the same as an App UI**, built with `appui_create` /
`appui_publish` (see `AGENTS.md`, `ELPIAN.md`), with only two differences:

1. **No frame** — no window chrome, background pad or title bar, so the
   screen can take any custom shape. Right-click or long-press opens its
   menu (minimise, close, open as page, move).
2. **Free positioning** — over chat, the space's left rail, or the desk
   (`placement`), or as a page; made in the person's own Aseman it is a
   universal / platform gadget across home and workspaces.

## How to build

```text
appui_create {
  "brief": "…",
  "title": "…",
  "kind": "plugin",
  "placement": "chat" | "rail" | "desk" | "page",
  "ui": "elpian"          // or "web" only when the person asked for web / 3D
}
```

Then build, test and drive the project end to end with `aseman-elpian` as
`AGENTS.md` says, write `READY.json`, and call `appui_publish` with the dir.
The platform verifies the app and registers the frameless gadget.

Desk software that should open as a framed card window uses the same tools
with `kind: "app"` (the default).

`list_plugins` / `remove_plugin` / `restore_plugin` manage what is already
registered. People open every plugin from the plugins handle on the right
edge of the screen.
