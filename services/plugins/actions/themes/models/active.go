package themes

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
)

// ActiveTheme is the legacy account-level apply row (themes.apply write-through).
// Session look lives in that session's metadata theme/theming tree instead.
type ActiveTheme struct {
	entity.Entity
	UserID    identity.ID `db:"user_id" json:"user_id"`
	ThemeID   identity.ID `db:"theme_id" json:"theme_id"`
	ListingID identity.ID `db:"listing_id" json:"listing_id,omitempty"`
	PackJSON  string      `db:"pack_json" json:"pack_json"`
}

// Touch updates UpdatedAt.
func (a *ActiveTheme) Touch() { a.UpdatedAt = time.Now().UTC() }
