package webkit

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/aseman/aseman/pkg/a2ui"
	"golang.org/x/net/html"
)

// A page an agent builds is inspected before anyone is shown it, as a
// generated frontend is (pkg/a2ui/inspect.go): InspectPage reads its HTML the
// way the kit runs it — the kit loaded, every <t-…> a component the kit has,
// every attribute a prop the kit can read, every call naming a tool and a
// microtool, every control wired to something, every value shown filled by
// something — and finds what would be broken or unclean on screen. The
// node then tests its calls live and looks at it (spaces/page_review.go).

// Call is a call of a tool's microtool a page makes: declared on an element
// (call="Tool/microtool" args into) or written in a script (Aseman.call,
// Aseman.load).
type Call struct {
	// Element describes where it is (t-button "Save", t-data, script).
	Element   string
	Tool      string
	Microtool string
	// Args are the declared arguments (bindings unresolved); nil for a
	// script's call, whose arguments are code.
	Args map[string]any
	// Into is where its result goes in the data model ("" for nowhere).
	Into string
	// Load: it runs when the page opens (t-data, Aseman.load).
	Load bool
	// Fields are the names of the fields a form adds to its arguments.
	Fields []string
	// Script: written in code, so only its tool and microtool are known.
	Script bool
}

// Page is a page read for inspection.
type Page struct {
	Title  string
	Issues []a2ui.Issue
	Calls  []Call
	// Reads, Writes and Aliases are as a2ui.CheckReads takes them.
	Reads   []a2ui.Read
	Writes  []string
	Aliases map[string]string
	// Resources are the page's own files it loads (relative URLs).
	Resources []string
	// ScriptsWrite: its scripts write the data model at paths not known
	// before they run, so a value nothing declared fills may still be filled.
	ScriptsWrite bool
	// Kit: it loads the kit.
	Kit bool

	events   map[string]string // event name → the element sending it
	handlers map[string]bool   // events Aseman.on handles
	ids      map[string]int
	scripts  strings.Builder
	controls []control
}

// control is a button or an input whose wiring is checked once the page's
// scripts are known.
type control struct {
	where, id string
	classes   []string
	input     bool
	wired     bool
	labelled  bool
	// unlabelled is what is said when it has no label.
	unlabelled string
}

// knownTags are the <t-…> elements the kit defines, read from the kit itself.
var knownTags = func() map[string]bool {
	src, _, _ := File("aseman-ui.js")
	out := map[string]bool{}
	for _, re := range []*regexp.Regexp{
		regexp.MustCompile(`\b(?:define|component|layout)\(\s*'([a-z0-9-]+)'`),
		regexp.MustCompile(`'([a-z]+(?:-[a-z]+)*-transition)'\s*:`),
	} {
		for _, m := range re.FindAllSubmatch(src, -1) {
			out["t-"+string(m[1])] = true
		}
	}
	// Families defined in a loop: for (const n of ['badge', 'tag']) define(n, …).
	family := regexp.MustCompile(`for \(const n of \[([^\]]*)\]\)`)
	name := regexp.MustCompile(`'([a-z0-9-]+)'`)
	for _, loc := range family.FindAllSubmatchIndex(src, -1) {
		body := src[loc[1]:min(len(src), loc[1]+400)]
		if !regexp.MustCompile(`\b(?:define|component|layout)\(n\b`).Match(body) {
			continue
		}
		for _, m := range name.FindAllSubmatch(src[loc[2]:loc[3]], -1) {
			out["t-"+string(m[1])] = true
		}
	}
	return out
}()

// KnownTag reports whether the kit defines the element [tag].
func KnownTag(tag string) bool { return knownTags[tag] }

// Kit elements that take input, and what their "value" is in A2UI.
var inputTags = map[string]bool{
	"t-text-field": true, "t-check-box": true, "t-checkbox": true, "t-switch": true, "t-slider": true,
	"t-choice-picker": true, "t-date-time-input": true, "t-segmented-control": true, "t-dropdown": true,
	"t-range-slider": true, "t-number-stepper": true, "t-search-field": true, "t-radio": true,
}

// Kit elements whose rows can be tapped, with their A2UI type.
var dataViews = map[string]string{
	"t-table": "Table", "t-chart": "Chart", "t-treemap": "Treemap", "t-allocation-bar": "AllocationBar",
	"t-data-grid": "Table", "t-heatmap": "Heatmap", "t-timeline": "Timeline", "t-graph": "Graph", "t-tree-view": "TreeView",
}

