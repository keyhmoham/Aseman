package surface

import (
	"encoding/json"
	"regexp"
	"strings"
)

// SkillContract is what a deployer skill declares for Fixed Schema / archetype
// compilation (author time). Parsed from markdown; free prose still guides the
// LLM fallback when no fixed surface is embedded.
type SkillContract struct {
	// Archetype names a vetted shell (analytics_console, form_workbench, …).
	Archetype string
	// Surface is an embedded Fixed Schema template (components/data/actions).
	Surface map[string]any
	// Title override when expanding an archetype.
	Title string
	// DataPath is the primary binding path (default /report).
	DataPath string
	// Microtool fills DataPath (default: first microtool the tool exposes).
	Microtool string
	// Args are literal default binding arguments (e.g. {"city":"London"}).
	Args map[string]any
	// Raw is the original skill text.
	Raw string
}

var (
	archetypeLine = regexp.MustCompile(`(?im)^(?:archetype|surface\.archetype)\s*[:=]\s*([a-z0-9_]+)`)
	titleLine     = regexp.MustCompile(`(?im)^(?:title|surface\.title)\s*[:=]\s*(.+)$`)
	dataPathLine  = regexp.MustCompile(`(?im)^(?:data_path|surface\.data_path)\s*[:=]\s*(/\S+)`)
	microLine     = regexp.MustCompile(`(?im)^(?:microtool|surface\.microtool)\s*[:=]\s*([a-zA-Z0-9_]+)`)
	argsLine      = regexp.MustCompile(`(?im)^(?:args|surface\.args)\s*[:=]\s*(\{.+\})\s*$`)
	// Inline JSON in prose, e.g. for `{"city": "London"}`.
	inlineArgsJSON = regexp.MustCompile(`\{[^{}]*"[a-zA-Z_][a-zA-Z0-9_]*"\s*:\s*"[^"]*"[^{}]*\}`)
	surfaceFence   = regexp.MustCompile("(?s)```(?:surface|json)\\s*\n(\\{.*?\\})\n```")
)

// ParseSkill extracts a Fixed Schema contract from a frontend skill.
func ParseSkill(skill string) SkillContract {
	c := SkillContract{Raw: skill, DataPath: "/report"}
	if m := archetypeLine.FindStringSubmatch(skill); len(m) == 2 {
		c.Archetype = strings.ToLower(strings.TrimSpace(m[1]))
	}
	if m := titleLine.FindStringSubmatch(skill); len(m) == 2 {
		c.Title = strings.TrimSpace(m[1])
	}
	if m := dataPathLine.FindStringSubmatch(skill); len(m) == 2 {
		c.DataPath = strings.TrimSpace(m[1])
	}
	if m := microLine.FindStringSubmatch(skill); len(m) == 2 {
		c.Microtool = strings.TrimSpace(m[1])
	}
	if m := argsLine.FindStringSubmatch(skill); len(m) == 2 {
		var args map[string]any
		if err := json.Unmarshal([]byte(m[1]), &args); err == nil && len(args) > 0 {
			c.Args = args
		}
	}
	if c.Args == nil {
		for _, m := range inlineArgsJSON.FindAllString(skill, -1) {
			var args map[string]any
			if err := json.Unmarshal([]byte(m), &args); err == nil && len(args) > 0 {
				c.Args = args
				break
			}
		}
	}
	if m := surfaceFence.FindStringSubmatch(skill); len(m) == 2 {
		var raw map[string]any
		if err := json.Unmarshal([]byte(m[1]), &raw); err == nil && raw["components"] != nil {
			c.Surface = raw
		}
	}
	return c
}

// HasFixedSchema reports whether the skill embeds a ready surface or names an archetype.
func (c SkillContract) HasFixedSchema() bool {
	return c.Surface != nil || c.Archetype != ""
}
