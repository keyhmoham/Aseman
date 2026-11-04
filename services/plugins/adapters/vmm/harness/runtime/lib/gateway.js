/**
 * The node's agent gateway, as one turn sees it.
 *
 * Every request carries the turn's token: the node accepts it only while it
 * waits on that turn, and acts as the agent's account (or, in personal chat,
 * as the person) inside the turn's execution scope — the space, room, payer,
 * budget and usage meter. The runtime holds no platform credential of its own.
 */

import { readFileSync } from 'node:fs'

export class GatewayError extends Error {
  constructor(message, { code = '', status = 0 } = {}) {
    super(message)
    this.name = 'GatewayError'
    this.code = code
    this.status = status
  }
}

export const SVID_HEADER = 'X-Aseman-SVID'

export class Gateway {
  /**
   * @param {{ base: string, svidFile?: string, callTimeoutSeconds?: number, fetch?: typeof fetch }} options
   */
  constructor({ base, svidFile = '', callTimeoutSeconds = 2700, fetch: fetchImpl = globalThis.fetch }) {
    if (!base) throw new Error('the gateway URL is not configured (ASEMAN_GATEWAY_URL)')
    this.base = base.replace(/\/+$/, '')
    this.svidFile = svidFile
    this.timeoutMs = callTimeoutSeconds * 1000
    this.fetch = fetchImpl
  }

  headers(token) {
    const headers = { 'content-type': 'application/json', authorization: `Bearer ${token}` }
    const svid = this.svid()
    if (svid) headers[SVID_HEADER] = svid
    return headers
  }

  svid() {
    if (!this.svidFile) return ''
    try {
      return readFileSync(this.svidFile, 'utf8').trim()
    } catch {
      return ''
    }
  }

  /** One platform action, dispatched as the turn's account. */
  async call(token, namespace, action, body = {}, { signal, timeoutMs } = {}) {
    return this.post(token, '/call', { namespace, action, body: compact(body) }, { signal, timeoutMs })
  }

  async post(token, path, payload, { signal, timeoutMs } = {}) {
    return this.request(token, 'POST', path, payload, { signal, timeoutMs })
  }

  async get(token, path, { signal, timeoutMs } = {}) {
    return this.request(token, 'GET', path, undefined, { signal, timeoutMs })
  }

  async request(token, method, path, payload, { signal, timeoutMs } = {}) {
    if (!token) throw new GatewayError('this turn has no gateway session', { code: 'unauthenticated' })
    const timeout = AbortSignal.timeout(timeoutMs ?? this.timeoutMs)
    const combined = signal ? AbortSignal.any([signal, timeout]) : timeout
    let resp
    try {
      resp = await this.fetch(this.base + path, {
        method,
        headers: this.headers(token),
        body: payload === undefined ? undefined : JSON.stringify(payload),
        signal: combined,
      })
    } catch (error) {
      if (timeout.aborted) throw new GatewayError(`${label(path, payload)}: no answer in time`, { code: 'deadline_exceeded' })
      if (signal?.aborted) throw error
      throw new GatewayError(`${label(path, payload)}: gateway unreachable (${error?.message ?? error})`, { code: 'unavailable' })
    }
    const text = await resp.text()
    let data
    try {
      data = text ? JSON.parse(text) : {}
    } catch {
      data = { error: text }
    }
    if (!resp.ok) {
      let message = data && typeof data === 'object' ? data.error ?? data.message : undefined
      if (message && typeof message === 'object') message = message.message
      throw new GatewayError(`${label(path, payload)}: ${message || resp.statusText || `HTTP ${resp.status}`}`, {
        code: String((data && data.code) || ''),
        status: resp.status,
      })
    }
    return data && typeof data === 'object' && !Array.isArray(data) ? data : { result: data }
  }
}

function label(path, payload) {
  if (path === '/call' && payload) return `${payload.namespace}.${payload.action}`
  return path.replace(/^\//, '')
}

/** Drops undefined/null fields so optional arguments are not sent as nulls. */
export function compact(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return body ?? {}
  const out = {}
  for (const [k, v] of Object.entries(body)) if (v !== undefined && v !== null) out[k] = v
  return out
}
