package tools

import (
	"context"
	"encoding/json"
	"sort"
	"strconv"
	"strings"

	"github.com/aseman/aseman/pkg/a2ui"
)

// A generated frontend is reviewed before anyone is told it is ready. Each
// round, what the model wrote is
//
//   - inspected: its component tree as a device renders it (references,
//     what is placed, inputs bound, buttons labelled and wired, layout that
//     holds on a phone), and every data binding and action against the
//     microtools' schemas;
//   - tested: its data bindings are run for the person asking, exactly as
//     opening it would, and every value a component shows is looked up in
//     what really came back; actions are resolved against that data, and
//     the ones whose microtool only reads (readOnlyHint) are run too;
//   - looked at: the surface, filled with that data, is rendered as an
//     outline and reviewed by the model for fitness to the tool and its
//     skill, cleanness and the design standard.
//
// Everything found goes back to the generator as one report, and the next
// round is reviewed again, until nothing blocking is left. A frontend that
// still does not work after the last round is not served.

// reviewRounds bounds the rounds of generating, reviewing and repairing.
const reviewRounds = 4

// Review is what the review of a generated frontend found.
type Review struct {
	// Passed: nothing blocking was left.
	Passed bool `json:"passed"`
	// Rounds is how many rounds it took.
	Rounds int `json:"rounds"`
	// Tested is what was run and checked live.
	Tested []string     `json:"tested,omitempty"`
	Issues []a2ui.Issue `json:"issues,omitempty"`
	// broken counts the blocking issues the inspection and the tests found
	// (as opposed to the design review's judgement).
	broken int
}

// blocking counts the review's blocking issues.
func (r *Review) blocking() int {
	n := 0
	for _, i := range r.Issues {
		if i.Severity == a2ui.Blocking {
			n++
		}
	}
	return n
}

// worse reports whether r is a worse candidate than [o]: more that does not
// work, then more blocking, then more advice.
func (r *Review) worse(o *Review) bool {
	if r.broken != o.broken {
		return r.broken > o.broken
	}
	if b, ob := r.blocking(), o.blocking(); b != ob {
		return b > ob
	}
	return len(r.Issues) > len(o.Issues)
}

// feedback is the review as the generator is told it.
func (r *Review) feedback() string {
	var b strings.Builder
	b.WriteString("Your frontend was rendered and tested before being shown, and it is not ready yet.\n")
	for _, severity := range []string{a2ui.Blocking, a2ui.Advice} {
		first := true
		for _, i := range r.Issues {
			if i.Severity != severity {
				continue
			}
			if first {
				if severity == a2ui.Blocking {
					b.WriteString("\nBlocking (fix every one):\n")
				} else {
					b.WriteString("\nAdvice (apply where it does not conflict with the skill):\n")
				}
				first = false
			}
			b.WriteString("- " + i.String() + "\n")
		}
	}
	if len(r.Tested) > 0 {
		b.WriteString("\nWhat the test ran:\n")
		for _, t := range r.Tested {
			b.WriteString("- " + t + "\n")
		}
	}
	b.WriteString("\nReply with the whole corrected JSON object only: {\"title\", \"components\", \"data\", \"actions\"}. Keep what works; change what the report names.")
	return b.String()
}

// summary is a short account of the review for errors and logs.
func (r *Review) summary(max int) string {
	var lines []string
	for _, i := range r.Issues {
		if i.Severity == a2ui.Blocking {
			lines = append(lines, i.String())
		}
	}
	if len(lines) > max {
		lines = append(lines[:max], "…")
	}
	return strings.Join(lines, "; ")
}

// reviewer reviews generated frontends of one tool, for one caller.
type reviewer struct {
	// tool, skill: what the frontend is for.
	tool, skill string
	commands    map[string]map[string]any
	shown       Shown
	// call runs a microtool for the caller; results are kept for the
	// rounds that follow (the same call is not paid for twice).
	call  func(microtool string, args map[string]any) (any, error)
	calls map[string]result
	// look asks the model to review the rendered surface; nil skips it.
	look func(messages []map[string]any) (string, error)
}

type result struct {
	value any
	err   error
}

func newReviewer(tool, skill string, commands []map[string]any, shown Shown, call func(string, map[string]any) (any, error),
	look func([]map[string]any) (string, error)) *reviewer {
	byName := map[string]map[string]any{}
	for _, cmd := range commands {
		if name, _ := cmd["name"].(string); name != "" {
			byName[name] = cmd
		}
	}
	return &reviewer{tool: tool, skill: skill, commands: byName, shown: shown, call: call, calls: map[string]result{}, look: look}
}

