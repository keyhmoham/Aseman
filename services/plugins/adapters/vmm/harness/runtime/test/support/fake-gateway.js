/**
 * A stand-in for the node's agent gateway in tests: the metered LLM endpoint
 * (OpenAI-compatible streaming), platform actions (/call) and the memory and
 * timeline endpoints. Every request is recorded with the token it carried.
 */

import http from 'node:http'

export function fakeGateway({ llm, actions = {}, notes = { space: '', own: '' }, memories = [] } = {}) {
  const calls = []
  const llmCalls = []
  const memoryCalls = []
  const server = http.createServer(async (req, res) => {
    let raw = ''
    for await (const c of req) raw += c
    const body = raw ? JSON.parse(raw) : {}
    const url = new URL(req.url, 'http://gw')
    const token = (req.headers.authorization ?? '').replace(/^Bearer /, '')
    const json = (status, payload) => {
      res.writeHead(status, { 'content-type': 'application/json' })
      res.end(JSON.stringify(payload))
    }
    try {
      if (url.pathname.endsWith('/llm/chat/completions')) {
        llmCalls.push({ turn: req.headers['x-aseman-turn'], model: body.model, body })
        const out = await (llm ?? (() => ({ text: 'ok' })))(body, llmCalls.length)
        return stream(res, body.model, out)
      }
      if (url.pathname.endsWith('/llm/models')) return json(200, { data: [] })
      if (url.pathname === '/call') {
        calls.push({ token, namespace: body.namespace, action: body.action, body: body.body })
        const handler = actions[`${body.namespace}.${body.action}`]
        if (!handler) return json(404, { error: `no fake for ${body.namespace}.${body.action}` })
        return json(200, await handler(body.body, token))
      }
      if (url.pathname.startsWith('/memory/') || url.pathname.startsWith('/timeline/') || url.pathname === '/catalog') {
        memoryCalls.push({ token, path: url.pathname, body, query: Object.fromEntries(url.searchParams) })
        if (url.pathname === '/memory/notes' && req.method === 'GET') return json(200, notes)
        if (url.pathname === '/memory/recall') return json(200, { items: memories })
        if (url.pathname === '/catalog') return json(200, { actions: [{ namespace: 'themes', name: 'list', summary: 'List themes' }] })
        return json(200, { ok: true, items: [] })
      }
      json(404, { error: 'not found' })
    } catch (error) {
      json(500, { error: String(error?.message ?? error) })
    }
  })
  return {
    calls,
    llmCalls,
    memoryCalls,
    async start() {
      await new Promise((r) => server.listen(0, '127.0.0.1', r))
      this.url = `http://127.0.0.1:${server.address().port}`
      return this.url
    },
    close() {
      return new Promise((r) => server.close(r))
    },
  }
}

/** Stream `{text}` or `{tools: [{name, args}]}` as OpenAI chat-completion chunks. */
function stream(res, model, out) {
  res.writeHead(200, { 'content-type': 'text/event-stream' })
  const base = { id: `c${Date.now()}`, object: 'chat.completion.chunk', created: 1, model }
  const send = (d) => res.write(`data: ${JSON.stringify({ ...base, ...d })}\n\n`)
  if (out.tools?.length) {
    send({
      choices: [{
        index: 0,
        delta: {
          role: 'assistant',
          tool_calls: out.tools.map((t, i) => ({ index: i, id: `call_${Date.now()}_${i}`, type: 'function', function: { name: t.name, arguments: JSON.stringify(t.args ?? {}) } })),
        },
        finish_reason: null,
      }],
    })
    send({ choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }], usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } })
  } else {
    send({ choices: [{ index: 0, delta: { role: 'assistant', content: out.text ?? '' }, finish_reason: null }] })
    send({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }], usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } })
  }
  res.end('data: [DONE]\n\n')
}

/** The last tool result content the model received, if any. */
export function lastToolResult(body) {
  const msgs = body.messages ?? []
  const last = msgs[msgs.length - 1]
  return last?.role === 'tool' ? String(typeof last.content === 'string' ? last.content : JSON.stringify(last.content)) : undefined
}

export function systemText(body) {
  return (body.messages ?? []).filter((m) => m.role === 'system').map((m) => (typeof m.content === 'string' ? m.content : JSON.stringify(m.content))).join('\n')
}

export function allText(body) {
  return JSON.stringify(body.messages ?? [])
}
