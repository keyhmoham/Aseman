// Package tools owns command registration and personal external connections.
package tools

import (
	"context"
	"encoding/json"
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/internal/plugins/module"
	"github.com/tradera/tradera/pkg/crypto"
	"github.com/tradera/tradera/pkg/errs"
	botdto "github.com/tradera/tradera/plugins/actions/bots/dto"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	market "github.com/tradera/tradera/plugins/actions/market/models"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/metasvc"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/actions/support/schema"
	"github.com/tradera/tradera/plugins/actions/tools/mechanisms/mcp"
	"github.com/tradera/tradera/plugins/actions/tools/models"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"os"
	"strings"
	"sync"
	"time"
)

type Service struct {
	K      api.Kernel
	R      *repo.Repo
	Client *mcp.Client
	// Internal reaches the backends this node runs itself (managed services
	// and sandbox-installed tools), which live on private addresses that the
	// public-facing Client refuses.
	Internal *mcp.Client
	// Compiler compiles Elpian VM programs (TRADERA_TOOL_COMPILER_URL).
	Compiler *Compiler

	// commandCache holds what each connected app offers, per person and
	// project, for a few minutes: agents ask for it at the start of every turn.
	commandMu    sync.Mutex
	commandCache map[string]cachedCommands
}

type cachedCommands struct {
	rows []map[string]any
	at   time.Time
}

// commandCacheTTL is how long an app's list of functions is trusted.
const commandCacheTTL = 5 * time.Minute

// maxAgentCommands bounds how many functions of one app an agent is given:
// every one is part of the prompt of every model call.
const maxAgentCommands = 40

// CommandsFor lists the functions of a connected app as an agent may call
// them for [actorID] in [spaceID]: name, description and argument schema.
// A per-person app that the person has not connected yet has none.
func (s *Service) CommandsFor(ctx context.Context, botID, actorID, spaceID string) ([]map[string]any, error) {
	key := botID + "/" + actorID + "/" + spaceID
	s.commandMu.Lock()
	hit, ok := s.commandCache[key]
	s.commandMu.Unlock()
	if ok && time.Since(hit.at) < commandCacheTTL {
		return hit.rows, nil
	}
	var tool models.Tool
	if e := s.R.GetString(ctx, "tool_registry", botID, &tool); e != nil {
		return nil, e
	}
	commands := tool.Commands
	if tool.EffectiveMode() != models.ModeExternal {
		// A managed backend is asked when nothing is known of it yet; an
		// installed one only answers inside a space's sandbox, so what it said
		// last is used rather than starting a sandbox to list it.
		if len(commands) == 0 && tool.EffectiveMode() == models.ModeManaged {
			if rec, e := s.bot(ctx, botID); e == nil {
				actor, _ := identity.Parse(actorID)
				if live, e := s.microtools(ctx, &tool, rec, actor, spaceID); e == nil {
					commands = live
					s.rememberMicrotools(ctx, &tool, live)
				}
			}
		}
	} else if tool.Auth != "user" && len(commands) > 0 {
		// A shared server's list was saved when it was registered; it is
		// asked again now and then (what it offers, and how its results are
		// shown, change), keeping the saved list if it does not answer.
		live := func() []map[string]any {
			listCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
			defer cancel()
			h, e := s.headers(listCtx, &tool, identity.ID{}, spaceID)
			if e != nil {
				return nil
			}
			if h, e = s.Client.Session(listCtx, tool.URL, h); e != nil {
				return nil
			}
			result, e := s.Client.RPC(listCtx, tool.URL, h, "tools/list", map[string]any{})
			if e != nil {
				return nil
			}
			return commandDefs(result)
		}()
		if len(live) > 0 {
			before, _ := json.Marshal(tool.Commands)
			after, _ := json.Marshal(live)
			if string(before) != string(after) {
				tool.Commands = live
				_ = s.R.UpdateString(ctx, "tool_registry", tool.ID, tool)
			}
			commands = live
		}
	} else if tool.Auth == "user" || len(commands) == 0 {
		actor, _ := identity.Parse(actorID)
		h, e := s.headers(ctx, &tool, actor, spaceID)
		if e != nil {
			return []map[string]any{}, nil // not connected yet: nothing to call
		}
		if h, e = s.Client.Session(ctx, tool.URL, h); e == nil {
			if result, e := s.Client.RPC(ctx, tool.URL, h, "tools/list", map[string]any{}); e == nil {
				commands = commandDefs(result)
			}
		}
	}
	rows := make([]map[string]any, 0, len(commands))
	for _, c := range commands {
		name, _ := c["name"].(string)
		if name == "" || len(rows) >= maxAgentCommands {
			continue
		}
		description, _ := c["description"].(string)
		if len(description) > 600 {
			description = description[:600]
		}
		if appOnly(c) {
			continue // its app's own (MCP Apps): not for agents
		}
		row := map[string]any{"name": name, "description": description}
		if schema, ok := c["schema"].(map[string]any); ok && schema != nil {
			row["schema"] = schema
		}
		if ui, ok := c["ui"].(string); ok && ui != "" {
			row["ui"] = ui
		}
		rows = append(rows, row)
	}
	s.commandMu.Lock()
	if s.commandCache == nil {
		s.commandCache = map[string]cachedCommands{}
	}
	s.commandCache[key] = cachedCommands{rows: rows, at: time.Now()}
	s.commandMu.Unlock()
	return rows, nil
}