// run calls a microtool once per arguments across the rounds.
func (rv *reviewer) run(microtool string, args map[string]any) (any, error) {
	raw, _ := json.Marshal(args)
	key := microtool + " " + string(raw)
	if r, ok := rv.calls[key]; ok {
		return r.value, r.err
	}
	v, err := rv.call(microtool, args)
	rv.calls[key] = result{v, err}
	return v, err
}

// schema is a microtool's argument schema: its properties and required
// arguments (nil when the microtool says nothing of them).
func (rv *reviewer) schema(microtool string) (properties map[string]any, required []string) {
	schema, _ := rv.commands[microtool]["schema"].(map[string]any)
	return a2ui.SchemaArgs(schema)
}

// readOnly reports whether a microtool says it only reads, so the review may
// run it.
func (rv *reviewer) readOnly(microtool string) bool {
	annotations, _ := rv.commands[microtool]["annotations"].(map[string]any)
	ro, _ := annotations["readOnlyHint"].(bool)
	return ro
}

// checkArgs checks the arguments a binding or an action passes a microtool
// against its schema.
func (rv *reviewer) checkArgs(where, microtool string, args map[string]any) []a2ui.Issue {
	schema, _ := rv.commands[microtool]["schema"].(map[string]any)
	return a2ui.CheckArgs(where, microtool, schema, args, "a literal, {\"$data\": \"/form/…\"} or {\"$context\": \"…\"} in an action")
}

// review inspects, tests and looks at a template, filling it as the person
// asking would see it.
func (rv *reviewer) review(t *Template) *Review {
	r := &Review{}
	surface := a2ui.Inspect(t.Components)
	r.Issues = append(r.Issues, surface.Issues...)

	// The data bindings, run as opening the frontend runs them.
	data := map[string]any{}
	var sources []a2ui.Source
	for _, b := range t.bindings(rv.shown) {
		where := "data " + b.Path
		r.Issues = append(r.Issues, rv.checkArgs(where, b.Microtool, b.Args)...)
		for k, v := range b.Args {
			if ref, ok := v.(map[string]any); ok && (ref["$data"] != nil || ref["$context"] != nil) {
				r.Issues = append(r.Issues, a2ui.Issue{Severity: a2ui.Blocking, Area: "data", Where: where,
					Problem: "argument " + k + " of a data binding is a reference; bindings run before anything is entered",
					Fix:     "give bindings literal arguments; run what depends on input from an action"})
			}
		}
		src := a2ui.Source{Path: b.Path, From: b.Microtool, Live: true}
		v, err := rv.run(b.Microtool, b.Args)
		if err != nil {
			src.Err = err.Error()
			r.Issues = append(r.Issues, a2ui.Issue{Severity: a2ui.Blocking, Area: "data", Where: where,
				Problem: b.Microtool + " failed when the frontend was filled: " + err.Error(),
				Fix:     "call it with arguments its schema accepts"})
			setPointer(data, b.Path, map[string]any{"error": err.Error()})
		} else {
			setPointer(data, b.Path, v)
			r.Tested = append(r.Tested, "filled "+b.Path+" from "+b.Microtool+" ("+shape(v)+")")
		}
		sources = append(sources, src)
	}

	// The actions: wired to an event, their arguments resolvable, run when
	// they only read.
	sent := map[string][]a2ui.Event{}
	for _, e := range surface.Events {
		sent[e.Name] = append(sent[e.Name], e)
	}
	names := make([]string, 0, len(t.Actions))
	for name := range t.Actions {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		a := t.Actions[name]
		where := "action " + name
		if a.Microtool == "" {
			r.Issues = append(r.Issues, a2ui.Issue{Severity: a2ui.Blocking, Area: "interaction", Where: where,
				Problem: "runs no microtool, so its button does nothing", Fix: "map it to a microtool or remove its button"})
			continue
		}
		if a.Result != "" {
			sources = append(sources, a2ui.Source{Path: a.Result, From: "the action " + name, Optional: true})
		}
		if len(sent[name]) == 0 {
			r.Issues = append(r.Issues, a2ui.Issue{Severity: a2ui.Advice, Area: "interaction", Where: where,
				Problem: "no component sends it", Fix: "give it a button or remove it"})
		}
		r.Issues = append(r.Issues, rv.checkArgs(where, a.Microtool, a.Args)...)
		for k, v := range a.Args {
			ref, ok := v.(map[string]any)
			if !ok || len(ref) != 1 {
				continue
			}
			if key, ok := ref["$context"].(string); ok {
				for _, e := range sent[name] {
					if !contains(e.Context, key) {
						r.Issues = append(r.Issues, a2ui.Issue{Severity: a2ui.Blocking, Area: "interaction", Where: e.Component,
							Problem: "sends " + name + " without \"" + key + "\" in its context, which argument " + k + " of " + a.Microtool + " takes",
							Fix:     "add \"" + key + "\" to the event's context, or take the argument from {\"$data\"}"})
					}
				}
			}
			if path, ok := ref["$data"].(string); ok && !surface.Written(path, sources) {
				r.Issues = append(r.Issues, a2ui.Issue{Severity: a2ui.Blocking, Area: "interaction", Where: where,
					Problem: "argument " + k + " reads " + path + ", which no input, selection or binding fills",
					Fix:     "bind an input's value to " + path + " or read the path one fills"})
			}
		}
		if a.Result == "" && !a.Reload {
			r.Issues = append(r.Issues, a2ui.Issue{Severity: a2ui.Advice, Area: "interaction", Where: where,
				Problem: "neither shows its result nor reloads, so the person sees nothing happen",
				Fix:     "put its result where the view reads it (\"result\") or set \"reload\": true"})
		}
		r.Tested = append(r.Tested, rv.tryAction(name, a, data, sent[name], &r.Issues))
	}
	for name, events := range sent {
		if _, ok := t.Actions[name]; !ok {
			r.Issues = append(r.Issues, a2ui.Issue{Severity: a2ui.Blocking, Area: "interaction", Where: events[0].Component,
				Problem: "sends the event " + name + ", which \"actions\" maps to nothing", Fix: "map it to a microtool"})
		}
	}

	// Every value shown is filled, and is there in what came back.
	r.Issues = append(r.Issues, surface.CheckData(data, sources)...)

	// Every microtool the tool offers is reachable.
	reached := map[string]bool{}
	for _, b := range t.Data {
		reached[b.Microtool] = true
	}
	for _, a := range t.Actions {
		reached[a.Microtool] = true
	}
	var unreached []string
	for name := range rv.commands {
		if !reached[name] {
			unreached = append(unreached, name)
		}
	}
	if len(unreached) > 0 {
		sort.Strings(unreached)
		r.Issues = append(r.Issues, a2ui.Issue{Severity: a2ui.Advice, Area: "purpose",
			Problem: "the frontend never uses " + strings.Join(unreached, ", "),
			Fix:     "offer what the skill asks for of them (a binding or an action); leave out only what the skill does not need"})
	}
	r.broken = r.blocking()

	// The surface as it looks, reviewed.
	if rv.look != nil {
		issues, err := rv.lookAt(t, surface, data, r.Issues)
		if err != nil {
			r.Tested = append(r.Tested, "design review unavailable: "+err.Error())
		} else {
			r.Issues = append(r.Issues, issues...)
			r.Tested = append(r.Tested, "design review of the rendered surface")
		}
	}
	r.Passed = r.blocking() == 0
	return r
}

