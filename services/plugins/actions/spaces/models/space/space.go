// Package space defines spaces and rooms, the containers of federation
// collaboration. A space groups members, rooms, files and bots; rooms scope
// messages, files and bot key-value data further.
package space

import (
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
)

// Space is a federation workspace owned by a single account.
type Space struct {
	entity.Entity
	OwnerID     identity.ID `db:"owner_id" json:"owner_id"`
	Name        string      `db:"name" json:"name"`
	Description string      `db:"description" json:"description,omitempty"`
	AvatarID    identity.ID `db:"avatar_id" json:"avatar_id,omitempty"`
	MetadataID  identity.ID `db:"metadata_id" json:"metadata_id"`
	Public      bool        `db:"public" json:"public"`
	// Home marks the person's own workspace: their personal Aseman chat
	// (self-Direct), computer, and lead. One space per person.
	Home bool `db:"home" json:"home,omitempty"`
	// Direct marks a direct conversation: a one-room space between two
	// accounts (two people, or a person and an agent), or the person's
	// home Aseman self-chat (DirectKey is person:person). DirectKey names
	// the pair so the conversation is found again from either side.
	Direct    bool   `db:"direct" json:"direct,omitempty"`
	DirectKey string `db:"direct_key" json:"direct_key,omitempty"`
}

// Room scopes messages, files and bots within a space.
//
// A room's conversation can be split into threads. A thread is stored as a
// room of its own whose ParentID names the room it belongs to: its messages,
// and the agents' conversation context (keyed by room), are its own, while
// the desk, grants and listings stay the parent room's. The room itself is
// its main thread.
type Room struct {
	entity.Entity
	SpaceID    identity.ID `db:"space_id" json:"space_id"`
	Name       string      `db:"name" json:"name"`
	Topic      string      `db:"topic" json:"topic,omitempty"`
	MetadataID identity.ID `db:"metadata_id" json:"metadata_id"`
	// ParentID is the room a thread belongs to (empty for a room).
	ParentID string `db:"parent_id" json:"parent_id,omitempty"`
	// Temporary marks a thread opened for one piece of work (an app asking an
	// agent): it is deleted when the work is done.
	Temporary bool `db:"temporary" json:"temporary,omitempty"`
	// CreatorID is who opened a thread.
	CreatorID string `db:"creator_id" json:"creator_id,omitempty"`
	// Purpose is what the room is for: its agents are told, keep the work
	// there about it, and greet it with three things to start on. Icon and
	// Color are how it shows, and the tasks started there wear its colour.
	Purpose string `db:"purpose" json:"purpose,omitempty"`
	Icon    string `db:"icon" json:"icon,omitempty"`
	Color   string `db:"color" json:"color,omitempty"`
}

// IsThread reports whether the room is a thread of another room.
func (r *Room) IsThread() bool { return r != nil && r.ParentID != "" }

// New assembles a fresh space.
func New(id, owner identity.ID, name string) *Space {
	return &Space{Entity: entity.Entity{ID: id}, OwnerID: owner, Name: name}
}

// NewRoom assembles a fresh room.
func NewRoom(id, spaceID identity.ID, name string) *Room {
	return &Room{Entity: entity.Entity{ID: id}, SpaceID: spaceID, Name: name}
}
