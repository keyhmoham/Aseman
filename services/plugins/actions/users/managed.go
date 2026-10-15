package users

import (
	"context"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// Managed accounts are ordinary user accounts an administrator makes for
// someone who does not sign up themselves — the traders the admins space's
// evaluator follows. A tool of the platform admins space may make them too,
// while it works for a platform administrator (the same rule that opens the
// platform database to that space's tools); the accounts it makes are
// tagged with it (metadata "managed_by", never public), and a tool deletes
// only the accounts it made.

// managedKey is the metadata key naming the tool bot that made an account.
const managedKey = "managed_by"

// adminsSpaceTool returns the bot of a tool calling through the tool gateway
// from the platform admins space for an active platform administrator; ""
// for any other caller.
func (s *Service) adminsSpaceTool(ctx context.Context, req *api.ActionRequest) string {
	if req.Caller.Kind != "bot" || req.Caller.ID.IsZero() {
		return ""
	}
	execution := vmm.ExecutionFrom(ctx)
	if execution.SpaceID == "" || execution.AgentID == "" || execution.ActorID == "" {
		return ""
	}
	var admins string
	if err := bridge.Invoke(ctx, s.K, "settings", "AdminsSpace", []any{ctx}, &admins); err != nil || strings.TrimSpace(admins) == "" || admins != execution.SpaceID {
		return ""
	}
	actorID, err := identity.Parse(execution.ActorID)
	if err != nil {
		return ""
	}
	var actor account.Account
	if s.R.Get(ctx, "accounts", actorID, &actor) != nil {
		return ""
	}
	handle := s.K.Env()["admin_handle"]
	if actor.Kind != account.KindUser || actor.Status != account.StatusActive || (actor.Role != "admin" && (handle == "" || actor.Handle != handle)) {
		return ""
	}
	botID, err := identity.Parse(execution.AgentID)
	if err != nil {
		return ""
	}
	var rec bot.Bot
	if s.R.Get(ctx, "bots", botID, &rec) != nil || rec.AccountID != req.Caller.ID || rec.Kind != bot.KindTool {
		return ""
	}
	return rec.ID.String()
}

// managedBy is the tool bot that made an account, "" when none did.
func (s *Service) managedBy(ctx context.Context, id identity.ID) string {
	m, err := s.M.Get(ctx, id)
	if err != nil || m == nil {
		return ""
	}
	tag, _ := m.Tree[managedKey].(map[string]any)
	by, _ := tag["bot"].(string)
	return by
}

// accountCreate implements users.account_create: an active, verified
// ordinary user account with the given username and password.
func (s *Service) accountCreate(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	tool := ""
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		if tool = s.adminsSpaceTool(ctx, req); tool == "" {
			return nil, e
		}
	}
	var in struct {
		Handle      string `json:"handle"`
		Password    string `json:"password"`
		Email       string `json:"email"`
		DisplayName string `json:"display_name"` // "First Last"
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	var acc account.Account
	if e := bridge.Invoke(ctx, s.K, "auth", "CreateManagedAccount", []any{ctx, in.Handle, in.Email, in.Password}, &acc); e != nil {
		return nil, e
	}
	if m, e := s.M.Get(ctx, acc.ID); e == nil && m != nil {
		if tool != "" {
			m.Tree[managedKey] = map[string]any{"bot": tool, "at": time.Now().UTC().Format(time.RFC3339)}
		}
		if name := strings.TrimSpace(in.DisplayName); name != "" {
			profile, _ := m.Tree["profile"].(map[string]any)
			if profile == nil {
				profile = map[string]any{}
			}
			// A person is named by their first and last name.
			first, last, _ := strings.Cut(name, " ")
			profile["firstName"], profile["lastName"] = first, strings.TrimSpace(last)
			m.Tree["profile"] = profile
		}
		if e := s.M.ReplaceTree(ctx, acc.ID, m.Tree); e != nil {
			return nil, e
		}
	}
	return helper.JSON(map[string]any{"id": acc.ID.String(), "handle": acc.Handle, "status": acc.Status, "managed_by": tool})
}

// MayPublishFor reports whether the caller may publish as [account] without
// signing in as it (posts.post_import): only into an account a tool made
// (users.account_create), by a platform administrator or that tool, from the
// platform admins space for an administrator.
func (s *Service) MayPublishFor(ctx context.Context, req *api.ActionRequest, account identity.ID) error {
	by := s.managedBy(ctx, account)
	if by == "" {
		return errs.Permission("posts are published for managed accounts only")
	}
	if helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]) == nil {
		return nil
	}
	if tool := s.adminsSpaceTool(ctx, req); tool == "" || tool != by {
		return errs.Permission("only an administrator, or the admins space tool that made the account, publishes for it")
	}
	return nil
}
