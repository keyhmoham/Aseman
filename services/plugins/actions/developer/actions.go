package developer

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// BuildActions are the console's actions: the app's /developers pages manage
// organizations, keys, money and logs through them, signed in as the person.
func BuildActions(s *Service) []api.Action {
	var actions []api.Action
	// add registers an action that works on one of the caller's organizations.
	add := func(name, summary string, fn func(ctx context.Context, caller identity.ID, req *api.ActionRequest, in map[string]json.RawMessage) (any, error)) {
		actions = append(actions, helper.Action{Namespace: "developer", Name: name, Summary: summary, Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireAuthenticated(req); err != nil {
				return nil, err
			}
			if req.Caller.Kind == "bot" {
				return nil, errs.Permission("the developer console is for people")
			}
			var in map[string]json.RawMessage
			if err := decode(req, &in); err != nil {
				return nil, err
			}
			out, err := fn(ctx, req.Caller.ID, req, in)
			if err != nil {
				return nil, err
			}
			return helper.JSON(out)
		}})
	}
	str := func(in map[string]json.RawMessage, key string) string {
		var v string
		_ = json.Unmarshal(in[key], &v)
		return v
	}
	into := func(in map[string]json.RawMessage, key string, out any) error {
		if raw, ok := in[key]; ok {
			if err := json.Unmarshal(raw, out); err != nil {
				return errs.InvalidArgument("invalid " + key)
			}
		}
		return nil
	}
	scoped := func(name, summary string, fn func(ctx context.Context, caller identity.ID, sc Scope, in map[string]json.RawMessage) (any, error)) {
		add(name, summary, func(ctx context.Context, caller identity.ID, _ *api.ActionRequest, in map[string]json.RawMessage) (any, error) {
			sc, err := s.Scope(ctx, caller, str(in, "org"))
			if err != nil {
				return nil, err
			}
			return fn(ctx, caller, sc, in)
		})
	}
	ok := map[string]any{"ok": true}

	add("orgs_list", "The organizations a person works in, and the invitations waiting for them", func(ctx context.Context, caller identity.ID, _ *api.ActionRequest, _ map[string]json.RawMessage) (any, error) {
		orgs, err := s.Orgs(ctx, caller)
		if err != nil {
			return nil, err
		}
		invites, err := s.Invites(ctx, caller)
		if err != nil {
			return nil, err
		}
		return map[string]any{"orgs": orgs, "invites": invites}, nil
	})
	add("org_create", "Create an organization", func(ctx context.Context, caller identity.ID, _ *api.ActionRequest, in map[string]json.RawMessage) (any, error) {
		org, err := s.CreateOrg(ctx, caller, str(in, "name"))
		if err != nil {
			return nil, err
		}
		return map[string]any{"org": org}, nil
	})
	add("invite_respond", "Accept or decline an invitation to an organization", func(ctx context.Context, caller identity.ID, _ *api.ActionRequest, in map[string]json.RawMessage) (any, error) {
		var accept bool
		_ = json.Unmarshal(in["accept"], &accept)
		if err := s.Respond(ctx, caller, str(in, "org"), accept); err != nil {
			return nil, err
		}
		return ok, nil
	})
	scoped("org_rename", "Rename an organization", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		return ok, s.RenameOrg(ctx, sc, str(in, "name"))
	})
	scoped("org_delete", "Delete an organization, returning its balance to the person deleting it", func(ctx context.Context, caller identity.ID, sc Scope, _ map[string]json.RawMessage) (any, error) {
		return ok, s.DeleteOrg(ctx, caller, sc)
	})
	scoped("members_list", "The people in an organization", func(ctx context.Context, caller identity.ID, sc Scope, _ map[string]json.RawMessage) (any, error) {
		members, err := s.Members(ctx, caller, sc)
		return map[string]any{"members": members, "role": sc.Role}, err
	})
	scoped("member_invite", "Invite a person to an organization by username", func(ctx context.Context, caller identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		m, err := s.Invite(ctx, caller, sc, str(in, "handle"), str(in, "role"))
		return map[string]any{"member": m}, err
	})
	scoped("member_role", "Change a person's role", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		return ok, s.SetRole(ctx, sc, str(in, "member"), str(in, "role"))
	})
	scoped("member_remove", "Remove a person from an organization, or leave it", func(ctx context.Context, caller identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		return ok, s.RemoveMember(ctx, caller, sc, str(in, "member"))
	})

	scoped("keys_list", "An organization's API keys", func(ctx context.Context, _ identity.ID, sc Scope, _ map[string]json.RawMessage) (any, error) {
		keys, err := s.Keys(ctx, sc)
		return map[string]any{"keys": keys}, err
	})
	scoped("key_create", "Create an API key; its secret is returned once", func(ctx context.Context, caller identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		var input KeyInput
		if err := into(in, "input", &input); err != nil {
			return nil, err
		}
		key, secret, err := s.CreateKey(ctx, caller, sc, input)
		return map[string]any{"key": key, "secret": secret}, err
	})
	scoped("key_update", "Change an API key's name, permissions and limits", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		var input KeyInput
		if err := into(in, "input", &input); err != nil {
			return nil, err
		}
		key, err := s.UpdateKey(ctx, sc, str(in, "id"), input)
		return map[string]any{"key": key}, err
	})
	scoped("key_revoke", "Revoke an API key", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		return ok, s.RevokeKey(ctx, sc, str(in, "id"))
	})
	scoped("key_delete", "Delete an API key", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		return ok, s.DeleteKey(ctx, sc, str(in, "id"))
	})

	scoped("logs_list", "An organization's recent API requests", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		var filter LogFilter
		var limit int
		if err := into(in, "filter", &filter); err != nil {
			return nil, err
		}
		_ = json.Unmarshal(in["limit"], &limit)
		logs, err := s.Logs(ctx, sc.Org, filter, limit)
		return map[string]any{"logs": logs}, err
	})
	scoped("usage_report", "An organization's usage over some days", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		var days, tz int
		_ = json.Unmarshal(in["days"], &days)
		_ = json.Unmarshal(in["tz"], &tz)
		report, err := s.Usage(ctx, sc.Org, days, tz)
		if report != nil {
			report.ByProvider = []UsageRow{} // the node's business, not the developer's
		}
		return report, err
	})

	scoped("wallet_get", "An organization's balance and recent movements", func(ctx context.Context, _ identity.ID, sc Scope, _ map[string]json.RawMessage) (any, error) {
		return s.Wallet(ctx, sc)
	})
	scoped("wallet_fund", "Add funds to an organization from your own balance", func(ctx context.Context, caller identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		var amount int64
		_ = json.Unmarshal(in["amount"], &amount)
		return s.Fund(ctx, caller, sc, amount)
	})
	scoped("settings_get", "An organization's limits", func(ctx context.Context, _ identity.ID, sc Scope, _ map[string]json.RawMessage) (any, error) {
		return s.Settings(ctx, sc)
	})
	scoped("settings_save", "Change an organization's limits", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		var next SettingsView
		if err := into(in, "settings", &next); err != nil {
			return nil, err
		}
		return s.SaveSettings(ctx, sc, next)
	})

	add("computers_options", "What a computer may be: sizes, images, limits and prices", func(ctx context.Context, _ identity.ID, _ *api.ActionRequest, _ map[string]json.RawMessage) (any, error) {
		return s.ComputerOptions(ctx)
	})
	scoped("computers_list", "An organization's computers", func(ctx context.Context, _ identity.ID, sc Scope, _ map[string]json.RawMessage) (any, error) {
		list, err := s.Computers(ctx, sc.Org)
		return map[string]any{"computers": list}, err
	})
	scoped("computer_create", "Create and start a computer", func(ctx context.Context, caller identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		if err := sc.Require("resources"); err != nil {
			return nil, err
		}
		var input ComputerInput
		if err := into(in, "input", &input); err != nil {
			return nil, err
		}
		c, err := s.CreateComputer(ctx, sc.Org, caller, input)
		return map[string]any{"computer": c}, err
	})
	scoped("computer_status", "Start or stop a computer", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		if err := sc.Require("resources"); err != nil {
			return nil, err
		}
		c, err := s.SetComputerStatus(ctx, sc.Org, str(in, "id"), str(in, "status"))
		return map[string]any{"computer": c}, err
	})
	scoped("computer_delete", "Delete a computer and its files", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		if err := sc.Require("resources"); err != nil {
			return nil, err
		}
		return ok, s.DeleteComputer(ctx, sc.Org, str(in, "id"))
	})
	scoped("computer_exec", "Run a command on a computer", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		if err := sc.Require("resources"); err != nil {
			return nil, err
		}
		return s.Exec(ctx, sc.Org, str(in, "id"), str(in, "command"), 0)
	})
	scoped("storage_info", "What an organization stores and what it costs", func(ctx context.Context, _ identity.ID, sc Scope, _ map[string]json.RawMessage) (any, error) {
		return s.Storage(ctx, sc.Org)
	})
	scoped("files_list", "An organization's stored files", func(ctx context.Context, _ identity.ID, sc Scope, _ map[string]json.RawMessage) (any, error) {
		list, err := s.Files(ctx, sc.Org)
		return map[string]any{"files": list}, err
	})
	scoped("file_upload", "Store a file; its content is base64", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		if err := sc.Require("resources"); err != nil {
			return nil, err
		}
		data, err := DecodeBase64(str(in, "content"))
		if err != nil {
			return nil, err
		}
		f, err := s.Upload(ctx, sc.Org, str(in, "name"), str(in, "mime"), str(in, "purpose"), data)
		return map[string]any{"file": f}, err
	})
	scoped("file_read", "A file's bytes, as base64", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		f, data, err := s.ReadFile(ctx, sc.Org, str(in, "id"))
		if err != nil {
			return nil, err
		}
		return map[string]any{"file": f, "content": base64.StdEncoding.EncodeToString(data)}, nil
	})
	scoped("file_delete", "Delete a stored file", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		if err := sc.Require("resources"); err != nil {
			return nil, err
		}
		return ok, s.DeleteFile(ctx, sc.Org, str(in, "id"))
	})

	add("models", "The unified model catalog: each model once, with the providers that serve it", func(ctx context.Context, _ identity.ID, _ *api.ActionRequest, _ map[string]json.RawMessage) (any, error) {
		catalog, err := s.Catalog(ctx)
		if catalog == nil {
			catalog = []CatalogModel{}
		}
		return map[string]any{"models": catalog}, err
	})
	add("platform_catalog", "Every non-admin platform action callable through the developer API", func(ctx context.Context, _ identity.ID, _ *api.ActionRequest, _ map[string]json.RawMessage) (any, error) {
		return s.PlatformCatalog(ctx), nil
	})
	scoped("platform_get", "This organization's sub-platform, if it has one", func(ctx context.Context, _ identity.ID, sc Scope, _ map[string]json.RawMessage) (any, error) {
		p, err := s.PlatformOfOrg(ctx, sc.Org)
		if err != nil {
			return nil, err
		}
		if p == nil {
			return map[string]any{"platform": nil}, nil
		}
		return map[string]any{"platform": platformView(*p)}, nil
	})
	scoped("platform_create", "Create the organization's isolated sub-platform", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		view, err := s.CreatePlatform(ctx, sc, str(in, "name"), str(in, "slug"))
		return map[string]any{"platform": view}, err
	})
	scoped("platform_rename", "Rename the organization's sub-platform", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		view, err := s.RenamePlatform(ctx, sc, str(in, "name"))
		return map[string]any{"platform": view}, err
	})
	scoped("platform_delete", "Delete the organization's sub-platform record", func(ctx context.Context, _ identity.ID, sc Scope, _ map[string]json.RawMessage) (any, error) {
		return ok, s.DeletePlatform(ctx, sc)
	})
	scoped("platform_stats", "Users, spaces and bots on this organization's sub-platform", func(ctx context.Context, _ identity.ID, sc Scope, _ map[string]json.RawMessage) (any, error) {
		return s.PlatformStats(ctx, sc)
	})
	scoped("platform_users", "People with accounts local to this sub-platform", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		var limit int
		_ = json.Unmarshal(in["limit"], &limit)
		users, err := s.PlatformUsers(ctx, sc, str(in, "query"), limit)
		return map[string]any{"users": users}, err
	})
	scoped("run", "Run a model from the console's playground", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		if err := sc.Require("resources"); err != nil {
			return nil, err
		}
		var request PlaygroundRequest
		if err := into(in, "request", &request); err != nil {
			return nil, err
		}
		return s.Playground(ctx, sc, request), nil
	})
	scoped("video_get", "How a video started from the playground is going", func(ctx context.Context, _ identity.ID, sc Scope, in map[string]json.RawMessage) (any, error) {
		if err := sc.Require("resources"); err != nil {
			return nil, err
		}
		id, err := identity.Parse(strings.TrimPrefix(str(in, "id"), videoPrefix))
		var job models.VideoJob
		if err == nil {
			err = s.R.Get(ctx, "dev_videos", id, &job)
		}
		if err != nil || job.OrgID != sc.Org {
			return nil, errs.NotFound("video")
		}
		return s.VideoStatus(ctx, &job)
	})
	// The node admin's view across every organization (read-only).
	admin := func(name, summary string, fn func(ctx context.Context, in map[string]json.RawMessage) (any, error)) {
		add(name, summary, func(ctx context.Context, _ identity.ID, req *api.ActionRequest, in map[string]json.RawMessage) (any, error) {
			if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
				return nil, err
			}
			return fn(ctx, in)
		})
	}
	admin("admin_orgs", "Admin: every organization using the developer API, with its last 30 days", func(ctx context.Context, _ map[string]json.RawMessage) (any, error) {
		return s.AdminOrgs(ctx)
	})
	admin("admin_org", "Admin: one organization in full", func(ctx context.Context, in map[string]json.RawMessage) (any, error) {
		return s.AdminOrg(ctx, str(in, "org"))
	})
	admin("admin_logs", "Admin: API requests across organizations", func(ctx context.Context, in map[string]json.RawMessage) (any, error) {
		var filter LogFilter
		var limit int
		if err := into(in, "filter", &filter); err != nil {
			return nil, err
		}
		_ = json.Unmarshal(in["limit"], &limit)
		logs, err := s.AdminLogs(ctx, str(in, "org"), filter, limit)
		return map[string]any{"logs": logs}, err
	})
	admin("admin_platforms", "Admin: every sub-platform and its main-Aseman bridge", func(ctx context.Context, _ map[string]json.RawMessage) (any, error) {
		list, err := s.AdminPlatforms(ctx)
		return map[string]any{"platforms": list}, err
	})
	admin("admin_platform_access", "Admin: grant or revoke a platform's bridge to main Aseman", func(ctx context.Context, in map[string]json.RawMessage) (any, error) {
		var access bool
		_ = json.Unmarshal(in["access"], &access)
		view, err := s.SetMainAccess(ctx, str(in, "platform"), access)
		return map[string]any{"platform": view}, err
	})
	return actions
}

