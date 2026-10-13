package schema

import "github.com/tradera/tradera/plugins/adapters/database/ports"

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func Models() []database.Model { return []database.Model{metadatas(), kv(), executionLeases()} }

func metadatas() database.Model {
	return database.Model{
		Name:  "metadatas",
		Table: "metadatas",
		Fields: []database.Field{
			f("id", database.KindString), // primary key (equals the owner)
			f("owner", database.KindString),
			f("tree", database.KindJSON),
			f("public_paths", database.KindJSON), f("version", database.KindInt64),
			f("updated_at", database.KindTime),
		},
	}
}

func kv() database.Model {
	return database.Model{
		Name:  "kv",
		Table: "kv",
		Fields: []database.Field{
			f("id", database.KindString), f("scope", database.KindString),
			f("scope_id", database.KindString), f("owner_id", database.KindString),
			f("key", database.KindString), f("value", database.KindJSON),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}

func executionLeases() database.Model {
	return database.Model{
		Name:  "execution_leases",
		Table: "execution_leases",
		Fields: []database.Field{
			f("id", database.KindString), f("token", database.KindString),
			f("expires_at", database.KindTime),
		},
	}
}
