package schema

import (
	records "github.com/aseman/aseman/plugins/actions/finance/models"
	shared "github.com/aseman/aseman/plugins/actions/support/schema"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func Models() []database.Model {
	return append(append(shared.Models(), []database.Model{wallets(), ledger()}...), records.RecordModels()...)
}

func wallets() database.Model {
	return database.Model{
		Name:  "wallets",
		Table: "wallets",
		Fields: []database.Field{
			f("id", database.KindString), f("owner_id", database.KindString),
			f("balance", database.KindInt64), f("locked", database.KindInt64),
			f("updated_at", database.KindTime),
		},
	}
}

func ledger() database.Model {
	return database.Model{
		Name:  "ledger",
		Table: "ledger",
		Fields: []database.Field{
			f("id", database.KindString), f("seq", database.KindInt64),
			f("node_id", database.KindString), f("type", database.KindString),
			f("from_id", database.KindString), f("to_id", database.KindString),
			f("amount", database.KindInt64), f("description", database.KindString),
			f("created_at", database.KindTime),
		},
	}
}
