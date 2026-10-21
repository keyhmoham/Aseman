package schema

import (
	shared "github.com/aseman/aseman/plugins/actions/support/schema"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func Models() []database.Model {
	return append(shared.Models(), []database.Model{follows(), pushDevices(), notifications()}...)
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

// notifications are each person's in-app inbox of what they were told.
func notifications() database.Model {
	return database.Model{
		Name:  "notifications",
		Table: "notifications",
		Fields: []database.Field{
			f("id", database.KindString), f("account", database.KindString),
			f("title", database.KindString), f("body", database.KindString),
			f("kind", database.KindString), f("space", database.KindString),
			f("room", database.KindString), f("collapse", database.KindString),
			f("read", database.KindBool), f("created_at", database.KindTime),
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
