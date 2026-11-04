/**
 * Creator mode: agents make plugins for people.
 *
 * A plugin is a screen (and, when it needs one, a small backend) the Aseman
 * app shows as a floating gadget or a page. Made in a person's own Aseman chat
 * it is theirs — a universal gadget across home tabs and workspaces; made in a
 * room, thread or direct chat it belongs to that space and its members,
 * floating on chat, the left rail, or the desk (or as a page). The node decides
 * the scope from the turn (tools.plugin_create) and gates everything the screen
 * calls (tools.plugin_call).
 *
 * The screen is Elpian by default — native Flutter UI in the person's theme,
 * written with the Aseman Elpian SDK — and web as the fallback for 3D, rich
 * visualization, or when the person asked for web: one self-contained HTML
 * document in the app's sandboxed web frame. Before a plugin reaches the node,
 * create_plugin checks it the way the app runs it, with aseman-plugin-check on
 * the conversation's computer (PLUGINS.md in the computer's Elpian kit), and
 * sends the findings back to fix.
 */

import vm from 'node:vm'
import { posix } from 'node:path'
import { defineTool, params } from './define.js'
import { Computer, computerOf, absolute, shq } from './sandbox.js'

export const KIT = '/opt/aseman-appui/elpian'
const MAX_WEB_DOCUMENT = 6 << 20
const MAX_PROGRAM = 1 << 20

export const CREATOR_GUIDE = `## Plugins (Creator mode)
A plugin is a small app of its own that stays: a screen the Aseman app shows as
a floating gadget on the conversation (placement "chat"), on the space's left
panel ("rail"), on the room's desk ("desk"), or as a page ("page"); people
manage them all from the plugins handle on the screen's right edge. Made in a
person's own Aseman chat it is theirs everywhere; made in a room, thread or
direct chat it belongs to that space, shared by its members.

When to make one: when the person asks for an interface, a tracker, a board,
a dashboard, a form or a tool to keep using; or when a result has a clear
later use the answer cannot give (keeping a record, exploring changing data).
Not for a one-off answer, a static table or a file. If the person did not ask
for it, answer first, then offer it with ask_user (options "Create it" and
"Not now") and build it only on yes. One plugin per need: check list_plugins
first and change an existing one (create_plugin with its id).

Choose the UI (ui):
- "elpian" (default): native UI in the person's theme on every device — forms,
  lists, trackers, boards, calendars, dashboards with standard charts.
- "web" (say why in ui_reason): the design needs 3D (Three.js / WebGL scenes,
  globes, model viewers, 3D charts); the person asked for web technology; or
  it needs rich, professional visualization Elpian draws poorly (interactive
  maps, dense or animated charts with ECharts / D3, node graphs, rich text or
  code editors, canvas animation). When in doubt, Elpian.

Elpian draws most things with one node, live and themed — use it, never a
picture made of Text: an analog or digital clock is {type: "Clock", props:
{mode: "analog", seconds: true, size: 240}} (it ticks by itself); a countdown
"Countdown"; a dial or level "Gauge" / "RadialBars" / "Progress"; trends and
parts "Chart" (line, bar, area, pie, radar …), "Sparkline", "Funnel",
"Sankey"; key numbers "Stat"; boards and dates "Kanban", "Gantt", "Calendar",
"Timeline"; records "ListGroup" of "ListTile", "DataGrid". Any other picture
is a "Canvas" of vector commands (fillCircle, arc, moveTo/lineTo, stroke,
fillText) in the theme's colors — or a web plugin for 3D. Rows of Text holding
dots, bullets, slashes or emoji are refused by the check.

Build it like software, on the computer, to a professional standard:
1. Read ${KIT}/PLUGINS.md (the plugin guide, with a complete example). For
   Elpian also read the Design section and the node tables of
   ${KIT}/ELPIAN.md and look at ${KIT}/examples/showcase.js; look props up
   with \`aseman-elpian elpian_describe '{"types":["Card"]}'\` and icons with
   \`aseman-elpian elpian_icons '{"query":"…"}'\` instead of guessing.
2. Write it in /workspace/.plugins/<name>/: frontend.js (Elpian: App.create
   from the SDK, Aseman.plugin.get/set/call/api/context; Material 3 Expressive
   — type roles, tonal cards, theme colors, every state designed) or
   index.html (web: one self-contained document, libraries bundled with
   esbuild and inlined with aseman-plugin-inline, the person's theme from the
   --aseman-* CSS variables, responsive from 360 px phones to desk windows;
   it never uses the network — data only through Aseman.plugin), and
   backend.js if it needs more than get/set.
3. Check it: \`aseman-plugin-check <file> [--backend backend.js]
   [--permissions a.b,c.*] [--screenshots shots]\`; fix every error, and for
   web look at the screenshots with read_image.
4. create_plugin with frontend_file (and backend_file): it runs the same check
   and refuses a plugin that fails. Then tell the person where it is.
Only the platform actions listed in permissions ("spaces.message_list",
"routines.*") work, as the person using the plugin; a space's plugin stays in
its space. Without a computer, pass the Elpian program inline in frontend
(web plugins need the computer).`

