import { spawn } from 'node:child_process'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
const R = process.argv[2], S = process.argv[3]
const { fakeGateway, lastToolResult } = await import(join(R, 'test/support/fake-gateway.js'))
let bodies = []
const gw = fakeGateway({ llm: (body) => { bodies.push(body); return bodies.length === 1 ? { tools: [{ name: 'delegate_task', args: { agent: 'nobody', task: 'x' } }, { name: 'edit_file', args: { path: 'a.txt', old_string: 'zzz', new_string: 'y' } }, { name: 'bash', args: { command: 'ls' } }] } : { text: 'done' } },
  actions: { 'spaces.tools_list': () => ({ tools: [] }), 'spaces.agent_log': () => ({ ok: true }), 'spaces.bots_list': () => ({ bots: [{ id: 'b2', name: 'writer', kind: 'agent', account_id: 'a2', description: 'Writes copy' }] }),
    'spaces.sandbox_files': (b) => (b.operation === 'read' ? { ok: true, data_base64: Buffer.from('hello\nworld\n').toString('base64') } : { ok: true }),
    'spaces.ask': (b) => ({ exit_code: 0, output: 'a.txt\nb.txt\n' }) } })
await gw.start()
const dataDir = mkdtempSync(join(tmpdir(), 'cap-'))
const port = 19000 + Math.floor(Math.random() * 900)
const base = `http://127.0.0.1:${port}`
const proc = spawn(process.execPath, [join(R, 'bin', 'decillion-harness.js')], { env: { ...process.env, DECILLION_DATA_DIR: dataDir, DECILLION_GATEWAY_URL: gw.url, DECILLION_RUNTIME_SECRET: 's', DECILLION_RUNTIME_PORT: String(port) }, stdio: 'ignore' })
for (let i = 0; i < 180; i++) { try { if ((await fetch(base + '/healthz')).ok) break } catch {} await new Promise((r) => setTimeout(r, 500)) }
const r = await (await fetch(base + '/v1/turns', { method: 'POST', headers: { 'content-type': 'application/json', 'x-decillion-runtime': 's' }, body: JSON.stringify({ token: 't', agent: { name: 'decillion', role: 'lead', bot_id: 'b1' }, turn: { space_id: 'sp', room_id: 'rm', sender_name: 'Sara', message: 'go' } }) })).json()
const last = bodies[bodies.length - 1]
console.log(JSON.stringify(last.messages.slice(-5), null, 1))
proc.kill(); await gw.close(); process.exit(0)