// PlaygroundRequest is a model call from the console, in the console's terms.
type PlaygroundRequest struct {
	Type          string         `json:"type"`
	Model         string         `json:"model"`
	Messages      []chatMessage  `json:"messages"`
	Temperature   *float64       `json:"temperature"`
	MaxTokens     int            `json:"maxTokens"`
	Route         ConsoleRoute   `json:"route"`
	FallbackModel []string       `json:"fallbackModels"`
	Options       map[string]any `json:"options"`
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// PlaygroundResult is what the console shows for a call.
type PlaygroundResult struct {
	Status    int            `json:"status"`
	Error     string         `json:"error,omitempty"`
	Text      string         `json:"text"`
	Model     string         `json:"model"`
	Provider  string         `json:"provider"`
	Attempts  []attemptView  `json:"attempts"`
	TokensIn  int64          `json:"tokensIn"`
	TokensOut int64          `json:"tokensOut"`
	Cost      int64          `json:"cost"`
	LatencyMs int64          `json:"latencyMs"`
	LogID     string         `json:"logId"`
	Artifact  map[string]any `json:"artifact,omitempty"`
}

type attemptView struct {
	Model    string `json:"model"`
	Provider string `json:"provider"`
	OK       bool   `json:"ok"`
	Reason   string `json:"reason,omitempty"`
}

// Playground runs a call for the console. It goes through the same engine as
// the API, so it is routed, billed and logged the same way, as the Playground.
func (s *Service) Playground(ctx context.Context, sc Scope, r PlaygroundRequest) *PlaygroundResult {
	started := s.now()
	c := Call{Org: sc.Org, KeyID: "playground", KeyName: "Playground", Type: r.Type, Model: r.Model, Fallbacks: r.FallbackModel, Route: r.Route.Options()}
	if c.Type == "" {
		c.Type = TypeLanguage
	}
	last := ""
	for _, m := range r.Messages {
		if m.Role == "user" {
			last = m.Content
		}
	}
	switch c.Type {
	case TypeLanguage:
		c.Body = map[string]any{"messages": r.Messages}
		if r.Temperature != nil {
			c.Body["temperature"] = *r.Temperature
		}
		if r.MaxTokens > 0 {
			c.Body["max_tokens"] = r.MaxTokens
		}
	case TypeEmbedding:
		c.Body = map[string]any{"input": last}
	case TypeImage:
		c.Body = map[string]any{"prompt": last, "n": 1}
		for _, k := range []string{"n", "size"} {
			if v, ok := r.Options[k]; ok {
				c.Body[k] = v
			}
		}
	case TypeSpeech:
		c.Body = map[string]any{"input": last}
		if v, ok := r.Options["voice"].(string); ok && v != "" {
			c.Body["voice"] = v
		}
	case TypeTranscription:
		src, _ := r.Options["audio"].(string)
		comma := strings.IndexByte(src, ',')
		if !strings.HasPrefix(src, "data:") || comma < 0 || !strings.HasSuffix(src[:comma], ";base64") {
			return &PlaygroundResult{Status: 400, Error: "Choose an audio file to transcribe.", Attempts: []attemptView{}}
		}
		c.Body = map[string]any{"audio": src[comma+1:], "media_type": strings.TrimSuffix(src[5:comma], ";base64")}
	case TypeRerank:
		docs, _ := r.Options["documents"].([]any)
		if len(docs) == 0 {
			return &PlaygroundResult{Status: 400, Error: "Add the documents to rank, one a line.", Attempts: []attemptView{}}
		}
		c.Body = map[string]any{"query": last, "documents": docs}
	case TypeVideo:
		seconds, _ := r.Options["seconds"].(float64)
		in, bad := parseVideo(map[string]any{"prompt": last, "duration": seconds, "resolution": r.Options["resolution"]})
		if bad != "" {
			return &PlaygroundResult{Status: 400, Error: bad, Attempts: []attemptView{}}
		}
		return s.playgroundVideo(ctx, c, in, started)
	case TypeDecision:
		if q, _ := r.Options["questions"].(map[string]any); len(q) == 0 {
			return &PlaygroundResult{Status: 400, Error: "A decision needs at least one question.", Attempts: []attemptView{}}
		}
		c.Body = map[string]any{"state": last, "questions": r.Options["questions"]}
	default:
		c.Body = map[string]any{}
	}
	res := s.Execute(ctx, c)
	out := &PlaygroundResult{Status: res.Status, Model: res.Model, Provider: res.Provider, Cost: res.Cost, TokensIn: res.TokensIn, TokensOut: res.TokensOut, LogID: res.LogID, LatencyMs: s.now().Sub(started).Milliseconds(), Attempts: []attemptView{}}
	for _, a := range res.Skipped {
		reason := a.Error
		if a.Status > 0 {
			reason = reason + " (HTTP " + itoa(a.Status) + ")"
		}
		out.Attempts = append(out.Attempts, attemptView{Model: a.Model, Provider: a.Provider, Reason: reason})
	}
	if res.Status >= 300 {
		var body struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		_ = json.Unmarshal(res.Body, &body)
		out.Error = body.Error.Message
		return out
	}
	out.Attempts = append(out.Attempts, attemptView{Model: res.Model, Provider: res.Provider, OK: true})
	var reply map[string]any
	if c.Type != TypeSpeech {
		_ = json.Unmarshal(res.Body, &reply)
	}
	switch c.Type {
	case TypeLanguage:
		if choices, _ := reply["choices"].([]any); len(choices) > 0 {
			if ch, _ := choices[0].(map[string]any); ch != nil {
				if msg, _ := ch["message"].(map[string]any); msg != nil {
					out.Text, _ = msg["content"].(string)
				}
			}
		}
	case TypeEmbedding:
		out.Text = string(res.Body)
		if data, _ := reply["data"].([]any); len(data) > 0 {
			out.Artifact = map[string]any{"kind": "vectors", "summary": itoa(len(data)) + " vector(s)"}
		}
	case TypeImage:
		data, _ := reply["data"].([]any)
		var src string
		for _, d := range data {
			if m, ok := d.(map[string]any); ok {
				if b64, ok := m["b64_json"].(string); ok {
					raw, _ := base64.StdEncoding.DecodeString(b64)
					src = "data:" + http.DetectContentType(raw) + ";base64," + b64
					m["b64_json"] = "<" + itoa(len(raw)) + " bytes of base64>"
				} else if u, ok := m["url"].(string); ok && src == "" {
					src = u
				}
			}
		}
		text, _ := json.MarshalIndent(reply, "", "  ")
		out.Text = string(text)
		out.Artifact = map[string]any{"kind": "image", "summary": itoa(len(data)) + " image(s) generated", "detail": map[string]any{"src": src}}
	case TypeSpeech:
		mt := res.Header["Content-Type"]
		text, _ := json.MarshalIndent(map[string]any{"content_type": mt, "bytes": len(res.Body), "cost": usd(float64(res.Cost))}, "", "  ")
		out.Text = string(text)
		out.Artifact = map[string]any{"kind": "audio", "summary": "Speech generated", "detail": map[string]any{"src": "data:" + mt + ";base64," + base64.StdEncoding.EncodeToString(res.Body)}}
	case TypeTranscription, TypeRerank:
		text, _ := json.MarshalIndent(reply, "", "  ")
		out.Text = string(text)
		if c.Type == TypeTranscription {
			t, _ := reply["text"].(string)
			out.Artifact = map[string]any{"kind": "transcript", "summary": clip(t, 160)}
		} else {
			results, _ := reply["results"].([]any)
			out.Artifact = map[string]any{"kind": "ranking", "summary": itoa(len(results)) + " document(s) ranked", "detail": results}
		}
	case TypeDecision:
		out.Text = string(res.Body)
		answers, _ := reply["answers"].(map[string]any)
		out.Artifact = map[string]any{"kind": "decision", "summary": itoa(len(answers)) + " question(s) answered", "detail": answers}
	}
	return out
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return strings.TrimSpace(string(b))
}

// playgroundVideo starts a video from the console: the console then follows it
// with video_get until it is done.
func (s *Service) playgroundVideo(ctx context.Context, c Call, in videoInput, started time.Time) *PlaygroundResult {
	res := s.StartVideo(ctx, c, in)
	out := &PlaygroundResult{Status: res.Status, Model: res.Model, Provider: res.Provider, Cost: res.Cost, LogID: res.LogID,
		LatencyMs: s.now().Sub(started).Milliseconds(), Attempts: []attemptView{}}
	var body map[string]any
	_ = json.Unmarshal(res.Body, &body)
	if res.Status >= 300 {
		if e, ok := body["error"].(map[string]any); ok {
			out.Error, _ = e["message"].(string)
		}
		return out
	}
	out.Attempts = append(out.Attempts, attemptView{Model: res.Model, Provider: res.Provider, OK: true})
	text, _ := json.MarshalIndent(body, "", "  ")
	out.Text = string(text)
	out.Artifact = map[string]any{"kind": "video", "summary": "Video started", "detail": map[string]any{"id": body["id"], "status": body["status"]}}
	return out
}