// forgetCommands drops what is remembered of an app's functions (its
// connection or address changed).
func (s *Service) forgetCommands(botID string) {
	s.commandMu.Lock()
	for key := range s.commandCache {
		if strings.HasPrefix(key, botID+"/") {
			delete(s.commandCache, key)
		}
	}
	s.commandMu.Unlock()
}

func (s *Service) key(ref string) string { return s.K.NodeID().String() + repo.ExecutionKey(ref)[16:] }
func (s *Service) seal(value any) (string, error) {
	b, e := json.Marshal(value)
	if e != nil {
		return "", e
	}
	master := s.K.Env()["node_private_key"]
	if master == "" {
		return "", errs.New(errs.CodeUnavailable, "node credential encryption is not available")
	}
	return crypto.EncryptPrivateKey(string(b), master)
}
func (s *Service) open(secret string) (map[string]any, error) {
	if secret == "" {
		return map[string]any{}, nil
	}
	text, e := crypto.DecryptPrivateKey(secret, s.K.Env()["node_private_key"])
	if e != nil {
		return nil, e
	}
	var out map[string]any
	e = json.Unmarshal([]byte(text), &out)
	return out, e
}
func (s *Service) bot(ctx context.Context, id string) (*bot.Bot, error) {
	key, e := identity.Parse(id)
	if e != nil {
		return nil, e
	}
	var b bot.Bot
	e = s.R.Get(ctx, "bots", key, &b)
	return &b, e
}
func commandDefs(result map[string]any) []map[string]any {
	defs := []map[string]any{}
	rows, _ := result["tools"].([]any)
	for _, v := range rows {
		r, ok := v.(map[string]any)
		if !ok {
			continue
		}
		schema, _ := r["inputSchema"].(map[string]any)
		props, _ := schema["properties"].(map[string]any)
		def := map[string]any{"name": r["name"], "description": r["description"], "args": props, "schema": schema, "annotations": r["annotations"], "widget": r["widget"]}
		if uri, visibility := appUI(r["_meta"]); uri != "" || len(visibility) > 0 {
			if uri != "" {
				def["ui"] = uri
			}
			if len(visibility) > 0 {
				def["visibility"] = visibility
			}
		}
		defs = append(defs, def)
	}
	return defs
}

