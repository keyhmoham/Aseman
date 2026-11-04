package tools

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/agentpolicy"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/tools/models"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Plugins: what agents create for people in Creator mode.
//
// A plugin is a tool (tool_create) with a scope, a place in the app and the
// platform actions its screen may call:
//
//   - account: made in the person's own Aseman chat. It is the person's,
//     app-wide: it appears in every space, room and direct chat of theirs and
//     on its own page, and its screen acts as the person across their account.
//     Its backend runs as a managed service of the node.
//   - space: made in a room, thread or direct chat of a space. It belongs to
//     that space, shared by its members (or the chat's participants): its
//     backend is installed into the space's own sandbox, serving only that
//     space, and its screen acts as the person using it, inside that space
//     only.
//
// Either way the screen is an Elpian program the app runs natively (the
// person's theme and UI kit); it reaches its own backend with tool.call, and
// the platform with aseman.call — tools.plugin_call here, which allows only
// the actions the plugin declared, within the scope's policy
// (pkg/agentpolicy), dispatched as the person. Removing a plugin keeps it
// (status "removed") so it can be restored.

const pluginsTable = "tool_plugins"

// Plugin scopes and placements.
const (
	PluginAccount = "account"
	PluginSpace   = "space"

	// PlacementPanel: beside the conversation (a room, thread or chat).
	PlacementPanel = "panel"
	// PlacementPage: a page of its own (app-wide plugins: in the app's
	// plugins page; space plugins: a tab of the space).
	PlacementPage = "page"
	// PlacementDesk: a window on the room's desk.
	PlacementDesk = "desk"

	pluginInstalled = "installed"
	pluginRemoved   = "removed"
	maxPermissions  = 40
)

func pluginModel() database.Model {
	f := func(n string, k database.Kind) database.Field { return database.Field{Name: n, Kind: k} }
	return database.Model{Name: pluginsTable, Table: pluginsTable, Fields: []database.Field{
		f("id", database.KindString), {Name: "owner", Kind: database.KindString, Index: true}, f("scope", database.KindString),
		{Name: "space_id", Kind: database.KindString, Index: true}, f("name", database.KindString), f("description", database.KindString),
		f("placement", database.KindString), f("permissions", database.KindJSON), f("status", database.KindString),
		f("created_by", database.KindString), f("created_at", database.KindTime), f("updated_at", database.KindTime),
	}}
}

// Plugin is one plugin: its tool (ID is the tool's bot id) and how it is used.
type Plugin struct {
	ID          string    `db:"id" json:"id"`
	Owner       string    `db:"owner" json:"owner"`
	Scope       string    `db:"scope" json:"scope"`
	SpaceID     string    `db:"space_id" json:"space_id,omitempty"`
	Name        string    `db:"name" json:"name"`
	Description string    `db:"description" json:"description,omitempty"`
	Placement   string    `db:"placement" json:"placement"`
	Permissions []string  `db:"permissions" json:"permissions"`
	Status      string    `db:"status" json:"status"`
	CreatedBy   string    `db:"created_by" json:"created_by,omitempty"`
	CreatedAt   time.Time `db:"created_at" json:"created_at"`
	UpdatedAt   time.Time `db:"updated_at" json:"updated_at"`
}

func (p *Plugin) policy() agentpolicy.Scope {
	if p.Scope == PluginAccount {
		return agentpolicy.Account
	}
	return agentpolicy.Space
}

// defaultPluginBackend serves a plugin whose creator wrote no backend: the
// plugin's own key-value store, for its screen to keep its data in.
const defaultPluginBackend = `function tools() {
  return [
    { name: 'get', description: 'Read a value the plugin kept', input: { type: 'object', properties: { key: { type: 'string' } }, required: ['key'] } },
    { name: 'set', description: 'Keep a value', input: { type: 'object', properties: { key: { type: 'string' }, value: {} }, required: ['key'] } },
  ];
}
function get(args) { return { value: askHost('aseman.kv.get', { key: args.key }) }; }
function set(args) { askHost('aseman.kv.set', { key: args.key, value: args.value }); return { ok: true }; }
`

