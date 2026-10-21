// Package entity defines the base embedded entity shared by all persisted
// domain records. Every entity carries a universal id and audit timestamps.
package entity

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
)

// Entity is embedded into all persisted domain records.
type Entity struct {
	ID        identity.ID `db:"id" json:"id"`
	CreatedAt time.Time   `db:"created_at" json:"created_at"`
	UpdatedAt time.Time   `db:"updated_at" json:"updated_at"`
}

// Touch updates the updated timestamp.
func (e *Entity) Touch(t time.Time) { e.UpdatedAt = t }

// Created sets the audit timestamps on creation.
func (e *Entity) Created(now time.Time) {
	e.CreatedAt = now
	e.UpdatedAt = now
}
