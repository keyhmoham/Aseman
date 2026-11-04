/**
 * Talking: the room the agent works in, direct messages, and questions only a
 * person can answer.
 *
 * A question pauses the agent's conversation: `ask_user` records it in the
 * runtime store (the node lists it as the agent's open question and the
 * client shows it) and concludes the turn through dsh's own turn control. The
 * person's answer resumes the same dsh Session as its next message.
 */

import { defineTool, params } from './define.js'

const MAX_OPTIONS = 8

export function messagingTools({ gateway, binding, store }) {
  const room = () => {
    const b = binding()
    if (!b?.spaceId || !b.roomId) throw new Error('this conversation is not in a room')
    return b
  }
  return [
    defineTool({
      name: 'post_message',
      binding,
      description:
        'Post a message in the room now (progress worth reporting, a hand-off, talking to someone else). ' +
        'Your final answer is posted for you as the reply: do not repeat it here. Mention people or agents with @name.',
      parameters: params({ text: { type: 'string' } }, ['text']),
      async run({ text }, { signal }) {
        const b = room()
        const out = await gateway.call(b.token, 'spaces', 'message_send', { space: b.spaceId, room: b.roomId, body: String(text) }, { signal })
        return `sent${out.id ? ` (${out.id})` : ''}`
      },
    }),
    defineTool({
      name: 'read_messages',
      binding,
      concurrent: true,
      description: 'Read the latest messages of the room (newest last).',
      parameters: params({ limit: { type: 'integer', description: 'How many (default 30, at most 200).' } }),
      async run({ limit = 30 }, { signal }) {
        const b = room()
        const out = await gateway.call(b.token, 'spaces', 'message_list', { space: b.spaceId, room: b.roomId, limit: clamp(limit, 1, 200) }, { signal })
        return formatMessages(out.messages ?? out.items ?? [])
      },
    }),
    defineTool({
      name: 'search_messages',
      binding,
      concurrent: true,
      description: 'Search the space\'s messages by text.',
      parameters: params({ query: { type: 'string' }, limit: { type: 'integer' } }, ['query']),
      async run({ query, limit = 20 }, { signal }) {
        const b = binding()
        if (!b?.spaceId) throw new Error('this conversation is not in a space')
        const out = await gateway.call(b.token, 'spaces', 'message_search', { space: b.spaceId, query: String(query), limit: clamp(limit, 1, 100) }, { signal })
        return formatMessages(out.messages ?? out.results ?? [])
      },
    }),
    defineTool({
      name: 'send_dm',
      binding,
      description: 'Send a direct message to a person or agent (account id or handle).',
      parameters: params({ to: { type: 'string' }, text: { type: 'string' } }, ['to', 'text']),
      async run({ to, text }, { signal }) {
        const b = binding()
        await gateway.call(b.token, 'users', 'dm_send', { to: String(to), body: String(text) }, { signal })
        return 'sent'
      },
    }),
    defineTool({
      name: 'read_dm',
      binding,
      concurrent: true,
      description: 'Read your direct messages with one person or agent.',
      parameters: params({ peer: { type: 'string' }, limit: { type: 'integer' } }, ['peer']),
      async run({ peer, limit = 30 }, { signal }) {
        const b = binding()
        const out = await gateway.call(b.token, 'users', 'dm_list', { peer: String(peer), limit: clamp(limit, 1, 200) }, { signal })
        return formatMessages(out.messages ?? out.items ?? [])
      },
    }),
    askUserTool({ binding, store }),
  ]
}

export function askUserTool({ binding, store }) {
  return {
    name: 'ask_user',
    description:
      'Ask the people in this conversation something only they can decide or supply. Your work pauses until they ' +
      'answer, then continues in this conversation with the answer. Find out what you can yourself first. ' +
      'Offer options when the answer is a choice.',
    parameters: params({
      question: { type: 'string' },
      options: { type: 'array', items: { type: 'string' }, description: `Up to ${MAX_OPTIONS} choices.` },
    }, ['question']),
    output: { schema: { type: 'string' }, render: (_a, v) => [{ type: 'text', text: String(v) }] },
    async execute(args, exec) {
      const b = binding()
      if (!b?.active) throw new Error('ask_user: this conversation has no running turn')
      const question = String(args.question ?? '').trim()
      if (!question) throw new Error('ask_user needs a question')
      const options = (Array.isArray(args.options) ? args.options : []).map((o) => String(o).trim()).filter(Boolean).slice(0, MAX_OPTIONS)
      const record = store.ask({
        sessionId: b.sessionId,
        vmId: b.agent?.vm_id ?? '',
        botId: b.agent?.bot_id ?? '',
        agent: b.agent?.name ?? '',
        spaceId: b.spaceId,
        roomId: b.roomId,
        accountId: b.accountId,
        question,
        options,
        flags: b.flags,
      })
      b.asked = record
      // The question is this turn's last word: end the turn here.
      exec.concludeTurn()
      return 'Asked. Your work pauses here; the conversation continues with their answer.'
    },
  }
}

export function formatMessages(list) {
  if (!Array.isArray(list) || list.length === 0) return '(no messages)'
  return list
    .map((m) => {
      const who = m.sender_name ?? m.author_name ?? m.sender ?? m.from ?? '?'
      const at = m.created_at ?? m.at ?? ''
      const body = String(m.body ?? m.text ?? m.content ?? '').trim()
      return `[${at}] ${who}: ${body}`
    })
    .join('\n')
}

function clamp(n, lo, hi) {
  const v = Number.parseInt(n, 10)
  return Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : lo
}
