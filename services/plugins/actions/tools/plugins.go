package tools

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/tools/models"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Plugins: App UIs hosted as frameless free-position gadgets.
//
// A plugin is the same artifact as a desk App UI (appui_create / appui_publish
// with kind=plugin): Elpian by default, web when asked. The two differences
// from a desk app are:
//
//  1. No window frame / background pad — the screen may take any custom
//     shape; right-click or long-press opens minimise / close / …
//  2. Free positioning: over chat, left rail or desk in a space, or as a
//     universal overlay over home and workspaces (account / platform).
//
// Scope:
//
//   - account: made in the person's own Aseman (home) chat. Universal
//     floating gadget across home tabs and over workspaces.
//   - space: made in a room, thread or direct chat. Shared by members;
//     confined to that space's surfaces (chat / rail / desk / page).
//
// Removing a plugin keeps it (status "removed") so it can be restored.

const pluginsTable = "tool_plugins"

// Plugin scopes and placements.
const (
	PluginAccount = "account"
	PluginSpace   = "space"

	PlacementChat = "chat"
	PlacementRail = "rail"
	PlacementPage = "page"
	PlacementDesk = "desk"

	PluginUIElpian = "elpian"
	PluginUIWeb    = "web"

	pluginInstalled = "installed"
	pluginRemoved   = "removed"
)

func pluginModel() database.Model {
	f := func(n string, k database.Kind) database.Field { return database.Field{Name: n, Kind: k} }
	return database.Model{Name: pluginsTable, Table: pluginsTable, Fields: []database.Field{
		f("id", database.KindString), {Name: "owner", Kind: database.KindString, Index: true}, f("scope", database.KindString),
		{Name: "space_id", Kind: database.KindString, Index: true}, f("name", database.KindString), f("description", database.KindString),
		f("placement", database.KindString), f("ui", database.KindString),
		f("preview", database.KindString), f("entry", database.KindString), {Name: "app_id", Kind: database.KindString, Index: true},
		f("status", database.KindString),
		f("created_by", database.KindString), f("created_at", database.KindTime), f("updated_at", database.KindTime),
	}}
}

// Plugin is one App UI plugin: its tool bot id and how it is hosted.
type Plugin struct {
	ID          string    `db:"id" json:"id"`
	Owner       string    `db:"owner" json:"owner"`
	Scope       string    `db:"scope" json:"scope"`
	SpaceID     string    `db:"space_id" json:"space_id,omitempty"`
	Name        string    `db:"name" json:"name"`
	Description string    `db:"description" json:"description,omitempty"`
	Placement   string    `db:"placement" json:"placement"`
	UI          string    `db:"ui" json:"ui,omitempty"`
	Preview     string    `db:"preview" json:"preview,omitempty"`
	Entry       string    `db:"entry" json:"entry,omitempty"`
	AppID       string    `db:"app_id" json:"app_id,omitempty"`
	Status      string    `db:"status" json:"status"`
	CreatedBy   string    `db:"created_by" json:"created_by,omitempty"`
	CreatedAt   time.Time `db:"created_at" json:"created_at"`
	UpdatedAt   time.Time `db:"updated_at" json:"updated_at"`
}

func (s *Service) installInSpace(ctx context.Context, owner, spaceID identity.ID, botID string) error {
	id, err := identity.Parse(botID)
	if err != nil {
		return err
	}
	return bridge.Invoke(ctx, s.K, "spaces", "AddBot", []any{ctx, owner, spaceID, identity.ID{}, id})
}

func (s *Service) uninstallFromSpace(ctx context.Context, owner, spaceID identity.ID, botID string) error {
	var rec bot.Bot
	if err := s.R.GetString(ctx, "bots", botID, &rec); err != nil {
		return err
	}
	return bridge.Invoke(ctx, s.K, "spaces", "RemoveBot", []any{ctx, owner, spaceID, rec.AccountID})
}

func (s *Service) plugin(ctx context.Context, id string) (*Plugin, error) {
	if strings.TrimSpace(id) == "" {
		return nil, errs.InvalidArgument("plugin required")
	}
	var p Plugin
	if err := s.R.GetString(ctx, pluginsTable, id, &p); err != nil {
		if errs.CodeOf(err) == errs.CodeNotFound {
			return nil, errs.NotFound("plugin")
		}
		return nil, err
	}
	return &p, nil
}

