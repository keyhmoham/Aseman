package tools

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/surface"
	"github.com/aseman/aseman/plugins/actions/tools/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// compileFromSkill builds a Surface Template without a serve-time generation
// loop when the skill carries Fixed Schema (embedded surface) or an archetype.
// Returns (nil, nil) when the skill needs LLM fallback.
func compileFromSkill(skill string, commands []map[string]any) (*Template, error) {
	contract := surface.ParseSkill(skill)
	if contract.Surface != nil {
		t, err := templateOf(contract.Surface)
		if err != nil {
			return nil, errs.InvalidArgument("skill embedded surface: " + err.Error())
		}
		t.Layout = AppLayout
		if t.Title == "" && contract.Title != "" {
			t.Title = contract.Title
		}
		return &t, nil
	}
	// Fixed Schema only when the skill explicitly names an archetype — never
	// from prose keywords (that hijacked unrelated tools into weather-shaped consoles).
	if contract.Archetype == "" {
		return nil, nil
	}
	defaultMicro := firstMicrotool(commands)
	args := map[string]any{}
	for k, v := range contract.Args {
		args[k] = v
	}
	slots := surface.SlotsFromSkill(contract, defaultMicro, args)
	title, comps, data, actions, layout, err := surface.ExpandArchetype(contract.Archetype, slots)
	if err != nil {
		return nil, errs.InvalidArgument(err.Error())
	}
	raw := map[string]any{
		"title":      title,
		"components": comps,
		"data":       data,
		"actions":    actions,
		"layout":     layout,
	}
	t, err := templateOf(raw)
	if err != nil {
		return nil, err
	}
	if layout != "" {
		t.Layout = layout
	} else {
		t.Layout = AppLayout
	}
	return &t, nil
}

func firstMicrotool(commands []map[string]any) string {
	for _, cmd := range commands {
		if name, _ := cmd["name"].(string); name != "" {
			return name
		}
	}
	return ""
}

// gateTemplate runs deterministic catalog + composition checks (no LLM).
func gateTemplate(t *Template, skill string, microtools map[string]bool) []surface.Issue {
	var issues []surface.Issue
	if err := t.validate(microtools); err != nil {
		return []surface.Issue{{
			Severity: surface.Blocking, Area: "structure", Code: "invalid_template",
			Problem: err.Error(), Fix: "repair the template JSON",
		}}
	}
	if err := t.checkEvents(); err != nil {
		issues = append(issues, surface.Issue{
			Severity: surface.Blocking, Area: "interaction", Code: "dead_events",
			Problem: err.Error(), Fix: "map every sent event in \"actions\"",
		})
	}
	issues = append(issues, surface.ValidateProps(t.Components)...)
	inspected := surface.Inspect(t.Components)
	surface.GateComposition(inspected, skill)
	issues = append(issues, inspected.Issues...)
	seen := map[string]bool{}
	out := make([]surface.Issue, 0, len(issues))
	for _, i := range issues {
		key := i.Code + "|" + i.Where + "|" + i.Problem
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, i)
	}
	return out
}

// blockingCount counts blocking issues.
func blockingCount(issues []surface.Issue) int {
	n := 0
	for _, i := range issues {
		if i.Severity == surface.Blocking {
			n++
		}
	}
	return n
}

// mustJSON is a tiny helper for tests / diagnostics.
func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// eagerCompileAndStore compiles a Fixed Schema / archetype Surface Bundle at
// tool_create / tool_update and writes it into tool_components so the first
// frontend_get is bind-only. Skills that need LLM fallback are skipped (nil).
// Structural gate failures fail the deploy so bad skills never ship.
func (s *Service) eagerCompileAndStore(ctx context.Context, tool *models.Tool, spec models.FrontendSpec, skill string, commands []map[string]any) error {
	if spec.Mode != models.FrontendGenerative || !spec.Cached() {
		return nil
	}
	fixed, err := compileFromSkill(skill, commands)
	if err != nil {
		return err
	}
	if fixed == nil {
		// Skill is free-form (LLM at serve time): drop any leftover Fixed Schema
		// rows from an earlier mistaken compile.
		s.pruneStaleComponents(ctx, tool.BotID, "")
		return nil
	}
	microtools := map[string]bool{}
	for _, cmd := range commands {
		if name, _ := cmd["name"].(string); name != "" {
			microtools[name] = true
		}
	}
	issues := gateTemplate(fixed, skill, microtools)
	if n := blockingCount(issues); n > 0 {
		var parts []string
		for _, i := range issues {
			if i.Severity == surface.Blocking {
				parts = append(parts, i.String())
				if len(parts) >= 5 {
					break
				}
			}
		}
		return errs.InvalidArgument("frontend Fixed Schema failed the gate: " + strings.Join(parts, "; "))
	}
	fixed.Layout = AppLayout
	fixed.Review = &Review{Passed: true, Rounds: 1, Issues: issues}
	raw, _ := json.Marshal(fixed)
	key := componentKey(spec, commands)
	id := s.key("component/" + tool.BotID + "/" + key)
	now := time.Now().UTC()
	row := models.Component{
		ID: id, BotID: tool.BotID, Key: key, Template: string(raw),
		Model: "fixed-schema", Uses: 0, CreatedAt: now, UpdatedAt: now,
	}
	if err := s.R.CreateID(ctx, "tool_components", identity.MustParse(id), &row); errs.CodeOf(err) == errs.CodeAlreadyExists {
		err = s.R.UpdateString(ctx, "tool_components", id, &row)
		if err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	s.pruneStaleComponents(ctx, tool.BotID, id)
	return nil
}

// pruneStaleComponents drops Surface Bundles for the tool other than keepID.
// When keepID is empty, every row is removed (skill left Fixed Schema).
func (s *Service) pruneStaleComponents(ctx context.Context, botID, keepID string) {
	var rows []models.Component
	if err := s.R.List(ctx, "tool_components", database.Filter{
		Equal: map[string]any{"bot_id": botID},
	}, &rows); err != nil {
		return
	}
	for i := range rows {
		if keepID != "" && rows[i].ID == keepID {
			continue
		}
		if id, err := identity.Parse(rows[i].ID); err == nil {
			_ = s.R.Delete(ctx, "tool_components", id)
		}
	}
}
