/**
 * A small builder for dsh ToolDefinitions with text results.
 *
 * Every Aseman tool works for the turn running in its Session: it refuses
 * when no turn is active (the token is gone) and follows the turn's abort
 * signal, so a cancelled room turn stops its tools too.
 */

export const DEFAULT_MAX_CHARS = 48000

/** Plain JSON-schema object parameters from a compact property map. */
export function params(properties, required = []) {
  return { type: 'object', properties, required, additionalProperties: false }
}

export function clip(value, max = DEFAULT_MAX_CHARS) {
  const text = typeof value === 'string' ? value : JSON.stringify(value, null, 1)
  if (text === undefined) return ''
  return text.length <= max ? text : `${text.slice(0, max)}\n[… ${text.length - max} more characters clipped]`
}

/**
 * @param {object} spec
 * @param {string} spec.name
 * @param {string} spec.description
 * @param {object} spec.parameters - JSON schema of the arguments
 * @param {(args: any, run: { exec: any, signal: AbortSignal }) => Promise<unknown>} spec.run
 * @param {() => import('../bindings.js').Binding | undefined} spec.binding
 * @param {boolean} [spec.concurrent] - safe to run beside other calls
 * @param {number} [spec.timeoutMs]
 * @param {number} [spec.maxChars]
 */
export function defineTool({ name, description, parameters, run, binding, concurrent = false, timeoutMs, maxChars }) {
  return {
    name,
    description,
    parameters,
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: String(value) }],
    },
    ...(timeoutMs ? { timeoutMs } : {}),
    isConcurrencySafe: () => concurrent,
    async execute(args, exec) {
      const b = binding()
      if (!b || !b.active) throw new Error(`${name}: this conversation has no running turn`)
      const signal = b.signal ? AbortSignal.any([exec.signal, b.signal]) : exec.signal
      const value = await run(args ?? {}, { exec, signal, binding: b })
      return clip(value === undefined ? 'done' : value, maxChars)
    },
  }
}

/** Register many tools on a (scoped) context; returns one disposer. */
export function registerAll(ctx, definitions) {
  const disposers = definitions.map((d) => ctx.tools.register(d))
  return () => {
    for (const dispose of disposers.splice(0)) {
      try {
        dispose()
      } catch {
        // Already gone with its scope.
      }
    }
  }
}
