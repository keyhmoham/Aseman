package themes

import "github.com/aseman/aseman/plugins/adapters/database/ports"

func f(name string, k database.Kind) database.Field {
	return database.Field{Name: name, Kind: k}
}

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model { return []database.Model{userThemes()} }

func userThemes() database.Model {
	return database.Model{
		Name:  "user_themes",
		Table: "user_themes",
		Fields: []database.Field{
			f("id", database.KindString),
			f("user_id", database.KindString),
			f("theme_id", database.KindString),
			f("listing_id", database.KindString),
			f("pack_json", database.KindString),
			f("created_at", database.KindTime),
			f("updated_at", database.KindTime),
		},
	}
}
