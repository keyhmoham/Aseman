package workflow

import _ "embed"

// Guide is docs/workflows/AUTHORING.md: how to write a rich, professional
// workflow, for models and people. The developer API serves it
// (GET /v1/workflows/guide); TestGuide keeps the copy current and its
// examples valid.
//
//go:embed guide.md
var Guide string
