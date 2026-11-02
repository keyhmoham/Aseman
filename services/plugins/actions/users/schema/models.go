package schema

import (
	shared "github.com/aseman/aseman/plugins/actions/support/schema"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func Models() []database.Model {
	return append(shared.Models(), []database.Model{follows(), pushDevices(), notifications(), directStates(), directHidden(), directReactions(), directAttachments(), keptFiles(), notificationPrefs(), privacyPrefs(), brainAccess(), brainReminders(), brainJobs(), aiLogs(), directCalls(), callSignals(), chatReports()}...)
}

// brainJobs is work handed to a person's own workspace by their Aseman, until the team has finished it
// (brain_jobs.go). What was asked is sealed at rest.
func brainJobs() database.Model {
	return database.Model{
		Name:  "brain_jobs",
		Table: "brain_jobs",
		Fields: []database.Field{
			f("id", database.KindString), f("person", database.KindString), f("space", database.KindString),
			f("space_name", database.KindString), f("turn", database.KindString), f("note", database.KindString),
			f("request", database.KindString), f("status", database.KindString), f("created_at", database.KindTime),
		},
	}
}

// aiLogs is the admin's record of what people asked their Aseman and the chat assistant (ailog.go).
// The prompt and the answer are sealed at rest.
func aiLogs() database.Model {
	return database.Model{
		Name:  "ai_logs",
		Table: "ai_logs",
		Fields: []database.Field{
			f("id", database.KindString), f("person", database.KindString), f("kind", database.KindString),
			f("peer", database.KindString), f("prompt", database.KindString), f("answer", database.KindString),
			f("plan", database.KindString), f("tools", database.KindString), f("status", database.KindString),
			f("error", database.KindString), f("millis", database.KindInt64), f("created_at", database.KindTime),
		},
	}
}

// brainReminders are what people asked their Aseman to remind them of: it
// writes in their notes (and pushes) at the time. The text is sealed at rest.
func brainReminders() database.Model {
	return database.Model{
		Name:  "brain_reminders",
		Table: "brain_reminders",
		Fields: []database.Field{
			f("id", database.KindString), f("person", database.KindString),
			f("due_at", database.KindTime), f("text", database.KindString),
			f("status", database.KindString), f("created_at", database.KindTime),
		},
	}
}

// brainAccess is which rooms a person's Aseman may read: the person's
// choices (a JSON object of space id → true or false); a room they made no
// choice for is readable when they own it. One row per person (id = account id).
func brainAccess() database.Model {
	return database.Model{
		Name:  "brain_access",
		Table: "brain_access",
		Fields: []database.Field{
			f("id", database.KindString), f("rooms", database.KindString),
			f("updated_at", database.KindTime),
		},
	}
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

// directReactions are the emoji people put on a direct message: one row per
// person per message (id = message:user), so a new emoji replaces the old.
func directReactions() database.Model {
	return database.Model{
		Name:  "direct_reactions",
		Table: "direct_reactions",
		Fields: []database.Field{
			f("id", database.KindString), f("message_id", database.KindString),
			f("user_id", database.KindString), f("emoji", database.KindString),
			f("created_at", database.KindTime),
		},
	}
}

// directAttachments are the files sent in direct messages: who uploaded each
// (whose storage it counts against), for whom, and the message it went with
// (empty until the message is sent). It is also what lets the other person
// open the file.
func directAttachments() database.Model {
	return database.Model{
		Name:  "direct_attachments",
		Table: "direct_attachments",
		Fields: []database.Field{
			f("id", database.KindString), f("owner_id", database.KindString),
			f("peer_id", database.KindString), f("message_id", database.KindString),
			f("name", database.KindString), f("mime", database.KindString),
			f("size", database.KindInt64), f("voice", database.KindBool),
			f("duration_ms", database.KindInt64), f("waveform", database.KindString),
			f("created_at", database.KindTime),
		},
	}
}

// keptFiles are files a person chose to keep from a chat. The person has a
// file record of their own (it counts against their storage) that uses the same
// stored bytes as the sender's, so deleting the original leaves the kept one.
func keptFiles() database.Model {
	return database.Model{
		Name:  "kept_files",
		Table: "kept_files",
		Fields: []database.Field{
			f("id", database.KindString), f("owner_id", database.KindString),
			f("from_id", database.KindString), f("source_id", database.KindString),
			f("message_id", database.KindString), f("name", database.KindString),
			f("mime", database.KindString), f("size", database.KindInt64),
			f("created_at", database.KindTime),
		},
	}
}

// notificationPrefs are what a person has turned off: kinds of notification
// (rooms, chats, calls, invites), and the rooms and chats they muted. One row
// per person, its id the person's account id.
func notificationPrefs() database.Model {
	return database.Model{
		Name:  "notification_prefs",
		Table: "notification_prefs",
		Fields: []database.Field{
			f("id", database.KindString), f("disabled", database.KindString),
			f("muted_spaces", database.KindString), f("muted_peers", database.KindString),
			f("updated_at", database.KindTime),
		},
	}
}

// privacyPrefs are who may reach a person: send them a message, ring them with
// a voice or a video call, or invite them to a room. One row per person (id = account id).
func privacyPrefs() database.Model {
	return database.Model{
		Name:  "privacy_prefs",
		Table: "privacy_prefs",
		Fields: []database.Field{
			f("id", database.KindString), f("calls_voice", database.KindString),
			f("calls_video", database.KindString), f("invites", database.KindString),
			f("messages", database.KindString),
			f("updated_at", database.KindTime),
		},
	}
}

// directCalls are voice and video calls between two people.
func directCalls() database.Model {
	return database.Model{
		Name:  "direct_calls",
		Table: "direct_calls",
		Fields: []database.Field{
			f("id", database.KindString), f("caller_id", database.KindString),
			f("callee_id", database.KindString), f("video", database.KindBool),
			f("state", database.KindString), f("end_reason", database.KindString),
			f("created_at", database.KindTime), f("answered_at", database.KindTime),
			f("ended_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}

// callSignals are the setup messages two phones swap to connect a call.
func callSignals() database.Model {
	return database.Model{
		Name:  "call_signals",
		Table: "call_signals",
		Fields: []database.Field{
			f("id", database.KindString), f("call_id", database.KindString),
			f("from_id", database.KindString), f("kind", database.KindString),
			f("payload", database.KindString), f("created_at", database.KindTime),
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
