// Package google holds the records of the google namespace: the node's OAuth
// client (registered once by an administrator) and each person's own
// connection to Gmail and Google Calendar.
package google

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// SettingsID is the one settings record's id.
const SettingsID = "00000000000000000000000000000001"

// Settings is the node's Google OAuth client.
type Settings struct {
	entity.Entity
	Enabled      bool   `db:"enabled" json:"enabled"`
	ClientID     string `db:"client_id" json:"client_id"`
	ClientSecret string `db:"client_secret" json:"-"`
	UpdatedBy    string `db:"updated_by" json:"updated_by,omitempty"`
}

// Connection states.
const (
	StatusConnected = "connected"
	StatusBroken    = "needs_reconnect"
)

// Connection is one person's Google account. Its id is the person's account
// id. The refresh token is sealed and never leaves the node.
type Connection struct {
	entity.Entity
	Email        string    `db:"email" json:"email"`
	Scopes       []string  `db:"scopes" json:"scopes"`
	RefreshToken string    `db:"refresh_token" json:"-"`
	Status       string    `db:"status" json:"status"`
	LastError    string    `db:"last_error" json:"last_error,omitempty"`
	ConnectedAt  time.Time `db:"connected_at" json:"connected_at"`
	// Fake marks a connection to the test Google, which a real one replaces.
	Fake bool `db:"fake" json:"fake,omitempty"`
}

// OAuthState is one sign-in in progress: who started it and its PKCE
// verifier. It is used once and expires in ten minutes.
type OAuthState struct {
	entity.Entity
	AccountID string    `db:"account_id" json:"account_id"`
	Verifier  string    `db:"verifier" json:"-"`
	Return    string    `db:"return_to" json:"return_to,omitempty"`
	ExpiresAt time.Time `db:"expires_at" json:"expires_at"`
}

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func base(fields ...database.Field) []database.Field {
	return append([]database.Field{f("id", database.KindString), f("created_at", database.KindTime), f("updated_at", database.KindTime)}, fields...)
}

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model {
	return []database.Model{
		{Name: "google_settings", Table: "google_settings", Fields: base(f("enabled", database.KindBool), f("client_id", database.KindString),
			f("client_secret", database.KindString), f("updated_by", database.KindString))},
		{Name: "google_connections", Table: "google_connections", Fields: base(f("email", database.KindString), f("scopes", database.KindJSON),
			f("refresh_token", database.KindString), f("status", database.KindString), f("last_error", database.KindString),
			f("connected_at", database.KindTime), f("fake", database.KindBool))},
		{Name: "google_oauth_states", Table: "google_oauth_states", Fields: base(f("account_id", database.KindString), f("verifier", database.KindString),
			f("return_to", database.KindString), f("expires_at", database.KindTime))},
	}
}
