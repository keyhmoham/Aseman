# Workflow client

This feature follows the app's view/model/data separation and keeps the workflow
namespace contract local. `domain/workflow.dart` parses public backend fields;
`data/workflow_repository.dart` handles signed workflow actions;
`presentation/workflow_view_model.dart` owns polling and commands. The panel and
its widgets display those results. The shared service supplies identity and
authorized file operations. No orchestration, skill selection or budget policy
is reimplemented in Flutter.

The room's **Agent tasks** button opens a responsive, live task panel. It shows
the authoritative workflow/step status, aggregate usage, separate corrective
retries and resource continuations, selected skills, criteria and inspection
feedback. Unknown server statuses remain explicit. Files stay accessible on
partial or failed runs; an attachment alone never makes a task completed.

Answers carry the exact workflow and pending question IDs. New questions clear
stale drafts. Interrupted runs expose recorded operations and allow an authorized
user to record an observed outcome before explicitly resuming. Commands are not
automatically retried after ambiguous failures. Polls do not overlap, preserve
the last successful data on errors, stop when the panel closes or the app goes
into the background, and ignore responses after disposal. Cancellation remains
available while a long resume request is pending. The server enforces ownership
and permissions; UI visibility is only a convenience.

The existing rich-content renderer accepts an optional link handler. Room and
workflow reports resolve `attachment://` links through authorized file metadata
and download cards, and relative gateway previews through the configured node.
External links never receive session credentials. Preview URLs preserve query
parameters and reject foreign/invalid gateway paths. Supported native platforms
use the existing webview; other platforms open the preview externally. Preview
unavailability provides a retry action; finite server leases are not presented
as permanent hosting.

Regression tests use a filtered public payload from the successful backend
website evaluation and cover unknown/older payloads, partial delivery, native
inspection acceptance, question identity, duplicate commands, uncertain
requests, correlated execution resolutions, attachment links, room polling,
disposal, and mobile layouts.

The separation follows [Flutter's architecture guidance](https://docs.flutter.dev/app-architecture/guide)
and [recommendations](https://docs.flutter.dev/app-architecture/recommendations),
using the existing dependencies rather than introducing another state library.
