/**
 * The space's shared computer as the agent's shell and filesystem.
 *
 * Every agent of a space — and every subagent, teammate and fork of them —
 * works on the same Linux sandbox the platform runs for the space. A command
 * is an ask of the space's sandbox bot (`spaces.ask` with `raw`), billed and
 * logged like every other tool. Files go through the project's stored files
 * (`spaces.sandbox_files`), which the platform reads and writes while the
 * computer sleeps; only running something wakes it. dsh's own local shell and
 * file tools are off: the runtime's machine is not the space's computer.
 */

import { posix } from 'node:path'
import { defineTool, params } from './define.js'

export const WORKSPACE = '/workspace'
const MAX_READ_LINES = 2000
const CHUNK = 48 * 1024

export function shq(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`
}

/** An absolute path under the workspace (relative paths are workspace-relative). */
export function absolute(path) {
  const raw = String(path ?? '').trim()
  if (!raw) throw new Error('a path is required')
  return posix.normalize(raw.startsWith('/') ? raw : posix.join(WORKSPACE, raw))
}

function stored(path) {
  if (path === WORKSPACE) return '.'
  return path.startsWith(WORKSPACE + '/') ? path.slice(WORKSPACE.length + 1) : null
}

export function numbered(text, offset = 0, limit = MAX_READ_LINES) {
  if (text === '') return '(empty file)'
  const lines = text.split('\n')
  if (lines.length > 1 && lines[lines.length - 1] === '') lines.pop()
  const start = Math.max(0, offset)
  const slice = lines.slice(start, start + limit)
  const width = String(start + slice.length).length
  const body = slice.map((line, i) => `${String(start + i + 1).padStart(width)}\t${line}`).join('\n')
  const more = lines.length > start + slice.length ? `\n[… ${lines.length - start - slice.length} more lines: read with offset=${start + slice.length}]` : ''
  return (body || '(empty file)') + more
}

/** Replace `old` with `replacement` in `text` the way the model asked. */
export function applyEdit(text, old, replacement, replaceAll = false) {
  if (!old) throw new Error('old_string must not be empty (use write_file to create a file)')
  if (old === replacement) throw new Error('old_string and new_string are the same')
  const count = text.split(old).length - 1
  if (count === 0) throw new Error('old_string was not found in the file; read it again and copy the text exactly')
  if (count > 1 && !replaceAll) throw new Error(`old_string occurs ${count} times; add surrounding lines to make it unique, or set replace_all`)
  return { text: replaceAll ? text.split(old).join(replacement) : text.replace(old, () => replacement), count: replaceAll ? count : 1 }
}

export class Computer {
  constructor(gateway, binding) {
    this.gateway = gateway
    this.binding = binding
  }

  guard() {
    const b = this.binding()
    if (!b?.spaceId) throw new Error('this conversation has no space computer')
    if (b.flags?.no_sandbox) throw new Error('the space computer is disabled for this request')
    return b
  }

  async exec(command, signal) {
    const b = this.guard()
    const out = await this.gateway.call(b.token, 'spaces', 'ask', {
      space: b.spaceId, room: b.roomId, bot: b.flags?.sandbox_bot || 'sandbox', body: command, raw: true,
    }, { signal })
    const code = Number.isInteger(out.exit_code) ? out.exit_code : -1
    return { code, output: String(out.output ?? out.reply ?? '') }
  }

  /** One stored-files operation; null when it must go through the shell. */
  async files(operation, path, extra, signal) {
    const b = this.guard()
    const rel = stored(path)
    if (rel === null) return null
    let out
    try {
      out = await this.gateway.call(b.token, 'spaces', 'sandbox_files', { space: b.spaceId, operation, path: rel, ...extra }, { signal })
    } catch {
      return null
    }
    if (out.asleep) return null
    return out
  }

  async read(path, signal) {
    const out = await this.files('read', path, {}, signal)
    if (out && out.missing) throw new Error(`${path} does not exist`)
    if (out && typeof out.data_base64 === 'string') return Buffer.from(out.data_base64, 'base64')
    const { code, output } = await this.exec(`base64 -w0 ${shq(path)}`, signal)
    if (code !== 0) throw new Error(output.trim() || `cannot read ${path}`)
    return Buffer.from(output.trim(), 'base64')
  }

  async write(path, data, signal) {
    const out = await this.files('write', path, { data_base64: data.toString('base64') }, signal)
    if (out && out.ok !== false && !out.unreadable) return
    const b64 = data.toString('base64')
    let first = true
    for (let i = 0; i < b64.length || first; i += CHUNK) {
      const part = b64.slice(i, i + CHUNK)
      const redirect = first ? '>' : '>>'
      const cmd = `${first ? `mkdir -p ${shq(posix.dirname(path))} && ` : ''}printf %s ${shq(part)} | base64 -d ${redirect} ${shq(path)}`
      const { code, output } = await this.exec(cmd, signal)
      if (code !== 0) throw new Error(output.trim() || `cannot write ${path}`)
      first = false
    }
  }
}

export function sandboxTools({ gateway, binding, attachments }) {
  const pc = new Computer(gateway, binding)
  const tools = [
    defineTool({
      name: 'bash',
      binding,
      description:
        'Run a shell command on the space\'s shared Linux computer (the same machine every agent of the space uses). ' +
        `Work under ${WORKSPACE} with absolute paths. Returns the exit code and output. The desktop helper ` +
        '`aseman-desktop` (start, open <url>, screenshot <file.png> [width], click x y, type, key) drives a real screen; ' +
        'look at screenshots with read_image.',
      parameters: params({ command: { type: 'string', description: 'The command (bash).' } }, ['command']),
      async run({ command }, { signal }) {
        if (!String(command ?? '').trim()) throw new Error('command is required')
        const { code, output } = await pc.exec(String(command), signal)
        return `exit ${code}\n${output}`
      },
    }),
    defineTool({
      name: 'read_file',
      binding,
      concurrent: true,
      description: `Read a text file from the space computer (relative paths are under ${WORKSPACE}). Lines are numbered; use offset/limit for long files.`,
      parameters: params({
        path: { type: 'string' },
        offset: { type: 'integer', description: 'First line to read, 0-based.' },
        limit: { type: 'integer', description: `Lines to read (default ${MAX_READ_LINES}).` },
      }, ['path']),
      async run({ path, offset = 0, limit = MAX_READ_LINES }, { signal }) {
        const abs = absolute(path)
        const data = await pc.read(abs, signal)
        if (data.includes(0)) return `${abs} is a binary file (${data.length} bytes); use read_image for images or bash to inspect it.`
        return numbered(data.toString('utf8'), Number(offset) || 0, Math.min(Number(limit) || MAX_READ_LINES, MAX_READ_LINES))
      },
    }),
    defineTool({
      name: 'write_file',
      binding,
      description: `Create or overwrite a text file on the space computer (relative paths are under ${WORKSPACE}). Parent folders are created.`,
      parameters: params({ path: { type: 'string' }, content: { type: 'string' } }, ['path', 'content']),
      async run({ path, content }, { signal }) {
        const abs = absolute(path)
        await pc.write(abs, Buffer.from(String(content ?? ''), 'utf8'), signal)
        return `wrote ${abs}`
      },
    }),
    defineTool({
      name: 'edit_file',
      binding,
      description: 'Replace exact text in a file on the space computer. old_string must match the file exactly and be unique unless replace_all is set.',
      parameters: params({
        path: { type: 'string' },
        old_string: { type: 'string' },
        new_string: { type: 'string' },
        replace_all: { type: 'boolean' },
      }, ['path', 'old_string', 'new_string']),
      async run({ path, old_string, new_string, replace_all = false }, { signal }) {
        const abs = absolute(path)
        const before = (await pc.read(abs, signal)).toString('utf8')
        const { text, count } = applyEdit(before, String(old_string), String(new_string ?? ''), Boolean(replace_all))
        await pc.write(abs, Buffer.from(text, 'utf8'), signal)
        return `edited ${abs} (${count} replacement${count === 1 ? '' : 's'})`
      },
    }),
    defineTool({
      name: 'list_files',
      binding,
      concurrent: true,
      description: `List a folder on the space computer (default ${WORKSPACE}).`,
      parameters: params({ path: { type: 'string' } }),
      async run({ path = WORKSPACE }, { signal }) {
        const abs = absolute(path)
        const out = await pc.files('list', abs, {}, signal)
        if (out && Array.isArray(out.items)) {
          if (!out.items.length) return `${abs} is empty`
          return out.items.map((e) => `${e.type === 'dir' ? 'd' : '-'} ${String(e.size ?? 0).padStart(10)}  ${e.name}${e.type === 'dir' ? '/' : ''}`).join('\n')
        }
        if (out && out.missing) return `${abs} does not exist`
        const { output } = await pc.exec(`ls -la ${shq(abs)}`, signal)
        return output
      },
    }),
    defineTool({
      name: 'glob',
      binding,
      concurrent: true,
      description: `Find files by name pattern (e.g. "**/*.ts") under a folder (default ${WORKSPACE}). Runs on the space computer.`,
      parameters: params({ pattern: { type: 'string' }, path: { type: 'string' } }, ['pattern']),
      async run({ pattern, path = WORKSPACE }, { signal }) {
        const abs = absolute(path)
        const cmd = `cd ${shq(abs)} && shopt -s globstar nullglob dotglob && for f in ${String(pattern).replace(/[^A-Za-z0-9_*?.\/\-\[\]{},]/g, '')}; do echo "$PWD/$f"; done | grep -v '/node_modules/\\|/\\.git/' | head -500`
        const { code, output } = await pc.exec(`bash -c ${shq(cmd)}`, signal)
        if (code !== 0 && !output.trim()) return `no match (exit ${code})`
        return output.trim() || 'no match'
      },
    }),
    defineTool({
      name: 'grep',
      binding,
      concurrent: true,
      description: `Search file contents with a regular expression (extended) under a folder (default ${WORKSPACE}). Returns file:line:text matches.`,
      parameters: params({
        pattern: { type: 'string' },
        path: { type: 'string' },
        include: { type: 'string', description: 'Only files matching this glob, e.g. "*.py".' },
        ignore_case: { type: 'boolean' },
      }, ['pattern']),
      async run({ pattern, path = WORKSPACE, include, ignore_case = false }, { signal }) {
        const abs = absolute(path)
        const flags = `-rnE${ignore_case ? 'i' : ''} --exclude-dir=node_modules --exclude-dir=.git`
        const inc = include ? ` --include=${shq(include)}` : ''
        const { code, output } = await pc.exec(`grep ${flags}${inc} -e ${shq(pattern)} ${shq(abs)} | head -400`, signal)
        if (code !== 0 && !output.trim()) return 'no match'
        return output
      },
    }),
  ]
  if (attachments) {
    tools.push(readImageTool({ pc, binding, attachments }))
  }
  return tools
}

const IMAGE_TYPES = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.gif': 'image/gif' }

/** read_image: the picture itself, so the agent sees pixels (screenshots, designs). */
function readImageTool({ pc, binding, attachments }) {
  return {
    name: 'read_image',
    description: 'Look at an image file on the space computer (PNG/JPEG/WebP/GIF): returns the image itself. Use it on desktop screenshots to check what a screen really shows.',
    parameters: params({ path: { type: 'string' } }, ['path']),
    output: {
      schema: { type: 'object' },
      render: (_args, value) => [
        { type: 'text', text: `${value.path}: ${value.image.mediaType} ${value.image.width}x${value.image.height}` },
        { type: 'image', attachment: value.image },
      ],
    },
    isConcurrencySafe: () => true,
    async execute(args, exec) {
      const b = binding()
      if (!b?.active) throw new Error('read_image: this conversation has no running turn')
      const store = attachments()
      if (!store) throw new Error('read_image: images are not available in this runtime')
      const abs = absolute(args.path)
      const mediaType = IMAGE_TYPES[posix.extname(abs).toLowerCase()]
      if (!mediaType) throw new Error('read_image reads PNG, JPEG, WebP or GIF files')
      const data = await pc.read(abs, exec.signal)
      const ref = await store.saveImage({ data: new Uint8Array(data), mediaType, name: posix.basename(abs) })
      return { path: abs, image: { ...ref } }
    },
  }
}
