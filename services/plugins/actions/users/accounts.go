package users

import (
	"context"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

func accountActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "users", Name: "accounts_list", Summary: "Admin account directory", Handler: s.accountsList},
		helper.Action{Namespace: "users", Name: "account_update", Summary: "Admin account status/profile management", Handler: s.accountUpdate},
		helper.Action{Namespace: "users", Name: "account_password", Summary: "Admin password recovery preserving identity", Handler: s.accountPassword},
		helper.Action{Namespace: "users", Name: "account_delete", Summary: "Admin account deletion", Handler: s.accountDelete},
		helper.Action{Namespace: "users", Name: "account_create", Summary: "Admin: create an active user account for someone (also the admins space's tools, for an administrator)", Handler: s.accountCreate},
		helper.Action{Namespace: "users", Name: "hireable_list", Summary: "Approved people available for hire", Handler: s.hireableList},
	}
}
func (s *Service) directory(ctx context.Context, admin, hireable bool) ([]map[string]any, error) {
	var rows []account.Account
	if e := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"kind": "user"}, OrderBy: "created_at", Asc: false}, &rows); e != nil {
		return nil, e
	}
	balances := map[string]int64{}
	if admin {
		var wallets []struct {
			OwnerID identity.ID `db:"owner_id"`
			Balance int64       `db:"balance"`
		}
		if e := s.R.List(ctx, "wallets", database.Filter{}, &wallets); e == nil {
			for _, w := range wallets {
				balances[w.OwnerID.String()] = w.Balance
			}
		}
	}
	out := []map[string]any{}
	for _, a := range rows {
		profile := map[string]any{}
		var authTree map[string]any
		if m, e := s.M.View(ctx, a.ID, a.ID); e == nil {
			profile, _ = m.Tree["profile"].(map[string]any)
			authTree, _ = m.Tree["auth"].(map[string]any)
		}
		if hireable && (a.Status != account.StatusActive || profile["hireable"] != true || profile["marketStatus"] != "approved") {
			continue
		}
		row := map[string]any{"id": a.ID.String(), "handle": a.Handle, "status": a.Status, "role": a.Role, "profile": profile, "is_admin": a.Role == "admin" || a.Handle == s.K.Env()["admin_handle"], "created_at": a.CreatedAt}
		if !a.LastSeen.IsZero() {
			row["last_seen"] = a.LastSeen
		}
		if admin {
			row["email"] = a.Email
			row["email_verified"] = a.EmailVerified
			row["balance"] = balances[a.ID.String()]

			hasPassword := a.PasswordHash != ""
			var oauthProviders []string
			if authTree != nil {
				// A provider-only account holds a derived hash, not a password of its own;
				// only the link's password flag says the owner set one (see auth.accountView).
				if prov, _ := authTree["provider"].(string); prov != "" {
					hp, _ := authTree["password"].(bool)
					hasPassword = hp
				}
				if primaryProvider, ok := authTree["provider"].(string); ok && primaryProvider != "" {
					oauthProviders = append(oauthProviders, primaryProvider)
				}
				if providersMap, ok := authTree["providers"].(map[string]any); ok {
					for p := range providersMap {
						p = strings.TrimSpace(p)
						if p == "" {
							continue
						}
						found := false
						for _, existing := range oauthProviders {
							if strings.EqualFold(existing, p) {
								found = true
								break
							}
						}
						if !found {
							oauthProviders = append(oauthProviders, p)
						}
					}
				}
			}
			row["has_password"] = hasPassword
			row["oauth_providers"] = oauthProviders
		}
		out = append(out, row)
	}
	return out, nil
}
func (s *Service) accountsList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	rows, e := s.directory(ctx, true, false)
	if e != nil {
		return nil, e
	}
	return helper.JSON(map[string]any{"accounts": rows})
}
func (s *Service) hireableList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	rows, e := s.directory(ctx, false, true)
	if e != nil {
		return nil, e
	}
	return helper.JSON(map[string]any{"accounts": rows})
}
func (s *Service) accountUpdate(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var in struct {
		Account string         `json:"account"`
		Handle  string         `json:"handle"`
		Email   string         `json:"email"`
		Status  string         `json:"status"`
		Role    string         `json:"role"`
		Profile map[string]any `json:"profile"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	id, e := identity.Parse(in.Account)
	if e != nil {
		return nil, e
	}
	a, e := s.GetAccount(ctx, in.Account)
	if e != nil {
		return nil, e
	}
	if in.Role != "" {
		if in.Role != "admin" && in.Role != "user" {
			return nil, errs.InvalidArgument("role must be admin or user")
		}
		if a.ID == req.Caller.ID && in.Role != "admin" {
			return nil, errs.Permission("cannot remove your own administrator role")
		}
		a.Role = in.Role
		if in.Role == "admin" {
			a.EmailVerified = true
			if a.Status == account.StatusPending {
				a.Status = account.StatusActive
			}
		}
	}
	if in.Status != "" {
		if in.Status != "active" && in.Status != "disabled" {
			return nil, errs.InvalidArgument("status must be active or disabled")
		}
		if a.ID == req.Caller.ID || a.Handle == s.K.Env()["admin_handle"] {
			return nil, errs.Permission("cannot disable the active node administrator")
		}
		a.Status = account.Status(in.Status)
	}
	if in.Handle != "" && in.Handle != a.Handle {
		handle, e := helper.NormalizeHandle(in.Handle)
		if e != nil {
			return nil, e
		}
		var taken []account.Account
		if e = s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"handle": handle}}, &taken); e != nil {
			return nil, e
		}
		for _, other := range taken {
			if other.ID != a.ID {
				return nil, errs.AlreadyExists("handle " + handle)
			}
		}
		if handle == s.K.Env()["admin_handle"] && handle != a.Handle && a.Role != "admin" {
			return nil, errs.AlreadyExists("bootstrap administrator handle is reserved")
		}
		if a.Handle == s.K.Env()["admin_handle"] {
			// Preserve handle-based administrator access on legacy accounts.
			a.Role = "admin"
		}
		a.Handle = handle
	}
	if in.Email != "" && in.Email != a.Email {
		email := strings.TrimSpace(in.Email)
		if !strings.Contains(email, "@") || strings.ContainsAny(email, " \t\r\n") {
			return nil, errs.InvalidArgument("invalid email")
		}
		var taken []account.Account
		if e = s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"email": email}}, &taken); e != nil {
			return nil, e
		}
		for _, other := range taken {
			if other.ID != a.ID {
				return nil, errs.AlreadyExists("email " + email)
			}
		}
		a.Email = email
	}
	a.UpdatedAt = time.Now().UTC()
	if e = s.R.Update(ctx, "accounts", id, a); e != nil {
		return nil, e
	}
	if (in.Role != "" || in.Status != "") && a.Role == "admin" && a.Status == account.StatusActive {
		// Platform administrators are kept members of the admins space.
		var added int
		if e := bridge.Invoke(ctx, s.K, "spaces", "SyncAdminsSpace", []any{ctx}, &added); e != nil && s.L != nil {
			s.L.Warn("add administrator to the admins space", "account", a.ID.String(), "error", e)
		}
	}
	if in.Profile != nil {
		m, e := s.M.Get(ctx, id)
		if e != nil {
			return nil, e
		}
		profile, _ := m.Tree["profile"].(map[string]any)
		if profile == nil {
			profile = map[string]any{}
		}
		for k, v := range in.Profile {
			switch k {
			case "password", "privateKey", "token", "currentPassword", "newPassword":
				continue
			}
			profile[k] = v
		}
		m.Tree["profile"] = profile
		if e = s.M.ReplaceTree(ctx, id, m.Tree); e != nil {
			return nil, e
		}
	}
	return helper.JSON(map[string]any{"id": a.ID.String(), "handle": a.Handle, "role": a.Role, "status": a.Status})
}
func (s *Service) accountPassword(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var in struct {
		Account  string `json:"account"`
		Password string `json:"password"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	id, e := identity.Parse(in.Account)
	if e != nil {
		return nil, e
	}
	if e = bridge.Invoke(ctx, s.K, "auth", "ResetPassword", []any{ctx, id, in.Password}); e != nil {
		return nil, e
	}
	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) accountDelete(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	// An administrator deletes any account; an admins space tool working for
	// one deletes only the accounts it made (users.account_create).
	tool := ""
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		if tool = s.adminsSpaceTool(ctx, req); tool == "" {
			return nil, e
		}
	}
	var in struct {
		Account string `json:"account"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	id, e := identity.Parse(in.Account)
	if e != nil {
		return nil, e
	}
	a, e := s.GetAccount(ctx, in.Account)
	if e != nil {
		return nil, e
	}
	if a.ID == req.Caller.ID || a.Handle == s.K.Env()["admin_handle"] {
		return nil, errs.Permission("cannot delete the active node administrator")
	}
	if tool != "" && s.managedBy(ctx, id) != tool {
		return nil, errs.Permission("a tool deletes only the accounts it created")
	}

	// Clean up related records: sessions, challenges, follows, and files
	var sessions []struct {
		ID identity.ID `json:"id"`
	}
	if e := s.R.List(ctx, "sessions", database.Filter{Equal: map[string]any{"owner_id": id.String()}}, &sessions); e == nil {
		for _, sess := range sessions {
			_ = s.R.Delete(ctx, "sessions", sess.ID)
		}
	}

	var challenges []struct {
		ID identity.ID `json:"id"`
	}
	if e := s.R.List(ctx, "auth_challenges", database.Filter{Equal: map[string]any{"account_id": id.String()}}, &challenges); e == nil {
		for _, ch := range challenges {
			_ = s.R.Delete(ctx, "auth_challenges", ch.ID)
		}
	}

	var follows []struct {
		ID identity.ID `json:"id"`
	}
	if e := s.R.List(ctx, "follows", database.Filter{Equal: map[string]any{"follower_id": id.String()}}, &follows); e == nil {
		for _, fol := range follows {
			_ = s.R.Delete(ctx, "follows", fol.ID)
		}
	}
	if e := s.R.List(ctx, "follows", database.Filter{Equal: map[string]any{"followee_id": id.String()}}, &follows); e == nil {
		for _, fol := range follows {
			_ = s.R.Delete(ctx, "follows", fol.ID)
		}
	}

	// Delete owned files and binary storage
	var files []struct {
		ID         identity.ID `json:"id"`
		StorageKey string      `json:"storage_key"`
	}
	if e := s.R.List(ctx, "files", database.Filter{Equal: map[string]any{"owner_id": id.String()}}, &files); e == nil {
		fs := s.K.FS()
		for _, fl := range files {
			if fs != nil && fl.StorageKey != "" {
				_ = fs.Delete(ctx, fl.StorageKey)
			}
			_ = s.R.Delete(ctx, "files", fl.ID)
		}
	}

	// Clean up metadata
	_ = s.M.ReplaceTree(ctx, id, map[string]any{})

	// Delete account record
	if e := s.R.Delete(ctx, "accounts", id); e != nil {
		return nil, e
	}

	return helper.JSON(map[string]any{"ok": true, "account_id": id.String()})
}
