package a2ui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/tradera/tradera/pkg/errs"
)

// The components devices render: the A2UI v0.9 basic catalog plus Tradera's
// (app/lib/src/features/tools/presentation/a2ui_catalog.dart, rendered by
// the app's UI kit). Models are taught them with CatalogPrompt; what they
// write is checked with Check, so an invented component comes back as an
// error the model can correct instead of a placeholder on screen.
var basic = []string{
	"Text", "Image", "Icon", "Video", "AudioPlayer", "Row", "Column", "List",
	"Card", "Tabs", "Modal", "Divider", "Button", "TextField", "CheckBox",
	"ChoicePicker", "Slider", "DateTimeInput",
}

var tradera = []string{
	"Chart", "Sparkline", "Gauge", "Heatmap", "Treemap", "Graph", "Table",
	"Stat", "KeyValue", "Timeline", "TreeView", "JsonView", "CodeBlock",
	"Progress", "Badge", "Rating", "Callout", "Avatar",
	"Grid", "Wrap", "Stack", "Box", "Center", "Spacer", "AspectRatio",
	"Scroll", "Section", "Expandable", "Switch", "Elpian", "ToolFrontend",
}

var known = func() map[string]bool {
	m := map[string]bool{}
	for _, c := range append(append([]string{}, basic...), tradera...) {
		m[c] = true
	}
	return m
}()

// Known reports whether devices render the component type.
func Known(component string) bool { return known[component] }

// Check verifies every component has an id and a type devices render, and
// that one is the root.
func Check(components []map[string]any) error {
	if len(components) == 0 {
		return errs.InvalidArgument("no components")
	}
	root := false
	var unknown []string
	seen := map[string]bool{}
	for i, c := range components {
		id, _ := c["id"].(string)
		kind, _ := c["component"].(string)
		if id == "" || kind == "" {
			keys := make([]string, 0, len(c))
			for k := range c {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			return errs.InvalidArgument(fmt.Sprintf("component #%d (keys: %s) needs an \"id\" and a \"component\" type; "+
				"every component is a flat entry of the list and children are referenced by id", i+1, strings.Join(keys, ", ")))
		}
		root = root || id == "root"
		if !known[kind] && !seen[kind] {
			seen[kind] = true
			unknown = append(unknown, kind)
		}
	}
	if !root {
		return errs.InvalidArgument("one component must have id \"root\"")
	}
	if len(unknown) > 0 {
		sort.Strings(unknown)
		return errs.InvalidArgument("unknown component type(s) " + strings.Join(unknown, ", ") +
			"; use only: " + strings.Join(basic, ", ") + ", " + strings.Join(tradera, ", "))
	}
	return nil
}

// CatalogPrompt teaches a model the components, how data reaches them and
// how they respond to taps.
const CatalogPrompt = `Components (flat list; each has "id" and "component"; children are ids; the root has id "root"; "weight": n in a Row/Column takes n shares of the space):
Layout
- Column / Row {children:[ids], justify: start|center|end|spaceBetween|spaceAround|stretch, align: start|center|end|stretch}
- Grid {children, columns?: n, minColumnWidth?: 220, gap?: 12} responsive equal columns (dashboards, tiles)
- Wrap {children, spacing?, runSpacing?}   Stack {children, alignment?: center|topLeft|bottomRight…, height?}
- Box {child, padding?, margin?, width?, height?, maxWidth?, color?, gradient?: [colors], borderRadius?, borderColor?, elevation?, alignment?}
- Card {child}   Center {child}   Spacer {size}   AspectRatio {child, ratio}   Divider {}
- Section {title, subtitle?, icon?, trailing?, children}   Expandable {title, subtitle?, expanded?, children}
- Tabs {tabs:[{title, child}]}   Modal {trigger, content}   Scroll {child|children, direction?, maxHeight?}
- List {children: {componentId: templateId, path: "/array"}} repeats templateId per item; inside it paths are relative to the item ("name", not "/name")
Content
- Text {text, variant: h1|h2|h3|h4|h5|body|caption} (Markdown)   Image {url, fit?, variant?}   Icon {name}
- Badge {text, status?: good|warning|serious|critical | color?, variant?: tonal|filled|outline, icon?}   Avatar {name, url?}
- Callout {title?, text, severity: info|good|warning|critical}   CodeBlock {code, language?}   JsonView {value}
Data
- Stat {label, value, format?, delta?, deltaFormat?: "+percent:1", deltaLabel?: "vs last week", goodDirection?: up|down, trend?: [numbers], icon?} — a KPI tile; put several in a Grid
- Chart {type: line|area|bar|scatter|bubble|candlestick|histogram|pie|donut|radar|heatmap|treemap, data: rows, x: field, series?: [{field, label?, color?}] (or y: field), title?, subtitle?, stacked?, horizontal?, smooth?, yFormat?, xFormat?, height?}
  candlestick reads open/high/low/close fields; bubble adds size: field; pie/donut use label: field, value: field; histogram bins field: values; one value axis only (two measures of different scale → two charts)
- Sparkline {values: [numbers]}   Gauge {value, min?, max?, label?, thresholds?: [{value, status}]}   Progress {value, max?, label?, variant?: linear|circular}   Rating {value, max?}
- Table {data: rows, columns: [{field, label?, type?: text|number|trend|badge|progress|sparkline|image|avatar|boolean|link, format?, align?}], search?, pageSize?, sortBy?, dense?} — sortable; the best view for lists of records
- KeyValue {items: [{label, value, format?, type?: trend|badge}]} or {data: object}   Timeline {data: rows of {title, description?, time, status?, icon?}}
- Heatmap {data: rows of {x, y, value}} or {rows, columns, values: [[…]]}   Treemap {data, label: field, value: field, group?: field, colorBy?: signed field}
- Graph {nodes: [{id, label?, group?}], edges: [{from, to, label?}], layout?: force|circle|tree, directed?}   TreeView {data: {label, children: [...]}}
Inputs
- Button {child: textId, action: {event: {name, context: {key: {"path": "/x"} or literal}}}, variant?: primary|borderless}
- TextField {label, value: {"path": "/form/x"}}   CheckBox / Switch {label, value: {"path"}}   Slider {value, min, max}   ChoicePicker {label, options: [{label, value}], value}   DateTimeInput {value, enableDate?, enableTime?}
Escape hatch
- Elpian {node: {type, props: {style: {...CSS}}, children: [nodes or {"slot": componentId}]}} — any Flutter/HTML node of the Elpian engine (Container, Padding, Opacity, ClipRRect, GridView, Wrap, Tooltip, AnimatedContainer, Shimmer, div, span, table…) when no component fits.
Data: a plain string is shown exactly as written. Show a value with {"path": "/x"}; mix text and values with {"call": "formatString", "args": {"value": "High ${/x}°"}, "returnType": "string"}. Never write {{...}} or ${...} in a plain string. Data props (data, values, value, delta, trend, nodes, items…) take a {"path"} binding to data, or literal values.
Formats: number[:decimals], integer, compact (12.9K), percent[:decimals] (0.12 → 12%), currency[:USD[:decimals]], date, time, datetime; a leading + signs positives.
Taps: Chart, Heatmap, Treemap, Graph, Table, Timeline and TreeView take "selection": {"path": "/selected"} (the tapped row is written there — show its details elsewhere bound to /selected/…) and "action" (a Button-style action; its context paths resolve relative to the tapped row, e.g. {"symbol": {"path": "symbol"}}).
Colors: series take blue, orange, aqua, yellow, magenta, green, violet, red (in that order) or #hex; status colors (good, warning, serious, critical) only for state, always with a label or icon.`
