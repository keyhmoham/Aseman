/**
 * The space's own capabilities as native dsh tools, generated each turn.
 *
 * `spaces.tools_list` names what this space offers the agent right now: the
 * platform's builtins (files, desk windows, AG-UI cards, app building,
 * routines, proxies, images, …) with their JSON schemas, and the space's
 * apps — connected MCP apps with their functions, and tool bots asked in plain
 * words. Each becomes one tool; calling it is `spaces.ask` as the agent,
 * inside the turn's execution scope, where the node checks the agent's grants,
 * the request's flags and the payer's funds exactly as for any other ask.
 * What an app answers is outside content and reaches the model enveloped.
 */

import { params } from './define.js'
import { clip } from './define.js'
import { wrap } from '../untrusted.js'

/** Builtins the runtime replaces with its own tools, or that no longer exist. */
const REPLACED = new Set(['sandbox_exec', 'file_edit', 'opencode_run', 'opencode_status', 'opencode_models'])
/** Native tool names a generated one must never shadow. */
export const RESERVED = new Set([
  'bash', 'read_file', 'write_file', 'edit_file', 'list_files', 'glob', 'grep', 'read_image',
  'post_message', 'read_messages', 'search_messages', 'send_dm', 'read_dm', 'ask_user',
  'aseman_api_search', 'aseman_api_call', 'remember', 'recall', 'rewrite_notes',
  'list_team', 'delegate_task', 'recruit_agent', 'hire_agent', 'load_skill',
  'create_gadget', 'list_gadgets', 'hand_to_workspace', 'timeline_search', 'timeline_entry',
  // dsh's own tools (Agent Teams, planning, workflows, session search).
  'send_message', 'list_agents', 'wait_agent', 'interrupt_agent', 'spawn_teammate',
  'team_task_create', 'team_task_list', 'team_task_get', 'team_task_update',
  'todo_write', 'workflow', 'run_code', 'session_search', 'session_event_search', 'session_trace',
  'session_event_trace', 'session_event_read',
])

export function toolName(raw, used) {
  let name = String(raw ?? '').toLowerCase().replace(/[^a-z0-9_-]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 60) || 'tool'
  if (/^[0-9]/.test(name)) name = `t_${name}`
  let candidate = name
  for (let i = 2; used.has(candidate) || RESERVED.has(candidate); i++) candidate = `${name.slice(0, 56)}_${i}`
  used.add(candidate)
  return candidate
}

function schemaOf(raw) {
  const s = raw && typeof raw === 'object' ? raw : {}
  return params(s.properties && typeof s.properties === 'object' ? s.properties : {}, Array.isArray(s.required) ? s.required : [])
}

/** Keep the tools an agent restricted to `allowed` may use (empty: all). */
export function allowedBy(allowed, name, bareName) {
  if (!Array.isArray(allowed) || allowed.length === 0) return true
  return allowed.includes(name) || (bareName !== undefined && allowed.includes(bareName))
}

/**
 * Tool definitions for one turn of one agent.
 * @param {object} deps
 * @param {Array<object>} deps.listed - `spaces.tools_list` entries
 */
export function spaceTools({ gateway, binding, listed, attachments }) {
  const b0 = binding()
  const allowed = b0?.agent?.allowed_tools
  const used = new Set()
  const out = []
  for (const t of Array.isArray(listed) ? listed : []) {
    if (!t || !t.name || REPLACED.has(t.name)) continue
    if (t.bot_id && !t.parameters && !(t.commands?.length) && /shared computer \(sandbox\)/.test(t.description ?? '')) continue
    if (Array.isArray(t.commands) && t.commands.length) {
      for (const c of t.commands) {
        const name = toolName(`${t.name}__${c.name}`, used)
        if (!allowedBy(allowed, name, t.name)) continue
        out.push(appFunction({ gateway, binding, name, app: t, command: c }))
      }
      continue
    }
    if (t.bot_id && !t.parameters) {
      const name = toolName(t.name, used)
      if (!allowedBy(allowed, name)) continue
      out.push(appRequest({ gateway, binding, name, app: t }))
      continue
    }
    const name = toolName(t.name, used)
    if (!allowedBy(allowed, name, t.name)) continue
    out.push(platformTool({ gateway, binding, name, platformName: t.name, spec: t, attachments }))
  }
  return out
}

