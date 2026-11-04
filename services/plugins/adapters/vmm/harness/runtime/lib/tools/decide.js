/**
 * jev_decide — ask the node's decision model (Admin → Decision; typically
 * TypeSafe Jev) typed questions about a state.
 *
 * The main language model keeps planning and generation; bounded judgments
 * (yes/no, pick-one, rubric scores) go here. Calls hit the turn's metered
 * `/llm/evaluate` gateway, which resolves the admin's decision model and
 * bills its own prices onto the turn — provider keys never enter the runtime.
 */

import { defineTool, params } from './define.js'

const QUESTION = {
  type: 'object',
  description:
    'One typed question. type is boolean (yes/no), choice (pick one key of criteria) or score (ordered levels).',
  properties: {
    type: { type: 'string', enum: ['boolean', 'choice', 'score', 'noul'] },
    instructions: { type: 'string', description: 'What to judge.' },
    criteria: {
      type: 'object',
      additionalProperties: { type: 'string' },
      description: 'For choice: map of option id → what it means.',
    },
    levels: {
      type: 'array',
      items: { type: 'string' },
      description: 'For score: ordered level labels (low → high), 2–10.',
    },
  },
  required: ['type'],
  additionalProperties: false,
}

export function decideTools({ gateway, binding }) {
  return [
    defineTool({
      name: 'jev_decide',
      binding,
      concurrent: true,
      timeoutMs: 35_000,
      description:
        'Ask the node\'s decision model (Jev) typed questions about a state and get calibrated ' +
        'answers with probabilities. Use it for bounded judgments — yes/no, pick one option, or a ' +
        'rubric score — while you keep planning and writing. Pass many questions in one call when ' +
        'they share the same state (cheap). If the decision model is off, decide yourself.',
      parameters: params(
        {
          state: {
            anyOf: [{ type: 'string' }, { type: 'object' }],
            description:
              'What to evaluate: a short plain-language brief, or a small JSON object of the facts ' +
              'the judgment needs (message, candidates, options, …).',
          },
          questions: {
            type: 'object',
            additionalProperties: QUESTION,
            description: 'Named questions (1–20). Keys are answer names.',
          },
        },
        ['state', 'questions'],
      ),
      async run({ state, questions }, { signal }) {
        const b = binding()
        if (state === undefined || state === null || state === '') {
          return 'jev_decide needs a state (what to evaluate).'
        }
        if (!questions || typeof questions !== 'object' || Array.isArray(questions) || !Object.keys(questions).length) {
          return 'jev_decide needs at least one named question.'
        }
        let out
        try {
          out = await gateway.post(b.token, '/llm/evaluate', { state, questions }, { signal, timeoutMs: 35_000 })
        } catch (error) {
          const msg = String(error?.message ?? error)
          if (/decision model is off|unavailable|503/i.test(msg)) {
            return 'The decision model is off. Decide yourself with what you know.'
          }
          throw error
        }
        return JSON.stringify(
          { model: out.model, answers: out.answers, usage: out.usage },
          null,
          1,
        )
      },
    }),
  ]
}
