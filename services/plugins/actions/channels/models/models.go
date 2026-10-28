// Package channels holds the records of the channels namespace: each
// provider's settings (Slack, Microsoft Teams, Twilio SMS), the bindings
// that tie a person's Slack, Teams or phone identity to their Aseman
// account, the one-time codes that make a binding, and the short codes an
// approval is answered with by text message.
package channels

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Providers.
const (
	Slack  = "slack"
	Teams  = "teams"
	Twilio = "twilio"
)

// Settings is one provider's configuration. Its id is derived from the
// provider's name. Secrets are sealed and never returned.
type Settings struct {
	entity.Entity
	Provider string `db:"provider" json:"provider"`
	Enabled  bool   `db:"enabled" json:"enabled"`
	// Slack: bot token and signing secret. Teams: app id and password.
	// Twilio: account SID, auth token and the sending number.
	AppID     string `db:"app_id" json:"app_id,omitempty"`
	Secret    string `db:"secret" json:"-"`
	Token     string `db:"token" json:"-"`
	From      string `db:"from_number" json:"from,omitempty"`
	Tenant    string `db:"tenant" json:"tenant,omitempty"`
	UpdatedBy string `db:"updated_by" json:"updated_by,omitempty"`
}

// Binding ties a provider identity to a person. Nothing in a message can
// choose the account a turn runs as: only the binding does.
type Binding struct {
	entity.Entity
	AccountID string `db:"account_id" json:"account_id"`
	Provider  string `db:"provider" json:"provider"`
	// External is the provider's user (Slack U…, Teams AAD object id, phone
	// number in E.164); Workspace its team or tenant.
	External  string `db:"external" json:"external"`
	Workspace string `db:"workspace" json:"workspace,omitempty"`
	// Conversation is where to write to the person: a Slack DM channel, or a
	// Teams conversation id with its service URL.
	Conversation string `db:"conversation" json:"conversation,omitempty"`
	ServiceURL   string `db:"service_url" json:"service_url,omitempty"`
	SpaceID      string `db:"space_id" json:"space_id,omitempty"`
	RoomID       string `db:"room_id" json:"room_id,omitempty"`
	// Notify sends approvals and briefs here too.
	Notify bool `db:"notify" json:"notify"`
}

// LinkCode is a one-time code a person sends from Slack, Teams or a phone to
// bind it to their account.
type LinkCode struct {
	entity.Entity
	AccountID string    `db:"account_id" json:"account_id"`
	Provider  string    `db:"provider" json:"provider"`
	CodeHash  string    `db:"code_hash" json:"-"`
	ExpiresAt time.Time `db:"expires_at" json:"expires_at"`
}

// SMSPrompt is an approval asked by text message, answered with its code.
type SMSPrompt struct {
	entity.Entity
	AccountID  string    `db:"account_id" json:"account_id"`
	Phone      string    `db:"phone" json:"phone"`
	Code       string    `db:"code" json:"code"`
	ApprovalID string    `db:"approval_id" json:"approval_id"`
	ExpiresAt  time.Time `db:"expires_at" json:"expires_at"`
}

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func base(fields ...database.Field) []database.Field {
	return append([]database.Field{f("id", database.KindString), f("created_at", database.KindTime), f("updated_at", database.KindTime)}, fields...)
}

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model {
	s, t, b := database.KindString, database.KindTime, database.KindBool
	return []database.Model{
		{Name: "channel_settings", Table: "channel_settings", Fields: base(f("provider", s), f("enabled", b), f("app_id", s), f("secret", s),
			f("token", s), f("from_number", s), f("tenant", s), f("updated_by", s))},
		{Name: "channel_bindings", Table: "channel_bindings", Fields: base(f("account_id", s), f("provider", s), f("external", s),
			f("workspace", s), f("conversation", s), f("service_url", s), f("space_id", s), f("room_id", s), f("notify", b))},
		{Name: "channel_link_codes", Table: "channel_link_codes", Fields: base(f("account_id", s), f("provider", s), f("code_hash", s), f("expires_at", t))},
		{Name: "channel_sms_prompts", Table: "channel_sms_prompts", Fields: base(f("account_id", s), f("phone", s), f("code", s),
			f("approval_id", s), f("expires_at", t))},
	}
}