// tryAction checks an action against the filled data, and runs it when its
// microtool only reads; it says what it did.
func (rv *reviewer) tryAction(name string, a Action, data map[string]any, events []a2ui.Event, issues *[]a2ui.Issue) string {
	if !rv.readOnly(a.Microtool) {
		return "action " + name + " (" + a.Microtool + ") checked, not run: it may change data"
	}
	context := map[string]any{}
	if len(events) > 0 {
		for _, k := range events[0].Context {
			context[k] = nil
		}
	}
	args := resolveArgs(a.Args, context, data)
	_, required := rv.schema(a.Microtool)
	for _, req := range required {
		if v, ok := args[req]; !ok || v == nil || v == "" {
			return "action " + name + " (" + a.Microtool + ") checked, not run: it needs \"" + req + "\" entered"
		}
	}
	if _, err := rv.run(a.Microtool, args); err != nil {
		*issues = append(*issues, a2ui.Issue{Severity: a2ui.Blocking, Area: "interaction", Where: "action " + name,
			Problem: a.Microtool + " failed when the action was run with " + compact(args) + ": " + err.Error(),
			Fix:     "pass arguments its schema accepts"})
		return "action " + name + " run: failed"
	}
	return "action " + name + " run with " + compact(args)
}

var reviewPrompt = `You review a generated tool frontend before it is shown, as a senior product designer and QA lead who ships real application UIs.
You are given the tool, what its deployer wants (the skill), its microtools, the surface as it renders (an outline: each component with the data it shows, filled by really running the tool, and what each control does) and what the automatic tests found.
Judge:
- Purpose: does it serve the skill and the tool — right data first, actions offered, nothing it cannot do, nothing important missing? Does it read as this domain's real product screen?
- Visualization-first: for numeric, temporal, categorical or tabular data, are Stats / Charts / Gauges / Tables used instead of walls of Text or Markdown? Is the hierarchy KPI strip → hero viz → evidence? Flag text-heavy or document-like screens as blocking when the data is visualizable.
- App layout & standards: the design rules below — fills the window, regions scroll inside, responsive at phone and desktop, formatted numbers with units, short labels, one primary action per region, no placeholders, filler, heroes, footers, duplicates or decorative controls, a compact phone widget.
- Interaction: can a person do each thing and see the outcome? Inputs labelled, bound and read by the action that submits them; selections shown by a detail block.
- Data: meaningful as filled (no MISSING values, no raw JSON or ids where people expect names, empty/loading states handled).
Reply with ONE JSON object: {"issues": [{"severity": "blocking" | "advice", "area": "purpose" | "design" | "interaction" | "data", "where": "<component id, data path or action>", "problem": "…", "fix": "…"}]}.
"blocking" is what makes it broken, misleading, unclean, text-heavy where it should be visual, or unfit for the tool; "advice" is polish. Name concrete component ids and concrete fixes. Do not repeat the automatic findings. An empty list means it is ready to show.
` + a2ui.DesignPrompt

