package tools

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/idutil"
	botdto "github.com/tradera/tradera/plugins/actions/bots/dto"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	market "github.com/tradera/tradera/plugins/actions/market/models"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/tools/models"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// A tool is created from one form with two halves:
//
//	backend   external (an MCP server), managed (run by this node as a Nomad
//	          service: Elpian VM, QuickJS or a docker image) or installed (run
//	          inside the sandbox of each space that adds it, on the same three
//	          runtimes)
//	frontend  static (an Elpian miniapp program on the Elpian VM or QuickJS)
//	          or generative (a skill A2UI is generated from on first use, then
//	          served from the component registry)
//
// Whatever the backend, it is reached as an MCP server, so its microtools are
// agents' tools (spaces.tools_list / spaces.ask) and the frontend's API
// (tools.invoke) alike.

// maxProgram bounds an uploaded program or skill.
const maxProgram = 1 << 20

type backendInput struct {
	Mode string `json:"mode"`
	// external
	URL     string            `json:"url,omitempty"`
	Auth    string            `json:"auth,omitempty"`
	Token   string            `json:"token,omitempty"`
	Headers map[string]string `json:"headers,omitempty"`
	// managed / installed
	Runtime  string `json:"runtime,omitempty"`
	Language string `json:"language,omitempty"`
	Source   string `json:"source,omitempty"`
	// docker
	Image     string              `json:"image,omitempty"`
	Port      int                 `json:"port,omitempty"`
	Path      string              `json:"path,omitempty"`
	Resources bot.ResourceProfile `json:"resources,omitempty"`
}

type frontendInput struct {
	Mode     string `json:"mode,omitempty"`
	Runtime  string `json:"runtime,omitempty"`
	Language string `json:"language,omitempty"`
	Source   string `json:"source,omitempty"`
	// Bytecode is a static Elpian frontend already compiled (base64), for a
	// node without a tool compiler.
	Bytecode string `json:"bytecode,omitempty"`
	Skill    string `json:"skill,omitempty"`
}

type toolInput struct {
	Name        string        `json:"name"`
	Description string        `json:"description"`
	Backend     backendInput  `json:"backend"`
	Frontend    frontendInput `json:"frontend"`
	Listed      bool          `json:"listed"`
	PerCall     int64         `json:"per_call,omitempty"`
}

// validate normalizes the form and reports the first thing wrong with it.
func (in *toolInput) validate() error {
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		return errs.InvalidArgument("name required")
	}
	b := &in.Backend
	switch b.Mode {
	case models.ModeExternal:
		if strings.TrimSpace(b.URL) == "" {
			return errs.InvalidArgument("an external backend needs its MCP server URL")
		}
	case models.ModeManaged, models.ModeInstalled:
		switch b.Runtime {
		case models.RuntimeElpian:
			if b.Language == "" {
				b.Language = "dart"
			}
			if b.Language != "dart" && b.Language != "js" {
				return errs.InvalidArgument("an Elpian VM program is written in dart or js")
			}
		case models.RuntimeQuickJS:
			b.Language = "js"
		case models.RuntimeDocker:
			if strings.TrimSpace(b.Image) == "" {
				return errs.InvalidArgument("a docker backend needs its image")
			}
			if b.Port == 0 {
				b.Port = 8080
			}
			if b.Port < 1 || b.Port > 65535 {
				return errs.InvalidArgument("port must be in 1..65535")
			}
			if b.Path == "" {
				b.Path = "/mcp"
			}
			if !strings.HasPrefix(b.Path, "/") {
				return errs.InvalidArgument("the MCP path starts with /")
			}
		default:
			return errs.InvalidArgument("the backend runtime is elpian, quickjs or docker")
		}
		if b.Runtime != models.RuntimeDocker && strings.TrimSpace(b.Source) == "" {
			return errs.InvalidArgument("upload the backend program")
		}
		if len(b.Source) > maxProgram {
			return errs.InvalidArgument("the backend program is too large")
		}
	default:
		return errs.InvalidArgument("the backend mode is external, managed or installed")
	}
	return in.Frontend.validate()
}

