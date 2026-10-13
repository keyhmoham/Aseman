package models

import (
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"time"
)

type Tool struct {
	ID        string           `db:"id" json:"id"`
	BotID     string           `db:"bot_id" json:"bot_id"`
	Owner     string           `db:"owner" json:"owner"`
	URL       string           `db:"url" json:"url"`
	Auth      string           `db:"auth" json:"auth"`
	Commands  []map[string]any `db:"commands" json:"commands"`
	Secrets   string           `db:"secrets" json:"-"`
	UpdatedAt time.Time        `db:"updated_at" json:"updated_at"`
}
type Connection struct {
	ID        string     `db:"id" json:"id"`
	Owner     string     `db:"owner" json:"owner"`
	BotID     string     `db:"bot_id" json:"bot_id"`
	SpaceID   string     `db:"space_id" json:"space_id"`
	Secret    string     `db:"secret" json:"-"`
	ExpiresAt *time.Time `db:"expires_at" json:"expires_at,omitempty"`
	UpdatedAt time.Time  `db:"updated_at" json:"updated_at"`
}
type OAuth struct {
	ID        string    `db:"id"`
	Owner     string    `db:"owner"`
	Status    string    `db:"status"`
	Secret    string    `db:"secret" json:"-"`
	ExpiresAt time.Time `db:"expires_at"`
}

func Models() []database.Model {
	f := func(n string, k database.Kind) database.Field { return database.Field{Name: n, Kind: k} }
	return []database.Model{
		{Name: "tool_registry", Table: "tool_registry", Fields: []database.Field{f("id", database.KindString), f("bot_id", database.KindString), f("owner", database.KindString), f("url", database.KindString), f("auth", database.KindString), f("commands", database.KindJSON), f("secrets", database.KindString), f("updated_at", database.KindTime)}},
		{Name: "tool_connections", Table: "tool_connections", Fields: []database.Field{f("id", database.KindString), f("owner", database.KindString), f("bot_id", database.KindString), f("space_id", database.KindString), f("secret", database.KindString), f("expires_at", database.KindTime), f("updated_at", database.KindTime)}},
		{Name: "tool_oauth", Table: "tool_oauth", Fields: []database.Field{f("id", database.KindString), f("owner", database.KindString), f("status", database.KindString), f("secret", database.KindString), f("expires_at", database.KindTime)}},
	}
}