// appUI reads an MCP tool's app metadata (MCP Apps): the ui:// resource its
// results are shown with, and who may call it ("model", "app"; both when
// unsaid).
func appUI(meta any) (string, []string) {
	m, _ := meta.(map[string]any)
	ui, _ := m["ui"].(map[string]any)
	uri, _ := ui["resourceUri"].(string)
	if uri == "" {
		uri, _ = m["ui/resourceUri"].(string)
	}
	if !strings.HasPrefix(uri, "ui://") {
		uri = ""
	}
	var visibility []string
	if list, ok := ui["visibility"].([]any); ok {
		for _, v := range list {
			if s, ok := v.(string); ok {
				visibility = append(visibility, s)
			}
		}
	}
	return uri, visibility
}

// appOnly is whether a microtool is for its app alone (hidden from agents).
func appOnly(c map[string]any) bool {
	var visibility []string
	switch v := c["visibility"].(type) {
	case []string:
		visibility = v
	case []any:
		for _, x := range v {
			if s, ok := x.(string); ok {
				visibility = append(visibility, s)
			}
		}
	}
	if len(visibility) == 0 {
		return false
	}
	for _, v := range visibility {
		if v == "model" {
			return false
		}
	}
	return true
}

// mcpInput is a remote MCP server to register as a tool.
type mcpInput struct {
	Name       string            `json:"name"`
	URL        string            `json:"url"`
	Auth       string            `json:"auth"` // "" (shared credentials) or "user" (each person connects)
	Token      string            `json:"token"`
	Headers    map[string]string `json:"headers"`
	Descriptor map[string]any    `json:"descriptor"`
	// Listed puts the server in the catalog every project can add it from.
	// Only a node administrator may list one; anyone else's server is their
	// own: it is not listed, not reviewed, and only they can add it.
	Listed bool `json:"listed"`
}

func (s *Service) mcpRegister(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in mcpInput
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	if in.Listed {
		if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
			return nil, errs.Permission("only a node administrator can list a server for everyone")
		}
	}
	out, e := s.registerMCP(ctx, req, in)
	if e != nil {
		return nil, e
	}
	return helper.JSON(out)
}

// registerMCP checks that a server answers (unless each person signs in to it
// themselves), then records it as a tool owned by the caller.
func (s *Service) registerMCP(ctx context.Context, req *api.ActionRequest, in mcpInput) (map[string]any, error) {
	if e := mcp.ValidURL(in.URL); e != nil {
		return nil, errs.InvalidArgument(e.Error())
	}
	if strings.TrimSpace(in.Name) == "" {
		return nil, errs.InvalidArgument("name required")
	}
	headers := in.Headers
	if headers == nil {
		headers = map[string]string{}
	}
	if in.Token != "" {
		headers["Authorization"] = "Bearer " + in.Token
	}
	commands := []map[string]any{}
	if in.Auth != "user" {
		session, e := s.Client.Session(ctx, in.URL, headers)
		if e != nil {
			return nil, errs.New(errs.CodeUnavailable, e.Error())
		}
		r, e := s.Client.RPC(ctx, in.URL, session, "tools/list", map[string]any{})
		if e != nil {
			return nil, e
		}
		commands = commandDefs(r)
	}
	var rec bot.Bot
	if e := bridge.Invoke(ctx, s.K, "bots", "CreateBot", []any{ctx, req.Caller.ID, botdto.CreateBotRequest{Name: in.Name, Kind: bot.KindTool, VMType: bot.VMTypeMCP, ImageRef: in.URL, SpecYML: in.URL}}, &rec); e != nil {
		return nil, e
	}
	secret, e := s.seal(map[string]any{"headers": headers})
	if e != nil {
		return nil, e
	}
	tool := models.Tool{ID: rec.ID.String(), BotID: rec.ID.String(), Owner: req.Caller.ID.String(), URL: in.URL, Auth: in.Auth, Commands: commands, Secrets: secret, UpdatedAt: time.Now().UTC()}
	if e = s.R.CreateID(ctx, "tool_registry", rec.ID, &tool); e != nil {
		return nil, e
	}
	descriptor := in.Descriptor
	if descriptor == nil {
		descriptor = map[string]any{}
	}
	delete(descriptor, "token")
	delete(descriptor, "headers")
	descriptor["kind"] = "mcp"
	descriptor["name"] = in.Name
	descriptor["mcp_url"] = in.URL
	descriptor["mcp_auth"] = in.Auth
	b, _ := json.Marshal(map[string]any{"bot": rec.ID.String(), "descriptor": descriptor})
	if _, e = s.K.Actions().Dispatch(ctx, "bots", "bot_edit", &api.ActionRequest{Caller: req.Caller, Body: b}); e != nil {
		return nil, e
	}
	if in.Listed {
		description, _ := descriptor["description"].(string)
		var listing *market.Listing
		if e = bridge.Invoke(ctx, s.K, "market", "Publish", []any{ctx, req.Caller.ID, rec.ID, market.ItemTool, in.Name, description, int64(0), "connected-app", ""}, &listing); e != nil {
			return nil, e
		}
	}
	return map[string]any{"bot_id": rec.ID.String(), "bot": rec, "kind": "mcp", "descriptor": descriptor, "commands": commands, "listed": in.Listed}, nil
}

