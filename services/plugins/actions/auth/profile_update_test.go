package auth

import (
	"encoding/json"
	"testing"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

func TestProfileUpdateRenamesNodeAdministrator(t *testing.T) {
	for _, role := range []string{"admin", "user"} {
		t.Run(role, func(t *testing.T) {
			s, _, ctx := recoveryHarness(t)
			s.K = kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{
				"admin_handle": "node-admin", "admin_password": "admin-password",
			}})
			original, token, privateKey, err := s.Register(ctx, "node-admin", "admin@localhost", "admin-password")
			if err != nil {
				t.Fatal(err)
			}
			original.Role = role // Include legacy administrators authorized by handle.
			if err := s.R.Update(ctx, "accounts", original.ID, original); err != nil {
				t.Fatal(err)
			}
			caller := api.Caller{ID: original.ID, Kind: "user"}
			req := &api.ActionRequest{Caller: caller, Body: []byte(`{"handle":" @New.Admin "}`)}
			resp, err := s.profileUpdate(ctx, req)
			if err != nil {
				t.Fatalf("rename administrator: %v", err)
			}
			var view map[string]any
			if err := json.Unmarshal(resp.Body, &view); err != nil {
				t.Fatal(err)
			}
			if view["handle"] != "new.admin" || view["is_admin"] != true {
				t.Fatalf("unexpected profile: %+v", view)
			}
			renamed, err := s.Account(ctx, "new.admin")
			if err != nil {
				t.Fatal(err)
			}
			if renamed.ID != original.ID || renamed.Role != "admin" ||
				renamed.PublicKey != original.PublicKey || renamed.PrivateKeyEnc != original.PrivateKeyEnc ||
				renamed.PasswordHash != original.PasswordHash || renamed.Email != original.Email {
				t.Fatal("rename must preserve the administrator identity and credentials")
			}
			if err := helper.RequireNodeAdmin(ctx, s.R, req, "node-admin"); err != nil {
				t.Fatalf("administrator access after rename: %v", err)
			}
			if _, err := s.Authenticate(ctx, token); err != nil {
				t.Fatalf("existing session after rename: %v", err)
			}
			if _, _, key, err := s.Login(ctx, "new.admin", "admin-password"); err != nil || key != privateKey {
				t.Fatalf("login with new handle must retain identity: %v", err)
			}
			if _, _, _, err := s.Login(ctx, "node-admin", "admin-password"); err == nil {
				t.Fatal("old handle must stop resolving")
			}
			if err := s.Bootstrap(ctx); err != nil {
				t.Fatal(err)
			}
			if _, err := s.Account(ctx, "node-admin"); err == nil {
				t.Fatal("bootstrap must not recreate the renamed administrator")
			}
			if _, _, _, err := s.Register(ctx, "node-admin", "takeover@example.com", "other-password"); errs.CodeOf(err) != errs.CodeAlreadyExists {
				t.Fatalf("old bootstrap handle must remain reserved: %v", err)
			}
			ordinary, _, _, err := s.Register(ctx, "ordinary", "ordinary@example.com", "other-password")
			if err != nil {
				t.Fatal(err)
			}
			if _, err := s.profileUpdate(ctx, &api.ActionRequest{Caller: api.Caller{ID: ordinary.ID, Kind: "user"}, Body: []byte(`{"handle":"node-admin"}`)}); errs.CodeOf(err) != errs.CodeAlreadyExists {
				t.Fatalf("ordinary user must not claim the freed bootstrap handle: %v", err)
			}
			// The administrator can still switch back to the original handle.
			if _, err := s.profileUpdate(ctx, &api.ActionRequest{Caller: caller, Body: []byte(`{"handle":"node-admin"}`)}); err != nil {
				t.Fatalf("administrator can restore original handle: %v", err)
			}
			if _, err := s.profileUpdate(ctx, req); err != nil {
				t.Fatalf("administrator can rename again: %v", err)
			}
			if _, err := s.accountDelete(ctx, &api.ActionRequest{Caller: caller, Body: []byte(`{"confirmation":"DELETE"}`)}); errs.CodeOf(err) != errs.CodePermission {
				t.Fatalf("renamed administrator must retain deletion protection: %v", err)
			}
		})
	}
}

func TestProfileHandleUpdateValidationAndOwnership(t *testing.T) {
	s, _, ctx := recoveryHarness(t)
	s.K = kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"admin_handle": "node-admin"}})
	admin, _, _, err := s.Register(ctx, "node-admin", "admin@localhost", "admin-password")
	if err != nil {
		t.Fatal(err)
	}
	alice, _, _, err := s.Register(ctx, "alice", "alice@example.com", "alice-password")
	if err != nil {
		t.Fatal(err)
	}
	caller := api.Caller{ID: alice.ID, Kind: "user"}
	for _, tc := range []struct {
		handle string
		code   errs.Code
	}{
		{"node-admin", errs.CodeAlreadyExists},
		{"bad handle", errs.CodeInvalidArgument},
		{"", errs.CodeInvalidArgument},
	} {
		body, _ := json.Marshal(map[string]any{"handle": tc.handle})
		if _, err := s.profileUpdate(ctx, &api.ActionRequest{Caller: caller, Body: body}); errs.CodeOf(err) != tc.code {
			t.Fatalf("handle %q: got %v, want %s", tc.handle, err, tc.code)
		}
	}
	// A target supplied by the client never changes which account is updated.
	body, _ := json.Marshal(map[string]any{"account": admin.ID.String(), "handle": "alice-new", "profile": map[string]any{"role": "admin", "isAdmin": true}})
	if _, err := s.profileUpdate(ctx, &api.ActionRequest{Caller: caller, Body: body}); err != nil {
		t.Fatal(err)
	}
	var fresh account.Account
	if err := s.R.Get(ctx, "accounts", alice.ID, &fresh); err != nil {
		t.Fatal(err)
	}
	if fresh.Handle != "alice-new" || fresh.Role != "user" {
		t.Fatalf("ordinary user may only rename themselves without gaining privileges: %+v", fresh)
	}
	if unchanged, err := s.Account(ctx, "node-admin"); err != nil || unchanged.ID != admin.ID {
		t.Fatalf("another user's administrator account must be unchanged: %v", err)
	}
}