type pluginProgram struct {
	Runtime  string `json:"runtime,omitempty"`
	Language string `json:"language,omitempty"`
	Source   string `json:"source"`
}

type pluginInput struct {
	// Plugin is an existing plugin to change (its id); empty creates one.
	Plugin      string         `json:"plugin,omitempty"`
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Placement   string         `json:"placement"`
	Permissions []string       `json:"permissions"`
	Frontend    pluginProgram  `json:"frontend"`
	Backend     *pluginProgram `json:"backend,omitempty"`
	// Space makes a person's plugin a space's (an agent's plugin takes the
	// space of its turn).
	Space string `json:"space,omitempty"`
}

func (in *pluginInput) normalize() error {
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		return errs.InvalidArgument("a plugin needs a name")
	}
	switch in.Placement {
	case "":
		in.Placement = PlacementPanel
	case PlacementPanel, PlacementPage, PlacementDesk:
	default:
		return errs.InvalidArgument("placement is panel, page or desk")
	}
	if strings.TrimSpace(in.Frontend.Source) == "" {
		return errs.InvalidArgument("a plugin needs its screen: the frontend program")
	}
	if in.Frontend.Runtime == "" {
		in.Frontend.Runtime = models.RuntimeQuickJS
	}
	if len(in.Permissions) > maxPermissions {
		return errs.InvalidArgument("too many permissions")
	}
	perms := make([]string, 0, len(in.Permissions))
	seen := map[string]bool{}
	for _, p := range in.Permissions {
		p = strings.TrimSpace(p)
		if p == "" || seen[p] {
			continue
		}
		if !strings.Contains(p, ".") {
			return errs.InvalidArgument("a permission is namespace.action or namespace.*: " + p)
		}
		seen[p] = true
		perms = append(perms, p)
	}
	in.Permissions = perms
	return nil
}

// pluginOwner is who a plugin is made for, and in which space: an agent's
// plugin is the person's who started its turn (in the turn's space, or
// app-wide in the person's own Aseman chat); a person's own is theirs.
func pluginOwner(ctx context.Context, req *api.ActionRequest, space string) (owner identity.ID, spaceID identity.ID, err error) {
	exec := vmm.ExecutionFrom(ctx)
	if req.Caller.Kind == "bot" {
		if exec.SpaceID == "" || exec.ActorID == "" {
			return identity.ID{}, identity.ID{}, errs.Permission("an agent creates plugins only for the person it works for")
		}
		owner, err = identity.Parse(exec.ActorID)
		if err != nil {
			return identity.ID{}, identity.ID{}, errs.Permission("no person to create the plugin for")
		}
		spaceID, err = identity.Parse(exec.SpaceID)
		return owner, spaceID, err
	}
	owner = req.Caller.ID
	if exec.SpaceID != "" {
		space = exec.SpaceID
	}
	if strings.TrimSpace(space) != "" {
		spaceID, err = identity.Parse(space)
		if err != nil {
			return identity.ID{}, identity.ID{}, errs.InvalidArgument("invalid space")
		}
	}
	return owner, spaceID, nil
}

// pluginCreate implements tools.plugin_create (and changes an existing plugin).
func (s *Service) pluginCreate(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in pluginInput
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if err := in.normalize(); err != nil {
		return nil, err
	}
	owner, spaceID, err := pluginOwner(ctx, req, in.Space)
	if err != nil {
		return nil, err
	}
	scope := PluginAccount
	if !spaceID.IsZero() {
		scope = PluginSpace
		if err := helper.CheckSpaceAccess(ctx, s.R, owner, spaceID, identity.ID{}, true); err != nil {
			return nil, err
		}
	}
	as := &api.ActionRequest{Caller: api.Caller{ID: owner, Kind: "user"}}
	if in.Plugin != "" {
		return s.pluginChange(ctx, as, req, in, owner)
	}
	backend := backendInput{Mode: models.ModeManaged, Runtime: models.RuntimeQuickJS, Source: defaultPluginBackend}
	if scope == PluginSpace {
		backend.Mode = models.ModeInstalled
	}
	if in.Backend != nil && strings.TrimSpace(in.Backend.Source) != "" {
		backend.Source = in.Backend.Source
		if in.Backend.Runtime != "" {
			backend.Runtime, backend.Language = in.Backend.Runtime, in.Backend.Language
		}
	}
	tool := toolInput{Name: in.Name, Description: in.Description, Backend: backend,
		Frontend: frontendInput{Mode: models.FrontendStatic, Runtime: in.Frontend.Runtime, Language: in.Frontend.Language, Source: in.Frontend.Source}}
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
		if err := s.installInSpace(ctx, owner, spaceID, botID); err != nil {
			return nil, err
		}
	}
	now := time.Now().UTC()
	p := &Plugin{ID: botID, Owner: owner.String(), Scope: scope, Name: in.Name, Description: in.Description,
		Placement: in.Placement, Permissions: in.Permissions, Status: pluginInstalled, CreatedBy: creatorName(ctx, req), CreatedAt: now, UpdatedAt: now}
	if scope == PluginSpace {
		p.SpaceID = spaceID.String()
	}
	if err := s.R.DB.Create(ctx, pluginsTable, p.ID, p); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"plugin": p})
}

