package models

import (
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"time"
)

type Offer struct {
	entity.Entity
	SpaceID      identity.ID `db:"space_id" json:"space_id"`
	SenderID     identity.ID `db:"sender_id" json:"sender_id"`
	RecipientID  identity.ID `db:"recipient_id" json:"recipient_id"`
	Amount       int64       `db:"amount" json:"amount"`
	Status       string      `db:"status" json:"status"`
	Message      string      `db:"message" json:"message"`
	InvitationID string      `db:"invitation_id" json:"invitation_id"`
	FundedAt     *time.Time  `db:"funded_at" json:"funded_at,omitempty"`
	RespondedAt  *time.Time  `db:"responded_at" json:"responded_at,omitempty"`
	Error        string      `db:"error" json:"error,omitempty"`
}

// Models are the namespace's records: offers, requests and partner keys.
func Models() []database.Model {
	return append(offerModels(), requestModels()...)
}

func offerModels() []database.Model {
	f := func(n string, k database.Kind) database.Field { return database.Field{Name: n, Kind: k} }
	return []database.Model{{Name: "talent_offers", Table: "talent_offers", Fields: []database.Field{f("id", database.KindString), f("space_id", database.KindString), f("sender_id", database.KindString), f("recipient_id", database.KindString), f("amount", database.KindInt64), f("status", database.KindString), f("message", database.KindString), f("invitation_id", database.KindString), f("funded_at", database.KindTime), f("responded_at", database.KindTime), f("error", database.KindString), f("created_at", database.KindTime), f("updated_at", database.KindTime)}}}
}
