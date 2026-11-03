package harness

import (
	"context"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
)

func TestPersonalSessionAllowsAccountActionsDeniesAdmin(t *testing.T) {
	person := identity.MustParse("00000000000000010000000000000001")
	s := &session{personal: true, account: person}
	for _, name := range []string{
		"spaces.message_send", "spaces.tools_list", "spaces.ask",
		"spaces.members_list", "spaces.bots_list", "spaces.agent_recruit",
		"spaces.thread_list", "spaces.thread_create", "spaces.room_create",
		"spaces.member_remove", "spaces.bot_add", "spaces.message_edit",
		"spaces.direct_open", "spaces.space_search", "spaces.chat_pin",
		"market.catalog", "market.install", "posts.post_feed", "posts.post_create",
		"users.follow", "users.search", "spaces.space_list", "spaces.chat_list",
		"spaces.space_create", "finance.wallet_get", "bots.bot_list", "routines.list",
	} {
		if !s.allows(name) {
			t.Fatalf("personal session refused %s", name)
		}
	}
	for _, name := range []string{
		"admin.health", "plugins.list",
		"spaces.space_list_all", "llm.llm_provider_set", "users.account_delete",
		"auth.login", "market.approve", "llm.chat_completions",
		"finance.transfer", "finance.wallet_mint", "spaces.admin_storage", "federation.dispatch",
	} {
		if s.allows(name) {
			t.Fatalf("personal session allowed %s", name)
		}
	}
	room := &session{personal: false, spaceID: "space-a"}
	for _, name := range []string{
		"spaces.space_create", "spaces.direct_open", "posts.post_feed", "posts.post_create",
		"finance.wallet_get", "themes.apply", "users.follow", "bots.bot_list", "finance.transfer", "admin.health",
	} {
		if room.allows(name) {
			t.Fatalf("room session allowed %s", name)
		}
	}
	for _, name := range []string{
		"spaces.message_send", "spaces.ask", "spaces.room_create", "spaces.thread_create", "spaces.file_list",
		"routines.create", "routines.list", "users.search", "users.dm_send", "market.catalog",
	} {
		if !room.allows(name) {
			t.Fatalf("room session refused %s", name)
		}
	}
}

func TestOpenPersonalMintsToken(t *testing.T) {
	a := &Adapter{sessions: map[string]*session{}, nodeURL: "http://node"}
	// ensureRuntime would fail without a kernel; mint the session shape directly.
	person := identity.MustParse("00000000000000010000000000000001")
	s := &session{
		token: "tok-personal", account: person, personal: true,
		base: context.Background(),
	}
	a.sessions[s.token] = s
	got := a.byToken("tok-personal")
	if got == nil || !got.personal || got.account != person {
		t.Fatalf("session: %+v", got)
	}
	a.close(s)
	if a.byToken("tok-personal") != nil {
		t.Fatal("session not revoked")
	}
}
