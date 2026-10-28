# Aseman Code Mode (Cloudflare)

This Worker wraps Aseman's capability surface with Cloudflare's **search-and-execute Code Mode** MCP (`openApiMcpServer` + `DynamicWorkerExecutor`).

Agents (or any MCP client) get two tools — `search` and `execute` — and write JavaScript against one OpenAPI document of the space's connected apps, platform tools and project timeline. Intermediate results stay in the Worker sandbox; only the return value enters the model context.

The Aseman node already serves the same pattern natively at `/deepagents/v1/codemode/mcp` for in-platform agents. Deploy this Worker when you want:

- External MCP clients (Claude, Cursor, …) to use Aseman capabilities through Code Mode
- Cloudflare's isolated Dynamic Worker executor instead of the node's goja sandbox

## Endpoints the Worker calls on Aseman

| Method | Path | Purpose |
| :--- | :--- | :--- |
| `GET` | `/tools/v1/codemode/openapi` | OpenAPI of apps + platform + timeline (`X-Aseman-Space`) |
| `POST` | `/tools/v1/codemode/request` | Authenticated `codemode.request` → app / platform / timeline |

Paths inside the OpenAPI document:

```
POST /apps/{slug}/{function}   # JSON body = microtool arguments
POST /apps/{slug}/ask          # apps without microtools
POST /platform/{tool}          # files, proxies, routines, desk, UI, db, …
POST /timeline/{tool}          # project timeline reads
POST /sandbox/{op}             # shared computer: exec, write_files, read_files, edit_file, list, delete
POST /agents/{name}            # hand a task to one of the space's agents → {agent, answer}
```

`/agents/{name}` needs a room (`X-Aseman-Room`). `codemode.batch` (concurrent
calls) exists only in the node's own executor; in the Worker, use
`Promise.all` over `codemode.request`.

## Deploy

```bash
cd deploy/codemode
npm install
# Set ASEMAN_ORIGIN to your node (e.g. https://node.example.com)
# Clients send Authorization: Bearer <aseman-session-or-token>
# and the Worker forwards it with X-Aseman-Space from the query or header.
npx wrangler deploy
```

Connect an MCP client to `https://<worker>/mcp?space=<space-id>` with the person's Aseman bearer token. Optional: `X-Aseman-Room` for room-scoped platform tools.

## In-platform agents

No Worker required: deepagents turns receive `codemode: true` and use `codemode_search` / `codemode_execute` against `/deepagents/v1/codemode/mcp`. Apps, platform tools, the timeline, the shared computer (`/sandbox/…`) and the space's agents (`/agents/…`) are injected into that OpenAPI surface automatically, and agents are told to do straightforward jobs in one execute. Messaging, `ask_user`, the native sandbox FS/shell, planning and swarm remain native harness tools.
