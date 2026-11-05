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

// Gadgets: App UIs hosted as compact frameless free-position widgets.
//
// A gadget is the same artifact as a desk App UI (appui_create / appui_publish
// with kind=gadget): Elpian by default, web when asked. Compared to a desk
// window app it is:
//
//  1. Compact like a mobile home-screen widget — dense, glanceable, not a
//     full window of chrome or sprawling multi-pane layout.
//  2. No window frame / background pad — any custom shape; right-click or
//     long-press opens minimise / close / …
//  3. Free positioning: over chat, left rail or desk in a space, or as a
//     universal overlay over home and workspaces (account / platform).
//
// Scope:
//
//   - account: made in the person's own Aseman (home) chat. Universal
//     floating gadget across home tabs and over workspaces.
//   - space: made in a room, thread or direct chat. Shared by members;
//     confined to that space's surfaces (chat / rail / desk / page).
//
// Agents may create gadgets; only a signed-in person (not an agent) may
// remove them.

const gadgetsTable = "tool_gadgets"

// legacyPluginsTable is the pre-rename storage name. Kept only so Bootstrap can
// copy rows into tool_gadgets on nodes that still have the old table.
const legacyPluginsTable = "tool_plugins"

// Gadget scopes and placements.
const (
	GadgetAccount = "account"
	GadgetSpace   = "space"

	PlacementChat = "chat"
	PlacementRail = "rail"
	PlacementPage = "page"
	PlacementDesk = "desk"

	GadgetUIElpian = "elpian"
	GadgetUIWeb    = "web"

	gadgetInstalled = "installed"
	gadgetRemoved   = "removed"
)

func gadgetFields() []database.Field {
	f := func(n string, k database.Kind) database.Field { return database.Field{Name: n, Kind: k} }
	return []database.Field{
		f("id", database.KindString), {Name: "owner", Kind: database.KindString, Index: true}, f("scope", database.KindString),
		{Name: "space_id", Kind: database.KindString, Index: true}, f("name", database.KindString), f("description", database.KindString),
		f("placement", database.KindString), f("ui", database.KindString),
		f("preview", database.KindString), f("entry", database.KindString), {Name: "app_id", Kind: database.KindString, Index: true},
		f("status", database.KindString),
		f("created_by", database.KindString), f("created_at", database.KindTime), f("updated_at", database.KindTime),
	}
}

func gadgetModel() database.Model {
	return database.Model{Name: gadgetsTable, Table: gadgetsTable, Fields: gadgetFields()}
}

func legacyPluginsModel() database.Model {
	return database.Model{Name: legacyPluginsTable, Table: legacyPluginsTable, Fields: gadgetFields()}
}

// migrateGadgetsFromPlugins copies rows from tool_plugins into tool_gadgets
// when the product rename lands on a node that already stored gadgets under
// the old table name. Idempotent: existing gadget ids are left alone.
func (s *Service) migrateGadgetsFromPlugins(ctx context.Context) error {
	if s == nil || s.R == nil || s.R.DB == nil {
		return nil
	}
	if err := s.R.DB.RegisterModel(ctx, legacyPluginsModel()); err != nil {
		return err
	}
	defer func() { _ = s.R.DB.UnregisterModel(ctx, legacyPluginsTable) }()

	var old []Gadget
	if err := s.R.DB.List(ctx, legacyPluginsTable, database.Filter{}, &old); err != nil {
		return err
	}
	for i := range old {
		var existing Gadget
		err := s.R.DB.Get(ctx, gadgetsTable, old[i].ID, &existing)
		if err == nil {
			continue
		}
		if errs.CodeOf(err) != errs.CodeNotFound {
			return err
		}
		if err := s.R.DB.Create(ctx, gadgetsTable, old[i].ID, &old[i]); err != nil {
			return err
		}
	}
	return nil
}

