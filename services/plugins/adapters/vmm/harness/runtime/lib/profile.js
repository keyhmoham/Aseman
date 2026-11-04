/**
 * The `aseman` dsh profile: the patch layer the runtime boots dsh with.
 *
 * It starts from dsh's shipped `sdk` template (dsh-base: the agent loop,
 * Sessions on disk, compaction, spill, retry, goals, todos, workflows,
 * subagents, plugin manager) and makes it Aseman's:
 *   - the stdio JSON-RPC server is off: Aseman's host plugin serves the node;
 *   - the LLM is the node's metered gateway (the `aseman` route on dsh's pi-ai
 *     adapter), with compaction tuned per context-window class;
 *   - the runtime's own machine is not the space's computer: dsh's local
 *     shell, file and working-directory tools are off (the Aseman sandbox tools
 *     replace them), and so are plan mode (no reviewer in a room), skills from
 *     the local disk, session titles and web search on DeepSeek's key;
 *   - Agent Teams (dsh's experimental team layer) replace plain subagents;
 *   - earlier sessions are searchable (FTS5) with dsh's session-query tools;
 *   - Aseman's plugins: aseman-llm (the turn's token on every model call) and
 *     aseman-host (the node's API and the turn driver).
 */

import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { WINDOWS, modelFor, ROUTE } from './models.js'

const HERE = dirname(fileURLToPath(import.meta.url))

export const TOKEN_ENV = 'ASEMAN_HARNESS_LLM_KEY'

const DISABLED = [
  // The SDK template's stdio transport and its lifetime; Aseman's host serves.
  'sdk-jsonrpc-server', 'sdk-app-startup', 'schedule', 'workspace-dependencies', 'skill-office',
  // DeepSeek's own account routes: models come from the node.
  'llm-deepseek', 'llm-deepseek-account',
  // The runtime's machine is not the space's computer.
  'tool-bash', 'tool-pwsh', 'tool-fs', 'tool-fs-search', 'tool-jobs', 'tool-working-directory',
  // No reviewer for plan mode in a room; skills are per agent (load_skill).
  'plan-mode', 'skill', 'skill-filesystem', 'tool-skill',
  // Titles cost model calls nobody reads; web search needs DeepSeek's key.
  'session-title-llm', 'web', 'web-search-deepseek', 'web-deepseek-api', 'web-fetch-http', 'tool-web',
  // Agent Teams replace the plain subagent tools.
  'tool-subagent-control', 'tool-subagent', 'tool-subagent-fork',
]

export function models() {
  return WINDOWS.map((w) => ({
    id: modelFor(w, w),
    name: modelFor(w, w),
    contextWindow: w,
    maxTokens: Math.min(16384, Math.floor(w / 4)),
  }))
}

/** Compaction headroom scaled to each window (dsh's 64k default disables it below ~74k). */
export function compactionPolicies() {
  return models().map((m) => ({
    provider: ROUTE,
    model: m.id,
    headroomTokens: Math.min(65536, Math.floor(m.contextWindow * 0.15)),
  }))
}

/**
 * @param {{ gateway: string, defaultContextWindow: number, dataDir: string }} config
 * @param {Set<string> | undefined} available - row ids the installed profile has
 */
export function buildPatch(config, available) {
  const rows = []
  const has = (id) => !available || available.has(id)
  for (const id of DISABLED) if (has(id)) rows.push({ id, disabled: true })
  rows.push({
    id: 'llm-pi-ai',
    config: {
      providers: {
        [ROUTE]: {
          displayName: 'Aseman',
          api: 'openai-completions',
          baseURL: `${config.gateway}/llm`,
          apiKeyEnv: TOKEN_ENV,
          models: models(),
          defaultContextWindow: config.defaultContextWindow,
          // The gateway already retries a provider and bills every attempt.
          retryPolicy: { mode: 'normal', maxRetries: 2 },
        },
      },
    },
  })
  rows.push({ id: 'agent-default-model', config: { provider: ROUTE, model: modelFor(config.defaultContextWindow, config.defaultContextWindow) } })
  if (has('compaction-basic')) rows.push({ id: 'compaction-basic', config: { modelPolicies: compactionPolicies() } })
  rows.push({
    insert: [
      {
        id: 'agent-team',
        name: '@deepseek-ai/dsh-experimental-agent-team',
        config: { maxMembers: 8, maxTasks: 256, maxMessageBytes: 65536, disposalTimeoutMs: 5000 },
      },
      { id: 'tool-agent-team', name: '@deepseek-ai/dsh-experimental-tool-agent-team', config: { freshProvider: 'spawn', forkProvider: 'fork' } },
      {
        id: 'aseman-session-search',
        name: 'cordis:group',
        group: true,
        isolate: { sessionQuery: true },
        config: [
          {
            id: 'aseman-session-query-sqlite',
            name: '@deepseek-ai/dsh-session-query-sqlite',
            config: { path: join(config.dataDir, 'session-index.sqlite'), openAt: 'first-search' },
          },
          { id: 'aseman-tool-session-query', name: '@deepseek-ai/dsh-tool-session-query' },
        ],
      },
      { id: 'aseman-llm', name: join(HERE, 'plugins', 'llm.js') },
      { id: 'aseman-host', name: join(HERE, 'plugins', 'host.js') },
    ],
  })
  return rows
}
