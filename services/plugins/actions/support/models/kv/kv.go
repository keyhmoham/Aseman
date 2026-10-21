// Package kv defines the key-value storage used by bots. Storage is scoped:
// global (bot-wide), space-wide or room-wide, and isolated per owner within
// each scope so no bot can read another bot's data.
package kv

import (
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
)

// Scope of a KV namespace.
type Scope string

const (
	ScopeGlobal Scope = "global" // bot's own global data
	ScopeSpace  Scope = "space"  // data scoped to a space the bot is in
	ScopeRoom   Scope = "room"   // data scoped to a room
	ScopeBot    Scope = "bot"    // a bot's entity storage (keyed by bot id)
)

// Item is a single key-value pair owned by one account within a scope.
type Item struct {
	entity.Entity
	Scope   Scope       `db:"scope" json:"scope"`
	ScopeID identity.ID `db:"scope_id" json:"scope_id,omitempty"` // space or room id
	OwnerID identity.ID `db:"owner_id" json:"owner_id"`
	Key     string      `db:"key" json:"key"`
	Value   string      `db:"value" json:"value"` // JSON value
}
