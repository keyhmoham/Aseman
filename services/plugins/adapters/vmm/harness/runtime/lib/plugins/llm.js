/**
 * aseman-llm — every model call of an Aseman Session goes to the node's
 * metered LLM gateway as the turn it belongs to.
 *
 * dsh's own pi-ai adapter carries the `aseman` route (an OpenAI-compatible
 * endpoint on the node). The node resolves the agent's real provider and
 * model from the turn, meters the tokens on it and gates them against the
 * budget and the wallet; the model name the harness uses only selects a
 * context-window class. This plugin adds the turn's token to each request
 * through pi-ai's request-headers waterfall — subagents, forks, teammates
 * and compaction calls of the Session included.
 */

import { bindings as shared } from '../state.js'

export const name = 'aseman-llm'
export const inject = ['agents']

export const TURN_HEADER = 'x-aseman-turn'

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {{ bindings?: import('../bindings.js').Bindings }} [config] - tests pass their own registry
 */
export function apply(ctx, config = {}) {
  const bindings = config.bindings ?? shared

  const parentOf = (id) => {
    const agent = ctx.agents.get(id)
    return agent?.session?.header?.parentSession
  }

  // Children inherit their parent's turn the moment they exist.
  ctx.on('agent/created', ({ agent }) => {
    const parent = agent?.session?.header?.parentSession
    if (parent) bindings.adopt(String(agent.session.id), String(parent))
    return undefined
  })

  ctx.on('llm-pi-ai/request-headers', (request, headers, next) => {
    const out = next() ?? headers
    if (request.provider !== 'aseman') return out
    const binding = bindings.resolve(String(request.sessionId ?? ''), parentOf)
    if (!binding?.token) {
      // No running turn owns this Session: nothing may be billed to anyone.
      throw new Error('this conversation has no running Aseman turn')
    }
    out.set(TURN_HEADER, binding.token)
    return out
  })
}