func (f *frontendInput) validate() error {
	switch f.Mode {
	case models.FrontendNone:
	case models.FrontendStatic:
		switch f.Runtime {
		case models.RuntimeElpian:
			if f.Language == "" {
				f.Language = "dart"
			}
			if f.Language != "dart" && f.Language != "js" {
				return errs.InvalidArgument("an Elpian VM frontend is written in dart or js")
			}
		case models.RuntimeQuickJS:
			f.Language = "js"
		default:
			return errs.InvalidArgument("a static frontend runs on elpian or quickjs")
		}
		if strings.TrimSpace(f.Source) == "" && f.Bytecode == "" {
			return errs.InvalidArgument("upload the frontend program")
		}
		if len(f.Source) > maxProgram || len(f.Bytecode) > 2*maxProgram {
			return errs.InvalidArgument("the frontend program is too large")
		}
	case models.FrontendGenerative:
		if strings.TrimSpace(f.Skill) == "" {
			return errs.InvalidArgument("a generative frontend needs its skill (what to show and how)")
		}
		if len(f.Skill) > maxProgram {
			return errs.InvalidArgument("the skill is too large")
		}
	default:
		return errs.InvalidArgument("the frontend mode is static, generative or none")
	}
	return nil
}

func fingerprint(parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return hex.EncodeToString(sum[:8])
}

// toolCreate implements tools.tool_create.
func (s *Service) toolCreate(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in toolInput
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	if e := in.validate(); e != nil {
		return nil, e
	}
	if in.Listed {
		if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
			return nil, errs.Permission("only a node administrator can list a tool for everyone")
		}
	}
	frontend, entities, err := s.prepareFrontend(ctx, in.Frontend)
	if err != nil {
		return nil, err
	}
	var tool *models.Tool
	if in.Backend.Mode == models.ModeExternal {
		tool, err = s.createExternal(ctx, req, in)
	} else {
		tool, err = s.createHosted(ctx, req, in)
	}
	if err != nil {
		return nil, err
	}
	botID := identity.MustParse(tool.BotID)
	for key, value := range entities {
		if err := s.putEntity(ctx, req.Caller.ID, botID, key, value, "text/plain"); err != nil {
			return nil, err
		}
	}
	raw, _ := json.Marshal(frontend)
	tool.Frontend = string(raw)
	tool.UpdatedAt = time.Now().UTC()
	if err := s.R.UpdateString(ctx, "tool_registry", tool.ID, tool); err != nil {
		return nil, err
	}
	if err := s.describe(ctx, req.Caller, tool.BotID, in); err != nil {
		return nil, err
	}
	if in.Listed && in.Backend.Mode != models.ModeExternal {
		var listing *market.Listing
		if err := bridge.Invoke(ctx, s.K, "market", "Publish", []any{ctx, req.Caller.ID, botID, market.ItemTool, in.Name, in.Description, in.PerCall, "tool", ""}, &listing); err != nil {
			return nil, err
		}
	}
	return helper.JSON(s.toolView(ctx, tool))
}

// createExternal registers an external MCP server as the tool's backend.
func (s *Service) createExternal(ctx context.Context, req *api.ActionRequest, in toolInput) (*models.Tool, error) {
	out, err := s.registerMCP(ctx, req, mcpInput{Name: in.Name, URL: in.Backend.URL, Auth: in.Backend.Auth, Token: in.Backend.Token, Headers: in.Backend.Headers,
		Descriptor: map[string]any{"description": in.Description}, Listed: in.Listed})
	if err != nil {
		return nil, err
	}
	var tool models.Tool
	if err := s.R.GetString(ctx, "tool_registry", out["bot_id"].(string), &tool); err != nil {
		return nil, err
	}
	tool.Mode = models.ModeExternal
	return &tool, nil
}

