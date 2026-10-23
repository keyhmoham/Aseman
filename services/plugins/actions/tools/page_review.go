package tools

import (
	"context"
	"encoding/json"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/surface"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// pagePrompt has the model review an interactive web page an agent built
// for the space's tools (spaces/page_review.go inspects and tests it first).
var pagePrompt = `You add optional polish notes for a web kit page that already passed a deterministic inspect + live-call gate.
Do NOT restate automatic findings. Reply with ONE JSON object:
{"issues": [{"severity": "advice", "area": "purpose" | "design" | "interaction" | "data", "where": "<element>", "problem": "…", "fix": "…"}]}.
Every issue MUST be severity "advice". Empty list is fine.
` + surface.DesignPrompt

// ReviewPage has the model look at a web page an agent built (described in
// [brief]: its purpose, the tools it calls, its source, what its calls
// returned, what the inspection found) and returns the issues it reports
// (JSON). [payer] is billed for the model, as a call of the tool [botID].
func (s *Service) ReviewPage(ctx context.Context, payer, space, room, botID, brief string) (string, error) {
	payerID, err := identity.Parse(payer)
	if err != nil {
		return "", errs.InvalidArgument("invalid payer")
	}
	var provider vmm.ProviderConfig
	if err := bridge.Invoke(ctx, s.K, "llm", "ResolveChat", []any{ctx, "", ""}, &provider); err != nil {
		return "", errs.New(errs.CodeUnavailable, "no model is configured to review pages: "+err.Error())
	}
	rec, err := s.bot(ctx, botID)
	if err != nil {
		return "", err
	}
	if err := bridge.Invoke(ctx, s.K, "bots", "EnsureFunds", []any{ctx, payerID, rec.ID}); err != nil {
		return "", err
	}
	content, in, out, err := s.complete(ctx, provider, []map[string]any{{"role": "system", "content": pagePrompt}, {"role": "user", "content": brief}})
	s.billGeneration(ctx, caller{Caller: api.Caller{ID: payerID}, Space: space, Room: room}, rec.ID, in, out)
	if err != nil {
		return "", err
	}
	issues, err := lookedAt(content)
	if err != nil {
		return "", err
	}
	for i := range issues {
		issues[i].Severity = surface.Advice
		if issues[i].Code == "" {
			issues[i].Code = "design_note"
		}
	}
	raw, _ := json.Marshal(issues)
	return string(raw), nil
}
