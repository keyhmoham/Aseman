package surface

import (
	"fmt"
	"strings"
)

// Known archetypes for Planner → deterministic renderer (Portal UX / Fixed Schema).
const (
	ArchetypeAnalyticsConsole = "analytics_console"
	ArchetypeFormWorkbench    = "form_workbench"
	ArchetypeEntityDetail     = "entity_detail"
	ArchetypeChatCard         = "chat_card"
)

// ArchetypeSlots fills a vetted shell. Paths are JSON pointers into the data model.
type ArchetypeSlots struct {
	Title     string
	Caption   string // bound or literal caption under the title
	DataPath  string // primary object path, e.g. /report
	Microtool string
	// Args for the primary data binding (literals only).
	Args map[string]any
	// KPI: up to 5 {Label, Field, Format} relative to DataPath.
	KPIs []KPISlot
	// Hero chart over an array path relative to DataPath (e.g. hours).
	HeroArray  string
	HeroX      string
	HeroY      string
	HeroLabel  string
	HeroType   string // area|line|bar
	// Evidence table over an array path relative to DataPath.
	TableArray   string
	TableColumns []TableCol
	// Optional horizontal strip (List) over an array path.
	StripArray string
	StripLabel string // field shown on each chip (caption)
	StripValue string // field shown on each chip (body); default "value"
	// Optional Gauge bound relative to DataPath.
	GaugeField string
	GaugeLabel string
	GaugeMax   float64
	// Search field + primary action (optional).
	SearchPath  string // e.g. /form/city
	SearchEvent string
	SearchLabel string
	// Extra unit/toggle actions: name → button label.
	Toggles map[string]string
}

// KPISlot is one Stat in the KPI strip.
type KPISlot struct {
	Label  string
	Field  string // relative to DataPath, e.g. current/temperature
	Format string
	Icon   string
}

// TableCol is one evidence column.
type TableCol struct {
	Field  string
	Label  string
	Format string
	Type   string
}

// ExpandArchetype builds a flat Surface Spec component list + data/actions maps
// from a vetted shell. Returns components, data bindings, actions, layout.
func ExpandArchetype(name string, slots ArchetypeSlots) (title string, components []map[string]any, data []map[string]any, actions map[string]any, layout string, err error) {
	name = strings.ToLower(strings.TrimSpace(name))
	if slots.DataPath == "" {
		slots.DataPath = "/report"
	}
	if slots.Title == "" {
		slots.Title = "Console"
	}
	if slots.HeroType == "" {
		slots.HeroType = "area"
	}
	switch name {
	case ArchetypeAnalyticsConsole, "analytics", "dashboard":
		return expandAnalytics(slots)
	case ArchetypeFormWorkbench, "form":
		return expandForm(slots)
	case ArchetypeEntityDetail, "detail":
		return expandDetail(slots)
	case ArchetypeChatCard, "chat":
		return expandChat(slots)
	default:
		return "", nil, nil, nil, "", fmt.Errorf("unknown archetype %q; use %s, %s, %s or %s",
			name, ArchetypeAnalyticsConsole, ArchetypeFormWorkbench, ArchetypeEntityDetail, ArchetypeChatCard)
	}
}

