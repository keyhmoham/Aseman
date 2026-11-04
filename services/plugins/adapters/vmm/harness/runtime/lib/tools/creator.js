/**
 * Creator mode: agents make plugins for people.
 *
 * A plugin is an Elpian screen (and, when it needs one, a small backend) the
 * Aseman app runs natively in the person's theme. Made in a person's own
 * Aseman chat it is theirs — a universal floating gadget across home tabs and
 * workspaces; made in a room, thread or direct chat it belongs to that space
 * and its members, floating on chat, the left rail, or the desk (or as a page).
 * The node decides the scope from the turn (tools.plugin_create) and gates
 * everything the screen calls (tools.plugin_call).
 */

import vm from 'node:vm'
import { defineTool, params } from './define.js'

export const CREATOR_GUIDE = `## Plugins (Creator mode)
A plugin is a small app of its own that stays: a screen the Aseman app draws
natively, in the person's theme, as a floating gadget on the conversation
(placement "chat"), on the space's left panel / nav drawer ("rail"), on the
room's desk ("desk"), or as a page of its own ("page"). Made in a person's own
Aseman chat it is theirs everywhere — a universal floating gadget across home
tabs and while they view workspaces; made in a room, thread or direct chat it
belongs to that space, shared by its members, mounted on the surface you pick.

When to make one: when the person asks for an interface, a tracker, a board,
a dashboard, a form or a tool to keep using; or when a result has a clear
later use the answer cannot give (keeping a record, exploring changing data).
Not for a one-off answer, a static table or a file. If the person did not ask
for it, answer first, then offer it with ask_user (options "Create it" and
"Not now") and build it only on yes. One plugin per need; check list_plugins
first and change an existing one (create_plugin with its id) rather than make
a second.

How to write it (create_plugin): the screen is one JavaScript program
(QuickJS). It draws by calling askHost('render', JSON.stringify(tree)) with a
node tree { type, props, children, events }: Column, Row, Text, Button,
TextField, Card, Image, Icon, ListView, plus the UI kit (Stat, Chart, DataGrid,
Gauge, KeyValue, Tag, Progress, ResponsiveGrid, Section, Timeline…). Events
name a global function: events: { tap: 'save' } calls save(event), whose
argument is the VM's typed value (unwrap .data.value). Render again after
every change. Host calls, each returning a JSON string:
- askHost('tool.call', [microtool, args]) — the plugin's own backend; without
  a backend of yours, 'get' {key} and 'set' {key, value} keep its data;
- askHost('aseman.call', [namespace, action, body]) — a platform action, as the
  person using the plugin; only the actions you list in permissions
  ("spaces.message_list", "routines.*") work, and a space's plugin stays in
  its space (the space is filled in for you);
- askHost('aseman.context', null) — {plugin, space, room, user, display}.
A backend (optional) is a JavaScript program declaring tools() (a list of
{name, description, input}) and one function per tool; it keeps state with
askHost('aseman.kv.get' | 'aseman.kv.set', {key, value}).
Keep it small and working: start from what the person needs most. After
create_plugin succeeds, tell the person where to find it (universal gadget,
chat / left panel / desk gadget, or page).`

/** Parse a program as JavaScript; the error the model should fix, or ''. */
export function syntaxError(source, label) {
  try {
    new vm.Script(String(source), { filename: label })
    return ''
  } catch (error) {
    return `${label}: ${error.message}`
  }
}

function plugins(out) {
  const list = out.plugins ?? []
  if (!list.length) return 'No plugins here yet.'
  return list
    .map((p) => `- ${p.name} (${p.id}; ${p.scope === 'account' ? 'universal gadget' : 'this space'}, ${p.placement}${p.status === 'removed' ? ', removed' : ''}): ${String(p.description ?? '').slice(0, 160)}`)
    .join('\n')
}

export function creatorTools({ gateway, binding }) {
  return [
    defineTool({
      name: 'create_plugin',
      binding,
      description:
        'Create a plugin for the person (or, with plugin, change one): its Elpian screen program, an optional backend ' +
        'program, where it shows as a floating gadget (or page) and the platform actions its screen may call. See "Plugins (Creator mode)".',
      parameters: params({
        name: { type: 'string' },
        description: { type: 'string', description: 'What it is for, in one sentence.' },
        placement: { type: 'string', enum: ['chat', 'rail', 'page', 'desk'], description: 'chat = conversation gadget; rail = left panel / nav drawer; desk = desk gadget; page = full page. Account plugins from Aseman chat are always universal floaters.' },
        permissions: { type: 'array', items: { type: 'string' }, description: 'Platform actions the screen calls: "namespace.action" or "namespace.*".' },
        frontend: { type: 'string', description: 'The screen: a JavaScript program that renders with askHost("render", …).' },
        backend: { type: 'string', description: 'Optional backend program (tools() and one function per tool).' },
        plugin: { type: 'string', description: 'An existing plugin id, to change it.' },
      }, ['name', 'description', 'frontend']),
      async run(args, { signal }) {
        const b = binding()
        const problems = [syntaxError(args.frontend, 'frontend'), args.backend ? syntaxError(args.backend, 'backend') : '']
          .filter(Boolean)
        if (!/askHost\(\s*['"]render['"]/.test(String(args.frontend))) problems.push('frontend: it never renders (askHost("render", JSON.stringify(tree)))')
        if (problems.length) throw new Error(`fix the program before creating the plugin:\n${problems.join('\n')}`)
        const out = await gateway.call(b.token, 'tools', 'plugin_create', {
          plugin: args.plugin || undefined,
          name: args.name,
          description: args.description,
          placement: args.placement,
          permissions: Array.isArray(args.permissions) ? args.permissions : [],
          frontend: { source: String(args.frontend), runtime: 'quickjs', language: 'js' },
          backend: args.backend ? { source: String(args.backend), runtime: 'quickjs', language: 'js' } : undefined,
        }, { signal })
        const p = out.plugin ?? {}
        const where = p.scope === 'account'
          ? 'as a universal floating gadget across home and workspaces'
          : `as a ${p.placement || 'chat'} gadget in this space for all its members`
        return `${args.plugin ? 'Changed' : 'Created'} plugin ${p.name} (${p.id}), ${p.placement}, ${where}.`
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
