/**
 * aseman-memory — DeepSeek Harness's own memory for Aseman agents.
 *
 * A Cordis plugin the Aseman engine mounts into dsh's headless profile. The
 * memory is the harness's, not the platform's: a store on the engine's disk,
 * one directory per space and one per agent in it:
 *
 *   <root>/AGENTS.md              the space's shared notes (every agent)
 *   <root>/.aseman-space          project-root marker for agent-instructions
 *   <root>/<agent>/AGENTS.md      the agent's own notes
 *   <root>/<agent>/journal/*.md   what happened, turn by turn (this plugin)
 *
 * The agent's turns run with <root>/<agent> as their working directory, so
 * dsh's own agent-instructions loader puts both notes files in context every
 * turn. This plugin adds the tools to keep them (memory_remember,
 * memory_rewrite, memory_search, memory_read) and journals each finished turn
 * from the Session's own events, so the memory learns without the platform.
 *
 * No imports: the plugin loads by path into whatever dsh is installed.
 */

import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { join, relative, resolve, sep } from 'node:path'

export const name = 'aseman-memory'
export const inject = ['tools']

const NOTES = 'AGENTS.md'
const MAX_READ = 24000
const MAX_NOTE = 2000
const MAX_JOURNAL_TEXT = 1500

function text(value) {
  return [{ type: 'text', text: String(value) }]
}

function tool(definition) {
  return {
    name: definition.name,
    description: definition.description,
    parameters: { type: 'object', additionalProperties: false, ...definition.parameters },
    output: { schema: { type: 'string' }, render: (_args, value) => text(value) },
    async execute(args) {
      try {
        return await definition.execute(args ?? {})
      } catch (error) {
        return `error: ${error instanceof Error ? error.message : String(error)}`
      }
    },
  }
}

function ensureFile(path, template) {
  if (!existsSync(path)) writeFileSync(path, template, { mode: 0o600 })
}

function inside(root, path) {
  const rel = relative(root, path)
  return rel === '' || (!rel.startsWith('..') && !rel.startsWith(sep) && !resolve(root, rel).includes('\0'))
}

function walk(dir, out = []) {
  let entries = []
  try { entries = readdirSync(dir, { withFileTypes: true }) } catch { return out }
  for (const entry of entries) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) walk(path, out)
    else if (entry.name.endsWith('.md')) out.push(path)
  }
  return out
}

function blocksText(content) {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content.filter(b => b && b.type === 'text' && typeof b.text === 'string').map(b => b.text).join('')
}

