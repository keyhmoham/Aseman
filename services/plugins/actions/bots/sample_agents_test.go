package bots

import (
	"regexp"
	"strings"
	"testing"
)

// The samples are what an administrator lists for everyone in one click: each
// must be complete, distinct and addressable.
func TestSampleAgentsAreWellFormed(t *testing.T) {
	categories := map[string]bool{"general": true, "research": true, "coding": true, "design": true, "marketing": true, "operations": true, "finance": true, "legal": true, "education": true, "support": true}
	username := regexp.MustCompile(`^[a-z0-9_.-]{3,}$`)
	slugs, names := map[string]bool{}, map[string]bool{}
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
			t.Errorf("%s: name, description and use cases are required", a.Name)
		}
		// Instructions are part of every model call the agent makes: enough to
		// direct the work, not so much that every step pays for it.
		if words := len(strings.Fields(a.Instructions)); words < 150 || words > 500 {
			t.Errorf("%s: instructions are %d words", a.Name, words)
		}
		if !strings.Contains(a.Instructions, "What you deliver") {
			t.Errorf("%s: instructions do not say what is delivered", a.Name)
		}
	}
}
