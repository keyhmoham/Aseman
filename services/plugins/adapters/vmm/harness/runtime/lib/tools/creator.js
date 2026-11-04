/**
 * Plugins: App UIs hosted as frameless free-position gadgets.
 *
 * A plugin is exactly the same as a desk App UI (appui_create / appui_publish),
 * with two differences: (1) no window frame / background pad — any custom
 * shape; right-click or long-press opens minimise / close / …; (2) free
 * positioning over chat, left rail or desk (space) or universal over home and
 * workspaces (account / platform, when built in the person's Aseman).
 *
 * Agents create them with create_plugin (preferred shorthand) or
 * appui_create { kind: "plugin", … }, then appui_publish. list / remove /
 * restore manage what is already registered.
 */

import { defineTool, params } from './define.js'

export const CREATOR_GUIDE = `## Plugins (frameless App UIs)
A plugin is **exactly the same as an App UI**, built with the same
\`appui_create\` / \`appui_publish\` pipeline (AGENTS.md, ELPIAN.md, aseman-appui
verify, Elpian or web), with only two differences:

1. **No frame** — no window chrome, background pad or title bar, so the
   screen can take any custom shape. Right-click or long-press opens its
   menu (minimise, close, open as page, move).
2. **Free positioning** — over the conversation ("chat"), the space's left
   panel ("rail"), the room's desk ("desk"), or as a "page"; people manage
   them from the plugins handle on the screen's right edge. Made in the
   person's own Aseman (home) it is a **platform / universal** gadget across
   home tabs and over workspaces; made in a space or DM it belongs to that
   space.

When to make one: when the person asks for an interface, tracker, board,
dashboard, form, graphical screen or lasting tool — the same cases as an App
UI. Not for a one-off answer, a static table or a file. If they did not ask,
answer first, then offer with ask_user ("Create it" / "Not now") and build
only on yes. One plugin per need: check list_plugins first; to change one,
\`create_plugin\` / \`appui_create\` again with its existing dir.

How to build:
1. \`create_plugin\` with a complete brief (and \`placement\`, optional \`title\` /
   \`ui\`) — or \`appui_create\` with \`kind: "plugin"\` and the same fields. Same
   project layout as a desk app (guides, SDKs, APPS.json, server key).
2. Build, test and drive it end to end with \`aseman-elpian\` as AGENTS.md
   says; write READY.json.
3. \`appui_publish\` with the dir: the platform verifies it and registers the
   frameless gadget (or answers with what to fix).
Desk software that should open as a framed card window uses \`appui_create\`
with \`kind: "app"\` (the default). list_plugins / remove_plugin /
restore_plugin manage what is already registered.`

function plugins(out) {
  const list = out.plugins ?? []
  if (!list.length) return 'No plugins here yet.'
  return list
    .map((p) => `- ${p.name} (${p.id}; ${p.scope === 'account' ? 'universal gadget' : 'this space'}, ${p.placement}, ${p.ui || 'elpian'}${p.status === 'removed' ? ', removed' : ''}): ${String(p.description ?? '').slice(0, 160)}`)
    .join('\n')
}

/** Space the turn can build App UIs / plugins on (room space or personal home). */
function spaceOf(b) {
  return String(b?.spaceId || b?.computerSpace || '').trim()
}

export function creatorTools({ gateway, binding }) {
  return [
    defineTool({
      name: 'create_plugin',
      binding,
      timeoutMs: 300000,
      description:
        'Start a frameless free-position plugin (App UI with kind=plugin): prepares the project ' +
        'and returns the build task. Then build, write READY.json, and call appui_publish with the dir. ' +
        'Same pipeline as appui_create; use this when the person asked for a plugin / gadget / lasting screen.',
      parameters: params({
        brief: { type: 'string', description: 'Complete request: what to build, for whom, features and data, which apps/agents it uses, what done means.' },
        name: { type: 'string', description: 'Short title when brief is omitted (becomes the brief).' },
        description: { type: 'string', description: 'Optional one-line purpose; folded into the brief when brief is set.' },
        title: { type: 'string', description: 'Plugin title (window / gadget name).' },
        placement: { type: 'string', enum: ['chat', 'rail', 'desk', 'page'], description: 'Where it floats: chat (default), rail, desk or page. Account plugins from Aseman chat are universal.' },
        ui: { type: 'string', enum: ['elpian', 'web'], description: 'elpian (default) or web (only when the person asked for web / 3D / rich viz).' },
        dir: { type: 'string', description: 'Existing project dir under /workspace to change in place.' },
        apps: { type: 'array', items: { type: 'string' }, description: 'Space apps to wire.' },
        agents: { type: 'array', items: { type: 'string' }, description: 'Space agents the plugin may ask.' },
      }),
      async run(args, { signal }) {
        const b = binding()
        const space = spaceOf(b)
        if (!space) throw new Error('create_plugin: this conversation has no computer to build on')
        const brief = String(args.brief || '').trim()
          || [args.name, args.description].filter(Boolean).map(String).join(': ').trim()
        if (!brief) throw new Error('create_plugin needs brief (or name) — what to build')
        const body = {
          brief,
          kind: 'plugin',
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
      name: 'list_plugins',
      binding,
      concurrent: true,
      description: 'The plugins here: the person\'s universal gadgets and this space\'s (removed ones too, to restore).',
      parameters: params({}),
      async run(_args, { signal }) {
        const b = binding()
        return plugins(await gateway.call(b.token, 'tools', 'plugin_list', { space: b.spaceId || b.computerSpace || undefined, removed: true }, { signal }))
      },
    }),
    defineTool({
      name: 'remove_plugin',
      binding,
      description: 'Remove a plugin (the person can have it restored).',
      parameters: params({ plugin: { type: 'string' } }, ['plugin']),
      async run({ plugin }, { signal }) {
        const b = binding()
        await gateway.call(b.token, 'tools', 'plugin_remove', { plugin }, { signal })
        return 'removed'
      },
    }),
    defineTool({
      name: 'restore_plugin',
      binding,
      description: 'Restore a removed plugin.',
      parameters: params({ plugin: { type: 'string' } }, ['plugin']),
      async run({ plugin }, { signal }) {
        const b = binding()
        await gateway.call(b.token, 'tools', 'plugin_restore', { plugin }, { signal })
        return 'restored'
      },
    }),
  ]
}
