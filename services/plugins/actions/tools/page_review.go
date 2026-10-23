package tools

import (
	"context"
	"encoding/json"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/a2ui"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// pagePrompt has the model review an interactive web page an agent built
// for the space's tools (spaces/page_review.go inspects and tests it first).
var pagePrompt = `You review an interactive web page an agent built as the frontend of a tool, before it is shown, as a senior product designer and QA lead who ships real application UIs.
The page uses Aseman's web UI kit: <t-…> components with the app's props (kebab-case attributes, JSON values), call="Tool/microtool" args into on buttons, forms and <t-data>, bindings {"path": "/x"} and bind-*="/x" on the data model, <t-for each>, Aseman.call/load/on in scripts.
You are given what the page is for, the tools it calls (with their microtools), its HTML source, what its calls really returned when it was tested, and what the automatic inspection found.
Judge:
- Purpose: does it serve what was asked and the tool — right data first, actions offered, nothing it cannot do, nothing important missing? Does it feel like a real product console for this domain?
- Visualization-first: numeric/temporal/categorical/tabular data must use t-stat, t-chart, t-gauge, t-table, t-quote, t-heatmap, t-treemap, t-sparkline — not paragraphs of t-text/t-markdown. Hierarchy: KPI strip → hero chart → evidence. Text-heavy document layouts are blocking when the data is visualizable.
- App layout: an application screen, not a web page — <body class="t-app"> fills the window without scrolling as a whole; fixed header; body region weight="1" (t-scroll, t-split or t-tabs); growing content scrolls inside its region; t-split for panes (tabs on a phone). Judge at ~360 × 640 and ~1400 × 900.
- Cleanness and standards: the design rules below — structure, responsive Grids with min-column-width, no fixed widths, formatted numbers with units, short labels, one primary action per region, no placeholders, filler, heroes, footers, duplicates or decorative controls; kit components and theme variables, never hard-coded colors.
- Interaction: can a person do each thing and see the outcome (result, toast, reload)? Inputs labelled, bound and passed to the call; /x__loading and /x__error shown; empty states handled.
- Data: fields the results really have, formatted; no raw JSON or ids where people expect names.
- Code: scripts that would throw, wrong call arguments, handlers never attached.
Reply with ONE JSON object: {"issues": [{"severity": "blocking" | "advice", "area": "purpose" | "design" | "interaction" | "data", "where": "<element, path or call>", "problem": "…", "fix": "…"}]}.
"blocking" is what makes it broken, misleading, unclean, text-heavy where it should be visual, or unfit for the tool; "advice" is polish. Name concrete elements and concrete fixes. Do not repeat the automatic findings. An empty list means it is ready to show.
` + a2ui.DesignPrompt

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
	raw, _ := json.Marshal(issues)
	return string(raw), nil
}
