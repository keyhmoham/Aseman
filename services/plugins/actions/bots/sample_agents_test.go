package bots

import (
	"regexp"
	"strings"
	"testing"
)

// The samples are what an administrator lists for everyone in one click: each
// must be complete, distinct and addressable. The catalogue is the Agency
// Agents roster embedded under agencyagents/.
func TestSampleAgentsAreWellFormed(t *testing.T) {
	categories := map[string]bool{
		"general": true, "research": true, "coding": true, "design": true,
		"marketing": true, "operations": true, "finance": true, "legal": true,
		"education": true, "support": true,
	}
	username := regexp.MustCompile(`^[a-z0-9_.-]{3,}$`)
	slugs, names := map[string]bool{}, map[string]bool{}

	if len(sampleAgents) < 200 {
		t.Fatalf("expected hundreds of agency agents, got %d", len(sampleAgents))
	}

	for _, a := range sampleAgents {
		if slugs[a.Slug] || names[a.Username] {
			t.Errorf("%s: slug or username used twice", a.Name)
		}
		slugs[a.Slug], names[a.Username] = true, true
		if !username.MatchString(a.Username) || a.Username == "aseman" || a.Username == "lead" {
			t.Errorf("%s: @%s is not a usable username", a.Name, a.Username)
		}
		if !categories[a.Category] {
			t.Errorf("%s: unknown category %q", a.Name, a.Category)
		}
		if a.Name == "" || len(a.Description) < 40 || len(a.Usecases) < 3 {
			t.Errorf("%s: name, description and use cases are required (desc=%d usecases=%d)",
				a.Name, len(a.Description), len(a.Usecases))
		}
		// Persona instructions must be enough to direct the agent; the heavy
		// methodology lives in skills so each model call stays lean.
		if words := len(strings.Fields(a.Instructions)); words < 40 {
			t.Errorf("%s: instructions are only %d words", a.Name, words)
		}
		if len(a.Skills) == 0 {
			t.Errorf("%s: expected at least one skill from operational sections", a.Name)
		}
		for _, sk := range a.Skills {
			if strings.TrimSpace(sk.Name) == "" || strings.TrimSpace(sk.Instructions) == "" {
				t.Errorf("%s: skill %#v is incomplete", a.Name, sk.Name)
			}
		}
	}
}

func TestAgencyAgentParseSplitsSoulAndSkills(t *testing.T) {
	raw := "---\nname: Example Specialist\ndescription: Expert example agent specializing in demos, parsing checks and catalogue imports for the sample roster\nvibe: Ships clear demos.\ncolor: cyan\n---\n\nYou are **Example Specialist**, a careful parser.\n\n## Identity & Memory\n- Role: parser\n- Personality: precise\n\n## Core Mission\n### Build demos\n- Produce working examples\n### Check parsing\n- Catch edge cases\n\n## Workflow Process\n1. Read the brief\n2. Deliver the file\n\n## Communication Style\n- Be brief\n"
	got, ok := parseAgencyAgent("agencyagents/engineering/example.md", raw)
	if !ok {
		t.Fatal("parse failed")
	}
	if got.Slug != "example-specialist" || got.Category != "coding" {
		t.Fatalf("slug/category: %s %s", got.Slug, got.Category)
	}
	if !strings.Contains(got.Instructions, "Identity") || !strings.Contains(got.Instructions, "Communication") {
		t.Fatalf("soul sections missing from instructions: %q", got.Instructions)
	}
	if strings.Contains(got.Instructions, "## Core Mission") {
		t.Fatalf("ops section leaked into instructions")
	}
	if len(got.Skills) < 2 {
		t.Fatalf("expected mission+workflow skills, got %#v", got.Skills)
	}
	if len(got.Usecases) < 3 {
		t.Fatalf("usecases: %#v", got.Usecases)
	}
}