func pluginPerson(ctx context.Context, req *api.ActionRequest) (identity.ID, error) {
	if req.Caller.Kind == "bot" {
		return identity.Parse(vmm.ExecutionFrom(ctx).ActorID)
	}
	if req.Caller.ID.IsZero() {
		return identity.ID{}, errs.Unauthenticated("authentication required")
	}
	return req.Caller.ID, nil
}

// pluginList implements tools.plugin_list: the person's app-wide plugins and,
// with space, that space's (removed ones too with removed=true, to restore).
func (s *Service) pluginList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space   string `json:"space"`
		Removed bool   `json:"removed"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	person, err := pluginPerson(ctx, req)
	if err != nil {
		return nil, err
	}
	if in.Space == "" {
		in.Space = vmm.ExecutionFrom(ctx).SpaceID
	}
	out := []Plugin{}
	var mine []Plugin
	if err := s.R.DB.List(ctx, pluginsTable, database.Filter{Equal: map[string]any{"owner": person.String(), "scope": PluginAccount}, OrderBy: "created_at"}, &mine); err != nil {
		return nil, err
	}
	out = append(out, mine...)
	if in.Space != "" {
		spaceID, err := identity.Parse(in.Space)
		if err != nil {
			return nil, errs.InvalidArgument("invalid space")
		}
		if err := helper.CheckSpaceAccess(ctx, s.R, person, spaceID, identity.ID{}, false); err != nil {
			return nil, err
		}
		var theirs []Plugin
		if err := s.R.DB.List(ctx, pluginsTable, database.Filter{Equal: map[string]any{"space_id": spaceID.String(), "scope": PluginSpace}, OrderBy: "created_at"}, &theirs); err != nil {
			return nil, err
		}
		out = append(out, theirs...)
	}
	kept := out[:0]
	for _, p := range out {
		if p.Status == pluginInstalled || (in.Removed && p.Owner == person.String()) {
			kept = append(kept, p)
		}
	}
	return helper.JSON(map[string]any{"plugins": kept})
}

// pluginSetStatus implements plugin_remove and plugin_restore.
func (s *Service) pluginSetStatus(status string) func(context.Context, *api.ActionRequest) (*api.ActionResponse, error) {
	return func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
		var in struct {
			Plugin string `json:"plugin"`
		}
		if err := helper.Decode(req, &in); err != nil {
			return nil, err
		}
		person, err := pluginPerson(ctx, req)
		if err != nil {
			return nil, err
		}
		p, err := s.plugin(ctx, in.Plugin)
		if err != nil {
			return nil, err
		}
		if p.Owner != person.String() {
			return nil, errs.Permission("only the plugin's owner removes or restores it")
		}
		if p.Status == status {
			return helper.JSON(map[string]any{"plugin": p})
		}
		if p.Scope == PluginSpace {
			spaceID, err := identity.Parse(p.SpaceID)
			if err != nil {
				return nil, err
			}
			if status == pluginRemoved {
				err = s.uninstallFromSpace(ctx, person, spaceID, p.ID)
			} else {
				err = s.installInSpace(ctx, person, spaceID, p.ID)
			}
			if err != nil {
				return nil, err
			}
		}
		p.Status, p.UpdatedAt = status, time.Now().UTC()
		if err := s.R.UpdateString(ctx, pluginsTable, p.ID, p); err != nil {
			return nil, err
		}
		return helper.JSON(map[string]any{"plugin": p})
	}
}

func firstNonEmptyString(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// RegisterAppPlugin creates or updates a plugin whose screen is an App UI
// preview. Called from spaces after appui_publish (kind=plugin).
// spaceID empty → account (universal) plugin; otherwise a space plugin.
func (s *Service) RegisterAppPlugin(ctx context.Context, ownerID, spaceID, name, description, placement, ui, preview, entry, appID, createdBy string) (*Plugin, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil, errs.InvalidArgument("a plugin needs a name")
	}
	preview = strings.TrimSpace(preview)
	if preview == "" || !strings.HasPrefix(preview, "/v1/proxy/") {
		return nil, errs.InvalidArgument("preview must be a /v1/proxy/… path")
	}
	placement = strings.TrimSpace(placement)
	switch placement {
	case "":
		placement = PlacementChat
	case PlacementChat, PlacementRail, PlacementPage, PlacementDesk:
	default:
		return nil, errs.InvalidArgument("placement is chat, rail, page or desk")
	}
	ui = strings.TrimSpace(ui)
	switch ui {
	case "", PluginUIElpian:
		ui = PluginUIElpian
	case PluginUIWeb:
	default:
		return nil, errs.InvalidArgument(`ui is "elpian" or "web"`)
	}
	owner, err := identity.Parse(strings.TrimSpace(ownerID))
	if err != nil || owner.IsZero() {
		return nil, errs.InvalidArgument("owner required")
	}
	var space identity.ID
	if sid := strings.TrimSpace(spaceID); sid != "" {
		space, err = identity.Parse(sid)
		if err != nil {
			return nil, errs.InvalidArgument("invalid space")
		}
	}
	scope := PluginAccount
	if !space.IsZero() {
		scope = PluginSpace
	}
	appID = strings.TrimSpace(appID)
	entry = strings.TrimSpace(entry)
	description = strings.TrimSpace(description)
	createdBy = strings.TrimSpace(createdBy)
	now := time.Now().UTC()

	if appID != "" {
		var found []Plugin
		filter := database.Filter{Equal: map[string]any{"app_id": appID, "owner": owner.String()}, Limit: 1}
		if err := s.R.DB.List(ctx, pluginsTable, filter, &found); err == nil && len(found) > 0 {
			p := found[0]
			p.Name, p.Description, p.Placement, p.UI = name, description, placement, ui
			p.Preview, p.Entry, p.Status = preview, entry, pluginInstalled
			p.UpdatedAt = now
			if err := s.R.UpdateString(ctx, pluginsTable, p.ID, &p); err != nil {
				return nil, err
			}
			return &p, nil
		}
	}

	// A tool bot is the plugin's identity (space install / ownership). The
	// Flutter client hosts the App UI preview; there is no static frontend
	// and no managed runtime — installed mode is enough for the bot record.
	as := &api.ActionRequest{Caller: api.Caller{ID: owner, Kind: "user"}}
	backend := backendInput{Mode: models.ModeInstalled, Runtime: models.RuntimeQuickJS, Source: "function tools(){return [];}"}
	tool := toolInput{Name: name, Description: description, Backend: backend,
		Frontend: frontendInput{Mode: models.FrontendNone}}
	raw, _ := json.Marshal(tool)
	as.Body = raw
	resp, err := s.toolCreate(ctx, as)
	if err != nil {
		return nil, err
	}
	var created struct {
		BotID string `json:"bot_id"`
		ID    string `json:"id"`
	}
	_ = json.Unmarshal(resp.Body, &created)
	botID := firstNonEmptyString(created.BotID, created.ID)
	if botID == "" {
		return nil, errs.New(errs.CodeInternal, "the plugin's tool was not created")
	}
	if scope == PluginSpace {
		if err := s.installInSpace(ctx, owner, space, botID); err != nil {
			return nil, err
		}
	}
	p := &Plugin{
		ID: botID, Owner: owner.String(), Scope: scope, Name: name, Description: description,
		Placement: placement, UI: ui, Preview: preview, Entry: entry, AppID: appID,
		Status: pluginInstalled, CreatedBy: createdBy, CreatedAt: now, UpdatedAt: now,
	}
	if scope == PluginSpace {
		p.SpaceID = space.String()
	}
	if err := s.R.DB.Create(ctx, pluginsTable, p.ID, p); err != nil {
		return nil, err
	}
	return p, nil
}

func pluginActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "tools", Name: "plugin_list", Summary: "The plugins a person can use: their app-wide ones and a space's", Handler: s.pluginList},
		helper.Action{Namespace: "tools", Name: "plugin_remove", Summary: "Remove a plugin (it can be restored)", Handler: s.pluginSetStatus(pluginRemoved)},
		helper.Action{Namespace: "tools", Name: "plugin_restore", Summary: "Restore a removed plugin", Handler: s.pluginSetStatus(pluginInstalled)},
	}
}
