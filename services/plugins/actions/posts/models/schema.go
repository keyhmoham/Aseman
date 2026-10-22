package post

import "github.com/aseman/aseman/plugins/adapters/database/ports"

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model { return []database.Model{posts(), postReports()} }

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
			f("source", database.KindString), f("source_id", database.KindString),
			f("source_at", database.KindTime), f("featured", database.KindInt64),
			f("forward_of", database.KindString), f("forward_author_id", database.KindString),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}

func postReports() database.Model {
	return database.Model{
		Name:  "post_reports",
		Table: "post_reports",
		Fields: []database.Field{
			f("id", database.KindString), f("reporter_id", database.KindString),
			f("post_id", database.KindString), f("accused_id", database.KindString),
			f("reason", database.KindString), f("note", database.KindString),
			f("body", database.KindString), f("status", database.KindString),
			f("resolved_by", database.KindString), f("resolved_at", database.KindTime),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}
