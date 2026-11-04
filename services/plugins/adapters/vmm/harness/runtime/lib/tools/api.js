/**
 * The whole Aseman API, for everything the dedicated tools do not cover.
 *
 * The node serves the turn a catalog of the platform actions it may call
 * (spaces, rooms and threads, files and media, apps and tools, agents, users,
 * routines, the desk, the market, themes, posts, …): every action the node
 * routes, minus administration, authentication and money movement, each with
 * its summary. A call is dispatched as the turn's account — the agent in a
 * space, the person in their own assistant chat — so the action's own
 * permission check decides, exactly as for a person using the app.
 */

import { defineTool, params } from './define.js'
import { wrap } from '../untrusted.js'

/** A body schema in one line: `{space: string, tags: [string], when: {at: string}}`. */
export function bodyLine(schema, depth = 0) {
  if (!schema || typeof schema !== 'object') return 'any'
  switch (schema.type) {
    case 'object': {
      const props = schema.properties && typeof schema.properties === 'object' ? Object.entries(schema.properties) : []
      if (!props.length) return depth ? 'object' : '{}'
      if (depth > 2) return 'object'
      return `{${props.map(([k, v]) => `${k}: ${bodyLine(v, depth + 1)}`).join(', ')}}`
    }
    case 'array':
      return `[${bodyLine(schema.items, depth + 1)}]`
    case undefined:
      return 'any'
    default:
      return String(schema.type)
  }
}

export function apiTools({ gateway, binding }) {
  return [
    defineTool({
      name: 'aseman_api_search',
      binding,
      concurrent: true,
      description:
        'Find Aseman platform actions you can call with aseman_api_call (spaces, rooms, threads, files, apps, agents, ' +
        'users, routines, desk, market, themes, posts, …). Search by words; returns namespace.action, what each does and ' +
        'the fields its body takes (all optional unless the action says otherwise).',
      parameters: params({
        query: { type: 'string', description: 'What you want to do, in a few words.' },
        namespace: { type: 'string', description: 'Only this namespace.' },
      }, ['query']),
      async run({ query, namespace }, { signal }) {
        const b = binding()
        const q = new URLSearchParams({ q: String(query ?? '') })
        if (namespace) q.set('namespace', String(namespace))
        const out = await gateway.get(b.token, `/catalog?${q}`, { signal })
        const actions = out.actions ?? []
        if (!actions.length) return 'No callable action matches. Try other words.'
        return actions
          .map((a) => `${a.namespace}.${a.name}${a.summary ? ` — ${a.summary}` : ''}${a.input ? `\n    body: ${bodyLine(a.input)}` : ''}`)
          .join('\n')
      },
    }),
    defineTool({
      name: 'aseman_api_call',
      binding,
      description:
        'Call one Aseman platform action (find it with aseman_api_search) as yourself, with a JSON body. ' +
        'Your permissions in the space apply, as for a person using the app.',
      parameters: params({
        namespace: { type: 'string' },
        action: { type: 'string' },
        body: { type: 'object', description: 'The action\'s JSON body (space and room ids as needed).' },
      }, ['namespace', 'action']),
      async run({ namespace, action, body }, { signal }) {
        const b = binding()
        const out = await gateway.call(b.token, String(namespace), String(action), body && typeof body === 'object' ? body : {}, { signal })
        return wrap(`aseman ${namespace}.${action}`, JSON.stringify(out, null, 1))
      },
    }),
  ]
}
