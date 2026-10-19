package models

import (
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// Request statuses. A hidden request was taken down by the node's admin: it
// stays with its poster as "removed" and is never shown to partners.
const (
	RequestOpen   = "open"
	RequestClosed = "closed"
	RequestHidden = "hidden"
	// RequestDeleted is a request its poster deleted: kept, so a partner syncing
	// changes hears it is gone, and never shown to anyone.
	RequestDeleted = "deleted"
)

// Request is a job a person posts for talent: what they need, in what
// category, for what budget. Partners read the open ones through the API.
type Request struct {
	entity.Entity
	OwnerID identity.ID `db:"owner_id" json:"owner_id"`
	// SpaceID is the project it was posted from, if any (never shown to partners).
	SpaceID     identity.ID `db:"space_id" json:"space_id"`
	Title       string      `db:"title" json:"title"`
	Category    string      `db:"category" json:"category"`
	Description string      `db:"description" json:"description"`
	// BudgetType is fixed, hourly or monthly; BudgetCents is the amount in US cents.
	BudgetType  string `db:"budget_type" json:"budget_type"`
	BudgetCents int64  `db:"budget_cents" json:"budget_cents"`
	Company     string `db:"company" json:"company"`
	Timeline    string `db:"timeline" json:"timeline"`
	// Skills is a JSON list of short strings.
	Skills string `db:"skills" json:"skills"`
	Status string `db:"status" json:"status"`
}

// PartnerKey lets a partner read the open requests. Only its hash is kept.
type PartnerKey struct {
	entity.Entity
	Name       string    `db:"name" json:"name"`
	Prefix     string    `db:"prefix" json:"prefix"`
	Last4      string    `db:"last4" json:"last4"`
	Hash       string    `db:"hash" json:"-"`
	Status     string    `db:"status" json:"status"`
	LastUsedAt time.Time `db:"last_used_at" json:"last_used_at"`
	Requests   int64     `db:"requests" json:"requests"`
}

func requestModels() []database.Model {
	f := func(n string, k database.Kind) database.Field { return database.Field{Name: n, Kind: k} }
	fi := func(n string, k database.Kind) database.Field { return database.Field{Name: n, Kind: k, Index: true} }
	return []database.Model{
		{Name: "talent_requests", Table: "talent_requests", Fields: []database.Field{
			f("id", database.KindString), fi("owner_id", database.KindString), f("space_id", database.KindString),
			f("title", database.KindString), fi("category", database.KindString), f("description", database.KindString),
			f("budget_type", database.KindString), f("budget_cents", database.KindInt64), f("company", database.KindString),
			f("timeline", database.KindString), f("skills", database.KindString), fi("status", database.KindString),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		}},
		{Name: "talent_partner_keys", Table: "talent_partner_keys", Fields: []database.Field{
			f("id", database.KindString), f("name", database.KindString), f("prefix", database.KindString),
			f("last4", database.KindString), fi("hash", database.KindString), f("status", database.KindString),
			f("last_used_at", database.KindTime), f("requests", database.KindInt64),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		}},
	}
}
