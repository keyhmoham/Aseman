package spaces

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
)

// members_list keeps listing agents by default (agents read their team from
// it) and leaves them out only when asked for people.
func TestMembersListKindFilter(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := mustID(t, "00000000000000010000000000000001")
	agent := mustID(t, "00000000000000010000000000000002")
	for _, acc := range []*account.Account{
		{Entity: entity.Entity{ID: owner}, Handle: "alice", Kind: account.KindUser, Status: account.StatusActive},
		{Entity: entity.Entity{ID: agent}, Handle: "helper", Kind: account.KindBot, Status: account.StatusActive},
	} {
		if err := s.R.CreateID(ctx, "accounts", acc.ID, acc); err != nil {
			t.Fatal(err)
		}
	}
	sp, err := s.CreateSpace(ctx, owner, "Team", "desc")
	if err != nil {
		t.Fatal(err)
	}
	id := mustID(t, "00000000000000010000000000000003")
	now := time.Now().UTC().Add(time.Second)
	if err := s.R.CreateID(ctx, "memberships", id, &membership.Membership{
		Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, SpaceID: sp.ID, MemberID: agent, Role: membership.RoleBot, JoinedAt: now,
	}); err != nil {
		t.Fatal(err)
	}
	list := func(body string) []string {
		t.Helper()
		resp, err := (&membersListAction{s: s}).Handle(ctx, &api.ActionRequest{Caller: api.Caller{ID: owner, Kind: "user"}, Body: []byte(body)})
		if err != nil {
			t.Fatal(err)
		}
		var out struct {
			Members []struct {
				Handle string `json:"handle"`
			} `json:"members"`
		}
		if err := json.Unmarshal(resp.Body, &out); err != nil {
			t.Fatal(err)
		}
		var handles []string
		for _, m := range out.Members {
			handles = append(handles, m.Handle)
		}
		return handles
	}
	sid := sp.ID.String()
	// A new space also gets the built-in tradera agent.
	if got := list(`{"space":"` + sid + `"}`); len(got) != 3 {
		t.Fatalf("all members = %v, want the person and both agents", got)
	}
	if got := list(`{"space":"` + sid + `","kind":"user"}`); len(got) != 1 || got[0] != "alice" {
		t.Fatalf("people = %v, want only alice", got)
	}
	// Paging applies after the filter: the agent is newest, yet page one of
	// people is not empty.
	if got := list(`{"space":"` + sid + `","kind":"user","limit":1}`); len(got) != 1 || got[0] != "alice" {
		t.Fatalf("first page of people = %v, want alice", got)
	}
	if got := list(`{"space":"` + sid + `","kind":"bot"}`); len(got) != 2 || got[0] != "helper" {
		t.Fatalf("bots = %v, want helper and tradera", got)
	}
}
