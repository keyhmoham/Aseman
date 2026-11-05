# OpenDuet parity plan

What OpenDuet (on CopilotKit's OpenBot) does that Aseman did not, and how each
piece is built into Aseman's own architecture: Go action namespaces loaded as
plugins, consumer-owned bridge ports, the deep agents runtime behind the node's
agent gateway, the per-project computer, and the Flutter client. Nothing is
bolted on beside the node; every feature is a namespace (or part of one), its
records are its own schemas, and other modules reach it only through
`bridge.Invoke`.

## Shape of the work

| New / changed module | Owns |
| --- | --- |
| `plugins/actions/governance` (new) | policy (CEL), the gate every agent action passes, approvals, audit trail and export, secret box and vault, outbound credential checks, project computer egress policy, computer handover |
| `pkg/untrusted` (new) | the envelope outside content is handed to models in |
| `plugins/actions/google` (new) | each person's Google connection (OAuth), Gmail and Calendar REST, the agents' mail and calendar tools |
| `plugins/actions/proactive` (new) | Tasks inbox, mail triage, morning brief, background research, first day, reply chips |
| `plugins/actions/responsibilities` (new) | standing triggers on email, GitHub, Slack and generic webhooks |
| `plugins/actions/routines` | demonstrations: record once, draft a skill, keep it as a routine |
| `plugins/actions/channels` (new) | Slack and Microsoft Teams as chat surfaces, Twilio SMS and push delivery, approvals answered there |
| `plugins/actions/enterprise` (new) | OIDC single sign-on, SCIM 2.0, organizations by email domain and groups, SPIFFE/SPIRE workload identity |
| `plugins/actions/hostaccess` (new) | brokered access to a person's own computer through the desktop app |
| `plugins/actions/admin` | setup checklist with real checks, telemetry switch |
| `plugins/actions/spaces` | room purpose (icon, colour, greeting), gate hooks for sandbox commands, handover checks |
| `plugins/adapters/vmm/harness` (was deepagents) | gate on every `/call`, initiator in the turn, untrusted envelope, SVID header |
| `plugins/actions/tools` | gate on every Code Mode request, Composio and Arcade brokers |
| `deploy/` | egress proxy in the sandbox image, gVisor option, Helm chart, SPIRE profile |
| `app/` | approval, secret and handover cards, Tasks, brief, Setup, Audit, Policy, Connections, Channels, SSO, desktop host agent, reply chips, dictation, room purpose |
| `evals/` | labelled triage and reply-chip sets and their runner |
| `.github/workflows/ci.yml` | Go, runtime and Flutter tests on every push |

## 1. Central action gateway and policy engine

- `governance.Gate(ctx, gate.Request) gate.Result` is the one decision. A
  request names the tool, its arguments, the agent, actor, initiator, space,
  room, and the derived target (`command`, `file.path`, `url`/`host`,
  `app.slug`/`app.function`, `mcp.effect`, `recipients`).
- Rules are CEL expressions (`cel-go`) over that request, in three lists:
  `deny`, `ask`, `allow`. Deny is evaluated first, then ask, then allow; no
  match denies. A rule that fails to compile is refused when saved; a rule that
  errors at evaluation denies (deny/ask) or does not permit (allow): fail
  closed.
- Policy scopes: the node policy (admin), then each project's policy (project
  owner), then each person's standing "always allow" grants. A project can only
  narrow the node policy.
- Effects are classified (`read`, `write`, `send`, `pay`, `delete`, `sign`,
  `external`) from the tool name, the app/MCP tool annotations
  (`readOnlyHint`, `destructiveHint`), and the sandbox command. Anything not
  positively classified as a read is a write.
- Default node policy: allow reads; ask before anything that sends to people
  outside Aseman, pays, signs or deletes; deny reaching cloud metadata.
