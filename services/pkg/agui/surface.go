package agui

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// Fence is the markdown fence language for AG-UI surfaces in chat bodies.
const Fence = "agui"

// SpecVersion tags Aseman chat surfaces.
const SpecVersion = "aseman.surface/v1"

// Surface is a compact generative UI tree for Flutter AG-UI chat mounts.
// Prefer a single root tree (Root) so agents do not duplicate id graphs.
type Surface struct {
	SurfaceID string         `json:"surfaceId,omitempty"`
	Version   string         `json:"version,omitempty"`
	Layout    string         `json:"layout,omitempty"` // "chat" (default) or "desk"
	Title     string         `json:"title,omitempty"`
	Root      map[string]any `json:"root,omitempty"` // {c|type, p|props, children}
	// Data is optional shared payload referenced by bindings.
	Data map[string]any `json:"data,omitempty"`
}

// ChatComponents are the generative nodes Flutter renders in-chat. Layout /
// viz types reuse the App UI kit names so there is one vocabulary; HITL types
// are chat-only.
var ChatComponents = map[string]string{
	// Layout (chat-safe)
	"Column": "stack vertical", "Row": "stack horizontal", "Stack": "flex",
	"Section": "titled group", "Card": "surface card", "Divider": "rule",
	"Spacer": "gap", "Scroll": "scroll region",
	// Text / feedback
	"Text": "paragraph", "Markdown": "markdown", "Callout": "banner",
	"Tag": "chip", "Badge": "chip", "Progress": "progress", "Empty": "empty state",
	// Data viz (ui_kit)
	"Stat": "metric tile", "KeyValue": "kv list", "Chart": "chart",
	"Sparkline": "sparkline", "Gauge": "gauge", "DataGrid": "table",
	"Table": "table", "Timeline": "timeline", "JsonView": "json",
	"CodeBlock": "code", "List": "list",
	// Human-in-the-loop (chat)
	"Question": "ask with optional free text",
	"Choices":  "single-select options",
	"Confirm":  "yes/no confirm bar",
	"Form":     "short field group + submit",
}

// EncodeFence wraps a surface as a chat body fence.
func EncodeFence(s Surface) (string, error) {
	if s.Version == "" {
		s.Version = SpecVersion
	}
	if s.Layout == "" {
		s.Layout = "chat"
	}
	raw, err := json.Marshal(s)
	if err != nil {
		return "", err
	}
	return "```" + Fence + "\n" + string(raw) + "\n```", nil
}

// FormatMessage builds a chat body: optional prose + AG-UI fence (no duplicate
// prose of the same facts the surface already shows).
func FormatMessage(caption string, s Surface) (string, error) {
	fence, err := EncodeFence(s)
	if err != nil {
		return "", err
	}
	caption = strings.TrimSpace(caption)
	if caption == "" {
		return fence, nil
	}
	return caption + "\n\n" + fence, nil
}

var fenceRE = regexp.MustCompile("(?s)```(?:agui|surface)\\s*\\n(.*?)\\n```")

// ParseFence extracts the first AG-UI surface from a message body.
func ParseFence(body string) (*Surface, string, bool) {
	m := fenceRE.FindStringSubmatch(body)
	if m == nil {
		return nil, body, false
	}
	var s Surface
	if err := json.Unmarshal([]byte(strings.TrimSpace(m[1])), &s); err != nil {
		return nil, body, false
	}
	rest := strings.TrimSpace(fenceRE.ReplaceAllString(body, ""))
	return &s, rest, true
}

// QuestionSurface builds a HITL choices card (for ask_user / clarifications).
func QuestionSurface(question string, options []string) Surface {
	props := map[string]any{"question": question, "allowFreeText": true}
	if len(options) > 0 {
		props["options"] = options
	}
	return Surface{
		Version: SpecVersion,
		Layout:  "chat",
		Title:   "Question",
		Root: map[string]any{
			"c": "Question",
			"p": props,
		},
	}
}

// MustFormat is FormatMessage that panics only in tests; production uses FormatMessage.
func MustFormat(caption string, s Surface) string {
	out, err := FormatMessage(caption, s)
	if err != nil {
		panic(err)
	}
	return out
}

// ValidateRoot checks the root node type is a known chat component.
func ValidateRoot(s Surface) error {
	if s.Root == nil {
		return fmt.Errorf("surface needs root")
	}
	t, _ := s.Root["c"].(string)
	if t == "" {
		t, _ = s.Root["type"].(string)
	}
	if t == "" {
		return fmt.Errorf("root needs c/type")
	}
	if _, ok := ChatComponents[t]; !ok {
		return fmt.Errorf("unknown chat component %q", t)
	}
	return nil
}
