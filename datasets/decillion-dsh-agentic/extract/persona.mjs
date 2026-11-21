import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
const [R, S] = process.argv.slice(2)
const P = await import(join(S, 'cap/persona_x.mjs'))
const sec = {}
for (const n of ['HARNESS', 'CHAT_RENDER', 'LEAD', 'SPECIALIST', 'PERSONAL_SHOW', 'PERSONAL', 'OUTSIDE', 'CREATOR_GUIDE']) sec[n] = P[n]
const cap = JSON.parse(readFileSync(join(S, 'captured.json')))
const lead = P.personaFor({ name: 'decillion', description: 'The space lead.', lead: true })
const spec = P.personaFor({ name: 'coder', description: 'Writes and tests code.', lead: false, skills: [{ name: 'tests', description: 'How to test', instructions: 'x' }] })
const pers = P.personalPersona(undefined)
const out = { sections: sec, checks: {} }
for (const [k, persona] of [['lead', lead], ['specialist', spec], ['personal', pers]]) {
  const full = cap[k].body.messages[0].content
  const i = full.indexOf(persona)
  out.checks[k] = { found: i >= 0, prefix: full.slice(0, i), suffix: full.slice(i + persona.length) }
}
// reference personas for python parity tests
const agents = [
  { name: 'decillion', description: 'The space lead.', lead: true },
  { name: 'coder', description: 'Writes and tests code.', lead: false, instructions: 'Use TypeScript.\nKeep diffs small.', skills: [{ name: 'tests', description: 'How to test' }, { name: 'release', description: 'Cut a release' }] },
  { name: 'analyst', description: '', lead: false },
]
out.reference = agents.map((a) => ({ agent: a, persona: P.personaFor(a) }))
out.reference_personal = [{ system: '', persona: P.personalPersona('') }, { system: 'The person prefers Persian.', persona: P.personalPersona('The person prefers Persian.') }]
writeFileSync(join(S, 'persona_parts.json'), JSON.stringify(out, null, 1))
console.log(Object.fromEntries(Object.entries(out.checks).map(([k, v]) => [k, [v.found, JSON.stringify(v.prefix), v.suffix.length]])))
console.log(out.checks.lead.suffix === out.checks.specialist.suffix, out.checks.lead.suffix === out.checks.personal.suffix)