func expandAnalytics(s ArchetypeSlots) (string, []map[string]any, []map[string]any, map[string]any, string, error) {
	rootKids := []any{"header", "body"}
	comps := []map[string]any{
		{"id": "root", "type": "Column", "children": rootKids},
		{"id": "header", "type": "Row", "justify": "spaceBetween", "align": "center", "children": []any{"header_text", "header_actions"}},
		{"id": "header_text", "type": "Column", "children": []any{"title", "caption"}},
		{"id": "title", "type": "Text", "text": s.Title, "variant": "h4"},
	}
	if s.Caption != "" {
		comps = append(comps, map[string]any{"id": "caption", "type": "Text", "text": s.Caption, "variant": "caption"})
	} else {
		comps = append(comps, map[string]any{"id": "caption", "type": "Text", "text": pathRef(joinPtr(s.DataPath, "updated")), "variant": "caption"})
	}

	actionKids := []any{}
	actions := map[string]any{}
	if s.SearchPath != "" {
		event := s.SearchEvent
		if event == "" {
			event = "search"
		}
		label := s.SearchLabel
		if label == "" {
			label = "Show"
		}
		comps = append(comps,
			map[string]any{"id": "search_field", "type": "SearchField", "value": map[string]any{"path": s.SearchPath}, "placeholder": "Search"},
			map[string]any{"id": "search_btn", "type": "Button", "variant": "primary", "child": "search_btn_t",
				"action": map[string]any{"event": map[string]any{"name": event}}},
			map[string]any{"id": "search_btn_t", "type": "Text", "text": label},
		)
		actionKids = append(actionKids, "search_field", "search_btn")
		args := map[string]any{}
		for k, v := range s.Args {
			args[k] = v
		}
		// Prefer form field as $data when search path is under /form.
		if strings.HasPrefix(s.SearchPath, "/form/") {
			field := strings.TrimPrefix(s.SearchPath, "/form/")
			args[field] = map[string]any{"$data": s.SearchPath}
		}
		if s.Microtool != "" {
			actions[event] = map[string]any{"microtool": s.Microtool, "args": args, "result": s.DataPath}
		}
	}
	for ev, label := range s.Toggles {
		tid, lid := "toggle_"+ev, "toggle_"+ev+"_t"
		comps = append(comps,
			map[string]any{"id": tid, "type": "Button", "variant": "borderless", "child": lid,
				"action": map[string]any{"event": map[string]any{"name": ev}}},
			map[string]any{"id": lid, "type": "Text", "text": label},
		)
		actionKids = append(actionKids, tid)
		if s.Microtool != "" {
			args := map[string]any{}
			for k, v := range s.Args {
				args[k] = v
			}
			actions[ev] = map[string]any{"microtool": s.Microtool, "args": args, "result": s.DataPath}
		}
	}
	if len(actionKids) == 0 {
		comps = append(comps, map[string]any{"id": "header_actions", "type": "Spacer", "size": 1})
	} else {
		comps = append(comps, map[string]any{"id": "header_actions", "type": "Wrap", "spacing": 8, "children": actionKids})
	}

	bodyKids := []any{}
	kpis := s.KPIs
	if len(kpis) == 0 {
		kpis = []KPISlot{
			{Label: "Value", Field: "value", Format: "number:1"},
			{Label: "Change", Field: "change", Format: "+percent:1"},
			{Label: "Count", Field: "count", Format: "integer"},
		}
	}
	statIDs := []any{}
	for i, k := range kpis {
		if i >= 5 {
			break
		}
		id := fmt.Sprintf("kpi_%d", i)
		statIDs = append(statIDs, id)
		st := map[string]any{
			"id": id, "type": "Stat", "label": k.Label,
			"value": pathRef(joinPtr(s.DataPath, k.Field)),
		}
		if k.Format != "" {
			st["format"] = k.Format
		}
		if k.Icon != "" {
			st["icon"] = k.Icon
		}
		comps = append(comps, st)
	}
	comps = append(comps, map[string]any{"id": "kpi_grid", "type": "Grid", "minColumnWidth": 150, "gap": 12, "children": statIDs})
	bodyKids = append(bodyKids, "kpi_grid")

	if s.GaugeField != "" {
		gmax := s.GaugeMax
		if gmax == 0 {
			gmax = 11
		}
		label := s.GaugeLabel
		if label == "" {
			label = "Score"
		}
		comps = append(comps, map[string]any{
			"id": "gauge", "type": "Gauge", "label": label, "min": 0, "max": gmax,
			"value": pathRef(joinPtr(s.DataPath, s.GaugeField)),
		})
		bodyKids = append(bodyKids, "gauge")
	}

	if s.HeroArray != "" {
		seriesField := s.HeroY
		if seriesField == "" {
			seriesField = "value"
		}
		xField := s.HeroX
		if xField == "" {
			xField = "label"
		}
		heroTitle := s.HeroLabel
		if heroTitle == "" {
			heroTitle = "Trend"
		}
		comps = append(comps, map[string]any{
			"id": "hero", "component": "Chart", "type": s.HeroType,
			"title": heroTitle, "height": 260,
			"data":   pathRef(joinPtr(s.DataPath, s.HeroArray)),
			"x":      xField,
			"series": []any{map[string]any{"field": seriesField, "label": heroTitle}},
		})
		bodyKids = append(bodyKids, "hero")
	}

	if s.StripArray != "" {
		field := s.StripLabel
		if field == "" {
			field = "label"
		}
		valueField := s.StripValue
		if valueField == "" {
			valueField = "value"
		}
		comps = append(comps,
			map[string]any{"id": "strip", "type": "List", "direction": "horizontal",
				"children": map[string]any{"componentId": "strip_item", "path": joinPtr(s.DataPath, s.StripArray)}},
			map[string]any{"id": "strip_item", "type": "Card", "child": "strip_row"},
			map[string]any{"id": "strip_row", "type": "Column", "children": []any{"strip_label", "strip_value"}},
			map[string]any{"id": "strip_label", "type": "Text", "text": pathRef(field), "variant": "caption"},
			map[string]any{"id": "strip_value", "type": "Text", "text": pathRef(valueField), "variant": "body"},
		)
		bodyKids = append(bodyKids, "strip")
	}

	if s.TableArray != "" {
		cols := s.TableColumns
		if len(cols) == 0 {
			cols = []TableCol{{Field: "label", Label: "Name"}, {Field: "value", Label: "Value", Format: "number:1"}}
		}
		var colAny []any
		for _, c := range cols {
			m := map[string]any{"field": c.Field, "label": c.Label}
			if c.Format != "" {
				m["format"] = c.Format
			}
			if c.Type != "" {
				m["type"] = c.Type
			}
			colAny = append(colAny, m)
		}
		comps = append(comps, map[string]any{
			"id": "evidence", "type": "Table", "dense": true,
			"data": pathRef(joinPtr(s.DataPath, s.TableArray)), "columns": colAny,
		})
		bodyKids = append(bodyKids, "evidence")
	}

	// Loading / empty / error chrome (must be placed so GateComposition sees them).
	errPath := joinPtr(s.DataPath, "error")
	comps = append(comps,
		map[string]any{"id": "error_callout", "type": "Callout", "severity": "critical",
			"title": "Could not load", "text": pathRef(errPath)},
		map[string]any{"id": "error_show", "type": "Show",
			"when": map[string]any{
				"call": "not",
				"args": map[string]any{
					"value": map[string]any{
						"call": "isEmpty",
						"args": map[string]any{"value": pathRef(errPath)},
					},
				},
			},
			"child": "error_callout"},
		map[string]any{"id": "loading_skel", "type": "Skeleton", "variant": "chart"},
		map[string]any{"id": "empty_state", "type": "EmptyState", "icon": "cloud",
			"title": "Nothing to show", "text": "Search to load results."},
		map[string]any{"id": "empty_column", "type": "Column", "gap": 12,
			"children": []any{"loading_skel", "empty_state"}},
		map[string]any{"id": "content", "type": "Column", "children": bodyKids},
		map[string]any{"id": "ready_show", "type": "Show",
			"when": map[string]any{
				"call": "isEmpty",
				"args": map[string]any{"value": pathRef(s.DataPath)},
			},
			"child": "empty_column", "fallback": "content"},
	)
	comps = append(comps,
		map[string]any{"id": "body", "type": "Scroll", "weight": 1,
			"children": []any{"error_show", "ready_show"}},
	)
	// Compact: first KPI.
	if len(kpis) > 0 {
		comps = append(comps, map[string]any{
			"id": "compact", "type": "Stat", "label": kpis[0].Label,
			"value": pathRef(joinPtr(s.DataPath, kpis[0].Field)), "format": kpis[0].Format,
		})
	}

	var data []map[string]any
	if s.Microtool != "" {
		bind := map[string]any{"path": s.DataPath, "microtool": s.Microtool}
		if len(s.Args) > 0 {
			bind["args"] = s.Args
		}
		data = append(data, bind)
	}
	return s.Title, comps, data, actions, "app", nil
}

