package schema

import (
	shared "github.com/tradera/tradera/plugins/actions/support/schema"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func Models() []database.Model {
	return append(shared.Models(), []database.Model{accounts(), sessions(), challenges()}...)
}

func accounts() database.Model {
	return database.Model{
		Name:  "accounts",
		Table: "accounts",
		Fields: []database.Field{
			f("id", database.KindString), f("kind", database.KindString),
			f("handle", database.KindString), f("email", database.KindString),
			f("role", database.KindString), f("recovery_key_enc", database.KindString), f("email_verified", database.KindBool), f("password_hash", database.KindString), f("public_key", database.KindString),
			f("private_key_enc", database.KindString), f("status", database.KindString),
			f("metadata_id", database.KindString),
			f("last_seen", database.KindTime), f("created_at", database.KindTime),
			f("updated_at", database.KindTime),
		},
	}
}

func sessions() database.Model {
	return database.Model{
		Name:  "sessions",
		Table: "sessions",
		Fields: []database.Field{
			f("id", database.KindString), f("owner_id", database.KindString),
			f("token_hash", database.KindString), f("kind", database.KindString),
			f("expires_at", database.KindTime), f("last_seen_at", database.KindTime),
			f("meta", database.KindJSON), f("created_at", database.KindTime),
			f("updated_at", database.KindTime),
		},
	}
}

func challenges() database.Model {
	return database.Model{
		Name:  "auth_challenges",
		Table: "auth_challenges",
		Fields: []database.Field{
			f("id", database.KindString), f("account_id", database.KindString),
			f("purpose", database.KindString), f("code_hash", database.KindString),
			f("attempts", database.KindInt64), f("expires_at", database.KindTime),
			f("used_at", database.KindTime), f("created_at", database.KindTime),
			f("updated_at", database.KindTime),
		},
	}
}
