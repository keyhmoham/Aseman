package users

import (
	"encoding/json"
	"testing"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

func TestAdminAccountUpdateRenamesHandles(t *testing.T) {
	for _, role := range []string{"admin", "user"} {
		t.Run(role, func(t *testing.T) {
			s, ctx := followHarness(t)
			s.K = kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"admin_handle": "node-admin"}})
			admin, err := s.GetAccount(ctx, "alice")
			if err != nil {
				t.Fatal(err)
			}
			admin.Handle, admin.Role = "node-admin", role
			if err := s.R.Update(ctx, "accounts", admin.ID, admin); err != nil {
				t.Fatal(err)
			}
			caller := api.Caller{ID: admin.ID, Kind: "user"}
			update := func(target, handle string) error {
				body, _ := json.Marshal(map[string]any{"account": target, "handle": handle})
				_, err := s.accountUpdate(ctx, &api.ActionRequest{Caller: caller, Body: body})
				return err
			}
			for _, tc := range []struct {
				handle string
				code   errs.Code
			}{
				{"bob", errs.CodeAlreadyExists},
				{"bad handle", errs.CodeInvalidArgument},
			} {
				if err := update(admin.ID.String(), tc.handle); errs.CodeOf(err) != tc.code {
					t.Fatalf("handle %q: got %v, want %s", tc.handle, err, tc.code)
				}
				if _, err := s.GetAccount(ctx, "node-admin"); err != nil {
					t.Fatal("failed updates must preserve the current handle")
				}
			}
			if err := update(admin.ID.String(), " @New.Admin "); err != nil {
				t.Fatalf("rename administrator: %v", err)
			}
			renamed, err := s.GetAccount(ctx, "new.admin")
			if err != nil || renamed.ID != admin.ID || renamed.Role != "admin" {
				t.Fatalf("renamed administrator must preserve identity and role: %v", err)
			}
			req := &api.ActionRequest{Caller: caller}
			if err := helper.RequireNodeAdmin(ctx, s.R, req, "node-admin"); err != nil {
				t.Fatalf("administrator access after rename: %v", err)
			}
			if _, err := s.accountsList(ctx, req); err != nil {
				t.Fatalf("administrator directory after rename: %v", err)
			}
			bob, err := s.GetAccount(ctx, "bob")
			if err != nil {
				t.Fatal(err)
			}
			if err := update(bob.ID.String(), "bob-new"); err != nil {
				t.Fatalf("administrator must still rename other users: %v", err)
			}
			if renamedBob, err := s.GetAccount(ctx, "bob-new"); err != nil || renamedBob.Role == "admin" {
				t.Fatalf("renaming another user must not grant admin access: %v", err)
			}
			if err := update(bob.ID.String(), "node-admin"); errs.CodeOf(err) != errs.CodeAlreadyExists {
				t.Fatalf("old bootstrap handle must remain reserved: %v", err)
			}
			if err := update(admin.ID.String(), "node-admin"); err != nil {
				t.Fatalf("administrator can restore original handle: %v", err)
			}
			if err := update(admin.ID.String(), "new.admin"); err != nil {
				t.Fatalf("administrator can rename again: %v", err)
			}
			body, _ := json.Marshal(map[string]any{"account": admin.ID.String(), "handle": "takeover"})
			if _, err := s.accountUpdate(ctx, &api.ActionRequest{Caller: api.Caller{ID: bob.ID, Kind: "user"}, Body: body}); errs.CodeOf(err) != errs.CodePermission {
				t.Fatalf("ordinary users must not use admin account updates: %v", err)
			}
			for _, patch := range []map[string]any{{"role": "user"}, {"status": "disabled"}} {
				patch["account"] = admin.ID.String()
				body, _ := json.Marshal(patch)
				if _, err := s.accountUpdate(ctx, &api.ActionRequest{Caller: caller, Body: body}); errs.CodeOf(err) != errs.CodePermission {
					t.Fatalf("renamed administrator must retain self-protection: %v", err)
				}
			}
		})
	}
}
