# Changelog

## Unreleased: governance, proactive work and connections

What upgraders need to know first:

- **Agents no longer reach people's own computers by default.** Host access
  (the desktop app's "Let agents use this computer") is a node setting,
  Admin → Governance → Host access, off by default; while off, desktop apps
  stop answering and the `host_*` tools are not offered. Shared folders now
  come from project computers, attached to a message like a file
  (Attach → Project folder; agent tools
  `folder_list`, `folder_read`, `folder_write`).
- **Google is an app.** Gmail and Calendar moved from built-in agent tools to
  the Google app in the Apps catalog (Admin → Catalog → Connector apps).
  A node that had Google on lists the app by itself after it starts; people
  connect their account from Apps, and connecting adds the app to their home
  project. Composio and Arcade are set up on the same admin page.
- **Responsibilities** react to many more sources (see below); existing ones
  keep working unchanged.

- **Agent actions now pass a policy gate.** The new `governance` namespace
  decides every tool call, app call and sandbox command (CEL rules: deny, then
  ask, then allow) and records it. The default policy **asks the person before
  sending, paying, signing or deleting**, and before anything that changes
  their own computer; proactive work may only read. Edit it in Admin →
  Governance. Set `ASEMAN_GOVERNANCE_REQUIRED=1` to refuse every action while
  governance is not loaded.
- **Approvals** offer Allow once, Always allow and Refuse; standing grants are
  listed and revoked in Settings → What agents may always do; pending ones
  are answered on the home feed. `ASEMAN_APPROVAL_TIMEOUT` (30m).
- **Outside content is wrapped** as untrusted data before it reaches a model
  (app results, mail, files from a person's computer); outbound content is
  checked for credentials and card numbers.
- **Secrets**: agents ask for credentials with a masked box; they use
  `{{secret:name}}` and never see the value.
- **Network policy** per project for project computers, enforced by the new
  `aseman/egress-proxy` sidecar (`ASEMAN_EGRESS_IMAGE`); `ASEMAN_SANDBOX_RUNTIME=runsc`
  runs them under gVisor. Docker Compose now puts Postgres and timelines on an
  internal `data` network.
- **Human takeover** of a project computer pauses its agents.

New namespaces (all on by default): `governance`, `google`, `proactive`,
`responsibilities`, `channels`, `enterprise`, `hostaccess`. Their tables are
created on start; no manual migration.

New features:

- Tasks, the morning brief, inbox triage, background research and a first-day
  greeting (proactive), at the top of the home feed with the approvals
  waiting on the person; reply chips under agent messages.
- Responsibilities: agents own an area and react to GitHub, GitLab, Slack,
  Microsoft Teams, SMS, Stripe, Linear, Jira, Shopify and signed webhooks; to
  new mail, upcoming calendar events, feed items, changed API answers and
  changed app answers; and to schedules. Demonstrations: show an agent how,
  save it as a routine.
- Slack, Microsoft Teams and SMS (Twilio), including approvals there.
- Google (Gmail and Calendar), Composio and Arcade as apps.
- Enterprise: OIDC single sign-on (enforceable), SCIM 2.0 provisioning,
  organizations, SPIFFE workload identity for the agent runtime (`spire`
  Compose profile).
- Shared folders from project computers; optionally (admin switch) a
  person's own computer through the desktop app.
- Voice dictation (`developer.dictate`), room purpose, icon and color, a
  setup checklist and deeper Admin → Health checks.
- `deploy/helm/aseman`, `.github/workflows/ci.yml`, `evals/`, `docs/telemetry.md`.

New settings are listed in `.env.example` under "Governance and connections".
