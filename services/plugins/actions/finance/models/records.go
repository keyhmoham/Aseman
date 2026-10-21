package models

import (
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"time"
)

type Record struct {
	ID        string         `db:"id" json:"id"`
	Owner     string         `db:"owner" json:"owner"`
	Kind      string         `db:"kind" json:"kind"`
	Amount    int64          `db:"amount" json:"amount"`
	Status    string         `db:"status" json:"status"`
	Data      map[string]any `db:"data" json:"data"`
	CreatedAt time.Time      `db:"created_at" json:"created_at"`
	UpdatedAt time.Time      `db:"updated_at" json:"updated_at"`
}

func RecordModels() []database.Model {
	return []database.Model{{Name: "financial_records", Table: "financial_records", Fields: []database.Field{{Name: "id", Kind: database.KindString}, {Name: "owner", Kind: database.KindString}, {Name: "kind", Kind: database.KindString}, {Name: "amount", Kind: database.KindInt64}, {Name: "status", Kind: database.KindString}, {Name: "data", Kind: database.KindJSON}, {Name: "created_at", Kind: database.KindTime}, {Name: "updated_at", Kind: database.KindTime}}}}
}