var (
	placeholderText = regexp.MustCompile(`(?i)lorem ipsum|\bTODO\b|placeholder text`)
	interpolation   = regexp.MustCompile(`\$\{\s*([^}\s]+)\s*\}`)
	hardColor       = regexp.MustCompile(`#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(`)
	fixedWidth      = regexp.MustCompile(`(?:^|[;{\s])(?:min-)?width\s*:\s*(\d+)px`)
	// Calls in scripts: Aseman.call('Tool', 'microtool' …), Aseman.call('Tool/microtool' …),
	// Aseman.load('/path', 'Tool', 'microtool' …), Aseman.tool('Tool').microtool(…).
	scriptCall = regexp.MustCompile(`Aseman\.(?:call|callRaw)\(\s*['"]([^'"]+)['"]\s*(?:,\s*['"]([^'"]+)['"])?`)
	scriptLoad = regexp.MustCompile(`Aseman\.load\(\s*['"]([^'"]+)['"]\s*,\s*['"]([^'"]+)['"]\s*,\s*['"]([^'"]+)['"]`)
	scriptTool = regexp.MustCompile(`Aseman\.tool\(\s*['"]([^'"]+)['"]\s*\)\.([A-Za-z_][A-Za-z0-9_]*)\(`)
	scriptOn   = regexp.MustCompile(`Aseman\.on\(\s*['"]([^'"]+)['"]`)
	scriptSet  = regexp.MustCompile(`Aseman\.data\.(?:set|merge|push|update)\(\s*(['"]([^'"]*)['"])?`)
)

// InspectPage reads a page's HTML the way the kit runs it.
func InspectPage(src []byte) *Page {
	p := &Page{Aliases: map[string]string{}, events: map[string]string{}, handlers: map[string]bool{}, ids: map[string]int{}}
	doc, err := html.Parse(bytes.NewReader(src))
	if err != nil {
		p.issue(a2ui.Blocking, "structure", "", "the page is not HTML: "+err.Error(), "serve an HTML page")
		return p
	}
	var viewport, tPage, css, usesKit bool
	var walk func(n *html.Node, scope string, form *Call)
	walk = func(n *html.Node, scope string, form *Call) {
		if n.Type == html.TextNode {
			if t := strings.TrimSpace(n.Data); t != "" && n.Parent != nil && n.Parent.Data != "script" && n.Parent.Data != "style" && placeholderText.MatchString(t) {
				p.issue(a2ui.Blocking, "design", describe(n.Parent), "shows placeholder text: "+strconv.Quote(clip(t, 60)), "show real content or remove it")
			}
			return
		}
		if n.Type != html.ElementNode && n.Type != html.DocumentNode {
			return
		}
		if n.Type == html.ElementNode {
			scope, form = p.element(n, scope, form, &viewport, &tPage, &css, &usesKit)
			if n.Data == "script" || n.Data == "style" {
				return
			}
			if each := attr(n, "each"); each != "" {
				list := eachPath(scope, each)
				if list != "" {
					p.Reads = append(p.Reads, a2ui.Read{Component: describe(n), Path: list + "/*"})
					scope = list + "/*"
				}
			}
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c, scope, form)
		}
		if n.Type == html.ElementNode && n.Data == "t-form" && form != nil && form.Tool != "" {
			p.Calls = append(p.Calls, *form)
		}
	}
	walk(doc, "", nil)
	p.appLayout(doc, usesKit)
	p.vizDensity(doc, usesKit)
	p.finish(viewport, tPage, css, usesKit)
	return p
}

func (p *Page) issue(severity, area, where, problem, fix string) {
	p.Issues = append(p.Issues, a2ui.Issue{Severity: severity, Area: area, Where: where, Problem: problem, Fix: fix})
}

