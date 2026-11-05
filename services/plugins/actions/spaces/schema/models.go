package schema

import (
	shared "github.com/aseman/aseman/plugins/actions/support/schema"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func Models() []database.Model {
	return append(shared.Models(), []database.Model{spaces(), rooms(), memberships(), files(), proxies(), invitations(), turns(), executionEvents(), executionArtifacts(), chatReports(), appKeys(), messageReactions(), messageHidden(), keptRoomFiles()}...)
}

func messageReactions() database.Model {
	return database.Model{
		Name:  "message_reactions",
		Table: "message_reactions",
		Fields: []database.Field{
			f("id", database.KindString), f("message_id", database.KindString),
			f("user_id", database.KindString), f("emoji", database.KindString),
			f("created_at", database.KindTime),
		},
	}
}

func messageHidden() database.Model {
	return database.Model{
		Name:  "message_hidden",
		Table: "message_hidden",
		Fields: []database.Field{
			f("id", database.KindString), f("user_id", database.KindString),
			f("message_id", database.KindString), f("created_at", database.KindTime),
		},
	}
}

func keptRoomFiles() database.Model {
	return database.Model{
		Name:  "kept_room_files",
		Table: "kept_room_files",
		Fields: []database.Field{
			f("id", database.KindString), f("owner_id", database.KindString),
			f("from_id", database.KindString), f("source_id", database.KindString),
			f("message_id", database.KindString), f("name", database.KindString),
			f("mime", database.KindString), f("size", database.KindInt64),
			f("created_at", database.KindTime),
		},
	}
}

func spaces() database.Model {
	return database.Model{
		Name:  "spaces",
		Table: "spaces",
		Fields: []database.Field{
			f("id", database.KindString), f("owner_id", database.KindString),
			f("name", database.KindString), f("description", database.KindString),
			f("avatar_id", database.KindString), f("metadata_id", database.KindString),
			f("public", database.KindBool), f("platform_id", database.KindString),
			f("home", database.KindBool),
			f("direct", database.KindBool), f("direct_key", database.KindString),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}

func rooms() database.Model {
	return database.Model{
		Name:  "rooms",
		Table: "rooms",
		Fields: []database.Field{
			f("id", database.KindString), f("space_id", database.KindString),
			f("name", database.KindString), f("topic", database.KindString),
			f("metadata_id", database.KindString),
			f("parent_id", database.KindString), f("temporary", database.KindBool),
			f("creator_id", database.KindString),
			f("purpose", database.KindString), f("icon", database.KindString), f("color", database.KindString),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}

func memberships() database.Model {
	return database.Model{
		Name:  "memberships",
		Table: "memberships",
		Fields: []database.Field{
			f("id", database.KindString), f("space_id", database.KindString),
			f("room_id", database.KindString), f("member_id", database.KindString),
			f("role", database.KindString), f("permissions", database.KindJSON),
			f("joined_at", database.KindTime), f("created_at", database.KindTime),
			f("updated_at", database.KindTime),
		},
	}
}

func files() database.Model {
	return database.Model{
		Name:  "files",
		Table: "files",
		Fields: []database.Field{
			f("id", database.KindString), f("owner_id", database.KindString),
			f("space_id", database.KindString), f("room_id", database.KindString),
			f("metadata_id", database.KindString), f("meta_path", database.KindString),
			f("name", database.KindString), f("mime", database.KindString),
			f("size", database.KindInt64), f("storage_key", database.KindString),
			f("public", database.KindBool),
			{Name: "source_url", Kind: database.KindString, Index: true},
			f("content_hash", database.KindString),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}

func proxies() database.Model {
	return database.Model{
		Name:  "proxies",
		Table: "proxies",
		Fields: []database.Field{
			f("id", database.KindString), f("space_id", database.KindString),
			f("room_id", database.KindString), f("owner_id", database.KindString),
			f("port", database.KindInt64), f("title", database.KindString),
			f("target_url", database.KindString), f("token", database.KindString),
			f("path", database.KindString),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}

func invitations() database.Model {
	return database.Model{
		Name:  "invitations",
		Table: "invitations",
		Fields: []database.Field{
			f("id", database.KindString), f("space_id", database.KindString),
			f("room_id", database.KindString), f("inviter_id", database.KindString),
			f("invitee_id", database.KindString), f("role", database.KindString),
			f("token", database.KindString), f("status", database.KindString),
			f("expires_at", database.KindTime), f("created_at", database.KindTime),
			f("updated_at", database.KindTime),
		},
	}
}

func turns() database.Model {
	return database.Model{Name: "room_turns", Table: "room_turns", Fields: []database.Field{
		f("id", database.KindString), f("space_id", database.KindString), f("room_id", database.KindString), f("actor_id", database.KindString), f("submission", database.KindString), f("fingerprint", database.KindString), f("message_id", database.KindString), f("prompt", database.KindString), f("seeds", database.KindJSON), f("attachments", database.KindJSON), f("status", database.KindString), f("error", database.KindString), f("started_at", database.KindTime), f("ended_at", database.KindTime), f("lease_until", database.KindTime), f("spans", database.KindJSON), f("created_at", database.KindTime), f("updated_at", database.KindTime)}}
}

// executionEvents records each platform tool an agent ran (idempotent replay
// and audit of agent work).
func executionEvents() database.Model {
	return database.Model{
		Name:  "execution_events",
		Table: "execution_events",
		Fields: []database.Field{
			f("id", database.KindString), f("space_id", database.KindString),
			f("room_id", database.KindString), f("run_id", database.KindString),
			f("step_id", database.KindString), f("attempt_id", database.KindString),
			f("agent_id", database.KindString), f("agent_name", database.KindString),
			f("tool", database.KindString), f("args", database.KindString),
			f("result", database.KindString), f("status", database.KindString),
			f("at", database.KindTime),
		},
	}
}

// executionArtifacts binds files agents delivered to the run that produced them.
func executionArtifacts() database.Model {
	return database.Model{Name: "execution_artifacts", Table: "execution_artifacts", Fields: []database.Field{
		f("id", database.KindString), f("file_id", database.KindString), f("space_id", database.KindString), f("room_id", database.KindString), f("run_id", database.KindString), f("step_id", database.KindString), f("attempt_id", database.KindString), f("agent_id", database.KindString), f("delivered", database.KindBool), f("created_at", database.KindTime), f("updated_at", database.KindTime),
	}}
}

// chatReports are what people reported in chats, for the node's admins.
func chatReports() database.Model {
	return database.Model{
		Name:  "chat_reports",
		Table: "chat_reports",
		Fields: []database.Field{
			f("id", database.KindString), f("reporter_id", database.KindString),
			f("space_id", database.KindString), f("room_id", database.KindString),
			f("message_id", database.KindString), f("accused_id", database.KindString),
			f("reason", database.KindString), f("note", database.KindString),
			f("evidence", database.KindString), f("status", database.KindString),
			f("resolved_by", database.KindString), f("resolved_at", database.KindTime),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}

// appKeys are apps' credentials for background work (see spaces/app_access.go).
func appKeys() database.Model {
	return database.Model{
		Name:  "app_keys",
		Table: "app_keys",
		Fields: []database.Field{
			f("id", database.KindString), f("app_id", database.KindString),
			f("space_id", database.KindString), f("room_id", database.KindString),
			f("proxy_id", database.KindString), f("owner_id", database.KindString),
			f("title", database.KindString), f("hash", database.KindString),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}


