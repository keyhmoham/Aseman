package tools

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/tools/models"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// The tool runtime gateway is how a managed or installed backend reaches the
// node: it fetches its program, and, while it serves a call, acts in the
// universal execution scope of that call — posting into the room it was asked
// from, asking the space's other tools and agents, reading the room — as the
// tool's own account, on behalf of the person or agent that called it.
const runtimeGatewayPrefix = "/tools/v1/runtime"

// Headers carrying the execution scope of a call to a managed or installed
// backend. The backend reads who is asking, from which space and room, and
// whether an agent asks on someone's behalf; Scope is the credential its
// callbacks for this call carry.
const (
	HeaderActor = "X-Tradera-Actor"
	HeaderSpace = "X-Tradera-Space"
	HeaderRoom  = "X-Tradera-Room"
	HeaderAgent = "X-Tradera-Agent"
	HeaderScope = "X-Tradera-Scope"
	HeaderTool  = "X-Tradera-Tool"
	// HeaderToken carries the node's runtime credential on calls to a
	// backend. It is not Authorization: a sandbox tunnel in between may need
	// that header for its own credential.
	HeaderToken = "X-Tradera-Token"
)

// scopeTTL bounds how long a backend may keep acting for one call.
const scopeTTL = 15 * time.Minute

// hostActions is the platform surface a backend's callbacks may use. Every
// one is dispatched as the tool's account inside the call's scope, with the
// same authorization any member of the space gets.
var hostActions = map[string]bool{
	"spaces.message_send": true, "spaces.message_list": true,
	"spaces.ask": true, "spaces.tools_list": true,
	"spaces.members_list": true, "spaces.room_get": true,
	"users.account_get": true,
	"bots.kv_get":       true, "bots.kv_set": true, "bots.kv_list": true, "bots.kv_delete": true,
}

// Scope is the execution scope of one call to a backend.
type Scope struct {
	Bot   string `json:"bot"`
	Actor string `json:"actor"`
	Space string `json:"space,omitempty"`
	Room  string `json:"room,omitempty"`
	Agent string `json:"agent,omitempty"`
	Exp   int64  `json:"exp"`
}

// secret is the node's key for runtime credentials, derived from its private
// key so it survives restarts and never leaves the node.
func (s *Service) secret(purpose string) ([]byte, error) {
	master := s.K.Env()["node_private_key"]
	if master == "" {
		return nil, errs.New(errs.CodeUnavailable, "node credential signing is not available")
	}
	mac := hmac.New(sha256.New, []byte(master))
	mac.Write([]byte("tools/" + purpose))
	return mac.Sum(nil), nil
}

func sign(key []byte, data string) string {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(data))
	return hex.EncodeToString(mac.Sum(nil))
}

// RuntimeToken is the credential shared by the node and one tool's backend,
// named by the tool's runtime key: the node sends it with every call (so only
// the node can call the backend), and the backend presents it to fetch its
// program.
func (s *Service) RuntimeToken(runtimeKey string) (string, error) {
	if runtimeKey == "" {
		return "", errs.New(errs.CodeUnavailable, "this tool has no runtime credential")
	}
	key, err := s.secret("runtime")
	if err != nil {
		return "", err
	}
	return sign(key, runtimeKey), nil
}

// scopeToken seals a call's scope; the backend hands it back with every
// callback it makes while serving that call.
func (s *Service) scopeToken(sc Scope) (string, error) {
	key, err := s.secret("scope")
	if err != nil {
		return "", err
	}
	if sc.Exp == 0 {
		sc.Exp = time.Now().Add(scopeTTL).Unix()
	}
	b, _ := json.Marshal(sc)
	body := base64.RawURLEncoding.EncodeToString(b)
	return body + "." + sign(key, body), nil
}

// openScope verifies a scope token and returns its scope.
func (s *Service) openScope(token string) (Scope, error) {
	var sc Scope
	body, sig, ok := strings.Cut(token, ".")
	if !ok {
		return sc, errs.Unauthenticated("invalid tool scope")
	}
	key, err := s.secret("scope")
	if err != nil {
		return sc, err
	}
	if !hmac.Equal([]byte(sign(key, body)), []byte(sig)) {
		return sc, errs.Unauthenticated("invalid tool scope")
	}
	raw, err := base64.RawURLEncoding.DecodeString(body)
	if err != nil || json.Unmarshal(raw, &sc) != nil {
		return sc, errs.Unauthenticated("invalid tool scope")
	}
	if time.Now().Unix() > sc.Exp {
		return sc, errs.Unauthenticated("tool scope expired")
	}
	return sc, nil
}

