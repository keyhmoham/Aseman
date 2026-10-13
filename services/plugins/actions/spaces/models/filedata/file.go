// Package filedata defines files stored in the platform: user/bot metadata
// files and space/room files. Storage is delegated to a filesystem plugin; the
// database row links the logical file to a storage key.
package filedata

import (
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
)

// File is a logical file record.
type File struct {
	entity.Entity
	OwnerID    identity.ID `db:"owner_id" json:"owner_id"` // uploading account
	SpaceID    identity.ID `db:"space_id" json:"space_id,omitempty"`
	RoomID     identity.ID `db:"room_id" json:"room_id,omitempty"`
	MetadataID identity.ID `db:"metadata_id" json:"metadata_id,omitempty"` // metadata record this file is linked to
	MetaPath   string      `db:"meta_path" json:"meta_path,omitempty"`     // path inside metadata tree
	Name       string      `db:"name" json:"name"`
	Mime       string      `db:"mime" json:"mime"`
	Size       int64       `db:"size" json:"size"`
	StorageKey string      `db:"storage_key" json:"storage_key"`
	Public     bool        `db:"public" json:"public"`
}
