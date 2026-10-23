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
	// Slots are optional archetype fill-ins from a `slots: {...}` line.
	Slots ArchetypeSlots
	// Raw is the original skill text.
	Raw string
}

var (
	archetypeLine = regexp.MustCompile(`(?im)^(?:archetype|surface\.archetype)\s*[:=]\s*([a-z0-9_]+)`)
	titleLine     = regexp.MustCompile(`(?im)^(?:title|surface\.title)\s*[:=]\s*(.+)$`)
	dataPathLine  = regexp.MustCompile(`(?im)^(?:data_path|surface\.data_path)\s*[:=]\s*(/\S+)`)
	microLine     = regexp.MustCompile(`(?im)^(?:microtool|surface\.microtool)\s*[:=]\s*([a-zA-Z0-9_]+)`)
	argsLine      = regexp.MustCompile(`(?im)^(?:args|surface\.args)\s*[:=]\s*(\{.+\})\s*$`)
	slotsLine     = regexp.MustCompile(`(?im)^(?:slots|surface\.slots)\s*[:=]\s*(\{.+\})\s*$`)
	surfaceFence  = regexp.MustCompile("(?s)```(?:surface|json)\\s*\n(\\{.*?\\})\n```")
)

// ParseSkill extracts a Fixed Schema contract from a frontend skill.
// Fixed Schema applies only when the skill names an archetype or embeds a
// ```surface``` fence — never from prose keywords.
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
	if m := slotsLine.FindStringSubmatch(skill); len(m) == 2 {
		c.Slots = parseSlotsJSON(m[1])
	}
	if m := surfaceFence.FindStringSubmatch(skill); len(m) == 2 {
		var raw map[string]any
		if err := json.Unmarshal([]byte(m[1]), &raw); err == nil && raw["components"] != nil {
			c.Surface = raw
		}
	}
	return c
}

// parseSlotsJSON maps a slots frontmatter object onto ArchetypeSlots.
func parseSlotsJSON(raw string) ArchetypeSlots {
	var in struct {
		KPIs []struct {
			Label  string `json:"label"`
			Field  string `json:"field"`
			Format string `json:"format"`
			Icon   string `json:"icon"`
		} `json:"kpis"`
		HeroArray    string            `json:"hero_array"`
		HeroX        string            `json:"hero_x"`
		HeroY        string            `json:"hero_y"`
		HeroLabel    string            `json:"hero_label"`
		HeroType     string            `json:"hero_type"`
		StripArray   string            `json:"strip_array"`
		StripLabel   string            `json:"strip_label"`
		StripValue   string            `json:"strip_value"`
		GaugeField   string            `json:"gauge_field"`
		GaugeLabel   string            `json:"gauge_label"`
		GaugeMax     float64           `json:"gauge_max"`
		TableArray   string            `json:"table_array"`
		TableColumns []TableCol        `json:"table_columns"`
		SearchPath   string            `json:"search_path"`
		SearchEvent  string            `json:"search_event"`
		SearchLabel  string            `json:"search_label"`
		Toggles      map[string]string `json:"toggles"`
		Caption      string            `json:"caption"`
	}
	if err := json.Unmarshal([]byte(raw), &in); err != nil {
		return ArchetypeSlots{}
	}
	out := ArchetypeSlots{
		Caption: in.Caption, HeroArray: in.HeroArray, HeroX: in.HeroX, HeroY: in.HeroY,
		HeroLabel: in.HeroLabel, HeroType: in.HeroType, StripArray: in.StripArray,
		StripLabel: in.StripLabel, StripValue: in.StripValue, GaugeField: in.GaugeField,
		GaugeLabel: in.GaugeLabel, GaugeMax: in.GaugeMax, TableArray: in.TableArray,
		TableColumns: in.TableColumns, SearchPath: in.SearchPath, SearchEvent: in.SearchEvent,
		SearchLabel: in.SearchLabel, Toggles: in.Toggles,
	}
	for _, k := range in.KPIs {
		out.KPIs = append(out.KPIs, KPISlot{Label: k.Label, Field: k.Field, Format: k.Format, Icon: k.Icon})
	}
	return out
}

// HasFixedSchema reports whether the skill embeds a ready surface or names an archetype.
func (c SkillContract) HasFixedSchema() bool {
	return c.Surface != nil || c.Archetype != ""
}
