package tools

import (
	"strings"
	"testing"

	"github.com/aseman/aseman/pkg/surface"
)

func TestCompileWeatherSkillToArchetype(t *testing.T) {
	skill := `archetype: analytics_console
title: Weather
data_path: /report
microtool: weather_report

A professional weather console visualization-first with Stat tiles and hero chart.
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

func TestParseSkillWeatherDefaults(t *testing.T) {
	c := surface.ParseSkill("archetype: analytics_console\nweather console\n")
	slots := surface.SlotsFromSkill(c, "weather_report", map[string]any{"city": "London"})
	if slots.HeroArray != "hours" || !strings.Contains(slots.KPIs[0].Field, "temperature") {
		t.Fatalf("%+v", slots)
	}
}
