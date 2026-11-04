/**
 * The personal Aseman hands work to the person's own workspace.
 *
 * Long or team work (research across many sites, building something, work
 * that takes a while) goes to the lead and team of the person's home
 * workspace, on the person's own computer: `users.brain_work` starts it as the
 * person and keeps it, and when the team has finished the node writes what
 * came of it into the person's Aseman chat, as an answer to the note it was
 * asked in, with a card that opens the workspace.
 */

import { defineTool, params } from './define.js'

export function workspaceTool({ gateway, binding }) {
  return defineTool({
    name: 'hand_to_workspace',
    binding,
    description:
      "Hand long or team work to the person's own workspace: its lead and team do it on the person's computer, and " +
      'the result is written in this chat by itself when they finish (with a card to open the workspace). Use it for ' +
      'work that takes a while or needs several agents; do quick things yourself. Give a complete brief: the goal, ' +
      'inputs, what "done" means and where to put the result. Then tell the person it is under way and that the ' +
      'result will come here.',
    parameters: params({ request: { type: 'string', description: 'The complete brief for the team.' } }, ['request']),
    async run({ request }, { signal }) {
      const b = binding()
      if (b?.kind !== 'personal') throw new Error('hand_to_workspace is for the personal Aseman')
      const brief = String(request ?? '').trim()
      if (!brief) throw new Error('say what the work is')
      const out = await gateway.call(b.token, 'users', 'brain_work', { request: brief }, { signal })
      return `Started in ${out.name || 'their workspace'} (space ${out.space_id}). The result will be written in this chat when the team finishes: say so; do not wait for it.`
    },
  })
}
