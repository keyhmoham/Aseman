/**
 * Gadgets: App UIs hosted as compact frameless free-position widgets.
 *
 * A gadget is exactly the same as a desk App UI (appui_create / appui_publish),
 * with these differences: (1) compact like a mobile home-screen widget — dense,
 * glanceable, not a full window layout; (2) no window frame / background pad —
 * any custom shape; right-click or long-press opens minimise / close / …;
 * (3) free positioning over chat, left rail or desk (space) or universal over
 * home and workspaces (account / platform, when built in the person's Aseman).
 *
 * Agents create them with create_gadget (preferred shorthand) or
 * appui_create { kind: "gadget", … }, then appui_publish. list_gadgets shows
 * what is already registered. Only the person removes gadgets from the
 * gadgets handle — agents do not remove or restore them.
 */

import { defineTool, params } from './define.js'

export const CREATOR_GUIDE = `## App UI hosting: window vs gadget
One App UI pipeline (\`appui_create\` / \`appui_publish\`, AGENTS.md, ELPIAN.md,
aseman-appui verify, Elpian or web) has two hosting modes:

### Window mode (\`kind: "app"\`, default)
Framed desk card window with title bar, resize and pin. Use for multi-screen
workspaces, docked software, and anything that needs a full window of UI.

### Gadget mode (\`kind: "gadget"\`)
A **compact widget**, not a window:
1. **No frame** — no window chrome, background pad or title bar; the screen
   may take any custom shape (not necessarily a rectangle). Right-click or
   long-press opens its menu (minimise, close, open as page). Drag from the
   top grabber to move.
2. **Very compact** — like a mobile home-screen widget: show only the
   necessary live facts and controls; dense, glanceable layout; do not fill
   the screen or ship a multi-pane app chrome. Prefer a small fixed footprint.
3. **Free positioning** — floats over the whole workspace (left panel, chat
   and desk share one layer) or as a "page"; \`placement\` is a size hint,
   not a cage. People manage them from the gadgets handle on the screen's
   right edge. Made in the person's own Aseman (home) it is a **platform /
   universal** gadget across every home tab and over workspaces; made in a
   space or DM it belongs to that space.

When to make lasting UI: when the person asks for an interface, tracker,
board, dashboard, form, graphical screen or lasting tool. Not for a one-off
answer, a static table or a file. If they did not ask, answer first, then
offer with ask_user ("Create it" / "Not now") and build only on yes. Prefer
gadget mode for glanceable trackers and status surfaces; window mode for
full workspaces. One gadget or window per need: check list_gadgets first;
to change one, \`create_gadget\` / \`appui_create\` again with its existing dir.

How to build a gadget:
1. \`create_gadget\` with a complete brief (and \`placement\`, optional \`title\` /
   \`ui\`) — or \`appui_create\` with \`kind: "gadget"\` and the same fields. Same
   project layout as a desk app (guides, SDKs, APPS.json, server key). State
   in the brief that the UI must stay compact like a mobile widget.
2. Build, test and drive it end to end with \`aseman-elpian\` as AGENTS.md
   says; write READY.json.
3. \`appui_publish\` with the dir: the platform verifies it and registers the
   frameless gadget (or answers with what to fix).
Desk software that should open as a framed card window uses \`appui_create\`
with \`kind: "app"\` (the default). \`list_gadgets\` shows what is registered;
only the person removes gadgets from the edge handle — do not remove them.`

function gadgets(out) {
  const list = out.gadgets ?? out.plugins ?? []
  if (!list.length) return 'No gadgets here yet.'
  return list
    .map((p) => `- ${p.name} (${p.id}; ${p.scope === 'account' ? 'universal gadget' : 'this space'}, ${p.placement}, ${p.ui || 'elpian'}): ${String(p.description ?? '').slice(0, 160)}`)
    .join('\n')
}

/** Space the turn can build App UIs / gadgets on (room space or personal home). */
function spaceOf(b) {
  return String(b?.spaceId || b?.computerSpace || '').trim()
}

export function creatorTools({ gateway, binding }) {
  return [
    defineTool({
      name: 'create_gadget',
      binding,
      timeoutMs: 300000,
      description:
        'Start a compact frameless gadget (App UI with kind=gadget): prepares the project ' +
        'and returns the build task. Then build, write READY.json, and call appui_publish with the dir. ' +
        'Same pipeline as appui_create; use this when the person asked for a gadget / widget / lasting compact screen. ' +
        'The generated UI must be compact like a mobile widget (no window frame, small footprint).',
      parameters: params({
        brief: { type: 'string', description: 'Complete request: what to build, for whom, features and data, which apps/agents it uses, what done means. Remind that the UI must stay compact like a mobile widget.' },
        name: { type: 'string', description: 'Short title when brief is omitted (becomes the brief).' },
        description: { type: 'string', description: 'Optional one-line purpose; folded into the brief when brief is set.' },
        title: { type: 'string', description: 'Gadget title.' },
        placement: { type: 'string', enum: ['chat', 'rail', 'desk', 'page'], description: 'Size hint: chat (default), rail, desk or page. Account gadgets from Aseman chat are universal.' },
        ui: { type: 'string', enum: ['elpian', 'web'], description: 'elpian (default) or web (only when the person asked for web / 3D / rich viz).' },
        dir: { type: 'string', description: 'Existing project dir under /workspace to change in place.' },
        apps: { type: 'array', items: { type: 'string' }, description: 'Space apps to wire.' },
        agents: { type: 'array', items: { type: 'string' }, description: 'Space agents the gadget may ask.' },
      }),
      async run(args, { signal }) {
        const b = binding()
        const space = spaceOf(b)
        if (!space) throw new Error('create_gadget: this conversation has no computer to build on')
        const brief = String(args.brief || '').trim()
          || [args.name, args.description].filter(Boolean).map(String).join(': ').trim()
        if (!brief) throw new Error('create_gadget needs brief (or name) — what to build')
        const body = {
          brief,
          kind: 'gadget',
          placement: args.placement || 'chat',
        }
        if (args.title || args.name) body.title = String(args.title || args.name).trim()
        if (args.ui) body.ui = args.ui
        if (args.dir) body.dir = args.dir
        if (Array.isArray(args.apps) && args.apps.length) body.apps = args.apps
        if (Array.isArray(args.agents) && args.agents.length) body.agents = args.agents
        const res = await gateway.call(b.token, 'spaces', 'ask', {
          space, room: b.roomId || undefined, tool: 'appui_create', args: body,
        }, { signal })
        return res.result ?? res.reply ?? res
      },
    }),
    defineTool({
      name: 'list_gadgets',
      binding,
      concurrent: true,
      description: 'The gadgets here: the person\'s universal gadgets and this space\'s.',
      parameters: params({}),
      async run(_args, { signal }) {
        const b = binding()
        return gadgets(await gateway.call(b.token, 'tools', 'gadget_list', { space: b.spaceId || b.computerSpace || undefined }, { signal }))
      },
    }),
  ]
}
