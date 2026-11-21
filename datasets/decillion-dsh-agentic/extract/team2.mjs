import { spawn } from 'node:child_process'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
const R = process.argv[2], S = process.argv[3]
const { fakeGateway } = await import(join(R, 'test/support/fake-gateway.js'))
const plan = JSON.parse(process.argv[4])
let bodies = [], step = 0
const gw = fakeGateway({ llm: (body) => { bodies.push(body); const txt = JSON.stringify(body.messages); if (!txt.includes("Team Lead named")) { return { text: "TEAMMATE: parser written in src/parser/csv.js, 6 tests pass" } } const p = plan[step++]; if (!p) return { text: 'done' }; return p.text ? { text: p.text } : { tools: p } },
  actions: { 'spaces.tools_list': () => ({ tools: [] }), 'spaces.agent_log': () => ({ ok: true }), 'spaces.ask': () => ({ exit_code: 0, output: 'ok\n' }) } })
await gw.start()
const dataDir = mkdtempSync(join(tmpdir(), 'cap-'))
const port = 19000 + Math.floor(Math.random() * 900)
const base = `http://127.0.0.1:${port}`
const proc = spawn(process.execPath, [join(R, 'bin', 'decillion-harness.js')], { env: { ...process.env, DECILLION_DATA_DIR: dataDir, DECILLION_GATEWAY_URL: gw.url, DECILLION_RUNTIME_SECRET: 's', DECILLION_RUNTIME_PORT: String(port) }, stdio: 'ignore' })
for (let i = 0; i < 180; i++) { try { if ((await fetch(base + '/healthz')).ok) break } catch {} await new Promise((r) => setTimeout(r, 500)) }
const r = await (await fetch(base + '/v1/turns', { method: 'POST', headers: { 'content-type': 'application/json', 'x-decillion-runtime': 's' }, body: JSON.stringify({ token: 't', agent: { name: 'decillion', role: 'lead', bot_id: 'b1' }, turn: { space_id: 'sp', room_id: 'rm', sender_name: 'Sara', message: 'go' } }) })).json()
const all = []
for (const b of bodies) for (const m of b.messages) if (m.role === 'tool' || (m.role === 'assistant' && m.tool_calls)) all.push(m)
const seenIds = new Set(); const uniq = all.filter((m) => { const k = JSON.stringify(m); if (seenIds.has(k)) return false; seenIds.add(k); return true })
for (const b of bodies) { const t = JSON.stringify(b.messages); if (t.includes("Team Lead named")) { for (const m of b.messages) { if (m.role==="user" && JSON.stringify(m.content).match(/TEAMMATE|csv-parser/)) console.log("LEADSEES:", JSON.stringify(m.content).slice(0,900)) } } }
console.log(JSON.stringify({ reply: r.reply, status: r.status, msgs: uniq.map((m) => m.role === 'tool' ? { tool: m.content } : { calls: m.tool_calls.map((c) => c.function.name + ' ' + c.function.arguments) }) }, null, 1))
proc.kill(); await gw.close(); process.exit(0)
