package harness

import (
	"context"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
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

// With its tools, the personal Aseman works on the person's own computer
// (their home workspace's): the runtime is told which.
func TestPersonalChatWorksOnThePersonsOwnComputer(t *testing.T) {
	a, rt, _ := newTestAdapter(t)
	person := mustID(t)
	a.platform = fakePlatform{homes: map[string]string{person: "home-1"}}
	chat := vmm.PersonalChat{PersonID: person, WithTools: true, Messages: []vmm.ChatMessage{{Role: "user", Content: "build it"}}}
	if _, err := a.PersonalChat(context.Background(), chat); err != nil {
		t.Fatal(err)
	}
	if got := rt.chats[0]["computer_space"]; got != "home-1" {
		t.Fatalf("computer_space = %v", got)
	}
	chat.WithTools = false
	if _, err := a.PersonalChat(context.Background(), chat); err != nil {
		t.Fatal(err)
	}
	if got := rt.chats[1]["computer_space"]; got != "" {
		t.Fatalf("a chat without tools got a computer: %v", got)
	}
}

// The personal Aseman's work on the person's computer is decided by that
// workspace's rules (approvals are asked there); anything else by the node's.
func TestPersonalWorkOnTheComputerIsGovernedByItsWorkspace(t *testing.T) {
	s := &session{personal: true, computer: "home-1"}
	if sp, room := s.governedSpace([]byte(`{"space":"home-1","bot":"sandbox","body":"ls"}`)); sp != "home-1" || room != "" {
		t.Fatalf("computer work governed by %q/%q", sp, room)
	}
	if sp, _ := s.governedSpace([]byte(`{"space":"team-9","body":"hi"}`)); sp != "" {
		t.Fatalf("work elsewhere took the rules of %q", sp)
	}
	room := &session{spaceID: "space-1", roomID: "room-1", computer: "home-1"}
	if sp, r := room.governedSpace([]byte(`{"space":"home-1"}`)); sp != "space-1" || r != "room-1" {
		t.Fatalf("a room agent governed by %q/%q", sp, r)
	}
	if s.agentName() != "Aseman" {
		t.Fatalf("approvals name %q", s.agentName())
	}
}
