package usage

import "github.com/tradera/tradera/plugins/adapters/database/ports"

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model { return []database.Model{usages(), memoryUsages()} }

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
			f("decision_in", database.KindInt64), f("decision_out", database.KindInt64), f("decision", database.KindInt64),
			f("image_count", database.KindInt64), f("image_in", database.KindInt64), f("image_out", database.KindInt64), f("image_model", database.KindString),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}

func memoryUsages() database.Model {
	return database.Model{
		Name:  "memory_usages",
		Table: "memory_usages",
		Fields: []database.Field{
			f("id", database.KindString), f("space_id", database.KindString),
			f("tokens", database.KindInt64), f("tokens_in", database.KindInt64), f("cost", database.KindInt64),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}