func expandForm(s ArchetypeSlots) (string, []map[string]any, []map[string]any, map[string]any, string, error) {
	comps := []map[string]any{
		{"id": "root", "type": "Column", "children": []any{"header", "body"}},
		{"id": "header", "type": "Column", "children": []any{"title"}},
		{"id": "title", "type": "Text", "text": s.Title, "variant": "h4"},
		{"id": "body", "type": "Scroll", "weight": 1, "children": []any{"form_block", "submit"}},
		{"id": "form_block", "type": "Section", "title": "Details", "children": []any{"field_a"}},
		{"id": "field_a", "type": "TextField", "label": "Value", "value": map[string]any{"path": "/form/value"}},
		{"id": "submit", "type": "Button", "variant": "primary", "child": "submit_t",
			"action": map[string]any{"event": map[string]any{"name": "submit"}}},
		{"id": "submit_t", "type": "Text", "text": "Submit"},
		{"id": "compact", "type": "Stat", "label": s.Title, "value": pathRef(joinPtr(s.DataPath, "value"))},
	}
	actions := map[string]any{}
	if s.Microtool != "" {
		actions["submit"] = map[string]any{
			"microtool": s.Microtool,
			"args":      map[string]any{"value": map[string]any{"$data": "/form/value"}},
			"result":    s.DataPath,
		}
	}
	var data []map[string]any
	if s.Microtool != "" {
		data = []map[string]any{{"path": s.DataPath, "microtool": s.Microtool, "args": s.Args}}
	}
	return s.Title, comps, data, actions, "app", nil
}

