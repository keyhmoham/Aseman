package surface

import (
	"fmt"
	"strings"
)

// ComponentSchema is a lightweight A2UI-style catalog entry: required props and
// allowed prop names. Unknown props are Advice (models invent extras); missing
// required props are Blocking.
type ComponentSchema struct {
	Required []string
	Optional []string
}

// CatalogSchemas is the Aseman Surface Spec prop contract used at author time.
var CatalogSchemas = map[string]ComponentSchema{
	"Text":        {Required: []string{"text"}, Optional: []string{"variant", "color", "align", "maxLines"}},
	"Markdown":    {Required: []string{"text"}},
	"Image":       {Required: []string{"url"}, Optional: []string{"fit", "variant"}},
	"Icon":        {Required: []string{"name"}, Optional: []string{"color", "size"}},
	"Button":      {Required: []string{"child"}, Optional: []string{"action", "variant", "icon"}},
	"IconButton":  {Required: []string{"icon", "action"}, Optional: []string{"tooltip", "variant"}},
	"Stat":        {Required: []string{"label", "value"}, Optional: []string{"format", "delta", "deltaFormat", "deltaLabel", "goodDirection", "trend", "icon"}},
	"Chart":       {Required: []string{"data"}, Optional: []string{"type", "x", "y", "series", "title", "subtitle", "height", "stacked", "horizontal", "smooth", "yFormat", "xFormat", "selection", "action", "label", "value"}},
	"Table":       {Required: []string{"data", "columns"}, Optional: []string{"search", "pageSize", "sortBy", "dense", "selection", "action"}},
	"Gauge":       {Required: []string{"value"}, Optional: []string{"min", "max", "label", "thresholds"}},
	"Sparkline":   {Required: []string{"values"}},
	"Progress":    {Required: []string{"value"}, Optional: []string{"max", "label", "variant"}},
	"Quote":       {Required: []string{"symbol", "price"}, Optional: []string{"name", "change", "changeAbs", "currency", "trend", "logo", "caption", "size", "action"}},
	"TextField":   {Required: []string{"value"}, Optional: []string{"label", "variant", "placeholder", "helper", "action"}},
	"SearchField": {Required: []string{"value"}, Optional: []string{"placeholder", "action"}},
	"CheckBox":    {Required: []string{"value"}, Optional: []string{"label"}},
	"Switch":      {Required: []string{"value"}, Optional: []string{"label"}},
	"Slider":      {Required: []string{"value"}, Optional: []string{"min", "max", "step", "format"}},
	"Dropdown":    {Required: []string{"value", "options"}, Optional: []string{"label"}},
	"ChoicePicker": {Required: []string{"value", "options"}, Optional: []string{"label"}},
	"SegmentedControl": {Required: []string{"value", "options"}},
	"Column":      {Optional: []string{"children", "child", "justify", "align", "gap", "weight"}},
	"Row":         {Optional: []string{"children", "child", "justify", "align", "gap", "weight"}},
	"Grid":        {Optional: []string{"children", "columns", "minColumnWidth", "gap"}},
	"Wrap":        {Optional: []string{"children", "spacing", "runSpacing"}},
	"Scroll":      {Optional: []string{"children", "child", "direction", "maxHeight", "weight"}},
	"Card":        {Optional: []string{"child", "children"}},
	"Section":     {Optional: []string{"title", "subtitle", "icon", "trailing", "children"}},
	"Split":       {Required: []string{"panes"}, Optional: []string{"minPaneWidth"}},
	"Tabs":        {Required: []string{"tabs"}, Optional: []string{"selected"}},
	"List":        {Required: []string{"children"}, Optional: []string{"direction", "gap", "spacing"}},
	"Show":        {Required: []string{"when", "child"}, Optional: []string{"fallback"}},
	"EmptyState":  {Required: []string{"title"}, Optional: []string{"icon", "text", "child"}},
	"Skeleton":    {Optional: []string{"variant"}},
	"Callout":     {Required: []string{"text"}, Optional: []string{"title", "severity"}},
	"ChatCard":    {Optional: []string{"child"}},
	"InlinePanel": {Optional: []string{"child"}},
	"Spacer":      {Optional: []string{"size"}},
	"Divider":     {},
}

var structuralKeys = map[string]bool{
	"id": true, "type": true, "component": true, "weight": true,
}

// ValidateCatalogSchema checks components against CatalogSchemas (A2UI catalog idea).
func ValidateCatalogSchema(components []map[string]any) []Issue {
	byID := map[string]bool{}
	for _, c := range components {
		if id, _ := c["id"].(string); id != "" {
			byID[id] = true
		}
	}
	var issues []Issue
	for _, c := range components {
		id, _ := c["id"].(string)
		kind := Kind(c)
		if kind == "" {
			continue
		}
		schema, ok := CatalogSchemas[kind]
		if !ok {
			continue
		}
		for _, prop := range schema.Required {
			if _, has := c[prop]; !has {
				issues = append(issues, Issue{
					Severity: Blocking, Area: "structure", Where: id,
					Code: "schema_missing_" + prop,
					Problem: fmt.Sprintf("%s requires prop %q", kind, prop),
					Fix:     "set \"" + prop + "\"",
				})
			}
		}
		// Containers must have children or child unless schema says otherwise.
		if kind == "Column" || kind == "Row" || kind == "Grid" || kind == "Wrap" || kind == "Scroll" || kind == "Section" {
			if c["children"] == nil && c["child"] == nil {
				issues = append(issues, Issue{
					Severity: Blocking, Area: "structure", Where: id, Code: "empty_container",
					Problem: kind + " has neither children nor child",
					Fix:     "add \"children\": [ids] or \"child\": id",
				})
			}
		}
		allowed := map[string]bool{}
		for _, p := range schema.Required {
			allowed[p] = true
		}
		for _, p := range schema.Optional {
			allowed[p] = true
		}
		if len(schema.Required)+len(schema.Optional) > 0 {
			for k := range c {
				if structuralKeys[k] || allowed[k] {
					continue
				}
				// Chart keeps series "type" as a non-catalog type string.
				if kind == "Chart" && k == "type" {
					continue
				}
				issues = append(issues, Issue{
					Severity: Advice, Area: "structure", Where: id, Code: "schema_unknown_prop",
					Problem: fmt.Sprintf("%s has undocumented prop %q", kind, k),
					Fix:     "remove it or use a catalog prop: " + strings.Join(append(append([]string{}, schema.Required...), schema.Optional...), ", "),
				})
			}
		}
		issues = append(issues, checkChildRefs(id, c, byID)...)
	}
	return issues
}

func checkChildRefs(id string, c map[string]any, byID map[string]bool) []Issue {
	var issues []Issue
	check := func(cid string) {
		if cid != "" && !byID[cid] {
			issues = append(issues, Issue{
				Severity: Blocking, Area: "structure", Where: id, Code: "dangling_child",
				Problem: "refers to missing component \"" + cid + "\"",
				Fix:     "add that component or fix the id",
			})
		}
	}
	switch v := c["child"].(type) {
	case string:
		check(v)
	}
	switch v := c["children"].(type) {
	case string:
		check(v)
	case []any:
		for _, item := range v {
			if cid, ok := item.(string); ok {
				check(cid)
			}
		}
	case map[string]any:
		// List template form.
		if cid, _ := v["componentId"].(string); cid != "" {
			check(cid)
		}
	}
	return issues
}
