/**
 * The runtime's settings, read once from the environment the node starts it
 * with (see the Go adapter's runtime.go).
 */

import { join } from 'node:path'

function int(value, fallback, { min = 0 } = {}) {
  const n = Number.parseInt(String(value ?? '').trim(), 10)
  return Number.isFinite(n) && n >= min ? n : fallback
}

/**
 * @param {Record<string, string | undefined>} env
 */
export function readConfig(env = process.env) {
  const dataDir = (env.ASEMAN_DATA_DIR || '/data').trim()
  return {
    /** Where sessions, questions and per-scope working directories live. */
    dataDir,
    /** The node's agent gateway (turn tokens are valid only there). */
    gateway: (env.ASEMAN_GATEWAY_URL || '').trim().replace(/\/+$/, ''),
    port: int(env.ASEMAN_RUNTIME_PORT, 8000, { min: 1 }),
    /** Shared with the node; every node → runtime request carries it. */
    secret: env.ASEMAN_RUNTIME_SECRET || '',
    /** The window assumed for a model whose window the node does not know. */
    defaultContextWindow: int(env.ASEMAN_DEFAULT_CONTEXT_WINDOW, 128000, { min: 4096 }),
    /** Longest a turn may run before it is stopped (seconds). */
    turnTimeoutSeconds: int(env.ASEMAN_TURN_TIMEOUT, 2700, { min: 30 }),
    /** Longest one gateway call may take (seconds); builds and hand-offs wait on other work. */
    callTimeoutSeconds: int(env.ASEMAN_GATEWAY_CALL_TIMEOUT, 2700, { min: 10 }),
    /** SPIFFE JWT-SVID file (deploy/spire), sent with every gateway call when present. */
    svidFile: (env.ASEMAN_SVID_FILE || '').trim(),
    /** Most characters of one tool result the model reads (the rest is spilled by dsh). */
    toolResultMaxChars: int(env.ASEMAN_TOOL_RESULT_MAX_CHARS, 48000, { min: 1000 }),
  }
}

/** The local working directory of one scope (dsh requires a real cwd). */
export function scopeDir(config, scope) {
  if (scope.kind === 'personal') return join(config.dataDir, 'people', safe(scope.accountId))
  return join(config.dataDir, 'spaces', safe(scope.spaceId))
}

export function safe(id) {
  const s = String(id ?? '').replace(/[^A-Za-z0-9_.-]/g, '_')
  if (!s || s === '.' || s === '..') throw new Error(`invalid scope id ${JSON.stringify(id)}`)
  return s
}
