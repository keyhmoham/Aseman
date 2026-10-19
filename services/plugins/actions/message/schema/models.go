package schema

import (
	shared "github.com/tradera/tradera/plugins/actions/support/schema"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func Models() []database.Model {
	return append(shared.Models(), []database.Model{messages(), directs(), packets()}...)
}

func messages() database.Model {
	return database.Model{
		Name:  "messages",
		Table: "messages",
		Fields: []database.Field{
			f("id", database.KindString), f("space_id", database.KindString),
			f("room_id", database.KindString), f("sender_id", database.KindString),
			f("body", database.KindString), f("kind", database.KindString),
			f("mentions", database.KindJSON),
			f("attachment_ids", database.KindJSON),
			f("reply_to", database.KindString),
			f("edited_at", database.KindTime),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}

func directs() database.Model {
	return database.Model{
		Name:  "directs",
		Table: "directs",
		Fields: []database.Field{
			f("id", database.KindString), f("from_id", database.KindString),
			f("to_id", database.KindString), f("body", database.KindString),
			f("sent_at", database.KindTime), f("reply_to", database.KindString),
			f("edited_at", database.KindTime), f("deleted_at", database.KindTime),
			f("agent_id", database.KindString), f("created_at", database.KindTime),
			f("updated_at", database.KindTime),
		},
	}
}

func packets() database.Model {
	return database.Model{
		Name:  "packets",
		Table: "packets",
		Fields: []database.Field{
			f("id", database.KindString), f("from_id", database.KindString),
			f("to_id", database.KindString), f("kind", database.KindString),
			f("status", database.KindString), f("body", database.KindString),
			f("payload", database.KindString), f("correlation_id", database.KindString),
			f("replied_at", database.KindTime), f("received_at", database.KindTime),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}