// element reads one element; it returns the scope and the form its
// children are in.
func (p *Page) element(n *html.Node, scope string, form *Call, viewport, tPage, css, usesKit *bool) (string, *Call) {
	tag := n.Data
	where := describe(n)
	if s := attr(n, "scope"); s != "" {
		scope = a2ui.JoinPath(scope, s)
	}
	if id := attr(n, "id"); id != "" {
		p.ids[id]++
		if p.ids[id] == 2 {
			p.issue(a2ui.Advice, "structure", "#"+id, "two elements have the id \""+id+"\"", "give every element its own id")
		}
	}
	switch tag {
	case "title":
		if n.FirstChild != nil {
			p.Title = strings.TrimSpace(n.FirstChild.Data)
		}
	case "meta":
		if strings.EqualFold(attr(n, "name"), "viewport") {
			*viewport = true
		}
	case "body":
		*tPage = hasClass(n, "t-app")
	case "link":
		href := attr(n, "href")
		if strings.HasSuffix(href, "_aseman/kit/aseman-ui.css") {
			*css = true
		} else if strings.Contains(attr(n, "rel"), "stylesheet") {
			p.resource(where, href)
		}
	case "script":
		srcAttr := attr(n, "src")
		if strings.HasSuffix(srcAttr, "_aseman/kit/aseman-ui.js") {
			p.Kit = true
		} else if srcAttr != "" {
			p.resource(where, srcAttr)
		} else if n.FirstChild != nil && (attr(n, "type") == "" || strings.Contains(attr(n, "type"), "javascript") || attr(n, "type") == "module") {
			p.script(n.FirstChild.Data)
		}
	case "style":
		if n.FirstChild != nil {
			p.style("<style>", n.FirstChild.Data)
		}
	case "img", "audio", "video", "source", "iframe":
		p.resource(where, attr(n, "src"))
	}
	if strings.HasPrefix(tag, "t-") {
		*usesKit = true
		if !knownTags[tag] {
			p.issue(a2ui.Blocking, "structure", where, "<"+tag+"> is no component of the kit, so it renders nothing",
				"use a kit component (gallery: /_aseman/kit/gallery.html)")
		}
	}
	if style := attr(n, "style"); style != "" {
		p.style(where, style)
	}

	props := map[string]any{}
	for _, a := range n.Attr {
		key, value := a.Key, a.Val
		switch {
		case strings.HasPrefix(key, "on"):
			continue
		case strings.HasPrefix(key, "bind-"):
			prop := key[5:]
			path := a2ui.JoinPath(scope, value)
			switch {
			case prop == "value" && (inputTags[tag] || isNativeInput(n)):
				p.Writes = append(p.Writes, path)
			case prop == "selection":
				p.Writes = append(p.Writes, path)
			default:
				p.Reads = append(p.Reads, a2ui.Read{Component: where, Path: path})
			}
			props[camel(prop)] = map[string]any{"path": value}
			continue
		case key == "call" || key == "into" || key == "each" || key == "scope" || key == "class" || key == "style" || key == "id" ||
			key == "href" || key == "src" || key == "name" || key == "type" || key == "rel" || key == "slot" || key == "toast":
			continue
		}
		v := parse(value)
		if s := strings.TrimSpace(value); (strings.HasPrefix(s, "{") && strings.HasSuffix(s, "}")) || (strings.HasPrefix(s, "[") && strings.HasSuffix(s, "]")) {
			if _, ok := v.(string); ok {
				p.issue(a2ui.Blocking, "structure", where, "its "+key+" attribute is not valid JSON, so the kit reads it as plain text",
					"write it as JSON (double quotes, no trailing commas)")
			}
		}
		props[camel(key)] = v
	}

	// Rows a data view shows, and the selection that stands for one.
	rows := ""
	if b, ok := props["data"].(map[string]any); ok {
		if path, ok := b["path"].(string); ok {
			rows = a2ui.JoinPath(scope, path) + "/*"
		}
	}
	if kind, ok := dataViews[tag]; ok && rows != "" {
		for _, f := range a2ui.Fields(kind, props) {
			p.Reads = append(p.Reads, a2ui.Read{Component: where, Path: a2ui.JoinPath(rows, f)})
		}
	}
	for key, v := range props {
		switch {
		case key == "action" || key == "then":
			ctx := scope
			if rows != "" {
				ctx = rows
			}
			p.action(where, v, scope, ctx, form)
		case key == "selection":
			if b, ok := v.(map[string]any); ok {
				if path, ok := b["path"].(string); ok {
					sel := a2ui.JoinPath(scope, path)
					p.Writes = append(p.Writes, sel)
					if rows != "" {
						p.Aliases[sel] = rows
					}
				}
			}
		case key == "value" && (inputTags[tag] || isNativeInput(n)):
			if b, ok := v.(map[string]any); ok && b["path"] != nil {
				if path, ok := b["path"].(string); ok {
					p.Writes = append(p.Writes, a2ui.JoinPath(scope, path))
				}
			}
		default:
			p.values(where, v, scope)
		}
	}

	// A declared call.
	if call := attr(n, "call"); call != "" {
		tool, microtool := splitCall(call)
		c := Call{Element: where, Tool: tool, Microtool: microtool, Load: tag == "t-data" && !hasAttr(n, "lazy")}
		if raw := attr(n, "args"); raw != "" {
			c.Args, _ = parse(raw).(map[string]any)
			p.values(where, c.Args, scope)
		}
		if into := attr(n, "into"); into != "" {
			c.Into = a2ui.JoinPath(scope, into)
			p.Writes = append(p.Writes, c.Into+"__loading", c.Into+"__error")
		}
		if microtool == "" {
			p.issue(a2ui.Blocking, "interaction", where, "call=\""+call+"\" names no microtool", "write call=\"Tool/microtool\"")
		}
		if tag == "t-data" && c.Into == "" {
			p.issue(a2ui.Blocking, "data", where, "the t-data has no into, so what it loads goes nowhere", "add into=\"/path\" and show that path")
		}
		if tag == "t-form" {
			form = &c
		} else if microtool != "" {
			p.Calls = append(p.Calls, c)
		}
	}
	if tag == "t-data" && attr(n, "call") == "" && props["call"] == nil {
		p.issue(a2ui.Blocking, "data", where, "the t-data has no call, so it loads nothing", "add call=\"Tool/microtool\" and into=\"/path\"")
	}

	// Controls: wired to something, inputs bound and labelled.
	if form != nil && tag != "t-form" {
		if name := attr(n, "name"); name != "" {
			form.Fields = append(form.Fields, name)
		}
	}
	switch {
	case tag == "t-button" || tag == "t-icon-button" || tag == "button" || (tag == "input" && (attr(n, "type") == "button" || attr(n, "type") == "submit")) ||
		(tag == "a" && (attr(n, "href") == "#" || strings.HasPrefix(attr(n, "href"), "javascript:"))):
		href := attr(n, "href")
		submit := attr(n, "type") == "submit" || (tag == "button" && attr(n, "type") == "")
		wired := hasAttr(n, "call") || props["action"] != nil || hasOn(n) ||
			(tag == "a" && href != "#" && !strings.HasPrefix(href, "javascript:")) ||
			(submit && (form != nil || inForm(n))) || // a form's submit
			attr(n, "slot") == "trigger" // opens its t-modal or t-menu
		label := text(n) != "" || attr(n, "text") != "" || attr(n, "label") != "" || attr(n, "aria-label") != "" || attr(n, "tooltip") != "" || attr(n, "value") != ""
		p.controls = append(p.controls, control{where: where, id: attr(n, "id"), classes: classes(n), wired: wired, labelled: label,
			unlabelled: "the button has no label"})
	case inputTags[tag] || isNativeInput(n):
		bound := hasAttr(n, "bind-value") || attr(n, "name") != "" || hasOn(n)
		if b, ok := props["value"].(map[string]any); ok && b["path"] != nil {
			bound = true
		}
		// A native input with an id may be labelled by a <label for>.
		label := attr(n, "label") != "" || attr(n, "placeholder") != "" || attr(n, "aria-label") != "" || (isNativeInput(n) && attr(n, "id") != "")
		p.controls = append(p.controls, control{where: where, id: attr(n, "id"), classes: classes(n), input: true, wired: bound, labelled: label,
			unlabelled: "the input has no label"})
	}
	return scope, form
}

