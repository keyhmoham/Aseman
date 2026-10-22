package a2ui

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// A generated surface is inspected before anyone is shown it: Inspect reads
// its component tree the way a device renders it — what hangs from root, what
// every component reads from the data model, what inputs, selections and
// device actions write there, and which events reach the node — and finds
// what would be broken or unclean on screen. CheckData then tests what the
// components read against the data the surface was really filled with, and
// Outline renders the filled surface as text for a reviewer to look at.

// Issue is one problem found in a surface.
type Issue struct {
	// Severity is Blocking (broken, misleading or unclean: it is fixed before
	// the surface is shown) or Advice (polish).
	Severity string `json:"severity"`
	// Area is what the issue is about: structure, data, interaction, design
	// or purpose.
	Area string `json:"area"`
	// Where names the component, data path or action concerned.
	Where   string `json:"where,omitempty"`
	Problem string `json:"problem"`
	Fix     string `json:"fix,omitempty"`
}

// Issue severities.
const (
	Blocking = "blocking"
	Advice   = "advice"
)

func (i Issue) String() string {
	s := "[" + i.Area + "] "
	if i.Where != "" {
		s += i.Where + ": "
	}
	s += i.Problem
	if i.Fix != "" {
		s += " Fix: " + i.Fix
	}
	return s
}

// Read is a place of the data model a component shows. Path is absolute; a
// "*" segment stands for every item of an array (a List's template, a
// Table's column, a tapped row).
type Read struct {
	Component string
	Path      string
}

// Event is an event a component sends to the node, with the keys of the
// context it sends.
type Event struct {
	Component string
	Name      string
	Context   []string
}

// Surface is a component list read for inspection.
type Surface struct {
	byID   map[string]map[string]any
	ids    []string
	placed map[string]bool
	// Issues are what the inspection found.
	Issues []Issue
	// Reads are what the components show from the data model.
	Reads []Read
	// Writes are the places inputs, selections and device actions write.
	Writes []string
	// Events are what the components send to the node.
	Events []Event
	// aliases: a selection's path stands for an item of the rows it selects.
	aliases map[string]string
}

// Components that take input: their "value" binding is where it goes.
var inputs = map[string]bool{
	"TextField": true, "CheckBox": true, "Switch": true, "Slider": true, "ChoicePicker": true,
	"DateTimeInput": true, "SegmentedControl": true, "Dropdown": true, "RangeSlider": true,
	"NumberStepper": true, "SearchField": true,
}

// Components whose rows can be tapped: their action's context paths are
// relative to the tapped row, and their selection holds it.
var tappable = map[string]bool{
	"Chart": true, "Heatmap": true, "Treemap": true, "Graph": true, "Table": true,
	"Timeline": true, "TreeView": true,
}

// Device actions that write the data model at their "path".
var deviceWrites = map[string]bool{"setValue": true, "toggle": true, "increment": true, "append": true, "removeAt": true}

// Keys that hold component ids or structure, never data.
var skipKeys = map[string]bool{
	"id": true, "component": true, "child": true, "children": true, "trigger": true,
	"fallback": true, "componentId": true, "weight": true,
}

var placeholder = regexp.MustCompile(`(?i)lorem ipsum|\bTODO\b|placeholder text|sample data`)

// interpolated are the ${…} paths of a formatString value.
var interpolated = regexp.MustCompile(`\$\{\s*([^}\s]+)\s*\}`)

