import { spawn } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
const R = process.argv[2], S = process.argv[3]
const { fakeGateway } = await import(join(R, 'test/support/fake-gateway.js'))
const builtins = JSON.parse(readFileSync(join(S, 'builtins.json')))
const person = JSON.parse(readFileSync(join(S, 'person.json')))
const listed = [...builtins, ...person,
  { name: 'Weather', bot_id: 'app-1', kind: 'tool', description: 'Weather app', commands: [{ name: 'forecast', description: 'Forecast for a city', schema: { type: 'object', properties: { city: { type: 'string' } }, required: ['city'] } }] },
  { name: 'Translator', bot_id: 'bot-tr', kind: 'tool', description: 'Translates text between languages.' }]
let captured = []
const gw = fakeGateway({ llm: (body) => { captured.push(body); return { text: 'ok' } }, notes: { space: '', own: '' }, recalled: '',
  actions: { 'spaces.tools_list': () => ({ tools: listed }), 'spaces.agent_log': () => ({ ok: true }) } })
await gw.start()
const dataDir = mkdtempSync(join(tmpdir(), 'cap-'))
const port = 18000 + Math.floor(Math.random() * 1000)
const base = `http://127.0.0.1:${port}`
const proc = spawn(process.execPath, [join(R, 'bin', 'decillion-harness.js')], { env: { ...process.env, DECILLION_DATA_DIR: dataDir, DECILLION_GATEWAY_URL: gw.url, DECILLION_RUNTIME_SECRET: 's', DECILLION_RUNTIME_PORT: String(port) }, stdio: ['ignore', 'pipe', 'pipe'] })
let logs = ''; proc.stdout.on('data', (d) => (logs += d)); proc.stderr.on('data', (d) => (logs += d))
for (let i = 0; i < 180; i++) { try { if ((await fetch(base + '/healthz')).ok) break } catch {} await new Promise((r) => setTimeout(r, 500)) }
const api = async (path, payload) => (await fetch(base + path, { method: 'POST', headers: { 'content-type': 'application/json', 'x-decillion-runtime': 's' }, body: JSON.stringify(payload) })).json()
const agent = (role, extra = {}) => ({ name: role === 'lead' ? 'decillion' : 'coder', description: role === 'lead' ? 'The space lead.' : 'Writes and tests code.', role, bot_id: 'bot-' + role, account_id: 'acct-' + role, vm_id: 'vm-' + role, ...extra })
const out = {}
for (const [key, req] of Object.entries({
  lead: { token: 't1', agent: agent('lead'), turn: { space_id: 'sp', room_id: 'rm', sender_name: 'Sara', message: 'hi', context: 'CTX', note: 'NOTE' }, timeline: true },
  specialist: { token: 't2', agent: agent('specialist', { skills: [{ name: 'tests', description: 'How to test', instructions: 'x' }] }), turn: { space_id: 'sp', room_id: 'rm2', sender_name: 'Sara', message: 'hi' }, timeline: false },
})) { captured = []; const r = await api('/v1/turns', req); out[key] = { reply: r, body: captured[0] } }
captured = []
const r = await api('/v1/chat', { token: 't3', account_id: 'acc', thread_id: 'th', with_tools: true, computer_space: 'home', messages: [{ role: 'user', content: 'hi' }] })
out.personal = { reply: r, body: captured[0] }
writeFileSync(join(S, 'captured.json'), JSON.stringify(out, null, 1))
proc.kill('SIGTERM'); await gw.close()
console.log(Object.fromEntries(Object.entries(out).map(([k, v]) => [k, [v.reply?.status, v.body?.tools?.length]])))
if (!out.lead.body) console.log(logs.slice(-3000))
process.exit(0)