// mcpDelete removes a registered MCP server for good: from the projects it was
// added to, from the catalog if it was listed, and with every connection
// people made to it. Its owner or a node administrator may do it.
func (s *Service) mcpDelete(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Bot string `json:"bot"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	var tool models.Tool
	if e := s.R.GetString(ctx, "tool_registry", in.Bot, &tool); e != nil {
		return nil, e
	}
	if tool.Owner != req.Caller.ID.String() && helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]) != nil {
		return nil, errs.Permission("tool owner or administrator required")
	}
	rec, e := s.bot(ctx, in.Bot)
	if e != nil {
		return nil, e
	}
	// Out of every project first, so no agent is still offered it.
	var mems []membership.Membership
	if e := s.R.List(ctx, "memberships", database.Filter{Equal: map[string]any{"member_id": rec.AccountID.String()}}, &mems); e == nil {
		for i := range mems {
			_ = s.R.Delete(ctx, "memberships", mems[i].ID)
		}
	}
	var listings []market.Listing
	if e := s.R.List(ctx, "market", database.Filter{Equal: map[string]any{"bot_id": in.Bot}}, &listings); e == nil {
		for i := range listings {
			_ = s.R.Delete(ctx, "market", listings[i].ID)
		}
	}
	var connections []models.Connection
	if e := s.R.List(ctx, "tool_connections", database.Filter{Equal: map[string]any{"bot_id": in.Bot}}, &connections); e == nil {
		for i := range connections {
			if id, e := identity.Parse(connections[i].ID); e == nil {
				_ = s.R.Delete(ctx, "tool_connections", id)
			}
		}
	}
	var components []models.Component
	if e := s.R.List(ctx, "tool_components", database.Filter{Equal: map[string]any{"bot_id": in.Bot}}, &components); e == nil {
		for i := range components {
			if id, e := identity.Parse(components[i].ID); e == nil {
				_ = s.R.Delete(ctx, "tool_components", id)
			}
		}
	}
	if e := s.R.Delete(ctx, "tool_registry", rec.ID); e != nil {
		return nil, e
	}
	b, _ := json.Marshal(map[string]any{"bot": in.Bot})
	if _, e := s.K.Actions().Dispatch(ctx, "bots", "bot_delete", &api.ActionRequest{Caller: req.Caller, Body: b}); e != nil {
		return nil, e
	}
	s.forgetCommands(in.Bot)
	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) mcpUpdate(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Bot     string            `json:"bot"`
		URL     string            `json:"url"`
		Token   *string           `json:"token"`
		Headers map[string]string `json:"headers"`
		Auth    *string           `json:"auth"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	var tool models.Tool
	if e := s.R.GetString(ctx, "tool_registry", in.Bot, &tool); e != nil {
		return nil, e
	}
	if tool.Owner != req.Caller.ID.String() && helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]) != nil {
		return nil, errs.Permission("tool owner or administrator required")
	}
	if e := s.setMCPAccess(&tool, in.URL, in.Auth, in.Token, in.Headers); e != nil {
		return nil, e
	}
	tool.UpdatedAt = time.Now().UTC()
	if e := s.R.UpdateString(ctx, "tool_registry", tool.ID, &tool); e != nil {
		return nil, e
	}
	s.forgetCommands(tool.BotID)
	return helper.JSON(map[string]any{"ok": true})
}

