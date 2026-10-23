package surface

import "testing"

func TestGateCompositionRequiresCompactAndKPIs(t *testing.T) {
	comps := []map[string]any{
		{"id": "root", "type": "Column", "children": []any{"header", "body"}},
		{"id": "header", "type": "Text", "text": "Demo", "variant": "h4"},
		{"id": "body", "type": "Scroll", "weight": 1, "children": []any{"chart", "t1", "t2", "t3"}},
		{"id": "chart", "component": "Chart", "type": "line", "data": map[string]any{"path": "/rows"}, "x": "x", "series": []any{map[string]any{"field": "y"}}},
		{"id": "t1", "type": "Text", "text": "One"},
		{"id": "t2", "type": "Text", "text": "Two"},
		{"id": "t3", "type": "Text", "text": "Three"},
	}
	s := Inspect(comps)
	GateComposition(s, "layout: \"app\" visualization-first dashboard")
	codes := map[string]bool{}
	for _, i := range s.Issues {
		if i.Severity == Blocking && i.Code != "" {
			codes[i.Code] = true
		}
	}
	for _, want := range []string{"missing_compact", "missing_kpi_strip"} {
		if !codes[want] {
			t.Fatalf("expected blocking %s; codes=%v issues=%v", want, codes, s.Issues)
		}
	}
}

func TestFingerprintStable(t *testing.T) {
	a := []Issue{{Severity: Blocking, Code: "a", Problem: "x"}, {Severity: Advice, Code: "b", Problem: "y"}}
	b := []Issue{{Severity: Blocking, Code: "a", Problem: "x"}}
	if FingerprintIssues(a) != FingerprintIssues(b) {
		t.Fatal("advice must not affect fingerprint")
	}
}

func TestExpandAnalyticsHasRootAndCompact(t *testing.T) {
	_, comps, data, actions, layout, err := ExpandArchetype(ArchetypeAnalyticsConsole, ArchetypeSlots{
		Title: "Weather", DataPath: "/report", Microtool: "weather_report",
		Args: map[string]any{"city": "London"},
		KPIs: []KPISlot{{Label: "Temp", Field: "current/temperature", Format: "number:1"}},
		HeroArray: "hours", HeroX: "hour", HeroY: "temperature",
		TableArray: "days", SearchPath: "/form/city", SearchEvent: "search",
	})
	if err != nil {
		t.Fatal(err)
	}
	if layout != "app" {
		t.Fatalf("layout %s", layout)
	}
	if len(data) != 1 || data[0]["microtool"] != "weather_report" {
		t.Fatalf("data %+v", data)
	}
	if actions["search"] == nil {
		t.Fatal("missing search action")
	}
	ids := map[string]bool{}
	for _, c := range comps {
		ids[c["id"].(string)] = true
	}
	for _, id := range []string{"root", "body", "kpi_grid", "hero", "evidence", "compact"} {
		if !ids[id] {
			t.Fatalf("missing %s", id)
		}
	}
	if err := Check(comps); err != nil {
		t.Fatal(err)
	}
	s := Inspect(comps)
	GateComposition(s, "archetype: analytics_console")
	for _, i := range s.Issues {
		if i.Severity == Blocking {
			t.Fatalf("blocking on expanded archetype: %v", i)
		}
		if i.Code == "missing_states" || i.Code == "missing_error_callout" {
			t.Fatalf("analytics_console should ship states/callout: %v", i)
		}
	}
	for _, id := range []string{"error_callout", "loading_skel", "empty_state", "ready_show"} {
		if !ids[id] {
			t.Fatalf("missing state chrome %s", id)
		}
	}
}

func TestParseSkillArchetypeAndFence(t *testing.T) {
	c := ParseSkill("archetype: form_workbench\ntitle: Signup\n\n```surface\n{\"title\":\"X\",\"components\":[{\"id\":\"root\",\"type\":\"Text\",\"text\":\"Hi\"}]}\n```\n")
	if c.Archetype != "form_workbench" || c.Title != "Signup" || c.Surface == nil {
		t.Fatalf("%+v", c)
	}
}

func TestParseSkillArgsAndSlotsFrontmatter(t *testing.T) {
	c := ParseSkill("archetype: analytics_console\nargs: {\"city\": \"Lisbon\"}\nslots: {\"hero_array\": \"hours\", \"strip_value\": \"temperature\", \"kpis\": [{\"label\": \"Temp\", \"field\": \"current/temperature\", \"format\": \"number:1\"}]}\n")
	if city, _ := c.Args["city"].(string); city != "Lisbon" {
		t.Fatalf("frontmatter args: %+v", c.Args)
	}
	if c.Slots.HeroArray != "hours" || c.Slots.StripValue != "temperature" || len(c.Slots.KPIs) != 1 {
		t.Fatalf("slots: %+v", c.Slots)
	}
	// Prose alone never implies Fixed Schema / weather slots.
	c = ParseSkill("Build an analytics dashboard with KPI tiles. visualization-first.\n")
	if c.Archetype != "" || c.Slots.HeroArray != "" {
		t.Fatalf("prose must not infer fixed schema: %+v", c)
	}
}