/** Parse a program as JavaScript; the error the model should fix, or ''. */
export function syntaxError(source, label) {
  try {
    new vm.Script(String(source), { filename: label })
    return ''
  } catch (error) {
    return `${label}: ${error.message}`
  }
}

/** Whether source is an HTML document rather than a script. */
export function looksLikeHTML(source) {
  const head = String(source ?? '').trim().slice(0, 512).toLowerCase()
  return head.startsWith('<!doctype html') || head.startsWith('<html') || head.includes('<head') || head.includes('<body')
}

/** The UI a plugin is made in: the one asked for, else what its frontend is. */
export function pluginUI(ui, frontend, file = '') {
  const asked = String(ui ?? '').trim().toLowerCase()
  if (asked === 'elpian' || asked === 'web') return asked
  if (asked) throw new Error('ui is "elpian" (native, the default) or "web"')
  return /\.html?$/i.test(String(file)) || looksLikeHTML(frontend) ? 'web' : 'elpian'
}

/** What is wrong with a plugin before anything runs it (the model fixes these). */
export function quickProblems({ ui, frontend, backend, uiReason }) {
  const problems = []
  if (ui === 'web') {
    if (!looksLikeHTML(frontend)) problems.push('frontend: a web plugin is one HTML document (<!doctype html><html>…)')
    if (Buffer.byteLength(String(frontend)) > MAX_WEB_DOCUMENT) problems.push('frontend: the document is larger than 6 MB (libraries included): import only what it uses and minify')
    if (!String(uiReason ?? '').trim()) problems.push('ui_reason: say why this plugin is web rather than Elpian (3D, asked for web, or a rich visualization Elpian draws poorly)')
  } else {
    if (looksLikeHTML(frontend)) problems.push('frontend: this is an HTML document: make it ui "web", or write the screen as an Elpian program')
    else {
      const bad = syntaxError(frontend, 'frontend')
      if (bad) problems.push(bad)
      else if (!/askHost\(\s*['"]render['"]|\bApp\.create\s*\(/.test(String(frontend))) problems.push('frontend: it never renders (build it with App.create({state, view}))')
    }
    if (String(frontend).length > MAX_PROGRAM) problems.push('frontend: the program is larger than 1 MB')
  }
  if (backend) {
    const bad = syntaxError(backend, 'backend')
    if (bad) problems.push(bad)
  }
  return problems
}

/** The checker's verdict from its --json output, or null when it did not run. */
export function parseCheck(code, output) {
  if (code === 127 || /aseman-plugin-check: (command )?not found/.test(output)) return null
  const line = String(output).trim().split('\n').reverse().find((l) => l.trim().startsWith('{'))
  if (!line) return null
  try {
    const r = JSON.parse(line)
    return Array.isArray(r.errors) ? r : null
  } catch {
    return null
  }
}

function listed(title, items, max) {
  if (!items?.length) return ''
  const shown = items.slice(0, max).map((i) => `- ${i}`).join('\n')
  return `\n${title}:\n${shown}${items.length > max ? `\n- … ${items.length - max} more` : ''}`
}

/** Runs aseman-plugin-check on the computer: its verdict, or null when it cannot run there. */
async function checkOnComputer(pc, { ui, frontend, backend, frontendFile, backendFile, permissions, name, description }, signal) {
  const dir = `/workspace/.plugins/.check-${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`
  const written = []
  try {
    let front = frontendFile
    if (!front) {
      front = posix.join(dir, ui === 'web' ? 'index.html' : 'frontend.js')
      await pc.write(front, Buffer.from(String(frontend), 'utf8'), signal)
      written.push(front)
    }
    let back = backendFile
    if (!back && backend) {
      back = posix.join(dir, 'backend.js')
      await pc.write(back, Buffer.from(String(backend), 'utf8'), signal)
      written.push(back)
    }
    const args = [shq(front), '--ui', ui, '--json', '--name', shq(name || 'Plugin')]
    if (description) args.push('--description', shq(description))
    if (back) args.push('--backend', shq(back))
    if (permissions.length) args.push('--permissions', shq(permissions.join(',')))
    const { code, output } = await pc.exec(`aseman-plugin-check ${args.join(' ')} 2>&1`, signal)
    return parseCheck(code, output)
  } finally {
    if (written.length) await pc.exec(`rm -rf ${shq(dir)}`, signal).catch(() => {})
  }
}

function plugins(out) {
  const list = out.plugins ?? []
  if (!list.length) return 'No plugins here yet.'
  return list
    .map((p) => `- ${p.name} (${p.id}; ${p.scope === 'account' ? 'universal gadget' : 'this space'}, ${p.placement}, ${p.ui || 'elpian'}${p.status === 'removed' ? ', removed' : ''}): ${String(p.description ?? '').slice(0, 160)}`)
    .join('\n')
}

export function creatorTools({ gateway, binding }) {
  const pc = new Computer(gateway, binding)
  const hasComputer = (b) => Boolean(computerOf(b)) && !b.flags?.no_sandbox
  return [
    defineTool({
      name: 'create_plugin',
      binding,
      timeoutMs: 300000,
      description:
        'Create a plugin for the person (or, with plugin, change one): its screen (Elpian by default; web for 3D, rich ' +
        'visualization or when web was asked for), an optional backend, where it shows and the platform actions its ' +
        'screen may call. Build it in files on the computer and pass frontend_file; it is checked the way the app runs ' +
        'it and refused with the findings when it would break. See "Plugins (Creator mode)".',
      parameters: params({
        name: { type: 'string' },
        description: { type: 'string', description: 'What it is for, in one sentence.' },
        ui: { type: 'string', enum: ['elpian', 'web'], description: 'elpian (native, the default) or web (3D, rich visualization, or web asked for).' },
        ui_reason: { type: 'string', description: 'For ui "web": why web rather than Elpian.' },
        placement: { type: 'string', enum: ['chat', 'rail', 'page', 'desk'], description: 'chat = conversation gadget; rail = left panel; desk = desk gadget; page = full page. Account plugins from Aseman chat are universal gadgets.' },
        permissions: { type: 'array', items: { type: 'string' }, description: 'Platform actions the screen calls: "namespace.action" or "namespace.*".' },
        frontend_file: { type: 'string', description: 'The screen on the computer: an Elpian program (.js) or a web document (.html).' },
        frontend: { type: 'string', description: 'The screen inline, when there is no computer: an Elpian program.' },
        backend_file: { type: 'string', description: 'Optional backend program on the computer (tools() and one function per tool).' },
        backend: { type: 'string', description: 'Optional backend program inline.' },
        plugin: { type: 'string', description: 'An existing plugin id, to change it.' },
      }, ['name', 'description']),
      async run(args, { signal }) {
        const b = binding()
        const computer = hasComputer(b)
        const frontendFile = args.frontend_file ? absolute(args.frontend_file) : ''
        const backendFile = args.backend_file ? absolute(args.backend_file) : ''
        if ((frontendFile || backendFile) && !computer) throw new Error('this conversation has no computer: pass the Elpian program inline in frontend')
        let frontend = String(args.frontend ?? '')
        if (frontendFile) frontend = (await pc.read(frontendFile, signal)).toString('utf8')
        if (!frontend.trim()) throw new Error('give the screen: frontend_file (a file on the computer) or frontend')
        const backend = backendFile ? (await pc.read(backendFile, signal)).toString('utf8') : String(args.backend ?? '')
        const ui = pluginUI(args.ui, frontend, frontendFile)
        if (ui === 'web' && !computer) throw new Error('a web plugin is built and checked on a computer, and this conversation has none: make it in Elpian')
        const permissions = Array.isArray(args.permissions) ? args.permissions.map(String) : []

        const problems = quickProblems({ ui, frontend, backend, uiReason: args.ui_reason })
        if (problems.length) throw new Error(`fix the plugin before creating it:\n${problems.join('\n')}`)

        let verdict = null
        if (computer) {
          verdict = await checkOnComputer(pc, { ui, frontend, backend, frontendFile, backendFile, permissions, name: args.name, description: args.description }, signal)
          if (verdict && !verdict.ok) {
            throw new Error(`the plugin check failed (aseman-plugin-check, as the app runs it); fix these and create it again:` +
              listed('errors', verdict.errors, 30) + listed('warnings', verdict.warnings, 10))
          }
        }

        const out = await gateway.call(b.token, 'tools', 'plugin_create', {
          plugin: args.plugin || undefined,
          name: args.name,
          description: args.description,
          placement: args.placement,
          ui,
          permissions,
          frontend: ui === 'web'
            ? { source: frontend, runtime: 'web', language: 'html' }
            : { source: frontend, runtime: 'quickjs', language: 'js' },
          backend: backend.trim() ? { source: backend, runtime: 'quickjs', language: 'js' } : undefined,
        }, { signal })
        const p = out.plugin ?? {}
        const where = p.scope === 'account'
          ? 'as a universal floating gadget across home and workspaces'
          : `as a ${p.placement || 'chat'} gadget in this space for all its members`
        const checked = verdict
          ? ` Checked as the app runs it${verdict.warnings?.length ? `; worth improving:${listed('warnings', verdict.warnings, 8)}${listed('design notes', verdict.notes, 6)}` : '.'}`
          : computer ? ' (the computer has no plugin checker yet: only the program\'s syntax was checked)' : ''
        return `${args.plugin ? 'Changed' : 'Created'} ${ui} plugin ${p.name} (${p.id}), ${p.placement}, ${where}.${checked}`
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
        return plugins(await gateway.call(b.token, 'tools', 'plugin_list', { space: b.spaceId || undefined, removed: true }, { signal }))
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