// Inspect reads a component list the way a device renders it.
func Inspect(components []map[string]any) *Surface {
	s := &Surface{byID: map[string]map[string]any{}, placed: map[string]bool{}, aliases: map[string]string{}}
	for _, c := range components {
		id, _ := c["id"].(string)
		if id == "" {
			continue
		}
		if _, dup := s.byID[id]; dup {
			s.issue(Blocking, "structure", id, "two components have the id \""+id+"\"", "give every component its own id")
			continue
		}
		s.byID[id] = c
		s.ids = append(s.ids, id)
	}
	if _, ok := s.byID["root"]; !ok {
		s.issue(Blocking, "structure", "", "no component has the id \"root\"", "make the surface's top component \"root\"")
		return s
	}
	s.visit("root", "", nil, false, false)
	s.appShell()
	if _, ok := s.byID["compact"]; ok {
		if !s.placed["compact"] {
			s.visit("compact", "", nil, false, true) // a widget, not a screen
		}
	} else {
		s.issue(Advice, "design", "compact", "there is no \"compact\" component for the phone board",
			"add one with id \"compact\", outside root's tree: the one to three numbers that matter most")
	}
	for _, id := range s.ids {
		if !s.placed[id] {
			s.issue(Advice, "structure", id, "is not placed anywhere (nothing under root or compact refers to it)", "place it or remove it")
		}
	}
	return s
}

func (s *Surface) issue(severity, area, where, problem, fix string) {
	s.Issues = append(s.Issues, Issue{Severity: severity, Area: area, Where: where, Problem: problem, Fix: fix})
}

// join resolves a path written at [scope]: absolute paths stand alone;
// relative ones ("name", ".") are of the scope's item.
func join(scope, path string) string {
	path = strings.TrimSpace(path)
	if strings.HasPrefix(path, "/") || scope == "" {
		if !strings.HasPrefix(path, "/") {
			path = "/" + path
		}
		return strings.TrimSuffix(path, "/.")
	}
	if path == "." || path == "" {
		return scope
	}
	return scope + "/" + strings.TrimPrefix(path, "./")
}

// child is a component a component shows, read at a scope.
type child struct {
	id, scope string
}

// children are the components [c] shows, and registers the paths of its
// List templates.
func (s *Surface) children(id string, c map[string]any, scope string) []child {
	var out []child
	kind, _ := c["component"].(string)
	for _, key := range []string{"child", "trigger", "fallback", "content", "trailing"} {
		ref, ok := c[key].(string)
		if !ok || ref == "" {
			continue
		}
		if (key == "content" && kind != "Modal") || (key == "trailing" && s.byID[ref] == nil) {
			continue // text, not a component
		}
		out = append(out, child{ref, scope})
	}
	switch ch := c["children"].(type) {
	case []any:
		for _, v := range ch {
			if ref, ok := v.(string); ok {
				out = append(out, child{ref, scope})
			}
		}
	case map[string]any:
		ref, _ := ch["componentId"].(string)
		path, _ := ch["path"].(string)
		if ref == "" || path == "" {
			s.issue(Blocking, "structure", id, "its repeated children need {\"componentId\", \"path\"}", "name the template component and the array it repeats over")
			break
		}
		list := join(scope, path)
		s.Reads = append(s.Reads, Read{id, list + "/*"}) // a list, of items
		out = append(out, child{ref, list + "/*"})
	}
	for _, key := range []string{"tabs", "items", "panes"} {
		if list, ok := c[key].([]any); ok {
			for _, item := range list {
				if m, ok := item.(map[string]any); ok {
					if ref, ok := m["child"].(string); ok {
						out = append(out, child{ref, scope})
					}
				}
			}
		}
	}
	if kind == "Elpian" {
		var slots func(v any)
		slots = func(v any) {
			switch x := v.(type) {
			case map[string]any:
				if ref, ok := x["slot"].(string); ok {
					out = append(out, child{ref, scope})
				}
				for _, inner := range x {
					slots(inner)
				}
			case []any:
				for _, inner := range x {
					slots(inner)
				}
			}
		}
		slots(c["node"])
	}
	return out
}

