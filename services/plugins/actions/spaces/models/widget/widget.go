// Package widget defines the desk-widget DSL served to clients for miniapps
// installed in a room. A widget is a JSON document describing the UI rendered
// on the room desk. It is refreshed by clients on a fixed interval (default 10
// seconds) and may contain actions with inline parameters that make static ask
// requests to the miniapp's backend VM.
package widget

import (
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
)

// Action is an inline DSL action. When the user triggers it, the client sends
// a static ask request to the miniapp's backend VM whose body is
// {"op": Op, "args": Args} and renders the returned reply back into the desk.
type Action struct {
	Op      string         `json:"op"`
	Args    map[string]any `json:"args,omitempty"`
	Label   string         `json:"label,omitempty"`
	Confirm string         `json:"confirm,omitempty"`
}

// Row is a single UI element in the widget DSL. The client renders each row
// inside the desk tile. Unknown row types are rendered as inert text.
type Row struct {
	Type   string    `json:"type"` // label | metric | sparkline | gauge | list | progress | status | button | toggle | text_field | divider | markdown
	Label  string    `json:"label,omitempty"`
	Text   string    `json:"text,omitempty"`
	Value  any       `json:"value,omitempty"`
	Delta  string    `json:"delta,omitempty"`
	Color  string    `json:"color,omitempty"` // success | danger | warning | info | muted | accent
	Icon   string    `json:"icon,omitempty"`
	Data   []float64 `json:"data,omitempty"`
	Items  []Row     `json:"items,omitempty"`
	Min    float64   `json:"min,omitempty"`
	Max    float64   `json:"max,omitempty"`
	Toggle bool      `json:"toggle,omitempty"`
	Action *Action   `json:"action,omitempty"` // button / toggle / text_field submit
	Submit *Action   `json:"submit,omitempty"` // text_field on-submit
}

// Widget is the DSL document served for a miniapp's room desk widget.
type Widget struct {
	Version    int    `json:"version"`
	Title      string `json:"title"`
	BotID      string `json:"bot_id,omitempty"`
	RefreshSec int    `json:"refresh_sec,omitempty"`
	Rows       []Row  `json:"rows"`
}

// Default builds a starter desk widget for a bot when neither its backend VM
// nor its stored widget/dsl metadata provides one.
func Default(b *bot.Bot) *Widget {
	return &Widget{
		Version:    1,
		Title:      b.Name,
		BotID:      b.ID.String(),
		RefreshSec: 10,
		Rows: []Row{
			{Type: "status", Label: "Status", Value: string(b.Status), Color: ColorForStatus(string(b.Status))},
			{Type: "metric", Label: "Backend", Value: string(b.VMType)},
			{Type: "button", Label: "Ping " + b.Name, Action: &Action{Op: "ping", Args: map[string]any{"echo": true}}},
		},
	}
}

// ColorForStatus maps a bot status onto a DSL color token.
func ColorForStatus(status string) string {
	switch status {
	case "running":
		return "success"
	case "paused":
		return "warning"
	case "stopped", "ended", "failed":
		return "danger"
	default:
		return "info"
	}
}
