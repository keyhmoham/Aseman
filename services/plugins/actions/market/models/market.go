// Package market defines the listings through which agents and apps are
// published, discovered and installed across the federated network.
package market

import (
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
)

// ItemType distinguishes the published artifacts: agents, and tools (apps).
type ItemType string

const (
	ItemAgent ItemType = "agent"
	ItemTool  ItemType = "tool"
)

// Status of a listing.
type Status string

const (
	StatusActive      Status = "active"
	StatusPending     Status = "pending"
	StatusDenied      Status = "denied"
	StatusUnpublished Status = "unpublished"
)

// Listing advertises a bot (an agent or an app) in the marketplace.
type Listing struct {
	entity.Entity
	// PublisherID is the account that published the listing.
	PublisherID identity.ID `db:"publisher_id" json:"publisher_id"`
	// BotID is the underlying bot VM being sold/advertised.
	BotID identity.ID `db:"bot_id" json:"bot_id"`
	// Type is agent or tool.
	Type ItemType `db:"type" json:"type"`
	// Name is the marketplace title.
	Name string `db:"name" json:"name"`
	// Description is the marketplace pitch.
	Description string `db:"description" json:"description"`
	// Price in ledger credits. Zero = free.
	Price int64 `db:"price" json:"price"`
	// ImageRef points at a cover image for the listing.
	ImageRef string `db:"image_ref" json:"image_ref,omitempty"`
	// Category is a free-form marketplace category tag.
	Category string `db:"category" json:"category,omitempty"`
	// Installs counts how many times the item was installed.
	Installs int64 `db:"installs" json:"installs"`
	// Status is active or unpublished.
	Status       Status `db:"status" json:"status"`
	ReviewReason string `db:"review_reason" json:"review_reason,omitempty"`
}

// InstallCount atomically bumps the install counter.
func (l *Listing) Installed() {
	l.Installs++
	l.UpdatedAt = time.Now().UTC()
}

// Unpublish marks the listing inactive.
func (l *Listing) Unpublish() {
	l.Status = StatusUnpublished
	l.UpdatedAt = time.Now().UTC()
}

// Publish marks the listing active.
func (l *Listing) Publish() {
	l.Status = StatusActive
	l.UpdatedAt = time.Now().UTC()
}