// visit reads component [id] and what it shows, at [scope] (the item a List
// template is repeated for), under [path] (its ancestors), [scrolled] when
// one of them scrolls.
func (s *Surface) visit(id, scope string, path []string, inCard, scrolled bool) {
	c := s.byID[id]
	parent := ""
	if len(path) > 0 {
		parent = path[len(path)-1]
	}
	if c == nil {
		s.issue(Blocking, "structure", parent, "refers to the component \""+id+"\", which does not exist", "add it or remove the reference")
		return
	}
	for _, p := range path {
		if p == id {
			s.issue(Blocking, "structure", id, "contains itself (a cycle through "+strings.Join(append(path, id), " → ")+")", "make the tree a tree")
			return
		}
	}
	s.placed[id] = true
	kind, _ := c["component"].(string)
	if kind == "Card" && inCard {
		s.issue(Advice, "design", id, "is a Card inside a Card", "use a Section or a Column inside the outer Card")
	}
	s.read(id, kind, c, scope)
	if grows(kind, c) && !scrolled {
		s.issue(Blocking, "layout", id, "the "+kind+" grows with its data but is in no scrolling region, so it pushes the screen taller than its window",
			"put it in the body's Scroll (\"weight\": 1), a Split pane or a Tabs tab, which scroll inside themselves")
	}
	if kind == "Scroll" && scrolled && c["direction"] != "horizontal" && c["maxHeight"] == nil {
		s.issue(Advice, "layout", id, "is a Scroll inside a region that already scrolls", "drop the inner Scroll, or give it a maxHeight")
	}
	if h, ok := number(c["height"]); ok && h > 640 {
		s.issue(Advice, "layout", id, fmt.Sprintf("is %v px tall, taller than a phone's screen", h), "keep heights to a chart's 220–320")
	}
	inner := scrolled || scrolls(kind, c) || kind == "Modal"
	for _, ch := range s.children(id, c, scope) {
		s.visit(ch.id, ch.scope, append(path, id), inCard || kind == "Card", inner)
	}
}

// scrolls reports whether a component scrolls its content by itself (when
// it is given a height, as the app's screens give their regions).
func scrolls(kind string, c map[string]any) bool {
	switch kind {
	case "Scroll":
		return c["direction"] != "horizontal"
	case "Split", "Tabs":
		return true
	}
	return false
}

// grows reports whether a component grows with its data or content without
// bound, so it needs a region that scrolls.
func grows(kind string, c map[string]any) bool {
	switch kind {
	case "Table", "Timeline", "Markdown", "JsonView", "CodeBlock", "TreeView", "Accordion":
		return true
	case "List", "Column", "Grid", "Wrap":
		ch, repeated := c["children"].(map[string]any)
		return repeated && ch["componentId"] != nil && c["direction"] != "horizontal"
	}
	return false
}

// region reports whether a component, given a height, fills it and scrolls
// inside it: a scrolling component, or a Card or Box around one.
func (s *Surface) region(id string) bool {
	c := s.byID[id]
	if c == nil {
		return false
	}
	kind, _ := c["component"].(string)
	if scrolls(kind, c) {
		return true
	}
	if kind == "Card" || kind == "Box" {
		if ref, ok := c["child"].(string); ok {
			return s.region(ref)
		}
	}
	return false
}

// small reports whether the screen is a few fixed components that cannot
// outgrow a phone's window (a figure or two, a short message): it needs no
// scrolling body.
func (s *Surface) small() bool {
	n := 0
	for id := range s.placed {
		c := s.byID[id]
		kind, _ := c["component"].(string)
		if grows(kind, c) || kind == "Chart" {
			return false
		}
		n++
	}
	return n <= smallScreen
}

// smallScreen is how many components a screen may have without a scrolling
// body.
const smallScreen = 6