func expandDetail(s ArchetypeSlots) (string, []map[string]any, []map[string]any, map[string]any, string, error) {
	comps := []map[string]any{
		{"id": "root", "type": "Column", "children": []any{"header", "body"}},
		{"id": "header", "type": "Column", "children": []any{"title"}},
		{"id": "title", "type": "Text", "text": s.Title, "variant": "h4"},
		{"id": "body", "type": "Scroll", "weight": 1, "children": []any{"kv"}},
		{"id": "kv", "type": "KeyValue", "data": pathRef(s.DataPath)},
		{"id": "compact", "type": "Stat", "label": s.Title, "value": pathRef(joinPtr(s.DataPath, "name"))},
	}
	var data []map[string]any
	if s.Microtool != "" {
		data = []map[string]any{{"path": s.DataPath, "microtool": s.Microtool, "args": s.Args}}
	}
	return s.Title, comps, data, nil, "app", nil
}

func expandChat(s ArchetypeSlots) (string, []map[string]any, []map[string]any, map[string]any, string, error) {
	comps := []map[string]any{
		{"id": "root", "type": "ChatCard", "child": "panel"},
		{"id": "panel", "type": "Column", "children": []any{"title", "body"}},
		{"id": "title", "type": "Text", "text": s.Title, "variant": "h5"},
		{"id": "body", "type": "Text", "text": pathRef(joinPtr(s.DataPath, "summary")), "variant": "body"},
	}
	var data []map[string]any
	if s.Microtool != "" {
		data = []map[string]any{{"path": s.DataPath, "microtool": s.Microtool, "args": s.Args}}
	}
	return s.Title, comps, data, nil, "chat", nil
}

func pathRef(p string) map[string]any { return map[string]any{"path": p} }

func joinPtr(base, rel string) string {
	rel = strings.TrimSpace(rel)
	if rel == "" {
		return base
	}
	if strings.HasPrefix(rel, "/") {
		return rel
	}
	return strings.TrimRight(base, "/") + "/" + strings.TrimLeft(rel, "/")
}

// SlotsFromSkill builds archetype slots from a skill contract only — no
// domain heuristics (weather or otherwise). Deployers declare layout in
// archetype + slots frontmatter (or an embedded ```surface``` fence).
func SlotsFromSkill(c SkillContract, defaultMicro string, defaultArgs map[string]any) ArchetypeSlots {
	slots := c.Slots
	if slots.Title == "" {
		slots.Title = c.Title
	}
	if slots.DataPath == "" {
		slots.DataPath = c.DataPath
	}
	if slots.Microtool == "" {
		slots.Microtool = c.Microtool
	}
	if len(slots.Args) == 0 {
		slots.Args = defaultArgs
	}
	if slots.Title == "" {
		slots.Title = "Console"
	}
	if slots.Microtool == "" {
		slots.Microtool = defaultMicro
	}
	return slots
}
