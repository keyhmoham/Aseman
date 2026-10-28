// Package responsibilities holds the standing triggers agents carry for a
// person: when an email, a GitHub event, a Slack message or a signed webhook
// matches, the agent runs the instruction as its owner.
package responsibilities

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Trigger kinds.
const (
	TriggerEmail   = "email"
	TriggerGitHub  = "github"
	TriggerSlack   = "slack"
	TriggerWebhook = "webhook"
)

// Responsibility is one standing instruction and what fires it.
type Responsibility struct {
	entity.Entity
	OwnerID     string `db:"owner_id" json:"owner_id"`
	SpaceID     string `db:"space_id" json:"space_id"`
	RoomID      string `db:"room_id" json:"room_id,omitempty"`
	Name        string `db:"name" json:"name"`
	Instruction string `db:"instruction" json:"instruction"`
	Trigger     string `db:"trigger" json:"trigger"`
	// Filters: email (From, Subject, Label), GitHub (Repo, Events, Action),
	// Slack (Channel, Keyword).
	From    string   `db:"from_filter" json:"from,omitempty"`
	Subject string   `db:"subject_filter" json:"subject,omitempty"`
	Label   string   `db:"label_filter" json:"label,omitempty"`
	Repo    string   `db:"repo_filter" json:"repo,omitempty"`
	Events  []string `db:"events" json:"events,omitempty"`
	Action  string   `db:"action_filter" json:"action,omitempty"`
	Channel string   `db:"channel_filter" json:"channel,omitempty"`
	Keyword string   `db:"keyword_filter" json:"keyword,omitempty"`
	// Secret verifies inbound events (sealed; shown once when generated).
	Secret     string    `db:"secret" json:"-"`
	Enabled    bool      `db:"enabled" json:"enabled"`
	Cursor     time.Time `db:"cursor" json:"cursor,omitempty"`
	Fired      int64     `db:"fired" json:"fired"`
	LastFired  time.Time `db:"last_fired" json:"last_fired,omitempty"`
	LastResult string    `db:"last_result" json:"last_result,omitempty"`
}

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model {
	s, t, b, j, i := database.KindString, database.KindTime, database.KindBool, database.KindJSON, database.KindInt64
	return []database.Model{{Name: "responsibilities", Table: "responsibilities", Fields: []database.Field{
		f("id", s), f("created_at", t), f("updated_at", t), f("owner_id", s), f("space_id", s), f("room_id", s), f("name", s),
		f("instruction", s), f("trigger", s), f("from_filter", s), f("subject_filter", s), f("label_filter", s), f("repo_filter", s),
		f("events", j), f("action_filter", s), f("channel_filter", s), f("keyword_filter", s), f("secret", s), f("enabled", b),
		f("cursor", t), f("fired", i), f("last_fired", t), f("last_result", s)}}}
}