// appShell checks the root is laid out as an app screen: a Column whose
// body takes the rest of the window's height and scrolls inside itself (or
// a Split, Tabs or Scroll that fills the window by itself).
func (s *Surface) appShell() {
	root := s.byID["root"]
	kind, _ := root["component"].(string)
	if scrolls(kind, root) || s.small() {
		return
	}
	if kind != "Column" {
		s.issue(Blocking, "layout", "root", "the root is a "+kind+"; an app screen's root is a Column: a header, then the body with \"weight\": 1 that scrolls inside itself",
			"make root a Column of the header and a body Scroll (or Split / Tabs) with \"weight\": 1")
		return
	}
	children, _ := root["children"].([]any)
	weighted := 0
	for _, v := range children {
		id, _ := v.(string)
		c := s.byID[id]
		if c == nil {
			continue
		}
		if w, ok := number(c["weight"]); !ok || w <= 0 {
			continue
		}
		weighted++
		if !s.region(id) {
			childKind, _ := c["component"].(string)
			s.issue(Blocking, "layout", id, "takes the rest of the window's height (weight) but, as a "+childKind+", does not scroll inside it, so what does not fit is cut off",
				"make it a Scroll (or a Split / Tabs, or a Card around a Scroll) holding what it showed")
		}
	}
	if weighted == 0 {
		s.issue(Blocking, "layout", "root", "nothing in the root takes the rest of the window's height, so the screen scrolls like a web page (or leaves the window half empty)",
			"give the body — a Scroll, Split or Tabs holding everything below the header — \"weight\": 1")
	}
}

// read registers what a component reads, writes and sends, and checks its
// own props.
func (s *Surface) read(id, kind string, c map[string]any, scope string) {
	rows := ""
	if data, ok := c["data"].(map[string]any); ok {
		if p, ok := data["path"].(string); ok {
			rows = join(scope, p) + "/*"
		}
	}
	for key, v := range c {
		if skipKeys[key] || (key == "content" && kind == "Modal") {
			continue
		}
		switch {
		case key == "action":
			ctx := scope
			if tappable[kind] && rows != "" {
				ctx = rows
			}
			s.action(id, kind, v, scope, ctx)
		case key == "selection":
			if sel, ok := v.(map[string]any); ok {
				if p, ok := sel["path"].(string); ok {
					target := join(scope, p)
					s.Writes = append(s.Writes, target)
					if rows != "" {
						s.aliases[target] = rows
					}
				}
			}
		case key == "value" && inputs[kind], key == "selected" && kind == "Tabs":
			if b, ok := v.(map[string]any); ok {
				if p, ok := b["path"].(string); ok {
					s.Writes = append(s.Writes, join(scope, p))
					continue
				}
			}
			if key == "value" {
				s.issue(Blocking, "interaction", id, "the "+kind+"'s value is bound to nothing, so what is entered reaches no action",
					"bind it: \"value\": {\"path\": \"/form/<field>\"}, and read it in the action with {\"$data\": \"/form/<field>\"}")
			}
		default:
			s.values(id, v, scope)
		}
	}
	if inputs[kind] && c["value"] == nil {
		s.issue(Blocking, "interaction", id, "the "+kind+" has no \"value\" binding, so what is entered reaches no action",
			"bind it: \"value\": {\"path\": \"/form/<field>\"}")
	}
	// Fields of the rows a data view shows.
	if rows != "" {
		for _, f := range Fields(kind, c) {
			s.Reads = append(s.Reads, Read{id, join(rows, f)})
		}
	}
	switch kind {
	case "Button":
		if c["child"] == nil && c["label"] == nil && c["text"] == nil {
			s.issue(Blocking, "design", id, "the Button has no label (no \"child\" Text)", "give it a child Text saying what it does")
		}
		if c["action"] == nil {
			s.issue(Blocking, "interaction", id, "the Button does nothing (no \"action\")", "give it an action or remove it")
		}
	case "IconButton":
		if c["action"] == nil {
			s.issue(Blocking, "interaction", id, "the IconButton does nothing (no \"action\")", "give it an action or remove it")
		}
	case "Grid":
		if n, ok := number(c["columns"]); ok && n > 2 && c["minColumnWidth"] == nil {
			s.issue(Advice, "design", id, fmt.Sprintf("the Grid has %v fixed columns, which overflow a phone", n), "use \"minColumnWidth\" instead of \"columns\"")
		}
	case "Text":
		if t, ok := c["text"].(string); ok && placeholder.MatchString(t) {
			s.issue(Blocking, "design", id, "shows placeholder text: "+strconv.Quote(truncate(t, 60)), "show real content from the data model or remove it")
		}
	}
	if w, ok := number(c["width"]); ok && w > 360 {
		s.issue(Advice, "design", id, fmt.Sprintf("has a fixed width of %v, wider than a phone", w), "drop the width and let the layout size it")
	}
}