// createHosted deploys a managed backend (a Nomad service of its own) or
// registers an installed one (deployed into each space that adds it).
func (s *Service) createHosted(ctx context.Context, req *api.ActionRequest, in toolInput) (*models.Tool, error) {
	b := in.Backend
	key, err := idutil.RandomHex(8)
	if err != nil {
		return nil, err
	}
	tool := &models.Tool{Owner: req.Caller.ID.String(), Mode: b.Mode, Runtime: b.Runtime, Language: b.Language, RuntimeKey: key}
	port := vmm.ToolRuntimePort
	if b.Runtime == models.RuntimeDocker {
		tool.Image, tool.Port, tool.URL = b.Image, int64(b.Port), b.Path
		port = b.Port
	}
	// What the program registers is learnt now when a compiler is at hand —
	// which also proves it compiles — else from the backend once it runs.
	if b.Runtime != models.RuntimeDocker && s.Compiler != nil {
		listed, err := s.Compiler.Describe(ctx, &Program{Engine: b.Runtime, Language: b.Language, Source: b.Source})
		if err != nil {
			return nil, err
		}
		tool.Commands = commandDefs(listed)
	}
	create := botdto.CreateBotRequest{Name: in.Name, Kind: bot.KindTool, Description: in.Description,
		Resources: b.Resources, Cost: bot.CostModel{PerCall: in.PerCall}}
	if b.Runtime != models.RuntimeDocker {
		create.Entities = map[string]string{models.EntityBackendSource: b.Source}
	}
	switch b.Mode {
	case models.ModeManaged:
		create.VMType = bot.VMType(b.Runtime)
		create.ImageRef = b.Image
		if create.ImageRef == "" {
			create.ImageRef = "tradera/tool-runtime"
		}
		create.Env, err = s.runtimeEnv(key, port)
		if err != nil {
			return nil, err
		}
		service := "tool-" + key
		create.Service = &botdto.ServiceSpec{ID: service, Network: runtimeNetwork(), Port: port}
		tool.Endpoint = vmm.ServiceAddress(map[string]string{vmm.LabelNetworkAlias: service, vmm.LabelServicePort: strconv.Itoa(port)})
	case models.ModeInstalled:
		create.VMType = bot.VMTypeInstalled
		create.ImageRef = "installed:" + b.Runtime
		if b.Runtime == models.RuntimeDocker {
			create.ImageRef = b.Image
		}
	}
	var rec bot.Bot
	if err := bridge.Invoke(ctx, s.K, "bots", "CreateBot", []any{ctx, req.Caller.ID, create}, &rec); err != nil {
		if errs.CodeOf(err) == errs.CodeUnavailable && b.Mode == models.ModeManaged {
			return nil, errs.New(errs.CodeUnavailable, "managed tools need a VMM adapter for "+b.Runtime+" (nomad) on this node: "+err.Error())
		}
		return nil, err
	}
	tool.ID, tool.BotID, tool.UpdatedAt = rec.ID.String(), rec.ID.String(), time.Now().UTC()
	if err := s.R.CreateID(ctx, "tool_registry", rec.ID, tool); err != nil {
		return nil, err
	}
	if b.Mode == models.ModeManaged && rec.Status != bot.StatusRunning {
		// Some providers create a VM stopped; a managed backend serves at once.
		var started *bot.Bot
		_ = bridge.Invoke(ctx, s.K, "bots", "Lifecycle", []any{ctx, rec.ID, "start"}, &started)
	}
	return tool, nil
}

// prepareFrontend turns the frontend half of the form into its spec and the
// bot entities that hold it. A static Elpian frontend is compiled here: the
// device runs bytecode.
func (s *Service) prepareFrontend(ctx context.Context, f frontendInput) (models.FrontendSpec, map[string][]byte, error) {
	spec := models.FrontendSpec{Mode: f.Mode, Runtime: f.Runtime, Language: f.Language}
	entities := map[string][]byte{}
	switch f.Mode {
	case models.FrontendStatic:
		if f.Source != "" {
			entities[models.EntityFrontendSource] = []byte(f.Source)
		}
		if f.Runtime == models.RuntimeElpian {
			var bytecode []byte
			switch {
			case f.Bytecode != "":
				raw, err := base64.StdEncoding.DecodeString(f.Bytecode)
				if err != nil {
					return spec, nil, errs.InvalidArgument("the frontend bytecode must be base64")
				}
				bytecode = raw
			case s.Compiler != nil:
				raw, err := s.Compiler.Compile(ctx, f.Language, f.Source)
				if err != nil {
					return spec, nil, err
				}
				bytecode = raw
			default:
				return spec, nil, errs.New(errs.CodeUnavailable, "this node has no tool compiler (TRADERA_TOOL_COMPILER_URL): upload the frontend compiled to Elpian bytecode")
			}
			entities[models.EntityFrontendBytecode] = []byte(base64.StdEncoding.EncodeToString(bytecode))
		}
		spec.Version = fingerprint(f.Runtime, f.Language, f.Source, f.Bytecode)
	case models.FrontendGenerative:
		entities[models.EntityFrontendSkill] = []byte(f.Skill)
		spec.Version = fingerprint("generative", f.Skill)
	}
	return spec, entities, nil
}