// action reads an action prop: a call, an event, a client function call,
// sets, or a list of them.
func (p *Page) action(where string, v any, scope, ctx string, form *Call) {
	switch a := v.(type) {
	case []any:
		for _, item := range a {
			p.action(where, item, scope, ctx, form)
		}
	case string:
		if tool, microtool := splitCall(a); microtool != "" {
			p.Calls = append(p.Calls, Call{Element: where, Tool: tool, Microtool: microtool})
		}
	case map[string]any:
		if fc, ok := a["functionCall"].(map[string]any); ok {
			args, _ := fc["args"].(map[string]any)
			if path, ok := args["path"].(string); ok {
				p.Writes = append(p.Writes, a2ui.JoinPath(scope, path))
			}
			p.values(where, args, scope)
			return
		}
		if e, ok := a["event"].(map[string]any); ok {
			if name, _ := e["name"].(string); name != "" {
				p.events[name] = where
			}
			if context, ok := e["context"].(map[string]any); ok {
				for _, cv := range context {
					if b, ok := cv.(map[string]any); ok {
						if path, ok := b["path"].(string); ok {
							p.Reads = append(p.Reads, a2ui.Read{Component: where, Path: a2ui.JoinPath(ctx, path)})
						}
					}
				}
			}
			return
		}
		if set, ok := a["set"].(map[string]any); ok {
			for path, sv := range set {
				p.Writes = append(p.Writes, a2ui.JoinPath(scope, path))
				p.values(where, sv, scope)
			}
		}
		call, _ := a["call"].(string)
		tool, microtool := splitCall(call)
		if t, ok := a["tool"].(string); ok {
			tool, microtool = t, asString(a["microtool"])
		}
		if microtool != "" {
			c := Call{Element: where, Tool: tool, Microtool: microtool}
			c.Args, _ = a["args"].(map[string]any)
			p.values(where, c.Args, scope)
			if into, ok := a["into"].(string); ok && into != "" {
				c.Into = a2ui.JoinPath(scope, into)
			}
			p.Calls = append(p.Calls, c)
		}
		if then, ok := a["then"]; ok {
			p.action(where, then, scope, ctx, form)
		}
	}
}

