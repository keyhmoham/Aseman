package surface

import (
	"sort"
	"strings"
)

// MaxRepairAttempts is the A2UI-toolkit-aligned cap on generate→validate→repair
// at author/compile time. Serve time never regenerates layout.
const MaxRepairAttempts = 3

// MaxWebShowAttempts caps agent web_show / proxy_create open retries for one page.
const MaxWebShowAttempts = 3

// FingerprintIssues is a stable key of blocking issue codes/problems used to
// detect non-convergence (same failures twice → stop repairing).
func FingerprintIssues(issues []Issue) string {
	var keys []string
	for _, i := range issues {
		if i.Severity != Blocking {
			continue
		}
		code := i.Code
		if code == "" {
			code = i.Area + "|" + i.Where + "|" + i.Problem
		}
		keys = append(keys, code)
	}
	sort.Strings(keys)
	return strings.Join(keys, "\n")
}

// GateComposition runs deterministic product-UI rules that used to be left to
// an LLM design judge. Call after Inspect. Skill may declare layout:"chat" to
// skip app-console rules.
func GateComposition(s *Surface, skill string) {
	if s == nil || s.small() {
		return
	}
	chat := strings.Contains(strings.ToLower(skill), `layout: "chat"`) ||
		strings.Contains(strings.ToLower(skill), "layout: chat") ||
		strings.Contains(strings.ToLower(skill), "theme.layout chat") ||
		strings.Contains(skill, "ChatCard") && !strings.Contains(strings.ToLower(skill), "layout: \"app\"")
	if chat {
		return
	}
	s.compositionApp()
}

func (s *Surface) compositionApp() {
	// Compact phone widget is required for desk app surfaces.
	if _, ok := s.byID["compact"]; !ok {
		s.issueCoded(Blocking, "design", "compact", "missing_compact",
			"there is no \"compact\" component for the phone board",
			"add one with id \"compact\", outside root's tree: the one to three numbers that matter most")
	}

	visual, prose, form, stats, charts, tables := 0, 0, 0, 0, 0, 0
	for id := range s.placed {
		c := s.byID[id]
		if c == nil {
			continue
		}
		kind := Kind(c)
		if visualKinds[kind] {
			visual++
		}
		if proseKinds[kind] {
			prose++
		}
		if inputs[kind] {
			form++
		}
		switch kind {
		case "Stat", "Quote", "Gauge", "Trend":
			stats++
		case "Chart", "Heatmap", "Treemap", "Sparkline", "Graph", "AllocationBar", "OrderBook":
			charts++
		case "Table":
			tables++
		}
	}

	// Document-like screens are blocking for app consoles (was Advice + LLM chase).
	if form < 3 {
		if visual == 0 && prose >= 3 {
			s.issueCoded(Blocking, "design", "root", "viz_density_prose",
				"the screen is mostly text with no Stats, Charts, Tables or other visual components",
				"lead with a Grid of Stats and a Chart or Table for the data; keep Text/Markdown for short labels only")
		} else if visual > 0 && prose > visual*2 && prose >= 4 {
			s.issueCoded(Blocking, "design", "root", "viz_density_prose_heavy",
				"prose components outnumber visual ones — the screen reads like a document",
				"replace walls of Text/Markdown with Stat tiles, Charts and Tables; keep captions short")
		}
	}
	if charts > 0 && stats == 0 {
		s.issueCoded(Blocking, "design", "root", "missing_kpi_strip",
			"has charts but no KPI Stat strip",
			"put 3–5 Stat tiles above the hero chart so headline numbers are readable at a glance")
	}
	if visual > 0 && stats > 0 && stats < 3 && charts+tables > 0 {
		s.issueCoded(Advice, "design", "root", "thin_kpi_strip",
			"KPI strip has fewer than 3 Stat/Quote/Gauge tiles",
			"prefer 3–5 headline Stats in a Grid (minColumnWidth 150–180)")
	}

	// Nested Card-in-Card.
	for id := range s.placed {
		c := s.byID[id]
		if c == nil || Kind(c) != "Card" {
			continue
		}
		for _, childID := range childIDs(c) {
			if ch := s.byID[childID]; ch != nil && Kind(ch) == "Card" {
				s.issueCoded(Blocking, "design", id, "nested_card",
					"Card nested inside Card",
					"use one Card or Section per block; put inner content directly in a Column/Grid")
			}
		}
	}

	s.gatePlaceholders()
	s.gateStates(visual, form)
}

func (s *Surface) gatePlaceholders() {
	for id := range s.placed {
		c := s.byID[id]
		if c == nil {
			continue
		}
		for _, key := range []string{"text", "label", "title", "placeholder"} {
			v, _ := c[key].(string)
			low := strings.ToLower(strings.TrimSpace(v))
			if low == "" {
				continue
			}
			if strings.Contains(low, "lorem") || low == "todo" || low == "placeholder" ||
				strings.HasPrefix(low, "xxx") || low == "n/a" {
				s.issueCoded(Blocking, "design", id, "placeholder_copy",
					"placeholder or filler copy \""+v+"\"",
					"use real labels from the skill or bind data with {\"path\"}")
			}
		}
	}
}

func (s *Surface) gateStates(visual, form int) {
	if visual == 0 && form == 0 {
		return
	}
	hasEmpty, hasSkeleton, hasCallout := false, false, false
	for id := range s.placed {
		switch Kind(s.byID[id]) {
		case "EmptyState":
			hasEmpty = true
		case "Skeleton", "Loading":
			hasSkeleton = true
		case "Callout":
			hasCallout = true
		}
	}
	// Advice only: many valid consoles rely on binding-empty natural blanks.
	if visual >= 3 && !hasEmpty && !hasSkeleton {
		s.issueCoded(Advice, "design", "root", "missing_states",
			"no EmptyState / Skeleton for loading or empty results",
			"add Skeleton matching final geometry and EmptyState when lists/tables can be empty")
	}
	if visual >= 3 && !hasCallout {
		s.issueCoded(Advice, "design", "root", "missing_error_callout",
			"no Callout for error presentation",
			"surface binding errors with a Callout (critical) bound to an error path when the skill needs it")
	}
}

func (s *Surface) issueCoded(severity, area, where, code, problem, fix string) {
	s.Issues = append(s.Issues, Issue{
		Severity: severity, Area: area, Where: where, Code: code, Problem: problem, Fix: fix,
	})
}

func childIDs(c map[string]any) []string {
	var out []string
	switch ch := c["children"].(type) {
	case []any:
		for _, v := range ch {
			if id, ok := v.(string); ok {
				out = append(out, id)
			}
		}
	case string:
		out = append(out, ch)
	}
	if id, ok := c["child"].(string); ok {
		out = append(out, id)
	}
	return out
}