// describe records the tool's profile: what people and agents read about it.
func (s *Service) describe(ctx context.Context, caller api.Caller, botID string, in toolInput) error {
	descriptor := map[string]any{"kind": "tool", "name": in.Name, "description": in.Description,
		"backend_mode": in.Backend.Mode, "runtime": in.Backend.Runtime, "frontend_mode": in.Frontend.Mode}
	if in.Backend.Mode == models.ModeExternal {
		descriptor["kind"] = "mcp"
		descriptor["mcp_url"] = in.Backend.URL
		descriptor["mcp_auth"] = in.Backend.Auth
	}
	b, _ := json.Marshal(map[string]any{"bot": botID, "descriptor": descriptor})
	_, err := s.K.Actions().Dispatch(ctx, "bots", "bot_edit", &api.ActionRequest{Caller: caller, Body: b})
	return err
}

// toolView is a tool as its owner and its users see it (no credentials).
func (s *Service) toolView(ctx context.Context, tool *models.Tool) map[string]any {
	var frontend models.FrontendSpec
	_ = json.Unmarshal([]byte(tool.Frontend), &frontend)
	out := map[string]any{"bot_id": tool.BotID, "mode": tool.EffectiveMode(), "runtime": tool.Runtime,
		"language": tool.Language, "frontend": frontend, "commands": tool.Commands}
	if rec, err := s.bot(ctx, tool.BotID); err == nil {
		out["name"], out["status"], out["vm_type"] = rec.Name, rec.Status, rec.VMType
	}
	switch tool.EffectiveMode() {
	case models.ModeExternal:
		out["url"], out["auth"] = tool.URL, tool.Auth
	case models.ModeManaged, models.ModeInstalled:
		if tool.Runtime == models.RuntimeDocker {
			out["image"], out["port"], out["path"] = tool.Image, tool.Port, tool.URL
		}
	}
	return out
}

// toolGet implements tools.tool_get.
func (s *Service) toolGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireAuthenticated(req); e != nil {
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
	return helper.JSON(s.toolView(ctx, &tool))
}