export function apply(ctx, config = {}) {
  const root = resolve(String(config.root || ''))
  const agent = String(config.agent || 'agent').replace(/[^A-Za-z0-9_.-]+/g, '-') || 'agent'
  const agentName = String(config.agentName || agent)
  if (!config.root) throw new Error('aseman-memory needs config.root')
  const own = join(root, agent)
  mkdirSync(join(own, 'journal'), { recursive: true })
  ensureFile(join(root, '.aseman-space'), '')
  ensureFile(join(root, NOTES), '# Space notes\n\nWhat every agent of this space should know.\n')
  ensureFile(join(own, NOTES), `# ${agentName} notes\n\nWhat ${agentName} keeps for later: preferences, decisions, conventions, people.\n`)
  const file = shared => join(shared ? root : own, NOTES)

  ctx.tools.register(tool({
    name: 'memory_remember',
    description: 'Save one self-contained fact, preference, decision or convention to your memory notes (they are in your context every turn). shared=true writes the space notes every agent of the space reads.',
    parameters: {
      properties: {
        note: { type: 'string', description: 'The note, one line.' },
        shared: { type: 'boolean', description: 'true: the space notes; false (default): your own.' },
      },
      required: ['note'],
    },
    execute({ note, shared }) {
      const line = String(note || '').split(/\s+/).join(' ').trim().slice(0, MAX_NOTE)
      if (!line) return 'error: nothing to remember'
      const path = file(Boolean(shared))
      const current = existsSync(path) ? readFileSync(path, 'utf8') : ''
      appendFileSync(path, `${current && !current.endsWith('\n') ? '\n' : ''}- ${line}\n`)
      return `saved to ${shared ? 'the space notes' : 'your notes'}`
    },
  }))

  ctx.tools.register(tool({
    name: 'memory_rewrite',
    description: 'Replace a whole notes file to condense it or correct what is no longer true.',
    parameters: {
      properties: {
        content: { type: 'string', description: 'The complete new notes (Markdown).' },
        shared: { type: 'boolean' },
      },
      required: ['content'],
    },
    execute({ content, shared }) {
      const body = String(content || '').trim()
      if (!body) return 'error: the notes would be empty'
      writeFileSync(file(Boolean(shared)), body + '\n')
      return `rewrote ${shared ? 'the space notes' : 'your notes'}`
    },
  }))

  ctx.tools.register(tool({
    name: 'memory_search',
    description: 'Search your memory: the space notes, your notes and your journal of earlier turns (newest first). Returns matching lines with their file; read more with memory_read.',
    parameters: {
      properties: {
        query: { type: 'string' },
        limit: { type: 'number', description: 'Most matches to return (default 20).' },
      },
      required: ['query'],
    },
    execute({ query, limit }) {
      const words = String(query || '').toLowerCase().split(/\s+/).filter(w => w.length > 1)
      if (!words.length) return 'error: an empty query'
      const files = [file(true), file(false), ...walk(join(own, 'journal')).sort().reverse()]
      const hits = []
      for (const path of files) {
        let lines = []
        try { lines = readFileSync(path, 'utf8').split('\n') } catch { continue }
        for (const line of lines) {
          const lower = line.toLowerCase()
          const score = words.filter(w => lower.includes(w)).length
          if (score > 0) hits.push({ score, line: line.trim().slice(0, 400), path: relative(root, path) })
        }
      }
      hits.sort((a, b) => b.score - a.score)
      const top = hits.slice(0, Math.max(1, Math.min(Number(limit) || 20, 100)))
      return top.length ? top.map(h => `- ${h.path}: ${h.line}`).join('\n') : '(nothing found)'
    },
  }))

  ctx.tools.register(tool({
    name: 'memory_read',
    description: 'Read a memory file by its path from memory_search (e.g. AGENTS.md, <agent>/journal/2026-11-03.md).',
    parameters: { properties: { path: { type: 'string' } }, required: ['path'] },
    execute({ path }) {
      const target = resolve(root, String(path || ''))
      if (!inside(root, target) || !existsSync(target) || !statSync(target).isFile()) return `error: no memory file ${path}`
      const body = readFileSync(target, 'utf8')
      return body.length > MAX_READ ? body.slice(-MAX_READ) : body
    },
  }))

  // Learning: each finished turn goes to the agent's journal, from the
  // Session's own durable events (what was asked, the tools run, the answer).
  if (config.journal === false) return
  const turns = new Map()
  ctx.on('session/event', (session, event) => {
    if (!event || typeof event.type !== 'string') return
    const key = session && session.id ? String(session.id) : 'session'
    const state = turns.get(key) ?? { asked: '', tools: [], answer: '' }
    turns.set(key, state)
    if (event.type === 'user/message') {
      // The event is the UserMessage itself; injected context (instructions,
      // notices, goal rounds) carries a non-user source and is not the ask.
      const message = event.data?.message ?? event.data
      const kind = message?.source?.kind
      if (kind !== undefined && kind !== 'user') return
      const said = blocksText(message?.content)
      if (said.trim() && !state.asked) state.asked = said.trim()
    } else if (event.type === 'tool/call') {
      if (event.data?.name && !String(event.data.name).startsWith('memory_')) state.tools.push(String(event.data.name))
    } else if (event.type === 'assistant/message') {
      const answer = blocksText(event.data?.message?.content)
      if (answer.trim()) state.answer = answer.trim()
    } else if (event.type === 'turn/end') {
      turns.delete(key)
      if (!state.asked && !state.answer) return
      const now = new Date()
      const day = now.toISOString().slice(0, 10)
      const tools = [...new Set(state.tools)].slice(0, 20)
      const entry = [
        `## ${now.toISOString().slice(11, 16)} UTC — ${event.data?.reason?.kind ?? 'ended'}`,
        `Asked: ${state.asked.slice(0, MAX_JOURNAL_TEXT)}`,
        tools.length ? `Tools: ${tools.join(', ')}` : '',
        `Answer: ${state.answer.slice(0, MAX_JOURNAL_TEXT)}`,
        '',
      ].filter(Boolean).join('\n')
      try { appendFileSync(join(own, 'journal', `${day}.md`), entry + '\n') } catch { /* memory is best effort */ }
    }
  })
}
