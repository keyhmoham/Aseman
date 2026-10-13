package schema

import (
	shared "github.com/tradera/tradera/plugins/actions/support/schema"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func Models() []database.Model {
	return append(shared.Models(), []database.Model{bots(), botEntities()}...)
}

func bots() database.Model {
	return database.Model{
		Name:  "bots",
		Table: "bots",
		Fields: []database.Field{
			f("id", database.KindString), f("owner_id", database.KindString),
			f("account_id", database.KindString), f("name", database.KindString),
			f("kind", database.KindString), f("vm_type", database.KindString),
			f("status", database.KindString),
			f("vm_id", database.KindString), f("image_ref", database.KindString),
			f("spec_yml", database.KindString), f("resources", database.KindJSON),
			f("cost", database.KindJSON), f("pool_id", database.KindString),
			f("frontend", database.KindString), f("frontend_ref", database.KindString),
			f("started_at", database.KindTime), f("stopped_at", database.KindTime),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}

func botEntities() database.Model {
	return database.Model{
		Name:  "bot_entities",
		Table: "bot_entities",
		Fields: []database.Field{
			f("id", database.KindString),
			f("bot_id", database.KindString),
			f("key", database.KindString),
			f("value", database.KindBytes), // arbitrary runtime content (binary-safe)
			f("mime", database.KindString),
			f("size", database.KindInt64),
			f("created_at", database.KindTime),
			f("updated_at", database.KindTime),
		},
	}
}