// scopeHeaders are the headers of a call to a managed or installed backend:
// the node's credential and the call's execution scope.
func (s *Service) scopeHeaders(ctx context.Context, tool *models.Tool, rec *bot.Bot, actor identity.ID, spaceID string) (map[string]string, error) {
	token, err := s.RuntimeToken(tool.RuntimeKey)
	if err != nil {
		return nil, err
	}
	execution := vmm.ExecutionFrom(ctx)
	sc := Scope{Bot: rec.ID.String(), Actor: actor.String(), Space: spaceID, Room: execution.RoomID}
	if sc.Room == "" {
		sc.Room = vmm.RoomFrom(ctx)
	}
	// An agent calling the tool is named apart from the person it acts for.
	if execution.AgentID != "" && execution.AgentID != rec.ID.String() {
		sc.Agent = execution.AgentID
	}
	scope, err := s.scopeToken(sc)
	if err != nil {
		return nil, err
	}
	return map[string]string{
		HeaderToken: token,
		HeaderTool:  sc.Bot, HeaderActor: sc.Actor, HeaderSpace: sc.Space,
		HeaderRoom: sc.Room, HeaderAgent: sc.Agent, HeaderScope: scope,
	}, nil
}

// nodeURL is the node as backends reach it.
func nodeURL() string {
	for _, name := range []string{"TRADERA_TOOL_NODE_URL", "TRADERA_AGENT_NODE_URL"} {
		if v := strings.TrimSpace(os.Getenv(name)); v != "" {
			return strings.TrimRight(v, "/")
		}
	}
	return "http://tradera:8080"
}

// runtimeNetwork is the docker network managed backends join, where the node
// reaches them by name.
func runtimeNetwork() string {
	for _, name := range []string{"TRADERA_TOOL_RUNTIME_NETWORK", "TRADERA_AGENT_RUNTIME_NETWORK"} {
		if v := strings.TrimSpace(os.Getenv(name)); v != "" {
			return v
		}
	}
	return ""
}

// runtimeEnv is what a backend needs to know at start: who it is, how the
// node knows it, and where the node is.
func (s *Service) runtimeEnv(runtimeKey string, port int) (map[string]string, error) {
	token, err := s.RuntimeToken(runtimeKey)
	if err != nil {
		return nil, err
	}
	return map[string]string{
		"TRADERA_TOOL_ID":    runtimeKey,
		"TRADERA_TOOL_TOKEN": token,
		"TRADERA_NODE_URL":   nodeURL(),
		"PORT":               strconv.Itoa(port),
	}, nil
}

// --- gateway routes ---------------------------------------------------------

type route struct {
	method  network.Method
	path    string
	handler network.Handler
}

func (s *Service) routes() []route {
	return []route{
		{network.MethodGet, runtimeGatewayPrefix + "/program", s.serveProgram},
		{network.MethodPost, runtimeGatewayPrefix + "/host", s.serveHost},
	}
}

