package surface

import (
	"fmt"
	"sort"
	"strings"
)

// Flatten repairs the component list a model wrote into the flat list the Surface Spec
// wants. Models get the shape wrong in a few common ways, all repaired here:
//
//   - children written inline (objects in "child", "children", "trigger",
//     "content" or a tab's "child") instead of ids: they are moved into the
//     list, given ids, and referenced by them;
//   - the type under "type", "kind" or "widget" instead of "component", or the
//     {"Text": {...props}} shorthand;
//   - no ids: they are generated;
//   - the components as an object keyed by id, or a single component;
//   - no "root": the one top-level component becomes it, or a Column holding
//     the top-level components does.
//
// What still has no type is dropped, with the references to it.
func Flatten(raw any) []map[string]any {
	f := &flattener{used: map[string]bool{}}
	var top []any
	switch v := raw.(type) {
	case []any:
		top = v
	case []map[string]any:
		// Author-time / archetype expanders emit typed slices.
		top = make([]any, len(v))
		for i := range v {
			top[i] = v[i]
		}
	case map[string]any:
		if _, ok := typeOf(v); ok {
			top = []any{v}
		} else {
			// Keyed by id.
			keys := make([]string, 0, len(v))
			for k := range v {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				if c, ok := v[k].(map[string]any); ok {
					if _, has := c["id"]; !has {
						c["id"] = k
					}
					top = append(top, c)
				}
			}
		}
	}
	// Ids the model gave are kept; generated ones avoid them.
	for _, c := range top {
		if m, ok := c.(map[string]any); ok {
			if id, ok := m["id"].(string); ok && id != "" {
				f.used[id] = true
			}
		}
	}
	var roots []string
	for _, c := range top {
		if m, ok := c.(map[string]any); ok {
			if id := f.add(m); id != "" {
				roots = append(roots, id)
			}
		}
	}
	f.drop()
	if !f.has("root") {
		referenced := f.referenced()
		var free []string
		for _, id := range roots {
			if !referenced[id] && f.has(id) {
				free = append(free, id)
			}
		}
		switch len(free) {
		case 0:
		case 1:
			f.rename(free[0], "root")
		default:
			children := make([]any, len(free))
			for i, id := range free {
				children[i] = id
			}
			f.out = append([]map[string]any{{"id": "root", "component": "Column", "children": children}}, f.out...)
		}
	}
	return f.out
}

type flattener struct {
	out  []map[string]any
	used map[string]bool
	n    int
}

var typeKeys = []string{"type", "component", "kind", "widget"}

// typeOf is a component's type and whether it has one. Prefers "type" when it
// names a known component; otherwise "component" (so Chart can keep type=line).
func typeOf(c map[string]any) (string, bool) {
	t, _ := c["type"].(string)
	comp, _ := c["component"].(string)
	if name, ok := knownName(t); ok {
		return name, true
	}
	if name, ok := knownName(comp); ok {
		return name, true
	}
	for _, k := range []string{"kind", "widget"} {
		if s, ok := c[k].(string); ok {
			if name, ok := knownName(s); ok {
				return name, true
			}
		}
	}
	if comp != "" {
		return comp, true // unknown types are Check's to report
	}
	if t != "" {
		return t, true
	}
	for _, k := range []string{"kind", "widget"} {
		if s, ok := c[k].(string); ok && s != "" {
			return s, true
		}
	}
	return "", false
}

// knownName is the catalog's spelling of a component type written in any
// case ("text", "TEXT" are Text).
func knownName(s string) (string, bool) {
	if known[s] {
		return s, true
	}
	for name := range known {
		if strings.EqualFold(name, s) {
			return name, true
		}
	}
	return "", false
}

func (f *flattener) newID(kind string) string {
	for {
		f.n++
		id := fmt.Sprintf("%s%d", lower(kind), f.n)
		if !f.used[id] {
			f.used[id] = true
			return id
		}
	}
}

func lower(s string) string {
	if s == "" {
		return "c"
	}
	b := []byte(s)
	if b[0] >= 'A' && b[0] <= 'Z' {
		b[0] += 'a' - 'A'
	}
	return string(b)
}

