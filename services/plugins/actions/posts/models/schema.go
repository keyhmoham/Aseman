package post

import "github.com/tradera/tradera/plugins/adapters/database/ports"

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model { return []database.Model{posts()} }

func posts() database.Model {
	return database.Model{
		Name:  "posts",
		Table: "posts",
		Fields: []database.Field{
			f("id", database.KindString), f("author_id", database.KindString),
			f("space_id", database.KindString), f("parent_id", database.KindString),
			f("body", database.KindString), f("tags", database.KindString),
			f("media", database.KindString), f("liked_by", database.KindString),
			f("likes", database.KindInt64), f("edited_at", database.KindTime),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}