// values registers the data a prop reads: its {"path"} bindings at any depth
// and the ${…} of its strings.
func (p *Page) values(where string, v any, scope string) {
	switch x := v.(type) {
	case string:
		for _, m := range interpolation.FindAllStringSubmatch(x, -1) {
			p.Reads = append(p.Reads, a2ui.Read{Component: where, Path: a2ui.JoinPath(scope, m[1])})
		}
	case map[string]any:
		if path, ok := x["path"].(string); ok && len(x) <= 2 {
			p.Reads = append(p.Reads, a2ui.Read{Component: where, Path: a2ui.JoinPath(scope, path)})
			return
		}
		for k, inner := range x {
			if k == "action" {
				p.action(where, inner, scope, scope, nil)
				continue
			}
			p.values(where, inner, scope)
		}
	case []any:
		for _, inner := range x {
			p.values(where, inner, scope)
		}
	}
}

// script reads an inline script: the calls it makes, the events it handles
// and where it writes the data model.
func (p *Page) script(code string) {
	p.scripts.WriteString(code + "\n")
	for _, m := range scriptLoad.FindAllStringSubmatch(code, -1) {
		p.Calls = append(p.Calls, Call{Element: "script (Aseman.load)", Tool: m[2], Microtool: m[3], Into: m[1], Load: true, Script: true})
		p.Writes = append(p.Writes, m[1], m[1]+"__loading", m[1]+"__error")
	}
	for _, m := range scriptCall.FindAllStringSubmatch(code, -1) {
		tool, microtool := m[1], m[2]
		if microtool == "" {
			tool, microtool = splitCall(tool)
		}
		if microtool != "" {
			p.Calls = append(p.Calls, Call{Element: "script (Aseman.call)", Tool: tool, Microtool: microtool, Script: true})
		}
	}
	for _, m := range scriptTool.FindAllStringSubmatch(code, -1) {
		if m[2] != "call" && m[2] != "microtools" && m[2] != "frontend" && m[2] != "show" {
			p.Calls = append(p.Calls, Call{Element: "script (Aseman.tool)", Tool: m[1], Microtool: m[2], Script: true})
		}
	}
	for _, m := range scriptOn.FindAllStringSubmatch(code, -1) {
		p.handlers[m[1]] = true
	}
	for _, m := range scriptSet.FindAllStringSubmatch(code, -1) {
		if m[1] == "" || strings.Contains(m[2], "${") {
			p.ScriptsWrite = true
		} else {
			p.Writes = append(p.Writes, m[2])
		}
	}
	if strings.Contains(code, "Aseman.data.batch") {
		p.ScriptsWrite = true
	}
}

// style checks CSS for hard-coded colors and widths a phone cannot hold.
func (p *Page) style(where, css string) {
	if hardColor.MatchString(strings.ReplaceAll(css, "var(", "")) {
		colors := hardColor.FindAllString(css, 3)
		p.issue(a2ui.Advice, "design", where, "hard-codes colors ("+strings.Join(colors, ", ")+"), which break the app's light/dark theme",
			"use the kit's variables (var(--t-primary), --t-surface, --t-series-1…)")
	}
	for _, m := range fixedWidth.FindAllStringSubmatch(css, -1) {
		if w, _ := strconv.Atoi(m[1]); w > 360 {
			p.issue(a2ui.Advice, "design", where, fmt.Sprintf("has a fixed width of %dpx, wider than a phone", w),
				"use max-width or a Grid with min-column-width")
			break
		}
	}
}

// resource registers a file the page loads from its own preview (a
// relative path, or a root-relative one, which the gateway keeps inside the
// preview): the review fetches them.
func (p *Page) resource(where, ref string) {
	ref = strings.TrimSpace(ref)
	if ref == "" || strings.HasPrefix(ref, "data:") || strings.HasPrefix(ref, "#") || strings.Contains(ref, "_aseman/") || strings.Contains(ref, "{") {
		return
	}
	u, err := url.Parse(ref)
	if err != nil {
		p.issue(a2ui.Blocking, "structure", where, "loads "+strconv.Quote(ref)+", which is no URL", "fix the address")
		return
	}
	if u.Scheme != "" || u.Host != "" {
		return // another site's
	}
	p.Resources = append(p.Resources, ref)
}