// add moves [c] (and what it holds inline) into the list; it returns its id,
// or "" when it is no component.
func (f *flattener) add(c map[string]any) string {
	// {"Text": {...}} shorthand.
	if len(c) == 1 {
		for k, v := range c {
			if props, ok := v.(map[string]any); ok {
				if name, ok := knownName(k); ok {
					props["type"] = name
					c = props
				}
			}
		}
	}
	kind, ok := typeOf(c)
	if !ok {
		return ""
	}
	// Prefer "type" as the discriminator; keep a non-component "type" (Chart
	// series) and write the kind to "component" instead.
	if t, _ := c["type"].(string); t == "" || t == kind || known[t] {
		c["type"] = kind
		if comp, _ := c["component"].(string); comp == "" || comp == kind || known[comp] {
			delete(c, "component")
		}
	} else {
		c["component"] = kind
	}
	for _, k := range []string{"kind", "widget"} {
		if s, ok := c[k].(string); ok {
			if name, ok := knownName(s); ok && name == kind {
				delete(c, k)
			} else if s == kind {
				delete(c, k)
			}
		}
	}
	id, _ := c["id"].(string)
	if id == "" {
		id = f.newID(kind)
		c["id"] = id
	}
	f.out = append(f.out, c)
	for _, key := range []string{"child", "trigger", "content", "trailing"} {
		if inner, ok := c[key].(map[string]any); ok {
			if cid := f.add(inner); cid != "" {
				c[key] = cid
			} else {
				delete(c, key)
			}
		}
	}
	switch ch := c["children"].(type) {
	case []any:
		ids := make([]any, 0, len(ch))
		for _, item := range ch {
			switch v := item.(type) {
			case string:
				ids = append(ids, v)
			case map[string]any:
				if cid := f.add(v); cid != "" {
					ids = append(ids, cid)
				}
			}
		}
		c["children"] = ids
	case map[string]any:
		if _, template := ch["componentId"]; !template {
			if cid := f.add(ch); cid != "" {
				c["children"] = []any{cid}
			}
		} else if inner, ok := ch["componentId"].(map[string]any); ok {
			if cid := f.add(inner); cid != "" {
				ch["componentId"] = cid
			}
		}
	}
	for _, key := range []string{"tabs", "panes"} {
		if tabs, ok := c[key].([]any); ok {
			for _, t := range tabs {
				if tab, ok := t.(map[string]any); ok {
					if inner, ok := tab["child"].(map[string]any); ok {
						if cid := f.add(inner); cid != "" {
							tab["child"] = cid
						}
					}
				}
			}
		}
	}
	return id
}

func (f *flattener) has(id string) bool {
	for _, c := range f.out {
		if c["id"] == id {
			return true
		}
	}
	return false
}

// referenced are the ids components point at.
func (f *flattener) referenced() map[string]bool {
	out := map[string]bool{}
	for _, c := range f.out {
		for _, key := range []string{"child", "trigger", "content", "trailing"} {
			if s, ok := c[key].(string); ok {
				out[s] = true
			}
		}
		if ch, ok := c["children"].([]any); ok {
			for _, v := range ch {
				if s, ok := v.(string); ok {
					out[s] = true
				}
			}
		}
		if ch, ok := c["children"].(map[string]any); ok {
			if s, ok := ch["componentId"].(string); ok {
				out[s] = true
			}
		}
		for _, key := range []string{"tabs", "panes"} {
			if tabs, ok := c[key].([]any); ok {
				for _, t := range tabs {
					if tab, ok := t.(map[string]any); ok {
						if s, ok := tab["child"].(string); ok {
							out[s] = true
						}
					}
				}
			}
		}
	}
	return out
}

func (f *flattener) rename(from, to string) {
	for _, c := range f.out {
		if c["id"] == from {
			c["id"] = to
		}
	}
}

// drop removes references to ids nothing defines (what had no type).
func (f *flattener) drop() {
	defined := map[string]bool{}
	for _, c := range f.out {
		if id, ok := c["id"].(string); ok {
			defined[id] = true
		}
	}
	for _, c := range f.out {
		if ch, ok := c["children"].([]any); ok {
			kept := ch[:0]
			for _, v := range ch {
				if s, ok := v.(string); !ok || defined[s] {
					kept = append(kept, v)
				}
			}
			c["children"] = kept
		}
	}
}
