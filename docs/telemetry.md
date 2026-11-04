# Telemetry

An Aseman node sends **nothing** to Aseman or to anyone else on its own: no
usage statistics, no crash reports, no update checks, no analytics. Admin →
Health says so too.

Everything a node sends leaves because an administrator configured a service
or a person used one. Here is every destination:

| Destination | When | What |
|---|---|---|
| Model providers (Admin → Providers) | An agent runs, a brief or triage is written, dictation is transcribed, Health probes the default provider | Prompts, tool results, audio for dictation; the provider key |
| Project computers (Modal or your Docker host) | A project computer starts or runs a command | The sandbox image, commands, files |
| Agent memory and timelines (your own Postgres) | Agents remember; projects record history | Memory and timeline entries |
| Google (Gmail, Calendar, OAuth) | A person connects Google and their agents read mail or calendar | That person's OAuth token; mail and calendar requests |
| Slack, Microsoft Teams, Twilio | An administrator connects them and people link their accounts | Replies, approval prompts, notifications |
| Feeds and APIs a responsibility watches | A person sets up a feed or API responsibility | GET requests to that public address, with the bearer token they gave |
| Composio, Arcade, MCP servers, apps | An administrator adds them and agents call their tools | Tool calls, with the person's id where the broker needs it |
| Single sign-on providers | SSO is on and people sign in | The standard OIDC exchange; SCIM only receives |
| Apple Push Notification service | APNs keys are set | Notification titles and bodies |
| RevenueCat | In-app purchases are set up | Purchase verification |
| Federated nodes | An administrator federates with another node | What federation shares |

The egress policy (Admin → Governance → Network) limits what project
computers reach; the governance audit trail records every agent action and
can be exported as CSV.