// Gadget is one App UI gadget: its tool bot id and how it is hosted.
type Gadget struct {
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

func (s *Service) gadget(ctx context.Context, id string) (*Gadget, error) {
	if strings.TrimSpace(id) == "" {
		return nil, errs.InvalidArgument("gadget required")
	}
	var p Gadget
	if err := s.R.GetString(ctx, gadgetsTable, id, &p); err != nil {
		if errs.CodeOf(err) == errs.CodeNotFound {
			return nil, errs.NotFound("gadget")
		}
		return nil, err
	}
	return &p, nil
}

func gadgetPerson(ctx context.Context, req *api.ActionRequest) (identity.ID, error) {
	if req.Caller.Kind == "bot" {
		return identity.Parse(vmm.ExecutionFrom(ctx).ActorID)
	}
	if req.Caller.ID.IsZero() {
		return identity.ID{}, errs.Unauthenticated("authentication required")
	}
	return req.Caller.ID, nil
}

// gadgetList implements tools.gadget_list: the person's app-wide gadgets and,
// with space, that space's installed gadgets.
func (s *Service) gadgetList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space string `json:"space"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	person, err := gadgetPerson(ctx, req)
	if err != nil {
		return nil, err
	}
	if in.Space == "" {
		in.Space = vmm.ExecutionFrom(ctx).SpaceID
	}
	out := []Gadget{}
	var mine []Gadget
	if err := s.R.DB.List(ctx, gadgetsTable, database.Filter{Equal: map[string]any{"owner": person.String(), "scope": GadgetAccount}, OrderBy: "created_at"}, &mine); err != nil {
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
		var theirs []Gadget
		if err := s.R.DB.List(ctx, gadgetsTable, database.Filter{Equal: map[string]any{"space_id": spaceID.String(), "scope": GadgetSpace}, OrderBy: "created_at"}, &theirs); err != nil {
			return nil, err
		}
		out = append(out, theirs...)
	}
	kept := out[:0]
	for _, p := range out {
		if p.Status == gadgetInstalled {
			kept = append(kept, p)
		}
	}
	return helper.JSON(map[string]any{"gadgets": kept})
}

// gadgetRemove implements tools.gadget_remove. Only a signed-in person (the
// owner) may remove a gadget — not an agent / bot caller.
func (s *Service) gadgetRemove(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Gadget string `json:"gadget"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	person, err := gadgetPerson(ctx, req)
	if err != nil {
		return nil, err
	}
	p, err := s.gadget(ctx, in.Gadget)
	if err != nil {
		return nil, err
	}
	if p.Owner != person.String() {
		return nil, errs.Permission("only the gadget's owner removes it")
	}
	if p.Status == gadgetRemoved {
		return helper.JSON(map[string]any{"gadget": p})
	}
	if p.Scope == GadgetSpace {
		spaceID, err := identity.Parse(p.SpaceID)
		if err != nil {
			return nil, err
		}
		if err := s.uninstallFromSpace(ctx, person, spaceID, p.ID); err != nil {
			return nil, err
		}
	}
	p.Status, p.UpdatedAt = gadgetRemoved, time.Now().UTC()
	if err := s.R.UpdateString(ctx, gadgetsTable, p.ID, p); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"gadget": p})
}

func firstNonEmptyString(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// RegisterAppGadget creates or updates a gadget whose screen is an App UI
// preview. Called from spaces after appui_publish (kind=gadget).
// spaceID empty → account (universal) gadget; otherwise a space gadget.
func (s *Service) RegisterAppGadget(ctx context.Context, ownerID, spaceID, name, description, placement, ui, preview, entry, appID, createdBy string) (*Gadget, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil, errs.InvalidArgument("a gadget needs a name")
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
	case "", GadgetUIElpian:
		ui = GadgetUIElpian
	case GadgetUIWeb:
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
	scope := GadgetAccount
	if !space.IsZero() {
		scope = GadgetSpace
	}
	appID = strings.TrimSpace(appID)
	entry = strings.TrimSpace(entry)
	description = strings.TrimSpace(description)
	createdBy = strings.TrimSpace(createdBy)
	now := time.Now().UTC()

	if appID != "" {
		var found []Gadget
		filter := database.Filter{Equal: map[string]any{"app_id": appID, "owner": owner.String()}, Limit: 1}
		if err := s.R.DB.List(ctx, gadgetsTable, filter, &found); err == nil && len(found) > 0 {
			p := found[0]
			p.Name, p.Description, p.Placement, p.UI = name, description, placement, ui
			p.Preview, p.Entry, p.Status = preview, entry, gadgetInstalled
			p.UpdatedAt = now
			if err := s.R.UpdateString(ctx, gadgetsTable, p.ID, &p); err != nil {
				return nil, err
			}
			return &p, nil
		}
	}

	// A tool bot is the gadget's identity (space install / ownership). The
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
		return nil, errs.New(errs.CodeInternal, "the gadget's tool was not created")
	}
	if scope == GadgetSpace {
		if err := s.installInSpace(ctx, owner, space, botID); err != nil {
			return nil, err
		}
	}
	p := &Gadget{
		ID: botID, Owner: owner.String(), Scope: scope, Name: name, Description: description,
		Placement: placement, UI: ui, Preview: preview, Entry: entry, AppID: appID,
		Status: gadgetInstalled, CreatedBy: createdBy, CreatedAt: now, UpdatedAt: now,
	}
	if scope == GadgetSpace {
		p.SpaceID = space.String()
	}
	if err := s.R.DB.Create(ctx, gadgetsTable, p.ID, p); err != nil {
		return nil, err
	}
	return p, nil
}

func gadgetActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "tools", Name: "gadget_list", Summary: "The gadgets a person can use: their app-wide ones and a space's", Handler: s.gadgetList},
		helper.Action{Namespace: "tools", Name: "gadget_remove", Summary: "Remove a gadget (owner, signed-in person only)", Handler: s.gadgetRemove},
	}
}
