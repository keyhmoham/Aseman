package schema

import (
	shared "github.com/tradera/tradera/plugins/actions/support/schema"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func Models() []database.Model { return append(shared.Models(), []database.Model{nodes()}...) }

func nodes() database.Model {
	return database.Model{
		Name:  "nodes",
		Table: "nodes",
		Fields: []database.Field{
			f("id", database.KindString), f("url", database.KindString),
			f("public_key", database.KindString), f("status", database.KindString),
			f("last_seen", database.KindTime), f("is_central", database.KindBool),
		},
	}
}