// pluginChange replaces a plugin's programs, name, placement or permissions.
func (s *Service) pluginChange(ctx context.Context, as, req *api.ActionRequest, in pluginInput, owner identity.ID) (*api.ActionResponse, error) {
	p, err := s.plugin(ctx, in.Plugin)
	if err != nil {
		return nil, err
	}
	if p.Owner != owner.String() {
		return nil, errs.Permission("only the plugin's owner (or an agent working for them) changes it")
	}
	update := map[string]any{"bot": p.ID, "name": in.Name, "description": in.Description,
		"frontend": frontendInput{Mode: models.FrontendStatic, Runtime: in.Frontend.Runtime, Language: in.Frontend.Language, Source: in.Frontend.Source}}
	if in.Backend != nil && strings.TrimSpace(in.Backend.Source) != "" {
		update["source"] = in.Backend.Source
	}
	raw, _ := json.Marshal(update)
	as.Body = raw
	if _, err := s.toolUpdate(ctx, as); err != nil {
		return nil, err
	}
	p.Name, p.Description, p.Placement, p.Permissions = in.Name, in.Description, in.Placement, in.Permissions
	p.UpdatedAt = time.Now().UTC()
	if err := s.R.UpdateString(ctx, pluginsTable, p.ID, p); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"plugin": p})
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

