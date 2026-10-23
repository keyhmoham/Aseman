package tools

import (
	"context"
	"encoding/json"
	"sort"
	"strconv"
	"strings"

	"github.com/aseman/aseman/pkg/surface"
)

// A frontend is reviewed with a deterministic gate only: inspect +
// composition rules + live microtool fill + action checks. Subjective LLM
// design judges are not in the accept or repair loop.
//
// Author-time repair (LLM fallback only) is capped at surface.MaxRepairAttempts
// and stops when the blocking issue fingerprint does not shrink.

// reviewRounds bounds author-time generate→validate→repair (LLM fallback).
const reviewRounds = surface.MaxRepairAttempts

// Review is what the review of a generated frontend found.
type Review struct {
	// Passed: nothing blocking was left.
	Passed bool `json:"passed"`
	// Rounds is how many rounds it took.
	Rounds int `json:"rounds"`
	// Tested is what was run and checked live.
	Tested []string     `json:"tested,omitempty"`
	Issues []surface.Issue `json:"issues,omitempty"`
	// broken counts blocking issues from the deterministic gate (inspect,
	// composition, live fill, actions).
	broken int
}

// blocking counts the review's blocking issues.
func (r *Review) blocking() int {
	n := 0
	for _, i := range r.Issues {
		if i.Severity == surface.Blocking {
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
	for _, severity := range []string{surface.Blocking, surface.Advice} {
		first := true
		for _, i := range r.Issues {
			if i.Severity != severity {
				continue
			}
			if first {
				if severity == surface.Blocking {
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
	b.WriteString("\nReply with the whole corrected JSON object only: {\"title\", \"components\": [flat list, each {\"id\", \"type\", ...props}], \"data\", \"actions\"}. Fix only what the Blocking lines name; keep everything else exactly as it was.")
	return b.String()
}

// summary is a short account of the review for errors and logs.
func (r *Review) summary(max int) string {
	var lines []string
	for _, i := range r.Issues {
		if i.Severity == surface.Blocking {
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
}

type result struct {
	value any
	err   error
}

func newReviewer(tool, skill string, commands []map[string]any, shown Shown, call func(string, map[string]any) (any, error)) *reviewer {
	byName := map[string]map[string]any{}
	for _, cmd := range commands {
		if name, _ := cmd["name"].(string); name != "" {
			byName[name] = cmd
		}
	}
	return &reviewer{tool: tool, skill: skill, commands: byName, shown: shown, call: call, calls: map[string]result{}}
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
	return surface.SchemaArgs(schema)
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
func (rv *reviewer) checkArgs(where, microtool string, args map[string]any) []surface.Issue {
	schema, _ := rv.commands[microtool]["schema"].(map[string]any)
	return surface.CheckArgs(where, microtool, schema, args, "a literal, {\"$data\": \"/form/…\"} or {\"$context\": \"…\"} in an action")
}

// review inspects and tests a template, filling it as the person asking
// would see it. Accept/reject is deterministic.
func (rv *reviewer) review(t *Template) *Review {
	r := &Review{}
	inspected := surface.Inspect(t.Components)
	surface.GateComposition(inspected, rv.skill)
	r.Issues = append(r.Issues, inspected.Issues...)
	r.Issues = append(r.Issues, surface.ValidateProps(t.Components)...)

	// The data bindings, run as opening the frontend runs them.
	data := map[string]any{}
	var sources []surface.Source
	for _, b := range t.bindings(rv.shown) {
		where := "data " + b.Path
		r.Issues = append(r.Issues, rv.checkArgs(where, b.Microtool, b.Args)...)
		for k, v := range b.Args {
			if ref, ok := v.(map[string]any); ok && (ref["$data"] != nil || ref["$context"] != nil) {
				r.Issues = append(r.Issues, surface.Issue{Severity: surface.Blocking, Area: "data", Where: where,
					Problem: "argument " + k + " of a data binding is a reference; bindings run before anything is entered",
					Fix:     "give bindings literal arguments; run what depends on input from an action"})
			}
		}
		src := surface.Source{Path: b.Path, From: b.Microtool, Live: true}
		v, err := rv.run(b.Microtool, b.Args)
		if err != nil {
			src.Err = err.Error()
			r.Issues = append(r.Issues, surface.Issue{Severity: surface.Blocking, Area: "data", Where: where,
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
	sent := map[string][]surface.Event{}
	for _, e := range inspected.Events {
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
			r.Issues = append(r.Issues, surface.Issue{Severity: surface.Blocking, Area: "interaction", Where: where,
				Problem: "runs no microtool, so its button does nothing", Fix: "map it to a microtool or remove its button"})
			continue
		}
		if a.Result != "" {
			sources = append(sources, surface.Source{Path: a.Result, From: "the action " + name, Optional: true})
		}
		if len(sent[name]) == 0 {
			r.Issues = append(r.Issues, surface.Issue{Severity: surface.Advice, Area: "interaction", Where: where,
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
						r.Issues = append(r.Issues, surface.Issue{Severity: surface.Blocking, Area: "interaction", Where: e.Component,
							Problem: "sends " + name + " without \"" + key + "\" in its context, which argument " + k + " of " + a.Microtool + " takes",
							Fix:     "add \"" + key + "\" to the event's context, or take the argument from {\"$data\"}"})
					}
				}
			}
			if path, ok := ref["$data"].(string); ok && !inspected.Written(path, sources) {
				r.Issues = append(r.Issues, surface.Issue{Severity: surface.Blocking, Area: "interaction", Where: where,
					Problem: "argument " + k + " reads " + path + ", which no input, selection or binding fills",
					Fix:     "bind an input's value to " + path + " or read the path one fills"})
			}
		}
		if a.Result == "" && !a.Reload {
			r.Issues = append(r.Issues, surface.Issue{Severity: surface.Advice, Area: "interaction", Where: where,
				Problem: "neither shows its result nor reloads, so the person sees nothing happen",
				Fix:     "put its result where the view reads it (\"result\") or set \"reload\": true"})
		}
		r.Tested = append(r.Tested, rv.tryAction(name, a, data, sent[name], &r.Issues))
	}
	for name, events := range sent {
		if _, ok := t.Actions[name]; !ok {
			r.Issues = append(r.Issues, surface.Issue{Severity: surface.Blocking, Area: "interaction", Where: events[0].Component,
				Problem: "sends the event " + name + ", which \"actions\" maps to nothing", Fix: "map it to a microtool"})
		}
	}

	// Every value shown is filled, and is there in what came back.
	r.Issues = append(r.Issues, inspected.CheckData(data, sources)...)

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
		r.Issues = append(r.Issues, surface.Issue{Severity: surface.Advice, Area: "purpose",
			Problem: "the frontend never uses " + strings.Join(unreached, ", "),
			Fix:     "offer what the skill asks for of them (a binding or an action); leave out only what the skill does not need"})
	}
	r.broken = r.blocking()
	r.Passed = r.broken == 0
	return r
}

// tryAction checks an action against the filled data, and runs it when its
// microtool only reads; it says what it did.
func (rv *reviewer) tryAction(name string, a Action, data map[string]any, events []surface.Event, issues *[]surface.Issue) string {
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
		*issues = append(*issues, surface.Issue{Severity: surface.Blocking, Area: "interaction", Where: "action " + name,
			Problem: a.Microtool + " failed when the action was run with " + compact(args) + ": " + err.Error(),
			Fix:     "pass arguments its schema accepts"})
		return "action " + name + " run: failed"
	}
	return "action " + name + " run with " + compact(args)
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
// to them, as opening the frontend is).
func (s *Service) reviewerFor(ctx context.Context, c caller, botID, toolName, skill string, commands []map[string]any, shown Shown) *reviewer {
	call := func(microtool string, args map[string]any) (any, error) {
		return s.call(ctx, c, botID, microtool, args)
	}
	return newReviewer(toolName, skill, commands, shown, call)
}
