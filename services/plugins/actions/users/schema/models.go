package schema

import (
	shared "github.com/tradera/tradera/plugins/actions/support/schema"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func Models() []database.Model {
	return append(shared.Models(), []database.Model{follows(), pushDevices()}...)
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
