package spaces

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// Only the admins space, and only for an active platform administrator.
func TestDBAccessNeedsTheAdminsSpaceAndAnAdministrator(t *testing.T) {
	s, ctx := profileHarness(t)
	admin := addAccount(t, s, ctx, "00000000000000010000000000000001", "boss", "admin", account.StatusActive)
	user := addAccount(t, s, ctx, "00000000000000010000000000000002", "plain", "user", account.StatusActive)
	gone := addAccount(t, s, ctx, "00000000000000010000000000000003", "gone", "admin", account.StatusDisabled)
	adminsSpace := mustID(t, "00000000000000010000000000000010")
	other := mustID(t, "00000000000000010000000000000011")
	cases := []struct {
		name                 string
		admins, space, actor identity.ID
		allowed              bool
	}{
		{"admin in the admins space", adminsSpace, adminsSpace, admin, true},
		{"no admins space chosen", identity.ID{}, adminsSpace, admin, false},
		{"another project", adminsSpace, other, admin, false},
		{"work for a non-admin", adminsSpace, adminsSpace, user, false},
		{"work for a disabled admin", adminsSpace, adminsSpace, gone, false},
		{"work for nobody", adminsSpace, adminsSpace, identity.ID{}, false},
	}
	for _, c := range cases {
		err := s.checkDBAccess(ctx, c.admins, c.space, c.actor)
		if (err == nil) != c.allowed {
			t.Errorf("%s: err = %v; allowed want %v", c.name, err, c.allowed)
		}
		if err != nil && errs.CodeOf(err) != errs.CodePermission {
			t.Errorf("%s: err = %v; want permission denied", c.name, err)
		}
	}
}

// The person a tool call is made for is the run's actor, not the agent.
func TestActorOfPrefersTheExecutionActor(t *testing.T) {
	person := mustID(t, "00000000000000010000000000000001")
	ctx := vmm.WithExecution(context.Background(), vmm.Execution{ActorID: person.String()})
	if got := actorOf(ctx); got != person {
		t.Fatalf("actorOf = %s; want %s", got, person)
	}
	if got := actorOf(vmm.WithExecution(context.Background(), vmm.Execution{ActorID: "not-an-id"})); !got.IsZero() {
		t.Fatalf("actorOf with a bad actor = %s; want none", got)
	}
}

func TestDBReadIsRedactedPagedAndChecked(t *testing.T) {
	s, ctx := profileHarness(t)
	for i, h := range []string{"ada", "bob", "cyd"} {
		role := "user"
		if i == 0 {
			role = "admin"
		}
		a := addAccount(t, s, ctx, "0000000000000001000000000000000"+string(rune('1'+i)), h, role, account.StatusActive)
		var acc account.Account
		if err := s.R.Get(ctx, "accounts", a, &acc); err != nil {
			t.Fatal(err)
		}
		acc.PasswordHash = "$2a$10$private-hash"
		acc.PrivateKeyEnc = "private-key"
		if err := s.R.Update(ctx, "accounts", a, &acc); err != nil {
			t.Fatal(err)
		}
	}

	tables, err := s.dbTables("")
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(tables)
	if !strings.Contains(string(raw), `"name":"accounts"`) || !strings.Contains(string(raw), `"name":"memberships"`) {
		t.Fatalf("tables do not list the models: %.300s", raw)
	}
	if _, err := s.dbTables("nope"); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("unknown table = %v; want not found", err)
	}

	page, err := s.dbRead(ctx, dbReadInput{Model: "accounts", OrderBy: "handle", Asc: true, Limit: 2})
	if err != nil {
		t.Fatal(err)
	}
	raw, _ = json.Marshal(page)
	if strings.Contains(string(raw), "private-") {
		t.Fatalf("credentials leaked: %s", raw)
	}
	if page["total"] != int64(3) || page["count"] != 2 || page["has_more"] != true {
		t.Fatalf("page = total %v count %v has_more %v; want 3, 2, true", page["total"], page["count"], page["has_more"])
	}
	if !strings.Contains(string(raw), `"ada"`) || strings.Contains(string(raw), `"cyd"`) {
		t.Fatalf("first page by handle should hold ada and bob: %s", raw)
	}

	admins, err := s.dbRead(ctx, dbReadInput{Model: "accounts", Equal: map[string]any{"role": "admin"}})
	if err != nil || admins["total"] != int64(1) {
		t.Fatalf("filter on role = %v, %v; want one admin", admins["total"], err)
	}
	one, err := s.dbRead(ctx, dbReadInput{Model: "accounts", ID: "00000000000000010000000000000002"})
	if err != nil {
		t.Fatal(err)
	}
	if raw, _ = json.Marshal(one); strings.Contains(string(raw), "private-") || !strings.Contains(string(raw), `"bob"`) {
		t.Fatalf("record by id = %s", raw)
	}

	for name, in := range map[string]dbReadInput{
		"unknown table":          {Model: "nope"},
		"unknown field":          {Model: "accounts", Equal: map[string]any{"nope": 1}},
		"filter on a credential": {Model: "accounts", Equal: map[string]any{"password_hash": "x"}},
		"sort on a credential":   {Model: "accounts", OrderBy: "private_key_enc"},
	} {
		if _, err := s.dbRead(ctx, in); err == nil {
			t.Errorf("%s: read succeeded; want refused", name)
		}
	}
}
