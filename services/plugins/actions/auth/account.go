package auth

import (
	"context"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/auth/models/session"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/metasvc"
	"github.com/aseman/aseman/plugins/actions/support/models/metadata"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"golang.org/x/crypto/bcrypt"
	"strings"
	"time"
)

func accountActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "auth", Name: "me", Summary: "Authenticated account and profile", Handler: s.me},
		helper.Action{Namespace: "auth", Name: "profile_update", Summary: "Update account/profile and securely change password", Handler: s.profileUpdate},
		helper.Action{Namespace: "auth", Name: "account_delete", Summary: "Permanently delete account and revoke sessions", Handler: s.accountDelete},
		helper.Action{Namespace: "auth", Name: "config", Summary: "Available authentication methods", Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			return helper.JSON(map[string]any{"password": true, "google": s.K.Env()["google_client_id"] != "", "google_client_id": s.K.Env()["google_client_id"], "apple": len(appleClientIDs()) > 0, "password_reset": true, "email_verify": true, "email_delivery": s.mailer().Transport()})
		}},
	}
}
func (s *Service) accountView(ctx context.Context, id identity.ID, private bool) (map[string]any, error) {
	var a account.Account
	if err := s.R.Get(ctx, "accounts", id, &a); err != nil {
		return nil, err
	}
	profile := metadata.Tree{}
	m := metasvc.Service{K: s.K, R: s.R}
	viewer := identity.ID{}
	if private {
		viewer = id
	}
	if rec, e := m.View(ctx, viewer, id); e == nil {
		if p, ok := rec.Tree["profile"].(map[string]any); ok {
			profile = p
		}
	}
	out := map[string]any{"id": a.ID.String(), "handle": a.Handle, "kind": a.Kind, "status": a.Status, "profile": profile, "created_at": a.CreatedAt, "is_admin": (a.Role == "admin" || a.Handle == s.K.Env()["admin_handle"])}
	if private {
		out["email"] = a.Email
		hasPassword := a.PasswordHash != ""
		if link, ok := s.loadOAuthLink(ctx, a.ID); ok && !link.Password {
			hasPassword = false
		}
		out["has_password"] = hasPassword
	}
	return out, nil
}
func (s *Service) me(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	a, err := s.accountView(ctx, req.Caller.ID, true)
	if err != nil {
		return nil, err
	}
	return helper.JSON(a)
}
func (s *Service) profileUpdate(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Handle          *string        `json:"handle"`
		Email           *string        `json:"email"`
		Profile         map[string]any `json:"profile"`
		CurrentPassword string         `json:"current_password"`
		Password        string         `json:"password"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	var a account.Account
	if err := s.R.Get(ctx, "accounts", req.Caller.ID, &a); err != nil {
		return nil, err
	}
	link, linked := s.loadOAuthLink(ctx, a.ID)
	if linked && !link.Password && in.CurrentPassword == "" {
		// A provider-only account has no password of its own to confirm.
		in.CurrentPassword = oauthPassword(link.Provider, link.Sub)
	}
	if in.Password != "" || in.Email != nil {
		if err := bcrypt.CompareHashAndPassword([]byte(a.PasswordHash), []byte(in.CurrentPassword)); err != nil {
			return nil, errs.Unauthenticated("current password is incorrect")
		}
	}
	if in.Password != "" {
		if len(in.Password) < 8 {
			return nil, errs.InvalidArgument("password must have at least 8 characters")
		}
		priv, err := s.PrivateKey(ctx, &a, in.CurrentPassword)
		if err != nil {
			return nil, err
		}
		encrypted, err := crypto.EncryptPrivateKey(priv, in.Password)
		if err != nil {
			return nil, err
		}
		hash, err := bcrypt.GenerateFromPassword([]byte(in.Password), bcrypt.DefaultCost)
		if err != nil {
			return nil, err
		}
		a.PasswordHash = string(hash)
		a.PrivateKeyEnc = encrypted
	}
	for field, value := range map[string]*string{"handle": in.Handle, "email": in.Email} {
		if value == nil {
			continue
		}
		v := strings.TrimSpace(*value)
		if v == "" || (field == "email" && !strings.Contains(v, "@")) {
			return nil, errs.InvalidArgument("invalid " + field)
		}
		if field == "handle" && v != a.Handle {
			clean, err := helper.NormalizeHandle(v)
			if err != nil {
				return nil, err
			}
			v = clean
		}
		var existing []account.Account
		if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{field: v}}, &existing); err != nil {
			return nil, err
		}
		for _, other := range existing {
			if other.ID != a.ID {
				return nil, errs.AlreadyExists(field + " already used")
			}
		}
		if field == "handle" {
			if a.Handle == s.K.Env()["admin_handle"] && v != a.Handle {
				// Legacy administrators may only be identified by the bootstrap handle.
				// Persist their role before renaming so access survives the change.
				a.Role = "admin"
			}
			if v == s.K.Env()["admin_handle"] && v != a.Handle && a.Role != "admin" {
				return nil, errs.AlreadyExists("bootstrap administrator handle is reserved")
			}
			a.Handle = v
		} else {
			a.Email = v
		}
	}
	a.UpdatedAt = time.Now().UTC()
	if err := s.R.Update(ctx, "accounts", a.ID, &a); err != nil {
		return nil, err
	}
	if linked && in.Password != "" && !link.Password {
		link.Password = true
		if err := s.saveOAuthLink(ctx, a.ID, link); err != nil {
			return nil, err
		}
	}
	if in.Profile != nil {
		if v, ok := in.Profile["avatar"]; ok {
			ref, _ := v.(string)
			avatar, err := helper.AvatarFile(ctx, s.R, a.ID, ref)
			if err != nil {
				return nil, err
			}
			in.Profile["avatar"] = avatar
		}
		m := metasvc.Service{K: s.K, R: s.R}
		rec, err := m.Get(ctx, a.ID)
		if err != nil {
			return nil, err
		}
		profile, _ := rec.Tree["profile"].(map[string]any)
		if profile == nil {
			profile = map[string]any{}
		}
		for k, v := range in.Profile {
			switch k {
			case "role", "isAdmin", "status", "marketStatus", "currentPassword", "newPassword", "password", "privateKey", "token", "email", "username":
				continue
			}
			profile[k] = v
		}
		rec.Tree["profile"] = profile
		if err = m.ReplaceTree(ctx, a.ID, rec.Tree); err != nil {
			return nil, err
		}
	}
	view, err := s.accountView(ctx, a.ID, true)
	if err != nil {
		return nil, err
	}
	return helper.JSON(view)
}
func (s *Service) accountDelete(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Confirmation string `json:"confirmation"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.Confirmation != "DELETE" {
		return nil, errs.InvalidArgument("type DELETE to confirm")
	}
	var a account.Account
	if err := s.R.Get(ctx, "accounts", req.Caller.ID, &a); err != nil {
		return nil, err
	}
	if a.Role == "admin" || a.Handle == s.K.Env()["admin_handle"] {
		return nil, errs.Permission("node administrator cannot delete its account")
	}

	id := a.ID

	// Clean up related records: sessions, challenges, follows, and files
	var sessions []session.Session
	if err := s.R.List(ctx, "sessions", database.Filter{Equal: map[string]any{"owner_id": id.String()}}, &sessions); err == nil {
		for _, credential := range sessions {
			_ = s.R.Delete(ctx, "sessions", credential.ID)
		}
	}

	var challenges []struct {
		ID identity.ID `json:"id"`
	}
	if err := s.R.List(ctx, "auth_challenges", database.Filter{Equal: map[string]any{"account_id": id.String()}}, &challenges); err == nil {
		for _, ch := range challenges {
			_ = s.R.Delete(ctx, "auth_challenges", ch.ID)
		}
	}

	var follows []struct {
		ID identity.ID `json:"id"`
	}
	if err := s.R.List(ctx, "follows", database.Filter{Equal: map[string]any{"follower_id": id.String()}}, &follows); err == nil {
		for _, fol := range follows {
			_ = s.R.Delete(ctx, "follows", fol.ID)
		}
	}
	if err := s.R.List(ctx, "follows", database.Filter{Equal: map[string]any{"followee_id": id.String()}}, &follows); err == nil {
		for _, fol := range follows {
			_ = s.R.Delete(ctx, "follows", fol.ID)
		}
	}

	// Delete owned files and binary storage
	var files []struct {
		ID         identity.ID `json:"id"`
		StorageKey string      `json:"storage_key"`
	}
	if err := s.R.List(ctx, "files", database.Filter{Equal: map[string]any{"owner_id": id.String()}}, &files); err == nil {
		fs := s.K.FS()
		for _, fl := range files {
			if fs != nil && fl.StorageKey != "" {
				_ = fs.Delete(ctx, fl.StorageKey)
			}
			_ = s.R.Delete(ctx, "files", fl.ID)
		}
	}

	// Clean up metadata
	m := metasvc.Service{K: s.K, R: s.R}
	_ = m.ReplaceTree(ctx, id, map[string]any{})

	// Delete account record
	if err := s.R.Delete(ctx, "accounts", id); err != nil {
		return nil, err
	}

	return helper.JSON(map[string]any{"ok": true, "account_id": id.String()})
}
