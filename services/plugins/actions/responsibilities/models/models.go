// Package responsibilities holds the standing triggers agents carry for a
// person: when an event from a service, an app, an API or the clock
// matches, the agent runs the instruction as its owner.
package responsibilities

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Trigger kinds. Hooks arrive signed at the responsibility's URL; polls are
// checked on an interval; a schedule fires on the clock.
const (
	// Hooks.
	TriggerGitHub  = "github"
	TriggerGitLab  = "gitlab"
	TriggerSlack   = "slack"
	TriggerTeams   = "teams"
	TriggerSMS     = "sms"
	TriggerStripe  = "stripe"
	TriggerLinear  = "linear"
	TriggerJira    = "jira"
	TriggerShopify = "shopify"
	TriggerWebhook = "webhook"
	// Polls.
	TriggerEmail    = "email"
	TriggerCalendar = "calendar"
	TriggerFeed     = "feed"
	TriggerAPI      = "api"
	TriggerApp      = "app"
	// Time.
	TriggerSchedule = "schedule"
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
	// Filters, by trigger: From (email, sms), Subject and Label (email),
	// Repo (GitHub and GitLab repository, Jira project), Events (event types),
	// Action (GitHub/GitLab/Linear action), Channel (Slack channel, Teams
	// conversation), Keyword (any text the event must contain).
	From    string   `db:"from_filter" json:"from,omitempty"`
	Subject string   `db:"subject_filter" json:"subject,omitempty"`
	Label   string   `db:"label_filter" json:"label,omitempty"`
	Repo    string   `db:"repo_filter" json:"repo,omitempty"`
	Events  []string `db:"events" json:"events,omitempty"`
	Action  string   `db:"action_filter" json:"action,omitempty"`
	Channel string   `db:"channel_filter" json:"channel,omitempty"`
	Keyword string   `db:"keyword_filter" json:"keyword,omitempty"`
	// Polls and schedules: a URL (feed, API), a JSON path in the answer, an
	// app's function with its arguments, how often, how long before an
	// event, a daily time.
	URL             string `db:"url" json:"url,omitempty"`
	Path            string `db:"json_path" json:"path,omitempty"`
	App             string `db:"app_bot" json:"app,omitempty"`
	Function        string `db:"function" json:"function,omitempty"`
	Args            string `db:"args" json:"args,omitempty"`
	IntervalMinutes int64  `db:"interval_minutes" json:"interval_minutes,omitempty"`
	LeadMinutes     int64  `db:"lead_minutes" json:"lead_minutes,omitempty"`
	At              string `db:"at" json:"at,omitempty"`
	Timezone        string `db:"timezone" json:"timezone,omitempty"`
	// Secret verifies inbound events (sealed; shown once when generated).
	Secret     string    `db:"secret" json:"-"`
	Enabled    bool      `db:"enabled" json:"enabled"`
	Cursor     time.Time `db:"cursor" json:"cursor,omitempty"`
	// NextRun is when a poll or schedule is due; Seen the latest items a poll
	// already fired for; Fingerprint the last answer an API or app gave.
	NextRun     time.Time `db:"next_run" json:"next_run,omitempty"`
	Seen        []string  `db:"seen" json:"-"`
	Fingerprint string    `db:"fingerprint" json:"-"`
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
		f("cursor", t), f("fired", i), f("last_fired", t), f("last_result", s),
		f("url", s), f("json_path", s), f("app_bot", s), f("function", s), f("args", s), f("interval_minutes", i), f("lead_minutes", i),
		f("at", s), f("timezone", s), f("next_run", t), f("seen", j), f("fingerprint", s)}}}
}