// Fields are the row fields a data view of type [kind] (Table, Chart,
// Treemap, AllocationBar) reads, given its props.
func Fields(kind string, c map[string]any) []string {
	var out []string
	str := func(keys ...string) {
		for _, k := range keys {
			if f, ok := c[k].(string); ok && f != "" {
				out = append(out, f)
			}
		}
	}
	list := func(key string) {
		if items, ok := c[key].([]any); ok {
			for _, item := range items {
				if m, ok := item.(map[string]any); ok {
					if f, ok := m["field"].(string); ok && f != "" {
						out = append(out, f)
					}
				}
			}
		}
	}
	switch kind {
	case "Table":
		list("columns")
	case "Chart":
		typ, _ := c["type"].(string)
		switch typ {
		case "pie", "donut":
			str("label", "value")
		case "histogram":
			str("field")
		case "candlestick":
			str("x")
			out = append(out, "open", "high", "low", "close")
		default:
			str("x", "y", "size")
			list("series")
		}
	case "Treemap":
		str("label", "value", "group", "colorBy")
	case "AllocationBar":
		str("label", "value")
	}
	return out
}

// values registers the data a prop reads: its {"path"} bindings, the paths
// of its function calls' arguments and of formatString's ${…}.
func (s *Surface) values(id string, v any, scope string) {
	switch x := v.(type) {
	case map[string]any:
		if p, ok := x["path"].(string); ok && len(x) <= 2 {
			s.Reads = append(s.Reads, Read{id, join(scope, p)})
			return
		}
		if call, ok := x["call"].(string); ok && call == "formatString" {
			if args, ok := x["args"].(map[string]any); ok {
				if text, ok := args["value"].(string); ok {
					for _, m := range interpolated.FindAllStringSubmatch(text, -1) {
						s.Reads = append(s.Reads, Read{id, join(scope, m[1])})
					}
				}
			}
		}
		for k, inner := range x {
			if k == "action" {
				if a, ok := inner.(map[string]any); ok {
					s.action(id, "", a, scope, scope)
					continue
				}
			}
			s.values(id, inner, scope)
		}
	case []any:
		for _, inner := range x {
			s.values(id, inner, scope)
		}
	}
}

// action registers an action: the event it sends (with its context read at
// [ctx]) or the device call it runs.
func (s *Surface) action(id, kind string, v any, scope, ctx string) {
	a, ok := v.(map[string]any)
	if !ok {
		return
	}
	if fc, ok := a["functionCall"].(map[string]any); ok {
		call, _ := fc["call"].(string)
		args, _ := fc["args"].(map[string]any)
		if deviceWrites[call] {
			if p, ok := args["path"].(string); ok {
				s.Writes = append(s.Writes, join(scope, p))
			}
		}
		for k, arg := range args {
			if k != "path" {
				s.values(id, arg, scope)
			}
		}
		return
	}
	event, ok := a["event"].(map[string]any)
	if !ok {
		if _, named := a["name"].(string); !named {
			return
		}
		event = a
	}
	name, _ := event["name"].(string)
	if name == "" {
		s.issue(Blocking, "interaction", id, "sends an event with no name", "name the event and map it in \"actions\"")
		return
	}
	e := Event{Component: id, Name: name}
	if context, ok := event["context"].(map[string]any); ok {
		for k, cv := range context {
			e.Context = append(e.Context, k)
			if b, ok := cv.(map[string]any); ok {
				if p, ok := b["path"].(string); ok {
					s.Reads = append(s.Reads, Read{id, join(ctx, p)})
					continue
				}
			}
			s.values(id, cv, scope)
		}
	}
	if inputs[kind] {
		e.Context = append(e.Context, "value")
	}
	sort.Strings(e.Context)
	s.Events = append(s.Events, e)
	// Menu items, Elpian nodes and the like nest further actions.
	for k, inner := range a {
		if k != "event" && k != "name" && k != "context" {
			s.values(id, inner, scope)
		}
	}
}