// setMCPAccess changes how an external server is reached: its URL (when
// given), who signs in to it and the shared credential. Everything else kept
// with the server (its sign-in client) stays.
func (s *Service) setMCPAccess(tool *models.Tool, url string, auth, token *string, extra map[string]string) error {
	if url != "" {
		if e := mcp.ValidURL(url); e != nil {
			return errs.InvalidArgument(e.Error())
		}
		tool.URL = url
	}
	if auth != nil {
		if *auth != "" && *auth != "user" {
			return errs.InvalidArgument("auth is empty (shared credentials) or user (each person signs in)")
		}
		tool.Auth = *auth
	}
	secret, e := s.open(tool.Secrets)
	if e != nil {
		return e
	}
	headers := map[string]any{}
	if raw, ok := secret["headers"].(map[string]any); ok {
		headers = raw
	}
	for k, v := range extra {
		headers[k] = v
	}
	if token != nil {
		if *token == "" {
			delete(headers, "Authorization")
		} else {
			headers["Authorization"] = "Bearer " + *token
		}
	}
	secret["headers"] = headers
	tool.Secrets, e = s.seal(secret)
	return e
}

func (s *Service) connectionSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Bot     string     `json:"bot"`
		Space   string     `json:"space"`
		Token   string     `json:"token"`
		Refresh string     `json:"refresh_token"`
		Expires *time.Time `json:"expires_at"`
		// Grant is the state of a sign-in just completed (oauth_exchange). The
		// connection is made from what that sign-in returned, and can renew
		// itself; a pasted token cannot.
		Grant string `json:"grant"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	sp, e := identity.Parse(in.Space)
	if e != nil {
		return nil, e
	}
	if e = helper.CheckSpaceAccess(ctx, s.R, req.Caller.ID, sp, identity.ID{}, true); e != nil {
		return nil, e
	}
	var tool models.Tool
	if e = s.R.GetString(ctx, "tool_registry", in.Bot, &tool); e != nil {
		return nil, e
	}
	stored := map[string]any{"token": in.Token, "refresh_token": in.Refresh}
	if in.Grant != "" {
		var grant models.OAuth
		if e = s.R.GetString(ctx, "tool_oauth", s.key("oauth/"+in.Grant), &grant); e != nil {
			return nil, e
		}
		if grant.Owner != req.Caller.ID.String() || grant.Status != "used" {
			return nil, errs.Permission("that sign-in cannot be used here")
		}
		signIn, e := s.open(grant.Secret)
		if e != nil {
			return nil, e
		}
		field := func(k string) string { v, _ := signIn[k].(string); return v }
		stored = map[string]any{"token": field("access_token"), "refresh_token": field("refresh_token"), "token_endpoint": field("token_endpoint"), "client_id": field("client_id"), "client_secret": field("client_secret"), "resource": field("resource")}
		in.Token = field("access_token")
		in.Expires = nil
		if at, e := time.Parse(time.RFC3339, field("expires_at")); e == nil {
			in.Expires = &at
		}
	}
	encrypted, e := s.seal(stored)
	if e != nil {
		return nil, e
	}
	key := s.key("connection/" + req.Caller.ID.String() + "/" + in.Space + "/" + in.Bot)
	row := models.Connection{ID: key, Owner: req.Caller.ID.String(), BotID: in.Bot, SpaceID: in.Space, Secret: encrypted, ExpiresAt: in.Expires, UpdatedAt: time.Now().UTC()}
	if e = s.R.CreateID(ctx, "tool_connections", identity.MustParse(key), &row); errs.CodeOf(e) == errs.CodeAlreadyExists {
		e = s.R.UpdateString(ctx, "tool_connections", key, &row)
	}
	if e != nil {
		return nil, e
	}
	s.forgetCommands(in.Bot)
	return helper.JSON(map[string]any{"ok": true, "connected": in.Token != ""})
}

// hasConnection reports whether the actor stored a credential for a tool in a space.
func (s *Service) hasConnection(ctx context.Context, actor identity.ID, space, bot string) bool {
	var row models.Connection
	if e := s.R.GetString(ctx, "tool_connections", s.key("connection/"+actor.String()+"/"+space+"/"+bot), &row); e != nil {
		return false
	}
	secret, e := s.open(row.Secret)
	if e != nil {
		return false
	}
	token, _ := secret["token"].(string)
	return token != ""
}
func (s *Service) headers(ctx context.Context, tool *models.Tool, actor identity.ID, space string) (map[string]string, error) {
	headers := map[string]string{}
	if tool.Auth != "user" {
		secret, e := s.open(tool.Secrets)
		if e != nil {
			return nil, e
		}
		if values, ok := secret["headers"].(map[string]any); ok {
			for k, v := range values {
				if text, ok := v.(string); ok {
					headers[k] = text
				}
			}
		}
	} else {
		var row models.Connection
		key := s.key("connection/" + actor.String() + "/" + space + "/" + tool.BotID)
		if e := s.R.GetString(ctx, "tool_connections", key, &row); e != nil {
			return nil, errs.Permission("connect this app using your own account before invoking it")
		}
		secret, e := s.open(row.Secret)
		if e != nil {
			return nil, e
		}
		// Renewed a little early, so a call never starts with a token about to lapse.
		if row.ExpiresAt != nil && row.ExpiresAt.Before(time.Now().Add(time.Minute)) {
			if renewed, e := s.refreshConnection(ctx, &row, secret); e == nil {
				secret = renewed
			} else if row.ExpiresAt.Before(time.Now()) {
				return nil, errs.Unauthenticated("connection expired; sign in to the app again")
			}
		}
		if token, ok := secret["token"].(string); ok && token != "" {
			headers["Authorization"] = "Bearer " + token
		} else {
			return nil, errs.Permission("connect this app before invoking it")
		}
	}
	return headers, nil
}
func (s *Service) invoke(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Bot      string         `json:"bot"`
		Space    string         `json:"space"`
		Function string         `json:"function"`
		Payload  map[string]any `json:"payload"`
		// Room, when set, posts the reply into that room as a tool message so
		// everyone in it sees the result and it survives a reload.
		Room string `json:"room"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	rec, e := s.bot(ctx, in.Bot)
	if e != nil {
		return nil, e
	}
	sp, e := identity.Parse(in.Space)
	if e != nil {
		return nil, e
	}
	var room identity.ID
	if in.Room != "" {
		if room, e = identity.Parse(in.Room); e != nil {
			return nil, errs.InvalidArgument("invalid room")
		}
	}
	if e = helper.CheckSpaceAccess(ctx, s.R, req.Caller.ID, sp, room, true); e != nil {
		return nil, e
	}
	if e = helper.CheckSpaceAccess(ctx, s.R, rec.AccountID, sp, identity.ID{}, false); e != nil {
		return nil, e
	}
	body, _ := json.Marshal(map[string]any{"function": in.Function, "payload": in.Payload})
	b, _ := json.Marshal(map[string]any{"space": in.Space, "bot": in.Bot, "body": string(body)})
	response, e := s.K.Actions().Dispatch(ctx, "spaces", "ask", &api.ActionRequest{Caller: req.Caller, Body: b})
	if e != nil {
		return nil, e
	}
	var answer struct {
		Reply string `json:"reply"`
	}
	if e = json.Unmarshal(response.Body, &answer); e != nil {
		return nil, e
	}
	var result any
	if json.Unmarshal([]byte(answer.Reply), &result) != nil {
		result = map[string]any{"text": answer.Reply}
	}
	out := map[string]any{"result": result}
	if !room.IsZero() {
		id, e := s.postReply(ctx, sp, room, rec.AccountID, in.Function, result)
		if e != nil {
			return nil, e
		}
		out["message_id"] = id.String()
	}
	return helper.JSON(out)
}