- Enforcement points call the gate: the agent gateway's `/call`
  (`deepagents/gateway.go`), every Code Mode request
  (`tools.CodeModeRequestCall`), and Slack/Teams/host-access tool calls.
  With the namespace absent, `ASEMAN_GOVERNANCE_REQUIRED=1` refuses every
  action; otherwise actions run as before.
- Admin → Policy edits the node policy, with a dry run against a sample
  request; project settings edit the project's.

## 2. Audit trail

- `audit_events`: time, decision (`allowed`, `denied`, `asked`, `approved`,
  `refused`, `failed`, `timed_out`), rule, tool, effect, target, agent, actor,
  `initiator_kind` (`person`, `routine`, `responsibility`, `proactive`,
  `handoff`, `channel`, `deployment`) and `initiator_id`, project, room, run,
  and the arguments with credentials and secrets redacted.
- The initiator travels in `vmm.Execution` (`Initiator`, `InitiatorID`): set by
  routines, responsibilities, proactive runs, channel turns and agent
  hand-offs, inherited by every delegated turn, never set by the model.
- A forwarded action that fails writes a second row.
- `governance.audit_list` (filters: time, project, agent, actor, decision,
  initiator, tool, "nobody watching") and `governance.audit_export` (RFC 4180
  CSV, 5,000 rows maximum, truncation reported, `=+-@` cells prefixed with `'`,
  the export itself audited as `audit.exported`).
- Admin → Audit shows the node, and each project's owner sees the project's
  trail.

## 3. Allow once / Always allow / Refuse

- An `ask` decision creates an `approvals` row and posts an AG-UI `Approval`
  card in the room (the exact action, the rule that asked, the recipients and
  text for a message), pushes a notification, and holds the agent's call until
  it is answered or expires (30 minutes by default, `timed_out` is a refusal).
- `governance.approval_answer {id, decision: once|always|refuse}`. "Always"
  writes a grant (person, agent, tool, target pattern) that later requests
  match before the ask list. Grants are listed and revoked in Settings →
  Approvals.
- Approvals are answerable from the room card, the Tasks tab, push, Slack and
  Teams.

## 4. Secret box

- Agent tool `secret_request {name, reason, site}` posts a `Secret` card with a
  masked field. `governance.secret_submit` seals the value (AES-256-GCM,
  `crypto.SealSecret`) into `vault_secrets` owned by the person and the project;
  values are write-only and never returned.
- Agents use `{{secret:name}}` in sandbox commands, app and MCP arguments; the
  gate substitutes the value server-side after the decision, and every result
  has the value redacted back to `[secret:name]` before the model reads it.
- Audit records that a secret was requested, supplied and used, with its
  length, never its value. Settings → Saved credentials lists names and lets
  people delete them.

## 5. Outbound checks and the untrusted envelope

- `governance.Inspect` scans arguments of any call that leaves the node (send,
  external MCP/app calls, messages to Slack/Teams/mail) for credentials
  (private keys, cloud/API keys and tokens, JWTs, connection strings with
  passwords) and payment card numbers (Luhn). A finding is a denial naming the
  category and path, never the value.
- `pkg/untrusted.Wrap(source, text)` is the one envelope for web pages, app and
  MCP results, mail, and messages from people other than the requester; the
  runtime explains it in the system prompt and wraps tool results the same way.

## 6. Project computer network egress

- Per-project egress policy: `allow_all`, `defaults_plus_allowlist`,
  `allowlist_only`, `deny_all`, with an allowlist of hosts and wildcards.
  Cloud metadata and link-local addresses are refused in every mode.
- The sandbox image runs `aseman-egress`, a small filtering proxy; shell and
  browser use it through `HTTP(S)_PROXY`. The node writes the policy into the
  computer before each command and on wake; until one arrives nothing leaves.
- The Docker backend can run computers under gVisor (`sandbox.runtime: runsc`)
  and keeps the database off the computers' network.

## 7. Human takeover