// --- testing against data ---------------------------------------------------------

// Source is a place of the data model something fills: a data binding (Live
// when it was really run for the inspection, Err when that failed) or an
// action's result.
type Source struct {
	Path string
	// From says what fills it ("weather_report", "the action refresh").
	From string
	Live bool
	Err  string
	// Optional: nothing need show it (an action's result).
	Optional bool
}

// segments of a pointer.
func segments(path string) []string {
	path = strings.TrimPrefix(path, "/")
	if path == "" {
		return nil
	}
	parts := strings.Split(path, "/")
	for i, p := range parts {
		parts[i] = strings.ReplaceAll(strings.ReplaceAll(p, "~1", "/"), "~0", "~")
	}
	return parts
}

// under reports whether [path] is [prefix] or below it ("*" matches any
// segment).
func under(path, prefix string) bool {
	a, b := segments(path), segments(prefix)
	if len(b) > len(a) {
		return false
	}
	for i := range b {
		if a[i] != b[i] && a[i] != "*" && b[i] != "*" {
			return false
		}
	}
	return true
}

// related reports whether one path is the other or below it.
func related(a, b string) bool { return under(a, b) || under(b, a) }

// Lookup resolves a pointer in [data]; "*" takes an array's first item. It
// reports why it cannot: ok is false with a reason when the data has no such
// place, and true with a nil value when an array on the way is empty (the
// place cannot be known).
func Lookup(data any, path string) (value any, ok bool, why string) {
	node := data
	walked := ""
	for _, p := range segments(path) {
		switch x := node.(type) {
		case map[string]any:
			if p == "*" {
				return nil, false, at(walked) + " is an object, not a list" + keysOf(x)
			}
			v, has := x[p]
			if !has {
				return nil, false, at(walked) + " has no \"" + p + "\"" + keysOf(x)
			}
			node = v
		case []any:
			i, err := strconv.Atoi(p)
			if p == "*" {
				i, err = 0, nil
			}
			if err != nil {
				return nil, false, at(walked) + " is a list; read its items with a List, Table or Chart over it, not \"" + p + "\""
			}
			if i >= len(x) {
				return nil, true, "" // empty: nothing to check
			}
			node = x[i]
		case nil:
			return nil, true, "" // nothing there yet
		default:
			return nil, false, at(walked) + " is a " + fmt.Sprintf("%T", x) + " (" + truncate(fmt.Sprint(x), 40) + "), it has no \"" + p + "\""
		}
		walked += "/" + p
	}
	return node, true, ""
}

func at(path string) string {
	if path == "" {
		return "the data"
	}
	return path
}

