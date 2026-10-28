// Package hostaccess holds the records of the hostaccess namespace: the
// folders people share from their projects' computers, the node's host access
// switch, and (only while that is on) the people's own computers and the
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

// Folder access.
const (
	AccessRead  = "read"
	AccessWrite = "write"
)

// SharedFolder is a folder of one of a person's project computers that the
// person shares with their own agents in every project: the agents read it
// (or, with write access, change it) through the folder tools.
type SharedFolder struct {
	entity.Entity
	OwnerID string `db:"owner_id" json:"owner_id"`
	// SpaceID is the project whose computer holds the folder; Path is the
	// folder inside its workspace ("" is the whole workspace).
	SpaceID string `db:"space_id" json:"space_id"`
	Path    string `db:"path" json:"path"`
	Name    string `db:"name" json:"name"`
	Access  string `db:"access" json:"access"`
	Enabled bool   `db:"enabled" json:"enabled"`
}

// Settings is the node's host access switch. Letting agents reach people's
// own computers is the highest access the node can give, so it is off until
// an administrator turns it on.
type Settings struct {
	entity.Entity
	HostEnabled bool   `db:"host_enabled" json:"host_enabled"`
	UpdatedBy   string `db:"updated_by" json:"updated_by,omitempty"`
}

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model {
	s, t, b, j := database.KindString, database.KindTime, database.KindBool, database.KindJSON
	return []database.Model{
		{Name: "hosts", Table: "hosts", Fields: []database.Field{f("id", s), f("created_at", t), f("updated_at", t), f("owner_id", s),
			f("name", s), f("platform", s), f("folders", j), f("enabled", b), f("last_seen", t)}},
		{Name: "shared_folders", Table: "shared_folders", Fields: []database.Field{f("id", s), f("created_at", t), f("updated_at", t), f("owner_id", s),
			f("space_id", s), f("path", s), f("name", s), f("access", s), f("enabled", b)}},
		{Name: "hostaccess_settings", Table: "hostaccess_settings", Fields: []database.Field{f("id", s), f("created_at", t), f("updated_at", t),
			f("host_enabled", b), f("updated_by", s)}},
		{Name: "host_calls", Table: "host_calls", Fields: []database.Field{f("id", s), f("created_at", t), f("updated_at", t), f("host_id", s),
			f("owner_id", s), f("agent_name", s), f("tool", s), f("args", s), f("status", s), f("output", s), f("error", s), f("expires_at", t)}},
	}
}
