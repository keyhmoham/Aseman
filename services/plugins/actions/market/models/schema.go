package market

import "github.com/aseman/aseman/plugins/adapters/database/ports"

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model { return []database.Model{market()} }

func market() database.Model {
	return database.Model{
		Name:  "market",
		Table: "market",
		Fields: []database.Field{
			f("id", database.KindString), f("publisher_id", database.KindString),
			f("bot_id", database.KindString), f("type", database.KindString),
			f("name", database.KindString), f("description", database.KindString),
			f("price", database.KindInt64), f("image_ref", database.KindString),
			f("category", database.KindString), f("installs", database.KindInt64),
			f("status", database.KindString), f("review_reason", database.KindString), f("created_at", database.KindTime),
			f("updated_at", database.KindTime),
		},
	}
}