func keysOf(m map[string]any) string {
	if len(m) == 0 {
		return " (it is empty)"
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if len(keys) > 20 {
		keys = append(keys[:20], "…")
	}
	return " (it has: " + strings.Join(keys, ", ") + ")"
}

// CheckData tests what the components read against the [sources] that fill
// the data model and against [data], the data model as it was really filled:
// every value shown must be filled by something, and where it was filled
// for real, be there.
func (s *Surface) CheckData(data map[string]any, sources []Source) []Issue {
	return CheckReads(s.Reads, s.Writes, s.aliases, data, sources, Blocking)
}

// CheckReads is CheckData for any surface: [reads] are what it shows,
// [writes] where its inputs, selections and client actions write, [aliases]
// selection paths and the rows they select (a pointer of rows + "/*" by
// selection path). A value nothing fills is reported as [unfilled] (Advice
// where a page's own scripts may fill it).
func CheckReads(reads []Read, writes []string, aliases map[string]string, data map[string]any, sources []Source, unfilled string) []Issue {
	unalias := func(path string) string {
		for sel, rows := range aliases {
			if under(path, sel) {
				return rows + strings.TrimPrefix(path, sel)
			}
		}
		return path
	}
	var out []Issue
	seen := map[string]bool{}
	for _, r := range reads {
		path := unalias(r.Path)
		key := r.Component + " " + path
		if seen[key] {
			continue
		}
		seen[key] = true
		var src *Source
		for i := range sources {
			if related(path, sources[i].Path) {
				src = &sources[i]
				break
			}
		}
		if src == nil {
			written := false
			for _, w := range writes {
				if related(path, w) {
					written = true
					break
				}
			}
			if !written {
				out = append(out, Issue{Severity: unfilled, Area: "data", Where: r.Component,
					Problem: "shows " + r.Path + ", which nothing fills (no data binding, input, selection or action result writes there)",
					Fix:     "bind a microtool's result there, or read the path a binding fills"})
			}
			continue
		}
		if !src.Live || src.Err != "" || !under(path, src.Path) {
			continue // not run, failed (reported on its own), or a parent of it
		}
		if _, ok, why := Lookup(data, path); !ok {
			out = append(out, Issue{Severity: Blocking, Area: "data", Where: r.Component,
				Problem: "shows " + r.Path + ", but in the result of " + src.From + " " + why,
				Fix:     "read a field the result really has"})
		}
	}
	for _, src := range sources {
		if src.Optional {
			continue
		}
		shown := false
		for _, r := range reads {
			if related(unalias(r.Path), src.Path) {
				shown = true
				break
			}
		}
		if !shown {
			out = append(out, Issue{Severity: Advice, Area: "data", Where: src.Path,
				Problem: src.From + " is fetched into " + src.Path + " but nothing on the surface shows it",
				Fix:     "show it or drop the binding"})
		}
	}
	return out
}

// Written reports whether something on the surface writes [path] (an input,
// a selection, a device action) or a source fills it.
func (s *Surface) Written(path string, sources []Source) bool {
	for _, w := range s.Writes {
		if related(path, w) {
			return true
		}
	}
	for _, src := range sources {
		if related(path, src.Path) {
			return true
		}
	}
	return false
}

// --- the surface as text ---------------------------------------------------------

// Outline renders the surface filled with [data] as an indented text tree, at
// most [max] bytes: each component with what it shows (bound values
// resolved), what its controls do, and each List template once, for its
// first item. It is what a reviewer looks at.
func (s *Surface) Outline(data map[string]any, max int) string {
	var b strings.Builder
	var walk func(id, scope string, depth int, seen map[string]bool)
	walk = func(id, scope string, depth int, seen map[string]bool) {
		if b.Len() > max || seen[id] {
			return
		}
		c := s.byID[id]
		if c == nil {
			return
		}
		seen[id] = true
		defer delete(seen, id)
		kind, _ := c["component"].(string)
		line := strings.Repeat("  ", depth) + id + " " + kind + describe(c, kind, scope, data)
		b.WriteString(truncate(line, 400) + "\n")
		for _, ch := range s.children(id, c, scope) {
			walk(ch.id, ch.scope, depth+1, seen)
		}
	}
	walk("root", "", 0, map[string]bool{})
	if _, ok := s.byID["compact"]; ok {
		b.WriteString("— phone widget —\n")
		walk("compact", "", 0, map[string]bool{})
	}
	out := b.String()
	if len(out) > max {
		out = out[:max] + "\n…"
	}
	return out
}

// describe sums up a component's props for the outline.
func describe(c map[string]any, kind, scope string, data map[string]any) string {
	keys := make([]string, 0, len(c))
	for k := range c {
		if !skipKeys[k] && !(k == "content" && kind == "Modal") {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	var parts []string
	for _, k := range keys {
		parts = append(parts, k+"="+show(c[k], scope, data))
	}
	if ch, ok := c["children"].(map[string]any); ok {
		if p, ok := ch["path"].(string); ok {
			parts = append(parts, "repeats over "+show(map[string]any{"path": p}, scope, data))
		}
	}
	if len(parts) == 0 {
		return ""
	}
	return " " + strings.Join(parts, " ")
}

// show is a prop's value as the outline prints it.
func show(v any, scope string, data map[string]any) string {
	switch x := v.(type) {
	case string:
		return strconv.Quote(truncate(x, 80))
	case map[string]any:
		if p, ok := x["path"].(string); ok && len(x) <= 2 {
			path := join(scope, p)
			value, ok, why := Lookup(data, path)
			switch {
			case !ok:
				return "{" + path + "} → MISSING (" + why + ")"
			case value == nil:
				return "{" + path + "} → (empty)"
			}
			if list, ok := value.([]any); ok {
				first := ""
				if len(list) > 0 {
					first = ", first: " + compactJSON(list[0], 160)
				}
				return fmt.Sprintf("{%s} → [%d items%s]", path, len(list), first)
			}
			return "{" + path + "} → " + compactJSON(value, 120)
		}
		if call, ok := x["call"].(string); ok {
			return "call:" + call + compactJSON(x["args"], 120)
		}
		if fc, ok := x["functionCall"].(map[string]any); ok {
			return "device:" + compactJSON(fc, 120)
		}
		if e, ok := x["event"].(map[string]any); ok {
			return "sends event " + compactJSON(e, 160)
		}
		return compactJSON(x, 200)
	default:
		return compactJSON(x, 200)
	}
}

func compactJSON(v any, max int) string {
	raw, _ := json.Marshal(v)
	return truncate(string(raw), max)
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "…"
}

func number(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int:
		return float64(n), true
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	}
	return 0, false
}

// JoinPath resolves a path written at [scope] (a List's item, a page
// element's scope): absolute paths stand alone, relative ones are of the
// scope.
func JoinPath(scope, path string) string { return join(scope, path) }

// --- arguments ------------------------------------------------------------------

// SchemaArgs are the properties and required arguments of a microtool's
// argument schema (nil when it says nothing of them).
func SchemaArgs(schema map[string]any) (properties map[string]any, required []string) {
	properties, _ = schema["properties"].(map[string]any)
	switch list := schema["required"].(type) {
	case []any:
		for _, r := range list {
			if s, ok := r.(string); ok {
				required = append(required, s)
			}
		}
	case []string:
		required = list
	}
	return properties, required
}

// CheckArgs checks the arguments [where] passes [microtool] against its
// [schema]: none it does not take, every one it requires. [howToPass] says
// how a missing one is passed there.
func CheckArgs(where, microtool string, schema map[string]any, args map[string]any, howToPass string) []Issue {
	var out []Issue
	properties, required := SchemaArgs(schema)
	if properties != nil {
		var unknown []string
		for k := range args {
			if _, ok := properties[k]; !ok {
				unknown = append(unknown, k)
			}
		}
		if len(unknown) > 0 {
			sort.Strings(unknown)
			names := make([]string, 0, len(properties))
			for k := range properties {
				names = append(names, k)
			}
			sort.Strings(names)
			out = append(out, Issue{Severity: Blocking, Area: "data", Where: where,
				Problem: microtool + " takes no argument " + strings.Join(unknown, ", "),
				Fix:     "use only its arguments: " + strings.Join(names, ", ")})
		}
	}
	for _, r := range required {
		if v, ok := args[r]; !ok || v == nil || v == "" {
			out = append(out, Issue{Severity: Blocking, Area: "data", Where: where,
				Problem: microtool + " requires \"" + r + "\", which is not passed",
				Fix:     "pass it (" + howToPass + ")"})
		}
	}
	return out
}
