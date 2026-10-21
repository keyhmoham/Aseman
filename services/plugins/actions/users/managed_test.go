package users

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/auth"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

type adminsSpaceStub struct{ id string }

func (s adminsSpaceStub) AdminsSpace(context.Context) (string, error) { return s.id, nil }

type provider struct{ service any }

func (p provider) Acquire(context.Context) (any, func(), error) { return p.service, func() {}, nil }

// managedKernel serves the auth and settings namespaces over the bridge.
type managedKernel struct {
	api.Kernel
	services map[string]any
}

func (k managedKernel) Env() map[string]string { return map[string]string{"admin_handle": "node-a"} }

func (k managedKernel) Resolve(name string) (any, error) {
	if s, ok := k.services[name]; ok {
		return provider{s}, nil
	}
	return k.Kernel.Resolve(name)
}

func TestManagedAccounts(t *testing.T) {
	s, ctx := followHarness(t) // alice (…01), bob (…02): active users
	base := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()})
	admins, other := "00000000000000010000000000000010", "00000000000000010000000000000011"
	k := managedKernel{Kernel: base, services: map[string]any{"service/settings": adminsSpaceStub{admins}}}
	authService := &auth.Service{K: k, R: s.R, L: logger.Global()}
	k.services["service/auth"] = authService
	s.K = k
	s.M.K = k

	alice, _ := s.GetAccount(ctx, "alice")
	alice.Role = "admin"
	if err := s.R.Update(ctx, "accounts", alice.ID, alice); err != nil {
		t.Fatal(err)
	}
	bob, _ := s.GetAccount(ctx, "bob")

	// The importer: a tool bot and its account.
	now := time.Now().UTC()
	toolAccount := mustID(t, "00000000000000010000000000000301")
	importer := &bot.Bot{Entity: entity.Entity{ID: mustID(t, "00000000000000010000000000000201"), CreatedAt: now, UpdatedAt: now},
		AccountID: toolAccount, Name: "importer", Kind: bot.KindTool}
	if err := s.R.CreateID(ctx, "bots", importer.ID, importer); err != nil {
		t.Fatal(err)
	}

	asTool := func(space string, actor identity.ID) (context.Context, api.Caller) {
		return vmm.WithExecution(ctx, vmm.Execution{ActorID: actor.String(), SpaceID: space, AgentID: importer.ID.String()}),
			api.Caller{ID: toolAccount, Kind: "bot"}
	}
	create := func(ctx context.Context, caller api.Caller, handle string) (map[string]any, error) {
		body, _ := json.Marshal(map[string]any{"handle": handle, "password": "s3cret-pass", "display_name": "Daniel Markson"})
		resp, err := s.accountCreate(ctx, &api.ActionRequest{Caller: caller, Body: body})
		if err != nil {
			return nil, err
		}
		var out map[string]any
		_ = json.Unmarshal(resp.Body, &out)
		return out, nil
	}
	remove := func(ctx context.Context, caller api.Caller, id string) error {
		body, _ := json.Marshal(map[string]any{"account": id})
		_, err := s.accountDelete(ctx, &api.ActionRequest{Caller: caller, Body: body})
		return err
	}

	// Refused: a plain user, a tool outside the admins space, a tool working for a non-admin.
	if _, err := create(ctx, api.Caller{ID: bob.ID, Kind: "user"}, "x_trader"); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a user created an account: %v", err)
	}
	octx, otool := asTool(other, alice.ID)
	if _, err := create(octx, otool, "x_trader"); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a tool outside the admins space created an account: %v", err)
	}
	bctx, btool := asTool(admins, bob.ID)
	if _, err := create(bctx, btool, "x_trader"); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a tool working for a non-admin created an account: %v", err)
	}

	// The importer in the admins space, for an admin.
	tctx, tool := asTool(admins, alice.ID)
	made, err := create(tctx, tool, "Daniel_Crypto365")
	if err != nil {
		t.Fatal(err)
	}
	if made["handle"] != "daniel_crypto365" || made["managed_by"] != importer.ID.String() {
		t.Fatalf("made %v", made)
	}
	acc, err := s.GetAccount(ctx, "daniel_crypto365")
	if err != nil {
		t.Fatal(err)
	}
	if acc.Status != account.StatusActive || !acc.EmailVerified || acc.Role != "user" || acc.Email != "daniel_crypto365@managed.tradera.invalid" {
		t.Fatalf("account %+v", acc)
	}
	// It signs in with its password, without verifying an email.
	if _, _, _, err := authService.Login(ctx, "daniel_crypto365", "s3cret-pass"); err != nil {
		t.Fatalf("login: %v", err)
	}
	if m, _ := s.M.Get(ctx, acc.ID); m.Tree["profile"].(map[string]any)["firstName"] != "Daniel" {
		t.Fatalf("profile %v", m.Tree["profile"])
	}
	if _, err := create(tctx, tool, "daniel_crypto365"); errs.CodeOf(err) != errs.CodeAlreadyExists {
		t.Fatalf("a taken username: %v", err)
	}
	if _, err := create(tctx, tool, "node-a"); errs.CodeOf(err) != errs.CodeAlreadyExists {
		t.Fatalf("the administrator handle: %v", err)
	}

	// The tool deletes the accounts it made, and no others.
	if err := remove(tctx, tool, bob.ID.String()); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("the tool deleted someone else's account: %v", err)
	}
	if err := remove(tctx, tool, acc.ID.String()); err != nil {
		t.Fatalf("the tool could not delete its own account: %v", err)
	}
	if _, err := s.GetAccount(ctx, "daniel_crypto365"); err == nil {
		t.Fatal("the account is still there")
	}

	// An administrator creates one directly too.
	if _, err := create(ctx, api.Caller{ID: alice.ID, Kind: "user"}, "vlad_anderson"); err != nil {
		t.Fatalf("admin create: %v", err)
	}
}