func (s *Service) bindRoutes(n network.Network) error {
	for _, r := range s.routes() {
		if err := n.Handle(r.method, r.path, r.handler); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) unbindRoutes(n network.Network) error {
	var first error
	for _, r := range s.routes() {
		if err := n.Unhandle(r.method, r.path); err != nil && first == nil {
			first = err
		}
	}
	return first
}

func header(h map[string]string, name string) string {
	for k, v := range h {
		if strings.EqualFold(k, name) {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func bearer(h map[string]string) string {
	return strings.TrimSpace(strings.TrimPrefix(header(h, "Authorization"), "Bearer "))
}

func jsonReply(status int, v any) *network.Response {
	b, _ := json.Marshal(v)
	return &network.Response{Status: status, Header: map[string]string{"Content-Type": "application/json"}, Body: b}
}

func errorReply(err error) *network.Response {
	return jsonReply(helper.StatusOf(err), map[string]any{"error": map[string]any{"code": string(errs.CodeOf(err)), "message": err.Error()}})
}

// serveProgram hands a managed or installed backend its program: the engine,
// the source language and the source.
func (s *Service) serveProgram(ctx context.Context, req *network.Request) (*network.Response, error) {
	runtimeKey := header(req.Header, HeaderTool)
	want, err := s.RuntimeToken(runtimeKey)
	if err != nil {
		return errorReply(errs.Unauthenticated("invalid tool runtime credential")), nil
	}
	if !hmac.Equal([]byte(want), []byte(bearer(req.Header))) {
		return errorReply(errs.Unauthenticated("invalid tool runtime credential")), nil
	}
	var tools []models.Tool
	if err := s.R.List(ctx, "tool_registry", filterEq("runtime_key", runtimeKey), &tools); err != nil || len(tools) == 0 {
		return errorReply(errs.NotFound("tool")), nil
	}
	program, err := s.program(ctx, tools[0].BotID)
	if err != nil {
		return errorReply(err), nil
	}
	return jsonReply(http.StatusOK, program), nil
}

// Program is what a backend runs.
type Program struct {
	Engine   string `json:"engine"`
	Language string `json:"language,omitempty"`
	Source   string `json:"source"`
}

func (s *Service) program(ctx context.Context, botID string) (*Program, error) {
	var tool models.Tool
	if err := s.R.GetString(ctx, "tool_registry", botID, &tool); err != nil {
		return nil, err
	}
	if tool.Runtime != models.RuntimeElpian && tool.Runtime != models.RuntimeQuickJS {
		return nil, errs.InvalidArgument("this tool's backend is not a program")
	}
	source, err := s.entity(ctx, botID, models.EntityBackendSource)
	if err != nil {
		return nil, err
	}
	return &Program{Engine: tool.Runtime, Language: tool.Language, Source: source}, nil
}

// serveHost runs one platform action for a backend serving a call, in that
// call's scope: {"namespace","action","body"} → the action's JSON response.
func (s *Service) serveHost(ctx context.Context, req *network.Request) (*network.Response, error) {
	sc, err := s.openScope(bearer(req.Header))
	if err != nil {
		return errorReply(err), nil
	}
	var in struct {
		Namespace string          `json:"namespace"`
		Action    string          `json:"action"`
		Body      json.RawMessage `json:"body"`
	}
	if err := json.Unmarshal(req.Body, &in); err != nil {
		return errorReply(errs.InvalidArgument("invalid host call")), nil
	}
	resp, err := s.HostCall(ctx, sc, in.Namespace, in.Action, in.Body)
	if err != nil {
		return errorReply(err), nil
	}
	status := resp.Status
	if status == 0 {
		status = http.StatusOK
	}
	return &network.Response{Status: status, Header: map[string]string{"Content-Type": "application/json"}, Body: resp.Body}, nil
}

// HostCall dispatches a backend's callback as the tool's account inside the
// scope of the call it serves. A backend acts only inside the space it was
// called from: a body naming another space is refused, and one naming none is
// given the call's.
func (s *Service) HostCall(ctx context.Context, sc Scope, namespace, action string, body json.RawMessage) (*api.ActionResponse, error) {
	name := namespace + "." + action
	if !hostActions[name] {
		return nil, errs.Permission(name + " is not part of the tool host API")
	}
	rec, err := s.bot(ctx, sc.Bot)
	if err != nil {
		return nil, err
	}
	if len(body) == 0 {
		body = json.RawMessage("{}")
	}
	var fields map[string]any
	if err := json.Unmarshal(body, &fields); err != nil || fields == nil {
		return nil, errs.InvalidArgument("host call body must be an object")
	}
	if namespace == "spaces" {
		if space, _ := fields["space"].(string); space != "" && space != sc.Space {
			return nil, errs.Permission("a tool acts only inside the space it was called from")
		}
		if sc.Space == "" {
			return nil, errs.Permission("this call was not made from a space")
		}
		fields["space"] = sc.Space
		if _, ok := fields["room"]; !ok && sc.Room != "" && name != "spaces.members_list" {
			fields["room"] = sc.Room
		}
	}
	if namespace == "bots" {
		fields["bot"] = sc.Bot
	}
	body, _ = json.Marshal(fields)
	ctx = vmm.WithExecution(ctx, vmm.Execution{ActorID: sc.Actor, SpaceID: sc.Space, RoomID: sc.Room, AgentID: sc.Bot})
	ctx = vmm.WithRoom(ctx, sc.Room)
	actor, err := identity.Parse(sc.Actor)
	if err == nil {
		ctx = helper.WithActor(ctx, actor)
	}
	return s.K.Actions().Dispatch(ctx, namespace, action, &api.ActionRequest{Caller: api.Caller{ID: rec.AccountID, Kind: "bot"}, Body: body})
}
