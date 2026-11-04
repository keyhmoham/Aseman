/**
 * Bindings: which Aseman turn a dsh Session works for.
 *
 * One dsh Session per agent per room thread (or per personal chat thread)
 * lives as long as the conversation. A binding ties that Session — and every
 * child Session its subagents, forks and teammates create — to the turn now
 * running in it: the gateway token, the space and room, the agent's
 * definition and the turn's flags. Tools, the LLM route and prompt sections
 * read the binding at call time, so a new turn (with a fresh token) is in
 * effect at once and an ended turn's token is never used again.
 */

import { createHash } from 'node:crypto'

/** The stable dsh Session id of one agent in one thread. */
export function sessionIdFor({ kind, spaceId = '', agentKey = '', threadId = '', accountId = '' }) {
  const parts = kind === 'personal' ? ['personal', accountId, threadId] : ['room', spaceId, agentKey, threadId]
  const digest = createHash('sha256').update(parts.join('\u0000')).digest('hex').slice(0, 32)
  return `aseman-${kind}-${digest}`
}

export class Binding {
  /**
   * @param {object} init
   * @param {'room' | 'personal'} init.kind
   * @param {string} init.sessionId
   */
  constructor(init) {
    this.kind = init.kind
    this.sessionId = init.sessionId
    /** Turn-scoped fields, replaced by {@link Binding#begin}. */
    this.token = ''
    this.spaceId = init.spaceId ?? ''
    this.roomId = init.roomId ?? ''
    this.threadId = init.threadId ?? ''
    this.accountId = init.accountId ?? ''
    /** The space whose computer this conversation works on when it is not its
     * own space's (the person's own computer, for their personal Aseman). */
    this.computerSpace = ''
    this.agent = init.agent ?? null
    this.turn = null
    this.flags = {}
    this.members = []
    this.tools = []
    this.abort = null
    /** The step-count budget of the running turn, when the agent sets one. */
    this.maxSteps = 0
    this.steps = 0
  }

  /** Start a turn: the token and everything the node sent with it. */
  begin({ token, agent, turn, flags = {}, roomId, threadId, computerSpace }) {
    this.token = token
    if (computerSpace !== undefined) this.computerSpace = computerSpace
    if (agent) this.agent = agent
    if (turn) this.turn = turn
    if (roomId !== undefined) this.roomId = roomId
    if (threadId !== undefined) this.threadId = threadId
    this.flags = flags
    this.abort = new AbortController()
    this.steps = 0
    this.maxSteps = Number(agent?.max_turns) > 0 ? Number(agent.max_turns) : 0
    return this.abort.signal
  }

  /** End a turn: the token is revoked by the node, so forget it here too. */
  end() {
    this.token = ''
    this.abort = null
  }

  get active() {
    return this.token !== ''
  }

  get signal() {
    return this.abort?.signal
  }

  /** The room (or DM) a reply and a question go to. */
  get room() {
    return this.roomId
  }
}

export class Bindings {
  constructor() {
    /** @type {Map<string, Binding>} root session id → binding */
    this.roots = new Map()
    /** @type {Map<string, string>} any session id → its root session id */
    this.lineage = new Map()
  }

  /** The binding of a root session, created on first use. */
  root(sessionId, init) {
    let b = this.roots.get(sessionId)
    if (!b) {
      b = new Binding({ ...init, sessionId })
      this.roots.set(sessionId, b)
      this.lineage.set(sessionId, sessionId)
    }
    return b
  }

  /** Record that `child` works for the same turn as `parent`. */
  adopt(child, parent) {
    const root = this.lineage.get(String(parent))
    if (root) this.lineage.set(String(child), root)
    return root !== undefined
  }

  /**
   * The binding a session works for.
   * @param {string} sessionId
   * @param {(id: string) => string | undefined} [parentOf] - recorded parent of a
   *   session (dsh's Session header `parentSession`), for children created
   *   before their parent was seen.
   */
  resolve(sessionId, parentOf) {
    let id = String(sessionId ?? '')
    const seen = new Set()
    while (id && !seen.has(id)) {
      seen.add(id)
      const root = this.lineage.get(id)
      if (root) {
        for (const s of seen) this.lineage.set(s, root)
        return this.roots.get(root)
      }
      id = parentOf ? String(parentOf(id) ?? '') : ''
    }
    return undefined
  }

  forget(sessionId) {
    const root = this.lineage.get(sessionId) ?? sessionId
    this.roots.delete(root)
    for (const [s, r] of this.lineage) if (r === root) this.lineage.delete(s)
  }

  /** Root bindings whose room thread is `roomId` in `spaceId` (deleted threads). */
  inRoom(spaceId, roomId) {
    return [...this.roots.values()].filter((b) => b.kind === 'room' && b.spaceId === spaceId && b.roomId === roomId)
  }
}
