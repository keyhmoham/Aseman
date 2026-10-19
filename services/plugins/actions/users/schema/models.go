package schema

import (
	shared "github.com/tradera/tradera/plugins/actions/support/schema"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func Models() []database.Model {
	return append(shared.Models(), []database.Model{follows(), pushDevices(), directStates(), directHidden(), chatReports()}...)
}

// pushDevices are the phones people are signed in on, for notifications.
func pushDevices() database.Model {
	return database.Model{
		Name:  "push_devices",
		Table: "push_devices",
		Fields: []database.Field{
			f("id", database.KindString), f("account", database.KindString),
			f("token", database.KindString), f("platform", database.KindString),
			f("environment", database.KindString), f("updated_at", database.KindTime),
		},
	}
}

// directStates are each person's own view of each direct conversation: read
// up to, deleted (cleared) before, whether they blocked the peer and when
// they pinned the chat to the top of their list.
func directStates() database.Model {
	return database.Model{
		Name:  "direct_states",
		Table: "direct_states",
		Fields: []database.Field{
			f("id", database.KindString), f("user_id", database.KindString),
			f("peer_id", database.KindString), f("read_at", database.KindTime),
			f("cleared_at", database.KindTime), f("blocked", database.KindBool),
			f("pinned_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}

// directHidden are single messages a person deleted for themselves only.
func directHidden() database.Model {
	return database.Model{
		Name:  "direct_hidden",
		Table: "direct_hidden",
		Fields: []database.Field{
			f("id", database.KindString), f("user_id", database.KindString),
			f("message_id", database.KindString), f("created_at", database.KindTime),
		},
	}
}

// chatReports are what people reported in their direct messages, for the admin.
func chatReports() database.Model {
	return database.Model{
		Name:  "chat_reports",
		Table: "chat_reports",
		Fields: []database.Field{
			f("id", database.KindString), f("reporter_id", database.KindString),
			f("peer_id", database.KindString), f("message_id", database.KindString),
			f("kind", database.KindString), f("reason", database.KindString),
			f("note", database.KindString), f("evidence", database.KindString),
			f("status", database.KindString), f("resolved_by", database.KindString),
			f("created_at", database.KindTime), f("resolved_at", database.KindTime),
		},
	}
}

func follows() database.Model {
	return database.Model{
		Name:  "follows",
		Table: "follows",
		Fields: []database.Field{
			f("id", database.KindString), f("follower_id", database.KindString),
			f("followee_id", database.KindString),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}