// finish checks what needs the whole page: the kit, the viewport, controls'
// wiring (scripts may wire them), events' handlers.
func (p *Page) finish(viewport, tPage, css, usesKit bool) {
	switch {
	case usesKit && !p.Kit:
		p.issue(a2ui.Blocking, "structure", "<head>", "uses <t-…> components without the kit's script, so none of them render",
			`add <script src="/_aseman/kit/aseman-ui.js"></script> in <head>`)
	case !usesKit && !p.Kit:
		p.issue(a2ui.Advice, "design", "<head>", "does not use the Aseman web UI kit, so it will not look like the app",
			`link /_aseman/kit/aseman-ui.css and /_aseman/kit/aseman-ui.js and build it from <t-…> components`)
	}
	if p.Kit && !css {
		p.issue(a2ui.Blocking, "design", "<head>", "loads the kit's script without its stylesheet, so it renders unstyled",
			`add <link rel="stylesheet" href="/_aseman/kit/aseman-ui.css"> in <head>`)
	}
	if !viewport {
		p.issue(a2ui.Blocking, "design", "<head>", "has no viewport meta tag, so phones render it zoomed out and unreadable",
			`add <meta name="viewport" content="width=device-width, initial-scale=1">`)
	}
	if strings.TrimSpace(p.Title) == "" {
		p.issue(a2ui.Advice, "design", "<head>", "has no <title>", "give it a short title")
	}
	scripts := p.scripts.String()
	referenced := func(c control) bool {
		if c.id != "" && strings.Contains(scripts, c.id) {
			return true
		}
		for _, cl := range c.classes {
			if cl != "" && strings.Contains(scripts, "."+cl) {
				return true
			}
		}
		return false
	}
	// A page whose scripts wire controls by tag or by walking the DOM is
	// not second-guessed control by control.
	generic := strings.Contains(scripts, "querySelectorAll(") || strings.Contains(scripts, "addEventListener('click'") && strings.Contains(scripts, "closest(")
	for _, c := range p.controls {
		if !c.wired && !referenced(c) && !generic {
			if c.input {
				p.issue(a2ui.Blocking, "interaction", c.where, "what is entered reaches nothing (no bind-value, name in a form, or script reading it)",
					`bind it (bind-value="/form/<field>") and pass it to the call that submits it`)
			} else {
				p.issue(a2ui.Blocking, "interaction", c.where, "the button does nothing (no call, action, form submit or script handling it)",
					`give it call="Tool/microtool" (args, into) or remove it`)
			}
		}
		if !c.labelled {
			p.issue(a2ui.Advice, "design", c.where, c.unlabelled, "label it")
		}
	}
	names := make([]string, 0, len(p.events))
	for name := range p.events {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if !p.handlers[name] {
			p.issue(a2ui.Blocking, "interaction", p.events[name], "sends the event "+name+", which no Aseman.on(\""+name+"\", …) handles, so it does nothing",
				`handle it in a script, or give the control call="Tool/microtool" instead`)
		}
	}
}

// --- helpers ------------------------------------------------------------------

func attr(n *html.Node, key string) string {
	for _, a := range n.Attr {
		if a.Key == key {
			return a.Val
		}
	}
	return ""
}

func hasAttr(n *html.Node, key string) bool {
	for _, a := range n.Attr {
		if a.Key == key {
			return true
		}
	}
	return false
}

func hasOn(n *html.Node) bool {
	for _, a := range n.Attr {
		if strings.HasPrefix(a.Key, "on") && len(a.Key) > 2 {
			return true
		}
	}
	return false
}

func classes(n *html.Node) []string { return strings.Fields(attr(n, "class")) }

func hasClass(n *html.Node, class string) bool {
	for _, c := range classes(n) {
		if c == class {
			return true
		}
	}
	return false
}

func inForm(n *html.Node) bool {
	for a := n.Parent; a != nil; a = a.Parent {
		if a.Type == html.ElementNode && (a.Data == "form" || a.Data == "t-form") {
			return true
		}
	}
	return false
}

func isNativeInput(n *html.Node) bool {
	switch n.Data {
	case "select", "textarea":
		return true
	case "input":
		switch attr(n, "type") {
		case "button", "submit", "reset", "hidden", "image":
			return false
		}
		return true
	}
	return false
}

