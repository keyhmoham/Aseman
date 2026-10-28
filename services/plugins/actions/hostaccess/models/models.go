// Package hostaccess holds the records of the hostaccess namespace: the
// computers people let their agents use through the desktop app, and the
// calls waiting for them.
package hostaccess

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Host is a person's own computer, connected through the desktop app,
// limited to the folders they share.
type Host struct {
	entity.Entity
	OwnerID  string    `db:"owner_id" json:"owner_id"`
	Name     string    `db:"name" json:"name"`
	Platform string    `db:"platform" json:"platform"`
	Folders  []string  `db:"folders" json:"folders"`
	Enabled  bool      `db:"enabled" json:"enabled"`
	LastSeen time.Time `db:"last_seen" json:"last_seen"`
}

// Call states.
const (
	CallPending = "pending"
	CallClaimed = "claimed"
	CallDone    = "done"
	CallFailed  = "failed"
	CallExpired = "expired"
)

// Call is one agent request for a host.
type Call struct {
	entity.Entity
	HostID    string    `db:"host_id" json:"host_id"`
	OwnerID   string    `db:"owner_id" json:"owner_id"`
	AgentName string    `db:"agent_name" json:"agent_name,omitempty"`
	Tool      string    `db:"tool" json:"tool"`
	Args      string    `db:"args" json:"args"`
	Status    string    `db:"status" json:"status"`
	Output    string    `db:"output" json:"output,omitempty"`
	Error     string    `db:"error" json:"error,omitempty"`
	ExpiresAt time.Time `db:"expires_at" json:"expires_at"`
}

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model {
	s, t, b, j := database.KindString, database.KindTime, database.KindBool, database.KindJSON
	return []database.Model{
		{Name: "hosts", Table: "hosts", Fields: []database.Field{f("id", s), f("created_at", t), f("updated_at", t), f("owner_id", s),
			f("name", s), f("platform", s), f("folders", j), f("enabled", b), f("last_seen", t)}},
		{Name: "host_calls", Table: "host_calls", Fields: []database.Field{f("id", s), f("created_at", t), f("updated_at", t), f("host_id", s),
			f("owner_id", s), f("agent_name", s), f("tool", s), f("args", s), f("status", s), f("output", s), f("error", s), f("expires_at", t)}},
	}
}