- Agent tool `computer_help {reason}` posts a `Handover` card; a person takes
  control (`governance.control_take`), works in the live desktop, and hands
  back (`control_release`). All three are audited.
- While a person holds the computer, agents' sandbox and desktop actions wait
  for the handover (up to the approval timeout) instead of fighting the person.
- The help request records the page/URL it was made on so the person lands
  there.

## 8. Proactive: brief, triage, research, Tasks

- `tasks`: owner, project, room, title, detail, kind (`needs_you`,
  `suggestion`, `work`), status (`suggested`, `working`, `needs_input`,
  `ready_for_review`, `failed`, `resolved`, `hidden`), reason, run, colour.
  `proactive.tasks_list|start|hide|resolve|retry|answer`.
- Triage: rules first (bulk, auto-reply, calendar response; rules only say "can
  wait"), then the model with a required one-line reason; every verdict records
  what decided it.
- Morning brief: built once a day per person (idempotent by date), from
  triage, today's calendar, open tasks and what it could not check; delivered
  as the first message of the day in the home project, with push; any time on
  request.
- Background research: every few hours per person, a read-only run (the gate
  denies writes for `initiator=proactive`) over what is new; it records
  suggestions with the `offer_task` tool. The newest suggestion is offered above
  the composer with Start and Hide.
- A started task runs as a turn in its room; its state follows the run
  (working → ready for review / needs input / failed with retry).

## 9. Responsibilities

- `responsibilities`: a standing instruction for an agent in a room, fired by
  a trigger from one catalog (`responsibilities.triggers`), which the app
  builds its form from.
- Signed hooks at `/hooks/v1/responsibilities/{id}`: GitHub
  (`X-Hub-Signature-256`), GitLab (`X-Gitlab-Token`), Slack (`v0`, replay
  window), Microsoft Teams outgoing webhooks (HMAC), SMS through Twilio
  (`X-Twilio-Signature`), Stripe (`Stripe-Signature`, replay window), Linear
  (`Linear-Signature`, delivery timestamp), Jira (`X-Hub-Signature`), Shopify
  (`X-Shopify-Hmac-Sha256`) and generic signed webhooks; each filters by
  repository or project, event types, action and keyword.
- Polls on the node's clock: Gmail and Google Calendar (through the Google
  app's connection), RSS/Atom feeds, any HTTP API (fires when its answer, or a
  JSON value in it, changes) and an app's read-only function (called as the
  person); the first look only learns what is there. Feeds and APIs reach
  public addresses only.
- Schedules: every N minutes, or daily at a time in a time zone.
- A firing runs as the owner with `initiator=responsibility`, is audited, and
  shows in the room and Tasks. Agents may set up polls and schedules
  themselves; hooks, whose secrets only the person should see, are set up by
  the person.

## 10. Demonstrations

- `routines.demo_start` begins a recording in the project computer (at most
  ten minutes): terminal commands through a shell hook, browser history, files
  touched, and the person's own commands.
- `routines.demo_stop` collects the trace and drafts a skill (title,
  instructions, inputs) with the model; `routines.demo_save` keeps it as the
  project's skill file and, with a schedule, as an ordinary routine.

## 11. Slack, Teams, SMS

- `channels` namespace: Slack (Events API + interactivity, `chat.postMessage`,
  signature verification) and Microsoft Teams (Bot Framework activities, JWT
  validation against Microsoft's OpenID keys, Bot Connector replies).
- A person links their Slack or Teams identity with a one-time code from
  Settings → Channels; the binding decides the owner, project and room — nothing
  in a message can choose them.
- Agent replies and approval cards (Block Kit buttons, Adaptive Cards) go back
  to the thread; answering an approval there answers it in Aseman.
- Delivery router: push (APNs, existing), Twilio SMS, Slack DM, Teams.

## 12. Gmail, Calendar, Composio, Arcade — as apps

- Apps are Aseman's connectors, so these are apps: listed in the Apps
  catalog, added to projects, connected per person through the same flow.
- Google: an administrator sets up one OAuth client (Admin → Catalog →
  Connector apps), which lists the Google app; its MCP server is the `google`
  namespace (`/google/v1/mcp`), called with the app's key and the person each
  call is for, using that person's own connection (authorization code + PKCE,
  offline refresh token sealed in the vault). Connecting adds it to the
  person's home project. Functions: `gmail_search`, `gmail_read`,
  `gmail_draft`, `gmail_send` (send asks by default), `calendar_events`,
  `calendar_create` (asks).
