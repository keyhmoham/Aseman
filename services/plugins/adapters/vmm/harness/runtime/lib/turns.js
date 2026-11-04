/**
 * The turn driver: one Aseman turn on one dsh Session.
 *
 * A room turn addresses one agent in one room thread; its dsh Session lives as
 * long as that conversation (created on the first turn, resumed from disk
 * after a restart, kept live while in use). Each turn binds the Session to the
 * node's fresh turn token, refreshes the agent's tools and context, sends the
 * message, drives the agent (and every child it spawns) to quiescence, and
 * answers with the final assistant text — or with the question the agent
 * asked, when it paused for a person.
 */

import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { SessionSeq } from '@deepseek-ai/dsh-session'
import { mkdirSync, readdirSync, rmSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { sessionIdFor } from './bindings.js'
import { scopeDir } from './config.js'
import { personaFor, personalPersona, notesText } from './persona.js'
import { registerAll, defineTool, params } from './tools/define.js'
import { sandboxTools } from './tools/sandbox.js'
import { messagingTools, askUserTool } from './tools/messaging.js'
import { spaceTools } from './tools/space.js'
import { apiTools } from './tools/api.js'
import { teamTools } from './tools/team.js'
import { memoryTools, timelineTools, formatMemories } from './tools/memory.js'
import { decideTools } from './tools/decide.js'
import { creatorTools } from './tools/creator.js'
import { workspaceTool } from './tools/workspace.js'

export { ROUTE, WINDOWS, modelFor } from './models.js'
import { ROUTE, modelFor } from './models.js'

/** The final assistant text and how the turn ended, from the durable log. */
export function summarize(session, firstSeq) {
  let text = ''
  let reason
  let started = false
  const tools = []
  for (let seq = firstSeq; seq < session.seq; seq++) {
    const event = session.eventAt(SessionSeq(seq))
    if (!event) continue
    if (event.type === 'turn/start') {
      started = true
      reason = undefined
      continue
    }
    if (!started) continue
    if (event.type === 'assistant/message') {
      const joined = event.data.message.content.filter((b) => b.type === 'text').map((b) => b.text).join('')
      if (joined) text = joined
    } else if (event.type === 'tool/call') {
      const name = event.data?.call?.name ?? event.data?.name
      if (name) tools.push(String(name))
    } else if (event.type === 'turn/end') {
      reason = event.data.reason
    }
  }
  return { text, reason, tools }
}

/** The turn's message: what is only true now, then what was said. */
export function composeMessage(turn, { memories = '', continuation = '' } = {}) {
  const parts = []
  if (turn.context) parts.push(`<where_you_are>\n${String(turn.context).trim()}\n</where_you_are>`)
  if (memories) parts.push(`<from_your_memory>\n${memories}\n</from_your_memory>`)
  if (turn.note) parts.push(`<now>\n${String(turn.note).trim()}\n</now>`)
  const atts = Array.isArray(turn.attachments) ? turn.attachments : []
  if (atts.length) {
    parts.push(
      '<attachments>\n' +
        atts.map((a) => `- ${a.name ?? 'file'} (${a.mime ?? a.content_type ?? 'file'}, id ${a.id}) — read it with file_read`).join('\n') +
        '\n</attachments>',
    )
  }
  if (continuation) parts.push(continuation)
  else parts.push(`${turn.sender_name || 'Someone'}: ${turn.message ?? ''}`)
  return parts.join('\n\n')
}

export class Runner {
  /**
   * @param {object} deps
   * @param {import('@deepseek-ai/cordis').Context} deps.ctx - the host plugin's context
   * @param {ReturnType<import('./config.js').readConfig>} deps.config
   * @param {import('./gateway.js').Gateway} deps.gateway
   * @param {import('./store.js').Store} deps.store
   * @param {import('./bindings.js').Bindings} deps.bindings
   */
  constructor({ ctx, config, gateway, store, bindings, log = console }) {
    this.ctx = ctx
    this.config = config
    this.gateway = gateway
    this.store = store
    this.bindings = bindings
    this.log = log
    /** @type {Map<string, { agent: any, dispose: () => Promise<void>, usedAt: number }>} */
    this.handles = new Map()
    /** One turn at a time per Session: a second message waits for the first. */
    this.locks = new Map()
  }

  // --- entry points ------------------------------------------------------------

  /** POST /v1/turns */
  async turn(req, signal) {
    return this.room(req, signal, '')
  }

  /** POST /v1/answers: a person's message answers the agent's open question. */
  async answer(req, signal) {
    const sessionId = this.roomSessionId(req)
    const pending = this.store.question(sessionId)
    if (!pending || (req.turn?.question_id && pending.id !== req.turn.question_id)) {
      return { answered: false, reply: '', status: 'done' }
    }
    this.store.drop(pending.id)
    const who = req.turn?.sender_name || 'A person'
    const continuation = `Answer to your question "${pending.question}" — ${who}: ${req.turn?.message ?? ''}`
    const out = await this.room(req, signal, continuation)
    return { ...out, answered: true }
  }

  /** POST /v1/chat: Aseman, the person's own assistant (personal chat). */
  async chat(req, signal) {
    const accountId = String(req.account_id ?? '').trim()
    if (!accountId || !req.token) return { reply: '', status: 'failed', error: 'personal chat needs the person\'s gateway session' }
    const threadId = String(req.thread_id || 'aseman-chat')
    const sessionId = sessionIdFor({ kind: 'personal', accountId, threadId })
    const binding = this.bindings.root(sessionId, { kind: 'personal', accountId, threadId })
    return this.locked(sessionId, async () => {
      const turnSignal = binding.begin({
        token: req.token,
        agent: { name: 'Aseman', personal: true, context_window: req.context_window, system: req.system },
        turn: null,
        flags: { with_tools: Boolean(req.with_tools), no_memory: Boolean(req.no_memory) },
        computerSpace: String(req.computer_space ?? ''),
      })
      const abort = linked(signal, turnSignal, this.config.turnTimeoutSeconds)
      try {
        await this.loadMemory(binding, lastUserText(req.messages), abort)
        const agent = await this.agentFor(binding, scopeDir(this.config, { kind: 'personal', accountId }), abort)
        // Home computer: same App UI / plugin builtins as a space turn (appui_*).
        let listed = []
        if (binding.computerSpace) {
          try {
            listed = (await this.gateway.call(binding.token, 'spaces', 'tools_list', { space: binding.computerSpace }, { signal: abort })).tools ?? []
          } catch (error) {
            this.log.warn?.(`tools_list for personal computer ${binding.computerSpace}: ${messageOf(error)}`)
          }
        }
        this.applyTools(binding, agent, listed)
        const resumed = agent.session.seq > 0
        // In a personal chat the person's next message is the answer to a
        // question their Aseman asked.
        const pending = this.store.question(sessionId)
        if (pending) this.store.drop(pending.id)
        binding.asked = undefined
        let text = personalMessage(req.messages, { resumed, memories: binding.recalled })
        if (pending) text = `Answer to your question "${pending.question}": ${lastUserText(req.messages)}`
        const result = await this.drive(binding, agent, text, abort)
        if (binding.asked) {
          return { reply: personalQuestion(result.text, binding.asked), status: 'awaiting', question_id: binding.asked.id, transcript: result.transcript }
        }
        return { reply: result.text, status: result.status, error: result.error ?? '', transcript: result.transcript }
      } catch (error) {
        return { reply: '', status: abort.aborted ? 'cancelled' : 'failed', error: messageOf(error) }
      } finally {
        binding.end()
      }
    })
  }

  questions({ vm, space }) {
    return { questions: this.store.questions({ vmId: vm, spaceId: space }) }
  }

  /** A deleted room thread: every agent's Session of it is dropped, on disk too. */
  async forgetRoom(spaceId, roomId) {
    const ids = new Set([...this.store.sessionsInRoom(spaceId, roomId), ...this.bindings.inRoom(spaceId, roomId).map((b) => b.sessionId)])
    for (const id of ids) {
      const handle = this.handles.get(id)
      this.handles.delete(id)
      if (handle) {
        handle.agent.cancel({ kind: 'user' })
        await handle.dispose().catch(() => {})
      }
      this.bindings.forget(id)
      this.store.dropSession(id)
      removeSessionFiles(join(process.env.DSH_HOME || join(this.config.dataDir, 'dsh'), 'sessions'), id)
    }
    return { forgotten: ids.size }
  }

  /** Dispose Sessions idle for longer than `maxIdleMs`; they resume from disk. */
  async sweep(maxIdleMs = 30 * 60 * 1000) {
    const now = Date.now()
    for (const [id, h] of this.handles) {
      if (this.locks.has(id) || now - h.usedAt < maxIdleMs || h.agent.status !== 'idle') continue
      this.handles.delete(id)
      await h.dispose().catch((e) => this.log.warn?.(`dispose ${id}: ${messageOf(e)}`))
    }
  }

  // --- a room turn ---------------------------------------------------------------

  roomSessionId(req) {
    const t = req.turn ?? {}
    const agentKey = req.agent?.bot_id || req.agent?.vm_id || req.agent?.name || ''
    return sessionIdFor({ kind: 'room', spaceId: t.space_id, agentKey, threadId: t.room_id })
  }

  async room(req, signal, continuation) {
    const t = req.turn ?? {}
    if (!req.token) return { reply: '', status: 'failed', error: 'the turn has no gateway session' }
    if (!t.space_id || !t.room_id) return { reply: '', status: 'failed', error: 'the turn has no space or room' }
    const sessionId = this.roomSessionId(req)
    const binding = this.bindings.root(sessionId, { kind: 'room', spaceId: t.space_id, roomId: t.room_id, threadId: t.room_id })
    this.store.noteSession(sessionId, { kind: 'room', spaceId: t.space_id, roomId: t.room_id, agent: req.agent?.name ?? '' })
    return this.locked(sessionId, async () => {
      // The room moved on while the agent waited on a question: that question
      // closes with the new message, which the agent reads below.
      const stale = !continuation && this.store.question(sessionId)
      if (stale) {
        this.store.drop(stale.id)
        continuation = `No answer to your question yet. Meanwhile ${t.sender_name || 'someone'} wrote: ${t.message ?? ''}`
      }
      const agentDef = { ...(req.agent ?? {}), lead: isLead(req.agent) }
      const turnSignal = binding.begin({
        token: req.token,
        agent: agentDef,
        turn: t,
        roomId: t.room_id,
        flags: {
          no_sandbox: Boolean(t.no_sandbox),
          no_memory: Boolean(t.no_memory),
          request_scope: t.request_scope ?? '',
          timeline: Boolean(req.timeline),
        },
      })
      binding.asked = undefined
      const abort = linked(signal, turnSignal, this.config.turnTimeoutSeconds)
      try {
        this.status(binding, 'thinking…')
        await this.loadMemory(binding, t.message, abort)
        const agent = await this.agentFor(binding, scopeDir(this.config, { kind: 'room', spaceId: t.space_id }), abort)
        let listed = []
        try {
          listed = (await this.gateway.call(binding.token, 'spaces', 'tools_list', { space: t.space_id, room: t.room_id }, { signal: abort })).tools ?? []
        } catch (error) {
          this.log.warn?.(`tools_list for ${t.space_id}: ${messageOf(error)}`)
        }
        this.applyTools(binding, agent, listed)
        const text = composeMessage(t, { memories: binding.recalled, continuation })
        const result = await this.drive(binding, agent, text, abort)
        if (binding.asked) {
          const q = binding.asked
          const options = q.options?.length ? `\n${q.options.map((o) => `- ${o}`).join('\n')}` : ''
          return { reply: `${result.text ? `${result.text}\n\n` : ''}${q.question}${options}`.trim(), status: 'awaiting', answered: false, question_id: q.id, transcript: result.transcript }
        }
        return { reply: result.text, status: result.status, error: result.error ?? '', answered: false, transcript: result.transcript }
      } catch (error) {
        return { reply: '', status: abort.aborted ? 'cancelled' : 'failed', error: messageOf(error) }
      } finally {
        this.status(binding, '')
        binding.end()
      }
    })
  }

  // --- the Session ----------------------------------------------------------------

  /** The binding's live agent: live, else resumed from disk, else created. */
  async agentFor(binding, cwd, signal) {
    const selection = this.selection(binding)
    const known = this.handles.get(binding.sessionId)
    if (known) {
      known.usedAt = Date.now()
      known.agent.model.select(selection)
      return known.agent
    }
    mkdirSync(cwd, { recursive: true })
    const setup = (agentCtx, agent) => {
      this.bindings.adopt(String(agent.session.id), binding.sessionId)
      binding.agentCtx = agentCtx
      agentCtx.systemPrompt.section({
        name: 'aseman-persona',
        order: 1,
        interpolate: false,
        text: () => (binding.kind === 'personal' ? personalPersona(binding.agent?.system) : personaFor(binding.agent ?? { name: 'agent' })),
      })
      agentCtx.systemPrompt.context({
        name: 'aseman-notes',
        order: 10,
        interpolate: false,
        text: () => notesText(binding.notes),
      })
      agent.model.select(selection)
    }
    const agentOptions = { ...selection }
    let handle
    try {
      handle = await this.ctx.agents.resume({ resumeSessionId: binding.sessionId, agentOptions, setup, signal })
    } catch (error) {
      if (!/not.?found|does not exist|no stored|unknown session/i.test(messageOf(error))) throw error
      handle = await this.ctx.agents.create({ sessionId: binding.sessionId, meta: { cwd }, agentOptions, setup, signal })
    }
    this.handles.set(binding.sessionId, { ...handle, usedAt: Date.now() })
    return handle.agent
  }

  selection(binding) {
    const sel = { provider: ROUTE, model: modelFor(binding.agent?.context_window, this.config.defaultContextWindow) }
    if (binding.agent?.reasoning_effort) sel.reasoningEffort = binding.agent.reasoning_effort
    return sel
  }

  /** This turn's tools, scoped to the agent (and inherited by its children). */
  applyTools(binding, agent, listed) {
    binding.disposeTools?.()
    const deps = { gateway: this.gateway, binding: () => binding, store: this.store, attachments: () => this.ctx.get('attachments') }
    const defs = [...apiTools(deps), ...creatorTools(deps), ...decideTools(deps)]
    if (binding.kind === 'personal') {
      defs.push(askUserTool(deps))
      // The person's own computer (their home workspace's), as the person —
      // sandbox + App UI / plugin builtins from that space's tools_list.
      if (binding.computerSpace) {
        defs.push(...sandboxTools(deps), workspaceTool(deps))
        if (listed?.length) defs.push(...spaceTools({ ...deps, listed }))
      }
      if (!binding.flags.no_memory) defs.push(...memoryTools(deps))
    } else {
      defs.push(...messagingTools(deps), ...teamTools(deps), ...sandboxTools(deps))
      if (!binding.flags.no_memory) defs.push(...memoryTools(deps))
      if (binding.flags.timeline && !binding.flags.no_memory) defs.push(...timelineTools(deps))
      defs.push(...spaceTools({ ...deps, listed }))
      const skills = Array.isArray(binding.agent?.skills) ? binding.agent.skills : []
      if (skills.length) defs.push(skillTool(binding))
    }
    binding.disposeTools = registerAll(agent.ctx, defs)
  }

  /** Notes in context and what memory holds about the message. */
  async loadMemory(binding, message, signal) {
    binding.recalled = ''
    if (binding.flags.no_memory) {
      binding.notes = null
      return
    }
    const [notes, recalled] = await Promise.allSettled([
      this.gateway.get(binding.token, '/memory/notes', { signal, timeoutMs: 15000 }),
      String(message ?? '').trim()
        ? this.gateway.post(binding.token, '/memory/recall', { query: String(message).slice(0, 2000), limit: 6 }, { signal, timeoutMs: 20000 })
        : Promise.resolve({ items: [] }),
    ])
    binding.notes = notes.status === 'fulfilled' ? { space: notes.value.space ?? '', own: notes.value.own ?? '' } : binding.notes ?? null
    binding.recalled = recalled.status === 'fulfilled' ? formatMemories(recalled.value.items) : ''
  }

  /** Send the message and drive the agent and its children to quiescence. */
  async drive(binding, agent, text, signal) {
    await agent.whenIdle()
    const firstSeq = agent.session.seq
    let failure
    const stopErrors = this.ctx.on('agent/error', ({ agent: subject, error }) => {
      if (subject === agent) failure = error
    })
    const stopTools = this.ctx.on('session/event', (session, event) => {
      if (session === agent.session && event.type === 'tool/call') {
        const name = event.data?.call?.name ?? event.data?.name
        if (name) this.status(binding, `using ${name}…`)
      }
    })
    const onAbort = () => agent.cancel({ kind: 'user' })
    signal.addEventListener('abort', onAbort, { once: true })
    try {
      agent.followup(createUserMessage({ content: [{ type: 'text', text }], source: { kind: 'user' } }))
      const subagents = this.ctx.get('subagents')
      while (true) {
        await agent.whenIdle()
        const idleSeq = agent.session.seq
        if (signal.aborted) break
        if (!(await subagents?.waitForChildren(agent)) && agent.status === 'idle' && agent.session.seq === idleSeq) break
      }
    } finally {
      signal.removeEventListener('abort', onAbort)
      stopErrors()
      stopTools()
    }
    await this.ctx.sessions.flush(agent.session)
    const outcome = summarize(agent.session, firstSeq)
    const transcript = { message: text.slice(-4000), reply: outcome.text.slice(0, 4000), tools: outcome.tools.slice(0, 50) }
    if (signal.aborted) return { text: outcome.text, status: 'cancelled', error: 'the run was cancelled', transcript }
    if (outcome.reason?.kind === 'error' && !outcome.text) {
      return { text: '', status: 'failed', error: outcome.reason.error?.message ?? messageOf(failure) ?? 'the run failed', transcript }
    }
    if (failure && !outcome.text) return { text: '', status: 'failed', error: messageOf(failure), transcript }
    return { text: outcome.text || (binding.asked ? '' : 'Done.'), status: 'done', transcript }
  }

  status(binding, text) {
    if (binding.kind !== 'room' || !binding.token) return
    const now = Date.now()
    if (text && now - (binding.statusAt ?? 0) < 2500) return
    binding.statusAt = now
    this.gateway
      .call(binding.token, 'spaces', 'agent_log', { space: binding.spaceId, room: binding.roomId, status: text }, { timeoutMs: 10000 })
      .catch(() => {})
  }

  async locked(sessionId, fn) {
    const prev = this.locks.get(sessionId) ?? Promise.resolve()
    let release
    const mine = new Promise((r) => (release = r))
    const chain = prev.then(() => mine)
    this.locks.set(sessionId, chain)
    await prev
    try {
      return await fn()
    } finally {
      release()
      if (this.locks.get(sessionId) === chain) this.locks.delete(sessionId)
    }
  }
}

function skillTool(binding) {
  return defineTool({
    name: 'load_skill',
    binding: () => binding,
    concurrent: true,
    description: 'Load one of your skills\' full instructions (see "Your skills").',
    parameters: params({ name: { type: 'string' } }, ['name']),
    async run({ name }) {
      const skills = binding.agent?.skills ?? []
      const skill = skills.find((s) => String(s.name).toLowerCase() === String(name).toLowerCase())
      if (!skill) return `No skill named ${JSON.stringify(name)}. Yours: ${skills.map((s) => s.name).join(', ')}`
      const tools = skill.tools?.length ? `\n\nTools it uses: ${skill.tools.join(', ')}` : ''
      return `# ${skill.name}\n\n${String(skill.instructions ?? '').trim()}${tools}`
    },
  })
}

export function isLead(agent) {
  return agent?.role === 'lead' || agent?.role === 'orchestrator' || agent?.lead === true
}

function lastUserText(messages) {
  const list = Array.isArray(messages) ? messages : []
  for (let i = list.length - 1; i >= 0; i--) if (list[i]?.role === 'user') return String(list[i].content ?? '')
  return ''
}

/** Personal chat: the app sends the whole thread; a live Session needs only the new turn. */
export function personalMessage(messages, { resumed, memories }) {
  const list = Array.isArray(messages) ? messages.filter((m) => m && m.content) : []
  const last = list.length ? list[list.length - 1] : { role: 'user', content: '' }
  const mem = memories ? `<from_your_memory>\n${memories}\n</from_your_memory>\n\n` : ''
  if (resumed || list.length <= 1) return `${mem}${String(last.content)}`
  const earlier = list.slice(0, -1).slice(-20).map((m) => `${m.role === 'assistant' ? 'Aseman' : 'Person'}: ${String(m.content).slice(0, 4000)}`)
  return `${mem}<earlier_conversation>\n${earlier.join('\n')}\n</earlier_conversation>\n\n${String(last.content)}`
}

/** A personal question as the reply: the question, its options as reply chips. */
export function personalQuestion(before, question) {
  const head = before && before !== question.question ? `${before}\n\n` : ''
  const opts = (question.options ?? []).map((o) => String(o).replace(/[|<>]/g, ' ').trim().slice(0, 40)).filter(Boolean).slice(0, 3)
  return `${head}${question.question}${opts.length ? `\n<replies>${opts.join(' | ')}</replies>` : ''}`.trim()
}

/** Cancelled by the node (the request), the turn's own end, or the turn timeout. */
function linked(signal, turnSignal, timeoutSeconds) {
  const parts = [turnSignal, AbortSignal.timeout(timeoutSeconds * 1000)]
  if (signal) parts.push(signal)
  return AbortSignal.any(parts)
}

function messageOf(error) {
  if (!error) return undefined
  return error instanceof Error ? error.message : String(error?.message ?? error)
}

/** Remove a Session's persisted files (JSONL log and sidecars) under the sessions root. */
export function removeSessionFiles(root, sessionId) {
  let entries
  try {
    entries = readdirSync(root)
  } catch {
    return 0
  }
  let removed = 0
  for (const name of entries) {
    const path = join(root, name)
    if (name.includes(sessionId)) {
      rmSync(path, { recursive: true, force: true })
      removed++
      continue
    }
    try {
      if (statSync(path).isDirectory()) removed += removeSessionFiles(path, sessionId)
    } catch {
      // Raced with another removal.
    }
  }
  return removed
}
