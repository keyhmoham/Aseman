/**
 * aseman-host — the runtime's API, called only by the node's harness adapter.
 *
 *   GET  /healthz              → {ok: true}
 *   POST /v1/turns             run a turn of an agent in a room       → {reply, status, answered, error, transcript}
 *   POST /v1/answers           a person's answer to the agent's question → same
 *   POST /v1/chat              Aseman, the person's assistant          → {reply, status, error, transcript}
 *   GET  /v1/questions?vm=&space=  open questions                    → {questions: [...]}
 *   POST /v1/rooms/forget      drop every agent's Session of a room thread → {forgotten: n}
 *
 * Every request carries the secret the node started the runtime with
 * (X-Aseman-Runtime). A turn's own platform access is the turn token in its
 * body, valid only while the node waits on that turn. When the node gives up
 * on a request (the room turn was cancelled), the turn is cancelled too.
 */

import http from 'node:http'
import { timingSafeEqual } from 'node:crypto'
import { join } from 'node:path'
import { readConfig } from '../config.js'
import { Gateway } from '../gateway.js'
import { Store } from '../store.js'
import { Runner } from '../turns.js'
import { bindings } from '../state.js'

export const name = 'aseman-host'
export const inject = ['agents', 'sessions', 'tools', 'systemPrompt', 'agentDefaultModel']

const MAX_BODY = 32 * 1024 * 1024

export function apply(ctx) {
  const config = readConfig()
  const log = ctx.logger ? ctx.logger('aseman') : console
  const gateway = new Gateway({ base: config.gateway, svidFile: config.svidFile, callTimeoutSeconds: config.callTimeoutSeconds })
  const store = new Store(join(config.dataDir, 'aseman-runtime.json'))
  const runner = new Runner({ ctx, config, gateway, store, bindings, log })
  const server = http.createServer((req, res) => {
    handle(runner, config, req, res).catch((error) => {
      log.warn?.(`request ${req.method} ${req.url}: ${error?.stack ?? error}`)
      send(res, 500, { error: String(error?.message ?? error) })
    })
  })
  server.requestTimeout = 0
  server.headersTimeout = 60_000
  server.listen(config.port, () => log.info?.(`aseman host listening on :${config.port}`))
  const sweep = setInterval(() => runner.sweep().catch(() => {}), 5 * 60 * 1000)
  sweep.unref()
  ctx.on('dispose', () => {
    clearInterval(sweep)
    server.close()
  })
}

export async function handle(runner, config, req, res) {
  const url = new URL(req.url ?? '/', 'http://runtime')
  if (req.method === 'GET' && url.pathname === '/healthz') return send(res, 200, { ok: true })
  if (!authorized(req.headers['x-aseman-runtime'], config.secret)) return send(res, 401, { error: 'unauthorized' })

  // The node gave up on the request: stop the work it was for.
  const aborter = new AbortController()
  res.on('close', () => {
    if (!res.writableFinished) aborter.abort()
  })

  switch (`${req.method} ${url.pathname}`) {
    case 'POST /v1/turns':
      return send(res, 200, await runner.turn(await body(req), aborter.signal))
    case 'POST /v1/answers':
      return send(res, 200, await runner.answer(await body(req), aborter.signal))
    case 'POST /v1/chat':
      return send(res, 200, await runner.chat(await body(req), aborter.signal))
    case 'GET /v1/questions':
      return send(res, 200, runner.questions({ vm: url.searchParams.get('vm') ?? '', space: url.searchParams.get('space') ?? '' }))
    case 'POST /v1/rooms/forget': {
      const b = await body(req)
      if (!b.space || !b.room) return send(res, 400, { error: 'space and room are required' })
      return send(res, 200, await runner.forgetRoom(String(b.space), String(b.room)))
    }
    default:
      return send(res, 404, { error: `no route ${req.method} ${url.pathname}` })
  }
}

export function authorized(given, secret) {
  if (!secret) return false
  const a = Buffer.from(String(given ?? ''))
  const b = Buffer.from(secret)
  return a.length === b.length && timingSafeEqual(a, b)
}

async function body(req) {
  let size = 0
  const chunks = []
  for await (const chunk of req) {
    size += chunk.length
    if (size > MAX_BODY) throw new Error('request body too large')
    chunks.push(chunk)
  }
  const raw = Buffer.concat(chunks).toString('utf8')
  if (!raw) return {}
  const parsed = JSON.parse(raw)
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('the body must be a JSON object')
  return parsed
}

function send(res, status, payload) {
  if (res.headersSent || res.destroyed) return
  const data = JSON.stringify(payload)
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) })
  res.end(data)
}
