/**
 * Memory tools and the project timeline.
 *
 * Memory has three layers:
 *   - notes: short, curated, always in context — the space's shared notes and
 *     the agent's own (in personal chat: the person's notes with Aseman);
 *   - long-term memories: facts, preferences, decisions and how things were
 *     done, kept by the node in Postgres with pgvector and recalled by
 *     meaning (the node embeds with the admin's memory embedding model and
 *     bills the project). The node also learns them from finished turns;
 *   - dsh's own session search over earlier conversations in the same space
 *     (session_search & co, from dsh-tool-session-query).
 * The timeline is the project's dated record (requests and outcomes, tools
 * run, messages, files, members, rooms, routines, usage), read-only.
 */

import { defineTool, params } from './define.js'
import { wrap } from '../untrusted.js'

export function memoryTools({ gateway, binding }) {
  const usable = () => {
    const b = binding()
    if (b?.flags?.no_memory) throw new Error('memory is disabled for this request')
    return b
  }
  return [
    defineTool({
      name: 'remember',
      binding,
      description:
        'Keep something worth knowing later (a preference, a decision, a fact about a person or the project, how a ' +
        'task was done). shared=true keeps it for every agent of the space; otherwise it is yours.',
      parameters: params({
        text: { type: 'string' },
        shared: { type: 'boolean' },
        kind: { type: 'string', enum: ['fact', 'preference', 'decision', 'procedure', 'person', 'event'] },
      }, ['text']),
      async run({ text, shared = false, kind }, { signal }) {
        const b = usable()
        await gateway.post(b.token, '/memory/remember', { text: String(text), shared: Boolean(shared), kind }, { signal })
        return 'remembered'
      },
    }),
    defineTool({
      name: 'recall',
      binding,
      concurrent: true,
      description: 'Search your long-term memory (yours and the space\'s) by meaning.',
      parameters: params({ query: { type: 'string' }, limit: { type: 'integer' } }, ['query']),
      async run({ query, limit = 8 }, { signal }) {
        const b = usable()
        const out = await gateway.post(b.token, '/memory/recall', { query: String(query), limit: Math.min(Math.max(Number(limit) || 8, 1), 30) }, { signal })
        return formatMemories(out.items) || 'Nothing in memory about that.'
      },
    }),
    defineTool({
      name: 'rewrite_notes',
      binding,
      description:
        'Replace your notes (always in your context) with a new version. Keep them short and current: conventions, ' +
        'standing decisions, where things are. shared=true rewrites the space\'s shared notes instead.',
      parameters: params({ content: { type: 'string' }, shared: { type: 'boolean' } }, ['content']),
      async run({ content, shared = false }, { signal }) {
        const b = usable()
        await gateway.post(b.token, '/memory/notes', { content: String(content), shared: Boolean(shared) }, { signal })
        if (b.notes) b.notes[shared ? 'space' : 'own'] = String(content)
        return 'notes updated'
      },
    }),
  ]
}

export function timelineTools({ gateway, binding }) {
  return [
    defineTool({
      name: 'timeline_search',
      binding,
      concurrent: true,
      description:
        'Search the project\'s dated timeline: requests and how they ended, tools run, messages, files, members, rooms, ' +
        'routines, usage. Filter by words, kinds and a time range (ISO dates). Use it whenever a question turns on time.',
      parameters: params({
        query: { type: 'string' },
        kinds: { type: 'array', items: { type: 'string' } },
        since: { type: 'string' },
        until: { type: 'string' },
        limit: { type: 'integer' },
      }),
      async run(args, { signal }) {
        const b = binding()
        const out = await gateway.post(b.token, '/timeline/search', args, { signal })
        const items = out.items ?? []
        if (!items.length) return 'Nothing on the timeline matches.'
        return wrap('project timeline', items.map((e) => `${e.at} [${e.kind}] ${e.summary}${e.id ? ` (${e.id})` : ''}`).join('\n'))
      },
    }),
    defineTool({
      name: 'timeline_entry',
      binding,
      concurrent: true,
      description: 'One timeline entry in full, with the entries recorded around it.',
      parameters: params({ id: { type: 'string' } }, ['id']),
      async run({ id }, { signal }) {
        const b = binding()
        const out = await gateway.post(b.token, '/timeline/entry', { id: String(id) }, { signal })
        return wrap('project timeline', JSON.stringify(out, null, 1))
      },
    }),
  ]
}

export function formatMemories(items) {
  if (!Array.isArray(items) || !items.length) return ''
  return items
    .map((m) => `- ${m.shared ? '[space] ' : ''}${m.kind ? `(${m.kind}) ` : ''}${String(m.text).trim()}${m.at ? ` — ${String(m.at).slice(0, 10)}` : ''}`)
    .join('\n')
}