// text is an element's own text content.
func text(n *html.Node) string {
	var b strings.Builder
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.TextNode {
			b.WriteString(n.Data)
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(n)
	return strings.TrimSpace(b.String())
}

// describe names an element for a report: its tag, id, and what it says.
func describe(n *html.Node) string {
	d := n.Data
	if id := attr(n, "id"); id != "" {
		return d + "#" + id
	}
	for _, k := range []string{"text", "label", "title", "call", "into", "name", "aria-label"} {
		if v := attr(n, k); v != "" {
			return d + "[" + k + "=" + strconv.Quote(clip(v, 40)) + "]"
		}
	}
	if t := text(n); t != "" && len(t) < 60 {
		return d + " " + strconv.Quote(t)
	}
	return d
}

// parse reads an attribute's value as the kit does (parseAttr).
func parse(v string) any {
	s := strings.TrimSpace(v)
	switch s {
	case "true":
		return true
	case "false":
		return false
	case "null":
		return nil
	}
	if f, err := strconv.ParseFloat(s, 64); err == nil && !(len(s) > 1 && s[0] == '0' && s[1] != '.') {
		return f
	}
	if (strings.HasPrefix(s, "{") && strings.HasSuffix(s, "}")) || (strings.HasPrefix(s, "[") && strings.HasSuffix(s, "]")) {
		var out any
		if json.Unmarshal([]byte(s), &out) == nil {
			return out
		}
	}
	return v
}

// eachPath is the list an each attribute repeats over ("" when it is
// literal data).
func eachPath(scope, each string) string {
	if strings.HasPrefix(strings.TrimSpace(each), "/") {
		return strings.TrimSpace(each)
	}
	if b, ok := parse(each).(map[string]any); ok {
		if path, ok := b["path"].(string); ok {
			return a2ui.JoinPath(scope, path)
		}
	}
	return ""
}

// splitCall is the kit's splitCall: "weather/forecast", "weather.forecast"
// or "weather:forecast" → tool, microtool.
func splitCall(spec string) (string, string) {
	s := strings.TrimSpace(spec)
	if i := strings.IndexAny(s, "/:"); i > 0 && i < len(s)-1 {
		return s[:i], s[i+1:]
	}
	if i := strings.Index(s, "."); i > 0 && i < len(s)-1 {
		return s[:i], s[i+1:]
	}
	return s, ""
}

func camel(s string) string {
	parts := strings.Split(s, "-")
	for i := 1; i < len(parts); i++ {
		if parts[i] != "" {
			parts[i] = strings.ToUpper(parts[i][:1]) + parts[i][1:]
		}
	}
	return strings.Join(parts, "")
}

func asString(v any) string { s, _ := v.(string); return s }

func clip(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "…"
}

// --- app layout ----------------------------------------------------------------

// The page is an application screen, not a document (a2ui.AppLayout): its
// body fills the window and never scrolls as a whole, a body region takes
// the rest of the height and scrolls inside itself, and whatever grows with
// its data is in a region that scrolls.

// growingTags are kit elements that grow with their data or content.
var growingTags = map[string]bool{
	"t-table": true, "t-data-grid": true, "t-timeline": true, "t-markdown": true, "t-json-view": true,
	"t-code-block": true, "t-tree-view": true, "t-accordion": true, "t-list": true, "t-list-view": true, "t-for": true,
}

var overflowScroll = regexp.MustCompile(`overflow(?:-y)?\s*:\s*(?:auto|scroll)`)

// scroller reports whether an element scrolls its content by itself when it
// is given a height.
func scroller(n *html.Node) bool {
	switch n.Data {
	case "t-scroll":
		return attr(n, "direction") != "horizontal"
	case "t-split", "t-tabs", "t-scaffold":
		return true
	}
	return overflowScroll.MatchString(attr(n, "style")) || hasClass(n, "t-scroll")
}

// region reports whether an element, given the rest of the height, scrolls
// inside it: a scroller, or a wrapper (t-expanded, t-card, div…) around one.
func region(n *html.Node) bool {
	if scroller(n) {
		return true
	}
	var only *html.Node
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if c.Type == html.ElementNode {
			if only != nil || c.Data == "script" {
				return false
			}
			only = c
		}
	}
	return only != nil && region(only)
}

func (p *Page) appLayout(doc *html.Node, usesKit bool) {
	body := find(doc, "body")
	if body == nil {
		return
	}
	if !usesKit && !p.Kit {
		return // said already: it does not use the kit
	}
	if !hasClass(body, "t-app") {
		p.issue(a2ui.Blocking, "layout", "<body>", "the body is not an app screen (class \"t-app\"), so the page scrolls as a whole like a web page instead of fitting the window",
			`<body class="t-app">: a header, then the body (weight="1": a t-split, t-tabs or t-scroll) that scrolls inside itself`)
	}
	// What grows must be in a region that scrolls.
	grows, elements := false, 0
	var walk func(n *html.Node, scrolled bool)
	walk = func(n *html.Node, scrolled bool) {
		if n.Type == html.ElementNode {
			if n.Data == "script" || n.Data == "style" || n.Data == "template" && n.Parent != nil && n.Parent.Data != "t-for" {
				return
			}
			if strings.HasPrefix(n.Data, "t-") {
				elements++
			}
			if growingTags[n.Data] || attr(n, "each") != "" {
				grows = true
				if !scrolled {
					p.issue(a2ui.Blocking, "layout", describe(n), "grows with its data but is in no region that scrolls, so it is cut off at the bottom of the screen",
						`put it in the body region (weight="1": a t-scroll, a t-split pane or a t-tabs tab), which scrolls inside itself`)
					scrolled = true // said once for what is inside it
				}
			}
			scrolled = scrolled || scroller(n)
			if n.Data == "t-row" {
				panes := 0
				for c := n.FirstChild; c != nil; c = c.NextSibling {
					if c.Type == html.ElementNode && region(c) {
						panes++
					}
				}
				if panes >= 2 {
					p.issue(a2ui.Advice, "layout", describe(n), "lays scrolling panes side by side in a t-row, which squeezes them on a phone",
						`use <t-split>: panes side by side on a desktop, tabs on a phone`)
				}
			}
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c, scrolled)
		}
	}
	walk(body, false)
	if !hasClass(body, "t-app") || (!grows && elements <= 8) {
		return
	}
	// The body: a region takes the rest of the height and scrolls.
	weighted := 0
	for c := body.FirstChild; c != nil; c = c.NextSibling {
		if c.Type != html.ElementNode || c.Data == "script" || c.Data == "t-data" {
			continue
		}
		if !hasAttr(c, "weight") && c.Data != "t-expanded" && c.Data != "t-split" && c.Data != "t-scaffold" && c.Data != "t-tabs" {
			continue
		}
		weighted++
		if !region(c) {
			p.issue(a2ui.Blocking, "layout", describe(c), "takes the rest of the screen's height but does not scroll inside it, so what does not fit is cut off",
				`make it a t-scroll (or a t-split / t-tabs, or wrap its content in one)`)
		}
	}
	if weighted == 0 {
		p.issue(a2ui.Blocking, "layout", "<body>", "nothing in the body takes the rest of the screen's height, so content below the window is cut off",
			`give the body region — a t-scroll, t-split or t-tabs holding everything below the header — weight="1"`)
	}
}

