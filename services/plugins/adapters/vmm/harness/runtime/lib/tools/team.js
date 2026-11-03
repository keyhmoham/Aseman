/**
 * The space's agents as a team.
 *
 * Inside one agent's turn, dsh brings its own swarm: subagents (fresh or
 * forked children), Agent Teams for a lead (teammates with a mailbox and a
 * shared task board) and workflows. Those children are the same agent working
 * in parallel. The space's *other* Aseman agents are separate agents with
 * their own definitions, models, skills and memory: a lead hands them work
 * with delegate_task (a room task they answer in their own turn), staffs a
 * goal by recruiting a specialist it writes, or hires one published in the
 * marketplace.
 */

import { defineTool, params } from './define.js'
import { randomBytes } from 'node:crypto'

export async function agentsOf(gateway, b, signal) {
  const out = await gateway.call(b.token, 'spaces', 'bots_list', { space: b.spaceId }, { signal })
  return (out.bots ?? []).filter((x) => x.kind === 'agent')
}

export function findAgent(agents, who) {
  const key = String(who ?? '').trim().replace(/^@/, '').toLowerCase()
  return agents.find((a) => [a.name, a.id, a.account_id].some((v) => String(v ?? '').toLowerCase() === key))
}

export function teamTools({ gateway, binding }) {
  const inSpace = () => {
    const b = binding()
    if (!b?.spaceId || !b.roomId) throw new Error('this conversation is not in a space room')
    return b
  }
  const tools = [
    defineTool({
      name: 'list_team',
      binding,
      concurrent: true,
      description: 'The space\'s agents (name, what each does) you can hand work to with delegate_task.',
      parameters: params({}),
      async run(_args, { signal }) {
        const b = inSpace()
        const agents = await agentsOf(gateway, b, signal)
        const me = b.agent?.bot_id
        const lines = agents.filter((a) => a.id !== me).map((a) => `- ${a.name}: ${String(a.description ?? '').slice(0, 300)}`)
        return lines.length ? lines.join('\n') : 'No other agents in this space yet (recruit_agent or hire_agent can add one).'
      },
    }),
    defineTool({
      name: 'delegate_task',
      binding,
      concurrent: true,
      description:
        'Hand a task to another agent of the space and wait for its answer. Say everything it needs in the task: ' +
        'it works in its own conversation and sees only what you write. Several delegations run in parallel.',
      parameters: params({ agent: { type: 'string', description: 'Its name.' }, task: { type: 'string' } }, ['agent', 'task']),
      async run({ agent, task }, { signal }) {
        const b = inSpace()
        if (!String(task ?? '').trim()) throw new Error('delegate_task needs a task')
        const member = findAgent(await agentsOf(gateway, b, signal), agent)
        if (!member) throw new Error(`no agent ${JSON.stringify(agent)} in this space: see list_team, or recruit_agent / hire_agent`)
        if (member.id === b.agent?.bot_id) throw new Error('that is you: do the work yourself, or use a subagent')
        const tag = randomBytes(3).toString('hex')
        const out = await gateway.call(b.token, 'spaces', 'message_send', {
          space: b.spaceId, room: b.roomId, body: `@${member.name} [task ${tag}] ${task}`,
          mentions: [member.account_id], wait: true,
        }, { signal })
        const reply = (out.replies ?? []).find((r) => r.bot_id === member.id)
        if (!reply) return `${member.name} did not take the task${out.error ? `: ${out.error}` : ''}`
        return `${member.name}: ${String(reply.reply ?? '').trim() || '(answered with no text)'}`
      },
    }),
  ]
  const b0 = binding()
  if (b0?.agent?.lead) {
    tools.push(
      defineTool({
        name: 'recruit_agent',
        binding,
        description:
          'Add a new specialist agent to the space for a role no existing or marketplace agent fits. Write its ' +
          'definition: a clear name, what it does, its standing instructions and optional skills.',
        parameters: params({
          name: { type: 'string' },
          description: { type: 'string' },
          instructions: { type: 'string' },
          skills: {
            type: 'array',
            items: params({ name: { type: 'string' }, description: { type: 'string' }, instructions: { type: 'string' } }, ['name', 'instructions']),
          },
        }, ['name', 'description', 'instructions']),
        async run({ name, description, instructions, skills }, { signal }) {
          const b = inSpace()
          const out = await gateway.call(b.token, 'spaces', 'agent_recruit', {
            space: b.spaceId, room: b.roomId, name, description, instructions, skills: skills?.length ? skills : undefined,
          }, { signal })
          return `recruited ${out.name ?? name} (bot ${out.bot_id}). Hand it work with delegate_task.`
        },
      }),
      defineTool({
        name: 'hire_agent',
        binding,
        description:
          'Find agents published in the marketplace (query) or hire one into the space (listing id). A hired agent ' +
          'keeps its owner\'s definition and pricing.',
        parameters: params({ query: { type: 'string' }, listing: { type: 'string' } }),
        async run({ query, listing }, { signal }) {
          const b = inSpace()
          if (listing) {
            const out = await gateway.call(b.token, 'spaces', 'agent_hire', { space: b.spaceId, room: b.roomId, listing }, { signal })
            return `hired ${out.name ?? 'the agent'} (bot ${out.bot_id}). Hand it work with delegate_task.`
          }
          const out = await gateway.call(b.token, 'market', 'catalog', { status: 'active' }, { signal })
          const words = String(query ?? '').toLowerCase().split(/\W+/).filter((w) => w.length > 2)
          const rows = (out.items ?? [])
            .filter((r) => !r.builtin && (r.kind ?? r.bot?.kind) === 'agent' && r.listing?.id)
            .map((r) => {
              const d = r.descriptor ?? {}
              const name = d.name ?? r.listing.name ?? r.bot?.name ?? 'agent'
              const desc = String(r.description ?? d.description ?? r.listing.description ?? '')
              const hay = `${name} ${desc}`.toLowerCase()
              return { name, desc, id: r.listing.id, price: r.listing.price ?? 0, score: words.filter((w) => hay.includes(w)).length }
            })
            .filter((r) => !words.length || r.score > 0)
            .sort((a, b) => b.score - a.score)
            .slice(0, 15)
          if (!rows.length) return 'No published agent matches.'
          return rows.map((r) => `- ${r.name} (listing ${r.id}, price ${r.price}): ${r.desc.slice(0, 200)}`).join('\n')
        },
      }),
    )
  }
  return tools
}