// postReply stores a tool's reply as a room message from the tool's account.
// The body is JSON {command, result}; the client renders it with the command's
// registered widget.
func (s *Service) postReply(ctx context.Context, space, room, sender identity.ID, command string, result any) (identity.ID, error) {
	body, e := json.Marshal(map[string]any{"command": command, "result": result})
	if e != nil {
		return identity.ID{}, e
	}
	id, e := identity.New(s.K.NodeID())
	if e != nil {
		return identity.ID{}, e
	}
	now := time.Now().UTC()
	m := &message.Message{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		SpaceID: space, RoomID: room, SenderID: sender, Body: string(body), Kind: message.KindTool}
	m.SetMentions(nil)
	if e := s.R.CreateID(ctx, "messages", id, m); e != nil {
		return identity.ID{}, errs.Wrap(errs.CodeInternal, e, "store tool reply")
	}
	return id, nil
}
func (s *Service) commandsList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireAuthenticated(req); e != nil {
		return nil, e
	}
	var in struct {
		Bot   string `json:"bot"`
		Space string `json:"space"`
	}
	_ = helper.Decode(req, &in)
	filter := database.Filter{}
	if in.Bot != "" {
		filter.Equal = map[string]any{"bot_id": in.Bot}
	}
	var rows []models.Tool
	if e := s.R.List(ctx, "tool_registry", filter, &rows); e != nil {
		return nil, e
	}
	out := []map[string]any{}
	// A server someone connected for themselves is theirs: others learn of it
	// only where they meet it (a project they share that it was added to).
	listed := s.listedBots(ctx)
	var space identity.ID
	if in.Space != "" {
		space, _ = identity.Parse(in.Space)
	}
	for _, r := range rows {
		rec, e := s.bot(ctx, r.BotID)
		if e != nil {
			continue
		}
		if r.Owner != req.Caller.ID.String() && !listed[r.BotID] {
			if space.IsZero() || helper.CheckSpaceAccess(ctx, s.R, req.Caller.ID, space, identity.ID{}, false) != nil ||
				helper.CheckSpaceAccess(ctx, s.R, rec.AccountID, space, identity.ID{}, false) != nil {
				continue
			}
		}
		commands := r.Commands
		// Shared-credential tools are connected for everyone; a per-person tool
		// is connected once the caller stored their own credential here.
		connected := r.Auth != "user"
		if r.Auth == "user" && in.Space != "" {
			connected = s.hasConnection(ctx, req.Caller.ID, in.Space, r.BotID)
		}
		if r.Auth == "user" && in.Space != "" {
			if h, e := s.headers(ctx, &r, req.Caller.ID, in.Space); e == nil {
				if h, e = s.Client.Session(ctx, r.URL, h); e == nil {
					if result, e := s.Client.RPC(ctx, r.URL, h, "tools/list", map[string]any{}); e == nil {
						commands = commandDefs(result)
					}
				}
			}
		}
		avatar := ""
		if m, e := (&metasvc.Service{K: s.K, R: s.R}).Get(ctx, rec.AccountID); e == nil && m != nil {
			avatar = helper.TreeAvatar(m.Tree)
		}
		out = append(out, map[string]any{"bot_id": r.BotID, "name": rec.Name, "auth": r.Auth, "connected": connected, "commands": commands, "avatar": avatar})
	}
	if in.Bot != "" && len(out) > 0 {
		return helper.JSON(out[0])
	}
	return helper.JSON(map[string]any{"tools": out})
}
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "tools-ns", Version: "1.0.0", Provides: []string{"service/tools"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		s := &Service{K: d.Kernel, R: repo.New(d.Kernel), Client: mcp.New(os.Getenv("TRADERA_MCP_ALLOW_PRIVATE") == "true"), Internal: mcp.New(true), Compiler: NewCompiler(os.Getenv("TRADERA_TOOL_COMPILER_URL"))}
		actions := []api.Action{helper.Action{Namespace: "tools", Name: "mcp_register", Summary: "Register a remote MCP tool", Handler: s.mcpRegister}, helper.Action{Namespace: "tools", Name: "mcp_update", Summary: "Update remote MCP configuration", Handler: s.mcpUpdate}, helper.Action{Namespace: "tools", Name: "mcp_oauth_get", Summary: "Read the OAuth client saved for an MCP server", Handler: s.mcpOAuthGet}, helper.Action{Namespace: "tools", Name: "mcp_oauth_set", Summary: "Save the OAuth client people sign in to an MCP server with", Handler: s.mcpOAuthSet}, helper.Action{Namespace: "tools", Name: "mcp_delete", Summary: "Delete a registered MCP server", Handler: s.mcpDelete}, helper.Action{Namespace: "tools", Name: "mcp_samples", Summary: "Admin: the sample MCP servers and which are already in the catalog", Handler: s.mcpSamples}, helper.Action{Namespace: "tools", Name: "mcp_import_samples", Summary: "Admin: add the sample MCP servers to the catalog", Handler: s.mcpImportSamples}, helper.Action{Namespace: "tools", Name: "connection_set", Summary: "Set a personal project connection", Handler: s.connectionSet}, helper.Action{Namespace: "tools", Name: "commands_list", Summary: "Discover tool commands", Handler: s.commandsList}, helper.Action{Namespace: "tools", Name: "invoke", Summary: "Invoke a project tool as its caller", Handler: s.invoke}}
		actions = append(actions,
			helper.Action{Namespace: "tools", Name: "tool_create", Summary: "Create a tool: an external, managed or installed backend and a static or generative frontend", Handler: s.toolCreate},
			helper.Action{Namespace: "tools", Name: "tool_update", Summary: "Replace a tool's backend program or frontend", Handler: s.toolUpdate},
			helper.Action{Namespace: "tools", Name: "tool_get", Summary: "Read a tool: its backend mode, runtime, frontend and microtools", Handler: s.toolGet},
			helper.Action{Namespace: "tools", Name: "tool_delete", Summary: "Delete a tool", Handler: s.toolDelete},
			helper.Action{Namespace: "tools", Name: "tool_microtools", Summary: "List a tool's microtools, asking its backend", Handler: s.toolMicrotools},
			helper.Action{Namespace: "tools", Name: "frontend_get", Summary: "A tool's frontend: its static program, or its generated surface filled with data", Handler: s.frontendGet},
			helper.Action{Namespace: "tools", Name: "frontend_action", Summary: "Run an action of a tool's generated frontend", Handler: s.frontendAction},
			helper.Action{Namespace: "tools", Name: "app_rpc", Summary: "A tool's app (MCP Apps) asks its server: resources/read or tools/call, as the person in the space", Handler: s.appRPC},
			helper.Action{Namespace: "tools", Name: "components_list", Summary: "The generated frontends the component registry holds for a tool", Handler: s.componentsList},
		)
		var release func()
		return module.Instance{Service: s, Models: append(schema.Models(), models.Models()...), Actions: append(actions, oauthActions(s)...),
			Mount: func(context.Context) error {
				// The gateway managed and installed backends reach the node by.
				binder, ok := d.Kernel.(api.NetworkBindings)
				if !ok {
					return nil
				}
				var err error
				release, err = binder.BindRoutes("tools", s.bindRoutes, s.unbindRoutes)
				return err
			},
			Close: func(context.Context) error {
				if release != nil {
					release()
				}
				return nil
			}}, nil
	})
}