// lookAt has the model review the rendered surface.
func (rv *reviewer) lookAt(t *Template, surface *a2ui.Surface, data map[string]any, found []a2ui.Issue) ([]a2ui.Issue, error) {
	var b strings.Builder
	b.WriteString("Tool: " + rv.tool + "\n\nWhat the deployer wants (skill):\n" + rv.skill + "\n\nMicrotools:\n")
	names := make([]string, 0, len(rv.commands))
	for name := range rv.commands {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		b.WriteString("- " + name + ": " + strings.TrimSpace(asString(rv.commands[name]["description"])) + "\n")
	}
	b.WriteString("\nTitle: " + t.Title + "\n\nThe surface as it renders:\n" + surface.Outline(data, 12000))
	raw, _ := json.Marshal(t.Actions)
	b.WriteString("\nActions (event → microtool): " + string(raw) + "\n")
	if len(found) > 0 {
		b.WriteString("\nAutomatic findings (already reported):\n")
		for _, i := range found {
			b.WriteString("- " + i.Severity + " " + i.String() + "\n")
		}
	}
	content, err := rv.look([]map[string]any{{"role": "system", "content": reviewPrompt}, {"role": "user", "content": b.String()}})
	if err != nil {
		return nil, err
	}
	return lookedAt(content)
}

// lookedAt reads the issues a model's review reports.
func lookedAt(content string) ([]a2ui.Issue, error) {
	var out struct {
		Issues []a2ui.Issue `json:"issues"`
	}
	if err := json.Unmarshal([]byte(jsonObject(content)), &out); err != nil {
		return nil, err
	}
	issues := out.Issues[:0]
	for _, i := range out.Issues {
		if strings.TrimSpace(i.Problem) == "" {
			continue
		}
		if i.Severity != a2ui.Blocking {
			i.Severity = a2ui.Advice
		}
		if i.Area == "" {
			i.Area = "design"
		}
		issues = append(issues, i)
	}
	return issues, nil
}

// shape sums up a result for the review's account of it.
func shape(v any) string {
	switch x := v.(type) {
	case []any:
		return "a list of " + itoa(len(x))
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		if len(keys) > 8 {
			keys = append(keys[:8], "…")
		}
		return "an object with " + strings.Join(keys, ", ")
	case nil:
		return "nothing"
	}
	return compact(v)
}

func compact(v any) string {
	raw, _ := json.Marshal(v)
	if len(raw) > 120 {
		return string(raw[:120]) + "…"
	}
	return string(raw)
}

func itoa(n int) string { return strconv.Itoa(n) }

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// reviewerFor is a reviewer that calls the tool's microtools as [c] (billed
// to them, as opening the frontend is) and looks with [look].
func (s *Service) reviewerFor(ctx context.Context, c caller, botID, toolName, skill string, commands []map[string]any, shown Shown,
	look func([]map[string]any) (string, error)) *reviewer {
	call := func(microtool string, args map[string]any) (any, error) {
		return s.call(ctx, c, botID, microtool, args)
	}
	return newReviewer(toolName, skill, commands, shown, call, look)
}
