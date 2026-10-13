// Package space defines spaces and rooms, the containers of federation
// collaboration. A space groups members, rooms, files and bots; rooms scope
// messages, files and bot key-value data further.
package space

import (
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
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
	// Home marks the workspace automatically linked to a user's account at
	// registration (the "my workspace" default).
	Home bool `db:"home" json:"home,omitempty"`
	// Direct marks a direct conversation: a one-room space between two
	// accounts (two people, or a person and an agent). DirectKey names the
	// pair so the conversation is found again from either side.
	Direct    bool   `db:"direct" json:"direct,omitempty"`
	DirectKey string `db:"direct_key" json:"direct_key,omitempty"`
}

// Room scopes messages, files and bots within a space.
type Room struct {
	entity.Entity
	SpaceID    identity.ID `db:"space_id" json:"space_id"`
	Name       string      `db:"name" json:"name"`
	Topic      string      `db:"topic" json:"topic,omitempty"`
	MetadataID identity.ID `db:"metadata_id" json:"metadata_id"`
}

// New assembles a fresh space.
func New(id, owner identity.ID, name string) *Space {
	return &Space{Entity: entity.Entity{ID: id}, OwnerID: owner, Name: name}
}

// NewRoom assembles a fresh room.
func NewRoom(id, spaceID identity.ID, name string) *Room {
	return &Room{Entity: entity.Entity{ID: id}, SpaceID: spaceID, Name: name}
}