func creatorName(ctx context.Context, req *api.ActionRequest) string {
	if req.Caller.Kind != "bot" {
		return ""
	}
	return vmm.ExecutionFrom(ctx).AgentID
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

// usable reports whether person may use p (here: in spaceID, when given).
func (s *Service) usable(ctx context.Context, person identity.ID, p *Plugin) error {
	if p.Status != pluginInstalled {
		return errs.NotFound("plugin")
	}
	if p.Scope == PluginAccount {
		if p.Owner != person.String() {
			return errs.NotFound("plugin")
		}
		return nil
	}
	spaceID, err := identity.Parse(p.SpaceID)
	if err != nil {
		return errs.NotFound("plugin")
	}
	if err := helper.CheckSpaceAccess(ctx, s.R, person, spaceID, identity.ID{}, false); err != nil {
		return errs.NotFound("plugin")
	}
	return nil
}

// the person a plugin action acts for: a person, or the person an agent works for.
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

// pluginSetStatus implements plugin_remove (Undo) and plugin_restore.
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

// pluginCall implements tools.plugin_call: a plugin's screen calls the
// platform. Only the person using it may (never an agent), only the actions
// the plugin declared, within its scope's policy, dispatched as the person;
// a space plugin acts in its own space only.
func (s *Service) pluginCall(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Plugin    string          `json:"plugin"`
		Namespace string          `json:"namespace"`
		Action    string          `json:"action"`
		Body      json.RawMessage `json:"body"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	p, err := s.plugin(ctx, in.Plugin)
	if err != nil {
		return nil, err
	}
	if err := s.usable(ctx, req.Caller.ID, p); err != nil {
		return nil, err
	}
	name := strings.TrimSpace(in.Namespace) + "." + strings.TrimSpace(in.Action)
	if !agentpolicy.Granted(p.Permissions, name) {
		return nil, errs.Permission(p.Name + " did not ask to use " + name)
	}
	if !agentpolicy.Allows(p.policy(), name) {
		return nil, errs.Permission(name + " is not available to plugins here")
	}
	body := map[string]any{}
	if len(in.Body) > 0 && string(in.Body) != "null" {
		if err := json.Unmarshal(in.Body, &body); err != nil {
			return nil, errs.InvalidArgument("the body must be a JSON object")
		}
	}
	if p.Scope == PluginSpace {
		// Every space, room and thread it names must be its space's.
		if err := agentpolicy.Confine(ctx, in.Body, p.SpaceID, s.roomSpace); err != nil {
			return nil, errs.Permission(p.Name + ": " + err.Error())
		}
		if _, ok := body["space"]; !ok {
			body["space"] = p.SpaceID
		}
	}
	raw, _ := json.Marshal(body)
	return s.K.Actions().Dispatch(ctx, in.Namespace, in.Action, &api.ActionRequest{Caller: req.Caller, Body: raw})
}

// roomSpace is the space a room (or thread) is in.
func (s *Service) roomSpace(ctx context.Context, roomID string) (string, error) {
	if s.roomSpaceFn != nil {
		return s.roomSpaceFn(ctx, roomID)
	}
	id, err := identity.Parse(roomID)
	if err != nil {
		return "", errs.InvalidArgument("not a room id")
	}
	var room struct {
		SpaceID string `json:"space_id"`
	}
	if err := bridge.Invoke(ctx, s.K, "spaces", "GetRoom", []any{ctx, id}, &room); err != nil {
		return "", err
	}
	return room.SpaceID, nil
}

// pluginInvoke implements tools.plugin_invoke: a plugin's screen calls its
// own backend (tool.call), as the person using it. A space plugin's backend
// runs in its space's sandbox; an app-wide plugin's is the person's, in no
// space (room and space only say where the person opened it).
func (s *Service) pluginInvoke(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Plugin   string         `json:"plugin"`
		Function string         `json:"function"`
		Payload  map[string]any `json:"payload"`
		Room     string         `json:"room"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	p, err := s.plugin(ctx, in.Plugin)
	if err != nil {
		return nil, err
	}
	if err := s.usable(ctx, req.Caller.ID, p); err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.Function) == "" {
		return nil, errs.InvalidArgument("function required")
	}
	exec := vmm.ExecutionFrom(ctx)
	exec.ActorID, exec.SpaceID, exec.RoomID = req.Caller.ID.String(), p.SpaceID, ""
	if p.Scope == PluginSpace && in.Room != "" {
		exec.RoomID = in.Room
	}
	body, _ := json.Marshal(map[string]any{"function": in.Function, "payload": in.Payload})
	reply, err := s.InvokeTool(vmm.WithExecution(ctx, exec), p.ID, string(body))
	if err != nil {
		return nil, err
	}
	var result any
	if json.Unmarshal([]byte(reply), &result) != nil {
		result = map[string]any{"text": reply}
	}
	return helper.JSON(map[string]any{"result": result})
}

func firstNonEmptyString(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

func pluginActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "tools", Name: "plugin_create", Summary: "Create (or change) a plugin: an Elpian screen with its backend, for a person app-wide or for a space", Handler: s.pluginCreate},
		helper.Action{Namespace: "tools", Name: "plugin_list", Summary: "The plugins a person can use: their app-wide ones and a space's", Handler: s.pluginList},
		helper.Action{Namespace: "tools", Name: "plugin_remove", Summary: "Remove a plugin (it can be restored)", Handler: s.pluginSetStatus(pluginRemoved)},
		helper.Action{Namespace: "tools", Name: "plugin_restore", Summary: "Restore a removed plugin", Handler: s.pluginSetStatus(pluginInstalled)},
		helper.Action{Namespace: "tools", Name: "plugin_invoke", Summary: "A plugin's screen calls its own backend, as the person using it", Handler: s.pluginInvoke},
		helper.Action{Namespace: "tools", Name: "plugin_call", Summary: "A plugin's screen calls a platform action it declared, as the person using it", Handler: s.pluginCall},
	}
}
