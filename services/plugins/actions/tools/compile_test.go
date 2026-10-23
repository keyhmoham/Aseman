package tools

import (
	"testing"

	"github.com/aseman/aseman/pkg/surface"
)

func TestCompileWeatherSkillToArchetype(t *testing.T) {
	skill := `archetype: analytics_console
title: Weather
data_path: /report
microtool: weather_report
args: {"city": "London"}
slots: {"kpis":[{"label":"Temperature","field":"current/temperature","format":"number:1"},{"label":"Humidity","field":"current/humidity","format":"integer"},{"label":"Wind","field":"current/wind_speed","format":"number:1"}],"hero_array":"hours","hero_x":"label","hero_y":"temperature","hero_label":"Next hours","hero_type":"area","strip_array":"hours","strip_label":"label","strip_value":"temperature","gauge_field":"today/uv_index","gauge_label":"UV","gauge_max":11,"table_array":"days","table_columns":[{"field":"label","label":"Day"},{"field":"high","label":"High","format":"number:0"}],"search_path":"/form/city","search_event":"search","search_label":"Show","toggles":{"metric":"°C","imperial":"°F"}}

A professional weather console.
`
	commands := []map[string]any{
		{"name": "weather_report", "description": "Full report", "schema": map[string]any{
			"properties": map[string]any{"city": map[string]any{"type": "string"}}, "required": []any{"city"},
		}},
	}
	tpl, err := compileFromSkill(skill, commands)
	if err != nil {
		t.Fatal(err)
	}
	if tpl == nil {
		t.Fatal("expected fixed schema template")
	}
	if tpl.Title != "Weather" {
		t.Fatalf("title %q", tpl.Title)
	}
	if len(tpl.Data) != 1 || tpl.Data[0].Args["city"] != "London" {
		t.Fatalf("data %+v", tpl.Data)
	}
	microtools := map[string]bool{"weather_report": true}
	issues := gateTemplate(tpl, skill, microtools)
	for _, i := range issues {
		if i.Severity == surface.Blocking {
			t.Fatalf("gate blocking: %v\nall=%v", i, issues)
		}
	}
}

func TestCompileEmbeddedSurface(t *testing.T) {
	skill := "```surface\n{\"title\":\"Hi\",\"components\":[{\"id\":\"root\",\"type\":\"Column\",\"children\":[\"body\"]},{\"id\":\"body\",\"type\":\"Scroll\",\"weight\":1,\"children\":[\"t\"]},{\"id\":\"t\",\"type\":\"Text\",\"text\":\"Hello\"},{\"id\":\"compact\",\"type\":\"Stat\",\"label\":\"Hi\",\"value\":\"1\"}]}\n```\n"
	tpl, err := compileFromSkill(skill, nil)
	if err != nil {
		t.Fatal(err)
	}
	if tpl == nil || len(tpl.Components) < 3 {
		t.Fatalf("%+v", tpl)
	}
}

func TestCompileNoMatchReturnsNil(t *testing.T) {
	tpl, err := compileFromSkill("Just show a greeting.", nil)
	if err != nil {
		t.Fatal(err)
	}
	if tpl != nil {
		t.Fatalf("expected nil for free-form skill, got %+v", tpl)
	}
}

func TestCompileDoesNotInferFromProseKeywords(t *testing.T) {
	skill := "Build an analytics dashboard with KPI tiles for contacts. visualization-first. Use list_contacts."
	tpl, err := compileFromSkill(skill, []map[string]any{
		{"name": "list_contacts", "schema": map[string]any{"type": "object"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if tpl != nil {
		t.Fatalf("prose keywords must not force Fixed Schema, got title=%q components=%d", tpl.Title, len(tpl.Components))
	}
}

func TestSlotsFromSkillUsesFrontmatterOnly(t *testing.T) {
	c := surface.ParseSkill("archetype: analytics_console\nweather console\n")
	slots := surface.SlotsFromSkill(c, "weather_report", map[string]any{"city": "London"})
	if slots.HeroArray != "" || len(slots.KPIs) != 0 {
		t.Fatalf("no slots frontmatter → no weather heuristic: %+v", slots)
	}
	c = surface.ParseSkill(`archetype: analytics_console
slots: {"hero_array":"hours","kpis":[{"label":"Temp","field":"current/temperature","format":"number:1"}]}
`)
	slots = surface.SlotsFromSkill(c, "weather_report", nil)
	if slots.HeroArray != "hours" || len(slots.KPIs) != 1 {
		t.Fatalf("%+v", slots)
	}
}