- Composio and Arcade are presets on the same page: listed as MCP apps with the
  node's key and each person's id; people connect their accounts at the broker.
- `tools.commands_list` reports connector apps as `auth: "account"` with how to
  connect them. A fake Google (`cmd/fakegoogle`) for tests and demos.

## 13. Enterprise identity

- OIDC SSO (Okta, Entra, Google Workspace, any discovery URL): authorization
  code with PKCE and nonce; accounts matched by verified email; "SSO required"
  for an email domain.
- SCIM 2.0 (`/scim/v2/Users`, `/Groups`, bearer token): create, update, patch,
  deactivate. Deactivation ends sessions, revokes Google connections and
  secrets, and stops the sandboxes of projects the person alone owns.
- Organizations by email domain, roles from groups (`admin_groups`).
- SPIFFE: optional SPIRE server/agent in Compose; the agent gateway accepts and
  verifies a JWT-SVID from the runtime (bundle from SPIRE's JWKS endpoint) as
  workload identity on top of the turn token.

## 14. Shared folders and host access

- People share folders of their project computers (sandboxes) with their own
  agents in every project: `folder_list`, `folder_read`, `folder_write` (write
  only where shared read-write); the files never leave that computer.
- Agents on people's own computers is the highest access the node can give:
  an administrator turns it on (Admin → Governance → Host access), off by
  default. Only then may the desktop app register its computer and answer
  `host_exec`, `host_read`, `host_write`, `host_list` over long-polling,
  limited to folders shared there; every call passes the gate and asks on the
  desktop first. Turning it off disconnects every computer.

## 15. Evals

- `evals/triage`: a labelled set of 60 messages and a runner
  (`go run ./cmd/evals triage`) that scores rules-only offline and any model
  through the node's OpenAI-compatible endpoint; results are written as
  Markdown with every disagreement.
- `evals/reply-chips`: labelled agent messages scored for whether chips are
  offered and whether they answer the question.

## 16. Operations

- Admin → Setup: real checks (database, LLM key answers, decision and memory
  models, OpenViking, timeline, Nomad, sandbox image, Google client, push, mail,
  Slack/Teams) with Ready / Not checked / Needs setup and how to fix each;
  "Check again".
- Helm chart (`deploy/helm/aseman`) for the node, web client, Postgres,
  OpenViking, timeline and Nomad agent.
- Telemetry: the node sends nothing outside unless `ASEMAN_TELEMETRY` is on;
  documented in `docs/telemetry.md`.
- `CHANGELOG.md` written for people upgrading; CI runs every test suite.

## 17. Experience

- Reply chips: agents end a question with up to three likely answers on a last
  line `<replies>a | b | c</replies>` (`pkg/replies`), shown as tappable chips
  under their newest message and as buttons in Slack and Teams.
- Dictation: a microphone button in the composer records, `developer.dictate`
  writes it down with the node's transcription model (billed to the person),
  and the text lands in the composer for the person to send.
- First day: the first time a person opens their home project, its lead greets
  them, reads recent mail and this week's calendar if connected, and answers in
  three short bubbles with "Sounds right" / "Something's off".
- Room purpose: a room has a purpose, icon and colour; the lead greets a new
  room and offers three things to start; agents are told the purpose; tasks
  started there wear its colour.
