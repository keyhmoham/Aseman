package bots

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// A sample agent is a specialist an administrator can add to the catalog in
// one go. The built-in lead already does general work: it plans, uses the
// project's computer and delegates. A specialist earns its place only where a
// focused brief changes the result.
//
// The catalogue is the Agency Agents roster (https://github.com/msitarzewski/agency-agents),
// vendored under agencyagents/. Each markdown file becomes one sample: its
// persona sections are the system instructions, and each operational section
// becomes a skill the runtime loads when relevant.
//
// The instructions say who the agent is and how it behaves. Skills hold the
// method, deliverables and workflows. They do not repeat what every agent is
// already told (the shared computer, how to message, how to deliver files):
// see the runtime's prompts.
type sampleAgent struct {
	Slug         string        `json:"slug"`
	Name         string        `json:"name"`
	Username     string        `json:"username"`
	Category     string        `json:"category"`
	Description  string        `json:"description"`
	Usecases     []string      `json:"usecases"`
	Instructions string        `json:"-"`
	Skills       []SkillConfig `json:"-"`
}

// sampleAgents is the importable catalogue, loaded from the embedded Agency
// Agents markdown at init.
var sampleAgents = loadAgencySampleAgents()

// installedSamples maps each sample already on this node to its bot id, and
// lists the usernames agents hold (a sample whose username someone else took
// cannot be added under it).
func (s *Service) installedSamples(ctx context.Context) (bySlug map[string]string, usernames map[string]bool, err error) {
	bySlug, usernames = map[string]string{}, map[string]bool{}
	var agents []bot.Bot
	if err = s.R.List(ctx, "bots", database.Filter{Equal: map[string]any{"kind": "agent"}}, &agents); err != nil {
		return nil, nil, err
	}
	for _, rec := range agents {
		m, e := s.M.Get(ctx, rec.AccountID)
		if e != nil || m == nil {
			continue
		}
		d, _ := m.Tree["descriptor"].(map[string]any)
		if slug, _ := d["sample"].(string); slug != "" {
			bySlug[slug] = rec.ID.String()
		}
		if u, _ := d["username"].(string); u != "" {
			usernames[strings.ToLower(strings.TrimPrefix(u, "@"))] = true
		}
	}
	return bySlug, usernames, nil
}

// agentSamples lists the sample agents and which are already on this node.
func (s *Service) agentSamples(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	installed, _, e := s.installedSamples(ctx)
	if e != nil {
		return nil, e
	}
	rows := make([]map[string]any, 0, len(sampleAgents))
	for _, sample := range sampleAgents {
		rows = append(rows, map[string]any{
			"slug": sample.Slug, "name": sample.Name, "username": sample.Username,
			"category": sample.Category, "description": sample.Description,
			"skills": len(sample.Skills), "installed": installed[sample.Slug] != "",
		})
	}
	return helper.JSON(map[string]any{"samples": rows})
}

// agentImportSamples creates every sample agent that is not on this node yet,
// on the node's default model and at the platform's agent rate, and lists it in
// the catalog. Running it again adds only what is missing; an agent an
// administrator has since edited or deleted is theirs and is left as it is
// (a deleted one is added again).
func (s *Service) agentImportSamples(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	installed, usernames, e := s.installedSamples(ctx)
	if e != nil {
		return nil, e
	}
	type outcome struct {
		Name   string `json:"name"`
		Status string `json:"status"` // added | already | failed
		Error  string `json:"error,omitempty"`
	}
	results := make([]outcome, 0, len(sampleAgents))
	added := 0
	for _, sample := range sampleAgents {
		if installed[sample.Slug] != "" {
			results = append(results, outcome{Name: sample.Name, Status: "already"})
			continue
		}
		if e := s.importSample(ctx, req, sample, usernames); e != nil {
			results = append(results, outcome{Name: sample.Name, Status: "failed", Error: e.Error()})
			continue
		}
		added++
		results = append(results, outcome{Name: sample.Name, Status: "added"})
	}
	return helper.JSON(map[string]any{"added": added, "results": results})
}

func (s *Service) importSample(ctx context.Context, req *api.ActionRequest, sample sampleAgent, usernames map[string]bool) error {
	owner := req.Caller.ID
	// A person may already hold the plain username; the agent then takes the next free one.
	username := sample.Username
	for n := 2; ; n++ {
		taken := usernames[username]
		if !taken {
			var e error
			if taken, e = s.usernameTaken(ctx, username, &bot.Bot{}); e != nil {
				return e
			}
		}
		if !taken {
			break
		}
		if n > 9 {
			return errs.Conflict("the username @" + sample.Username + " and its alternatives are taken")
		}
		username = sample.Username + strconv.Itoa(n)
	}
	rec, e := s.CreateBot(helper.WithActor(ctx, owner), owner, CreateBotRequest{
		Name: sample.Name, Kind: bot.KindAgent, VMType: bot.VMTypeDeepAgents,
		Description: sample.Description, Instructions: sample.Instructions,
		Skills: sample.Skills,
	})
	if e != nil {
		return e
	}
	undo := func(cause error) error {
		// Never leave a half-made agent behind.
		_ = s.DeleteBot(ctx, owner, rec.ID)
		return cause
	}
	provider, model := AgentBackbone(rec.SpecYML)
	body, _ := json.Marshal(map[string]any{
		"bot": rec.ID.String(),
		// 0 = billed at the platform's agent rate (Settings, Pricing), so one
		// setting prices every sample.
		"cost": map[string]any{"per_minute": 0},
		"descriptor": map[string]any{
			"kind": "agent", "name": sample.Name, "username": username, "category": sample.Category,
			"usecases": sample.Usecases, "description": sample.Description, "skill": sample.Instructions,
			"provider": provider, "model": model, "sample": sample.Slug,
		},
	})
	if _, e = s.editAction(ctx, &api.ActionRequest{Caller: req.Caller, Body: body}); e != nil {
		return undo(e)
	}
	var listing map[string]any
	if e = bridge.Invoke(ctx, s.K, "market", "Publish", []any{ctx, owner, rec.ID, "agent", sample.Name, sample.Description, s.pricing(ctx).AgentPerMinute, sample.Category, ""}, &listing); e != nil {
		return undo(e)
	}
	usernames[username] = true
	return nil
}