// toolUpdate implements tools.tool_update: a new backend program and/or a new
// frontend. A managed backend is restarted to load its new program; an
// installed one is reinstalled by the next call in each space (its version
// no longer matches); a generative frontend is regenerated on next use.
func (s *Service) toolUpdate(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Bot      string         `json:"bot"`
		Source   *string        `json:"source"`
		Frontend *frontendInput `json:"frontend"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	tool, err := s.ownedTool(ctx, req, in.Bot)
	if err != nil {
		return nil, err
	}
	botID, err := identity.Parse(tool.BotID)
	if err != nil {
		return nil, err
	}
	if in.Source != nil {
		if tool.Runtime != models.RuntimeElpian && tool.Runtime != models.RuntimeQuickJS {
			return nil, errs.InvalidArgument("this tool's backend is not a program")
		}
		if strings.TrimSpace(*in.Source) == "" || len(*in.Source) > maxProgram {
			return nil, errs.InvalidArgument("upload the backend program")
		}
		if s.Compiler != nil {
			listed, err := s.Compiler.Describe(ctx, &Program{Engine: tool.Runtime, Language: tool.Language, Source: *in.Source})
			if err != nil {
				return nil, err
			}
			tool.Commands = commandDefs(listed)
		}
		if err := s.putEntity(ctx, req.Caller.ID, botID, models.EntityBackendSource, []byte(*in.Source), "text/plain"); err != nil {
			return nil, err
		}
		if tool.EffectiveMode() == models.ModeManaged {
			var rec *bot.Bot
			_ = bridge.Invoke(ctx, s.K, "bots", "Lifecycle", []any{ctx, botID, "stop"}, &rec)
			if err := bridge.Invoke(ctx, s.K, "bots", "Lifecycle", []any{ctx, botID, "start"}, &rec); err != nil {
				return nil, err
			}
		}
	}
	if in.Frontend != nil {
		if err := in.Frontend.validate(); err != nil {
			return nil, err
		}
		spec, entities, err := s.prepareFrontend(ctx, *in.Frontend)
		if err != nil {
			return nil, err
		}
		for key, value := range entities {
			if err := s.putEntity(ctx, req.Caller.ID, botID, key, value, "text/plain"); err != nil {
				return nil, err
			}
		}
		raw, _ := json.Marshal(spec)
		tool.Frontend = string(raw)
	}
	tool.UpdatedAt = time.Now().UTC()
	if err := s.R.UpdateString(ctx, "tool_registry", tool.ID, tool); err != nil {
		return nil, err
	}
	s.forgetCommands(tool.BotID)
	return helper.JSON(s.toolView(ctx, tool))
}

// toolDelete implements tools.tool_delete for every backend mode (and
// tools.mcp_delete, its older name for external servers).
func (s *Service) toolDelete(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	return s.mcpDelete(ctx, req)
}

// toolMicrotools implements tools.tool_microtools: what a tool's backend
// offers, asked live for the caller (in a space for an installed tool).
func (s *Service) toolMicrotools(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireAuthenticated(req); e != nil {
		return nil, e
	}
	var in struct {
		Bot   string `json:"bot"`
		Space string `json:"space"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	var tool models.Tool
	if e := s.R.GetString(ctx, "tool_registry", in.Bot, &tool); e != nil {
		return nil, e
	}
	rec, err := s.bot(ctx, in.Bot)
	if err != nil {
		return nil, err
	}
	if in.Space != "" {
		sp, err := identity.Parse(in.Space)
		if err != nil {
			return nil, errs.InvalidArgument("invalid space")
		}
		if err := helper.CheckSpaceAccess(ctx, s.R, req.Caller.ID, sp, identity.ID{}, false); err != nil {
			return nil, err
		}
		if err := helper.CheckSpaceAccess(ctx, s.R, rec.AccountID, sp, identity.ID{}, false); err != nil {
			return nil, err
		}
	} else if tool.Owner != req.Caller.ID.String() {
		return nil, errs.Permission("ask for a tool's microtools from a space it was added to")
	}
	ctx = vmm.WithExecution(ctx, vmm.Execution{ActorID: req.Caller.ID.String(), SpaceID: in.Space})
	commands, err := s.microtools(ctx, &tool, rec, req.Caller.ID, in.Space)
	if err != nil {
		return nil, err
	}
	s.rememberMicrotools(ctx, &tool, commands)
	return helper.JSON(map[string]any{"bot_id": tool.BotID, "commands": commands})
}

// Install warms an installed tool in a space: called when the tool is added
// to the space, so the first person to use it does not wait for it.
func (s *Service) Install(ctx context.Context, spaceID, botID string) error {
	var tool models.Tool
	if err := s.R.GetString(ctx, "tool_registry", botID, &tool); err != nil {
		return err
	}
	if tool.EffectiveMode() != models.ModeInstalled {
		return nil
	}
	rec, err := s.bot(ctx, botID)
	if err != nil {
		return err
	}
	_, err = s.install(ctx, &tool, rec, spaceID)
	return err
}

// FrontendMode is the mode of a tool's frontend (static, generative or empty).
func (s *Service) FrontendMode(ctx context.Context, botID string) (string, error) {
	var tool models.Tool
	if err := s.R.GetString(ctx, "tool_registry", botID, &tool); err != nil {
		return "", err
	}
	var spec models.FrontendSpec
	_ = json.Unmarshal([]byte(tool.Frontend), &spec)
	return spec.Mode, nil
}