function textOutput() {
  return { schema: { type: 'string' }, render: (_a, v) => [{ type: 'text', text: String(v) }] }
}

function scope(binding, name) {
  const b = binding()
  if (!b?.active) throw new Error(`${name}: this conversation has no running turn`)
  // Personal Aseman uses the home computer space for App UI / gadget builtins.
  const space = b.spaceId || b.computerSpace
  if (!space) throw new Error(`${name}: this conversation is not in a space`)
  return { ...b, spaceId: space }
}

function appFunction({ gateway, binding, name, app, command }) {
  const description = `[${app.name}] ${String(command.description || `${command.name} of ${app.name}.`).slice(0, 1500)}`
  return {
    name,
    description,
    parameters: schemaOf(command.schema),
    output: textOutput(),
    async execute(args, exec) {
      const b = scope(binding, name)
      const res = await gateway.call(b.token, 'spaces', 'ask', {
        space: b.spaceId, room: b.roomId, bot: app.bot_id,
        body: JSON.stringify({ function: command.name, payload: args ?? {} }),
      }, { signal: exec.signal })
      return clip(wrap(`app ${app.name}`, String(res.reply ?? '')))
    },
  }
}

function appRequest({ gateway, binding, name, app }) {
  return {
    name,
    description: `${String(app.description || `The ${app.name} tool of this space.`).slice(0, 1500)}\nSend it a request in plain words or its command syntax; returns its reply.`,
    parameters: params({ request: { type: 'string' } }, ['request']),
    output: textOutput(),
    async execute(args, exec) {
      const b = scope(binding, name)
      const res = await gateway.call(b.token, 'spaces', 'ask', {
        space: b.spaceId, room: b.roomId, bot: app.bot_id, body: String(args?.request ?? ''),
      }, { signal: exec.signal })
      return clip(wrap(`app ${app.name}`, String(res.reply ?? '')))
    },
  }
}

/** A platform builtin; an image it returns (`__multimodal`) reaches the model as an image. */
function platformTool({ gateway, binding, name, platformName, spec, attachments }) {
  let description = String(spec.description || platformName).slice(0, 3000)
  if (spec.usage) description += `\n${String(spec.usage).slice(0, 3000)}`
  return {
    name,
    description,
    parameters: schemaOf(spec.parameters),
    output: {
      schema: {},
      render: (_a, v) => (v && typeof v === 'object' && v.image
        ? [{ type: 'text', text: String(v.text ?? 'image') }, { type: 'image', attachment: v.image }]
        : [{ type: 'text', text: String(v) }]),
    },
    async execute(args, exec) {
      const b = scope(binding, name)
      const res = await gateway.call(b.token, 'spaces', 'ask', {
        space: b.spaceId, room: b.roomId, tool: platformName, args: args ?? {},
      }, { signal: exec.signal })
      const result = res.result ?? res
      const text = typeof result === 'string' ? result : JSON.stringify(result)
      const image = await asImage(text, attachments)
      return image ?? clip(text)
    },
  }
}

/** `{"__multimodal": {"text", "image_url": "data:…"}}` → a saved image attachment. */
export async function asImage(text, attachments) {
  const s = String(text).trim()
  if (!s.startsWith('{') || !s.includes('__multimodal')) return undefined
  let multi
  try {
    multi = JSON.parse(s).__multimodal
  } catch {
    return undefined
  }
  const url = multi?.image_url
  const m = typeof url === 'string' ? /^data:(image\/(?:png|jpeg|webp|gif));base64,(.+)$/s.exec(url) : null
  const store = attachments?.()
  if (!m || !store) return multi?.text ? String(multi.text) : undefined
  const ref = await store.saveImage({ data: new Uint8Array(Buffer.from(m[2], 'base64')), mediaType: m[1], name: 'image' })
  return { text: String(multi.text ?? 'image'), image: { ...ref } }
}
