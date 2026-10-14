// Package a2ui holds what the platform does to A2UI it receives from models
// (agents composing widgets, generated tool frontends) before storing it.
package a2ui

import (
	"regexp"
	"strings"
)

// In A2UI a plain string is a literal: data reaches a component only through
// a binding, {"path": "/x"}, or a function call — text mixed with data is
// {"call": "formatString", "args": {"value": "High ${/x}°"}}. Models write
// templated text as plain strings anyway, in ${…} or {{…}} (the syntax most
// template languages use), and both then render literally — with the path's
// underscores read as Markdown emphasis. Normalize turns them into the forms
// A2UI evaluates.

// mustache matches a {{ path }} placeholder.
var mustache = regexp.MustCompile(`\{\{\s*([A-Za-z0-9_./~\-\[\]]+)\s*\}\}`)

// whole matches a string that is nothing but one ${path}.
var whole = regexp.MustCompile(`^\$\{\s*([A-Za-z0-9_./~\-]+)\s*\}$`)

// structural keys hold component ids and names, never data.
var structural = map[string]bool{"id": true, "component": true, "child": true, "children": true, "componentId": true}

// Interpolation rewrites {{path}} placeholders in a string as ${path}.
// /a/b stays absolute; a.b and a[1] become a/b and a/1 (relative paths stay
// relative, so placeholders inside List templates keep resolving per item).
func Interpolation(s string) string {
	if !strings.Contains(s, "{{") {
		return s
	}
	return mustache.ReplaceAllStringFunc(s, func(m string) string {
		path := mustache.FindStringSubmatch(m)[1]
		if !strings.Contains(path, "/") {
			path = strings.ReplaceAll(path, ".", "/")
		}
		path = strings.NewReplacer("[", "/", "]", "").Replace(path)
		return "${" + path + "}"
	})
}

// Value is the A2UI form of a templated string: a binding when it is one
// placeholder, a formatString call when it mixes text and data, the string
// itself when it has no placeholder.
func Value(s string) any {
	t := Interpolation(s)
	if m := whole.FindStringSubmatch(t); m != nil {
		return map[string]any{"path": m[1]}
	}
	if strings.Contains(t, "${") {
		return map[string]any{"call": "formatString", "args": map[string]any{"value": t}, "returnType": "string"}
	}
	return s
}

// Normalize rewrites the templated strings of the components in place (see
// Value) and reports how many it rewrote.
func Normalize(components []map[string]any) int {
	n := 0
	for _, c := range components {
		for k, v := range c {
			if !structural[k] {
				c[k] = normalize(v, &n)
			}
		}
	}
	return n
}

func normalize(v any, n *int) any {
	switch x := v.(type) {
	case string:
		out := Value(x)
		if s, ok := out.(string); !ok || s != x {
			*n++
		}
		return out
	case map[string]any:
		if _, ok := x["path"]; ok {
			return x // a binding (or a List template's data path)
		}
		if _, ok := x["call"]; ok {
			// A function call already: its arguments are where ${…} belongs,
			// so only {{…}} is rewritten there.
			if args, ok := x["args"].(map[string]any); ok {
				for k, a := range args {
					if s, ok := a.(string); ok {
						if out := Interpolation(s); out != s {
							args[k] = out
							*n++
						}
					}
				}
			}
			return x
		}
		for k, item := range x {
			if !structural[k] {
				x[k] = normalize(item, n)
			}
		}
		return x
	case []any:
		for i, item := range x {
			x[i] = normalize(item, n)
		}
		return x
	}
	return v
}
