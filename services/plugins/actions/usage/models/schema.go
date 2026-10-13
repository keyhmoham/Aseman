package usage

import "github.com/tradera/tradera/plugins/adapters/database/ports"

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model { return []database.Model{usages()} }

func usages() database.Model {
	return database.Model{
		Name:  "usages",
		Table: "usages",
		Fields: []database.Field{
			f("id", database.KindString), f("space_id", database.KindString),
			f("room_id", database.KindString), f("bot_id", database.KindString),
			f("bot_name", database.KindString), f("actor_id", database.KindString),
			f("request_id", database.KindString), f("provider", database.KindString), f("model", database.KindString), f("kind", database.KindString),
			f("tokens_in", database.KindInt64), f("tokens_out", database.KindInt64),
			f("images", database.KindInt64), f("cost", database.KindInt64),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}
