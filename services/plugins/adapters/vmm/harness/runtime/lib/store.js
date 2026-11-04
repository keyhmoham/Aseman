/**
 * What the runtime must remember across restarts besides dsh's own Sessions:
 * the questions agents wait on, and which Sessions belong to which room
 * thread (so a deleted thread's conversations can be forgotten).
 *
 * One small JSON file, replaced atomically on every change.
 */

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { randomUUID } from 'node:crypto'

export class Store {
  constructor(path) {
    this.path = path
    this.state = { questions: {}, sessions: {} }
    try {
      const raw = JSON.parse(readFileSync(path, 'utf8'))
      this.state.questions = raw.questions ?? {}
      this.state.sessions = raw.sessions ?? {}
    } catch {
      // A first start, or an unreadable file: begin empty.
    }
  }

  save() {
    mkdirSync(dirname(this.path), { recursive: true })
    const tmp = `${this.path}.${randomUUID()}.tmp`
    writeFileSync(tmp, JSON.stringify(this.state), { mode: 0o600 })
    renameSync(tmp, this.path)
  }

  // --- sessions -------------------------------------------------------------

  noteSession(sessionId, info) {
    const prev = this.state.sessions[sessionId]
    if (prev && prev.spaceId === info.spaceId && prev.roomId === info.roomId) return
    this.state.sessions[sessionId] = { ...info, at: new Date().toISOString() }
    this.save()
  }

  sessionsInRoom(spaceId, roomId) {
    return Object.entries(this.state.sessions)
      .filter(([, s]) => s.kind === 'room' && s.spaceId === spaceId && s.roomId === roomId)
      .map(([id]) => id)
  }

  dropSession(sessionId) {
    delete this.state.sessions[sessionId]
    for (const [id, q] of Object.entries(this.state.questions)) if (q.sessionId === sessionId) delete this.state.questions[id]
    this.save()
  }

  // --- questions --------------------------------------------------------------

  ask(question) {
    // One open question per session: a new one replaces the old.
    for (const [id, q] of Object.entries(this.state.questions)) if (q.sessionId === question.sessionId) delete this.state.questions[id]
    const id = `q-${randomUUID()}`
    const record = { id, kind: 'question', asked_at: new Date().toISOString(), ...question }
    this.state.questions[id] = record
    this.save()
    return record
  }

  question(sessionId) {
    return Object.values(this.state.questions).find((q) => q.sessionId === sessionId)
  }

  drop(questionId) {
    if (this.state.questions[questionId]) {
      delete this.state.questions[questionId]
      this.save()
    }
  }

  /** Open questions of one agent (vm) in one space, in the node's shape. */
  questions({ vmId, spaceId }) {
    return Object.values(this.state.questions)
      .filter((q) => (!vmId || q.vmId === vmId) && (!spaceId || q.spaceId === spaceId))
      .sort((a, b) => a.asked_at.localeCompare(b.asked_at))
      .map((q) => ({
        id: q.id,
        bot_id: q.botId ?? '',
        agent: q.agent ?? '',
        space_id: q.spaceId ?? '',
        room_id: q.roomId ?? '',
        question: q.question,
        options: q.options ?? [],
        kind: q.kind ?? 'question',
        asked_at: q.asked_at,
        no_sandbox: Boolean(q.flags?.no_sandbox),
        no_memory: Boolean(q.flags?.no_memory),
        request_scope: q.flags?.request_scope ?? '',
      }))
  }
}