// visualTags / proseTags mirror a2ui's visualization-first density check for
// kit pages: dashboards of t-text/t-markdown without stats or charts are
// flagged so the model review has automatic evidence.
var visualTags = map[string]bool{
	"t-chart": true, "t-sparkline": true, "t-gauge": true, "t-heatmap": true, "t-treemap": true,
	"t-graph": true, "t-table": true, "t-data-grid": true, "t-stat": true, "t-stat-card": true,
	"t-key-value": true, "t-timeline": true, "t-progress": true, "t-quote": true,
	"t-order-book": true, "t-ticker-tape": true, "t-allocation-bar": true, "t-trend": true,
	"t-tree-view": true,
}

var proseTags = map[string]bool{
	"t-text": true, "t-markdown": true, "t-callout": true, "t-code-block": true, "t-json-view": true,
}

var formTags = map[string]bool{
	"t-text-field": true, "t-search-field": true, "t-checkbox": true, "t-switch": true,
	"t-slider": true, "t-range-slider": true, "t-dropdown": true, "t-choice-picker": true,
	"t-segmented-control": true, "t-number-stepper": true, "t-date-time-input": true,
	"t-form": true,
}

func (p *Page) vizDensity(doc *html.Node, usesKit bool) {
	if !usesKit && !p.Kit {
		return
	}
	body := find(doc, "body")
	if body == nil {
		return
	}
	visual, prose, form, elements := 0, 0, 0, 0
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.ElementNode {
			if n.Data == "script" || n.Data == "style" || n.Data == "template" {
				return
			}
			if strings.HasPrefix(n.Data, "t-") {
				elements++
			}
			if visualTags[n.Data] {
				visual++
			}
			if proseTags[n.Data] {
				prose++
			}
			if formTags[n.Data] {
				form++
			}
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(body)
	if elements <= 8 {
		return
	}
	if form >= 3 && visual == 0 {
		return
	}
	if visual == 0 && prose >= 3 {
		p.issue(a2ui.Advice, "design", "<body>", "the page is mostly text with no Stats, Charts, Tables or other visual components",
			"lead with a t-grid of t-stat and a t-chart or t-table; keep t-text/t-markdown for short labels only")
		return
	}
	if visual > 0 && prose > visual*2 && prose >= 4 {
		p.issue(a2ui.Advice, "design", "<body>", "prose components outnumber visual ones — the page reads like a document",
			"replace walls of t-text/t-markdown with t-stat, t-chart and t-table")
	}
	hasStat, hasChartish := false, false
	var findKinds func(*html.Node)
	findKinds = func(n *html.Node) {
		if n.Type == html.ElementNode {
			switch n.Data {
			case "t-stat", "t-stat-card", "t-quote", "t-gauge", "t-trend":
				hasStat = true
			case "t-chart", "t-heatmap", "t-treemap", "t-sparkline", "t-graph", "t-allocation-bar", "t-order-book":
				hasChartish = true
			}
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			findKinds(c)
		}
	}
	findKinds(body)
	if hasChartish && !hasStat && visual >= 2 {
		p.issue(a2ui.Advice, "design", "<body>", "has charts but no KPI Stat strip",
			"put 3–5 t-stat tiles above the hero chart so headline numbers are readable at a glance")
	}
}

// find is the first element [tag] under [n].
func find(n *html.Node, tag string) *html.Node {
	if n.Type == html.ElementNode && n.Data == tag {
		return n
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if f := find(c, tag); f != nil {
			return f
		}
	}
	return nil
}
