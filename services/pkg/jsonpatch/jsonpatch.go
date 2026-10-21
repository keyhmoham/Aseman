// Package jsonpatch implements partial JSON tree operations (add / set / remove)
// used for federated metadata trees, profile updates and space metadata.
//
// A metadata tree is a generic JSON object. Callers address nodes with slash
// separated JSON pointers (e.g. "profile/displayName", "members/0/role").
package jsonpatch

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/aseman/aseman/pkg/errs"
)

// Op is a single mutation operation.
type Op struct {
	Op    string `json:"op"` // "add" | "set" | "remove"
	Path  string `json:"path"`
	Value any    `json:"value,omitempty"`
}

// Patch is an ordered set of operations applied atomically.
type Patch []Op

// Apply applies the patch to a deep-copied tree and returns the new tree.
// It never mutates the input.
func (p Patch) Apply(tree map[string]any) (map[string]any, error) {
	out := Clone(tree)
	for _, op := range p {
		if err := op.apply(out); err != nil {
			return nil, err
		}
	}
	return out, nil
}

func (o Op) apply(root map[string]any) error {
	segs, err := parsePath(o.Path)
	if err != nil {
		return err
	}
	if len(segs) == 0 {
		return errs.InvalidArgument("empty patch path")
	}
	switch o.Op {
	case "add", "set":
		return setPath(root, segs, o.Value)
	case "remove":
		return removePath(root, segs)
	default:
		return errs.InvalidArgument(fmt.Sprintf("unknown op %q", o.Op))
	}
}

// Validate checks op names and path syntax without applying.
func (p Patch) Validate() error {
	for _, o := range p {
		switch o.Op {
		case "add", "set", "remove":
		default:
			return errs.InvalidArgument(fmt.Sprintf("unknown op %q", o.Op))
		}
		if _, err := parsePath(o.Path); err != nil {
			return err
		}
	}
	return nil
}

// MarshalJSON renders a patch in standard RFC 6902 style.
func (p Patch) MarshalJSON() ([]byte, error) {
	type wire struct {
		Op    string `json:"op"`
		Path  string `json:"path"`
		Value any    `json:"value,omitempty"`
	}
	out := make([]wire, len(p))
	for i, o := range p {
		out[i] = wire{Op: o.Op, Path: o.Path, Value: o.Value}
	}
	return json.Marshal(out)
}

func parsePath(path string) ([]string, error) {
	path = strings.TrimSpace(path)
	if path == "" || path == "/" {
		return nil, nil
	}
	path = strings.TrimPrefix(path, "/")
	raw := strings.Split(path, "/")
	segs := make([]string, 0, len(raw))
	for _, s := range raw {
		if s == "" {
			return nil, errs.InvalidArgument("path must not contain empty segments")
		}
		segs = append(segs, strings.ReplaceAll(s, "~1", "/"))
	}
	return segs, nil
}

// PathString renders segments back into a slash separated path.
func PathString(segs []string) string {
	escaped := make([]string, len(segs))
	for i, s := range segs {
		escaped[i] = strings.ReplaceAll(s, "/", "~1")
	}
	return "/" + strings.Join(escaped, "/")
}

func setPath(root map[string]any, segs []string, value any) error {
	cur := any(root)
	for i, seg := range segs {
		last := i == len(segs)-1
		if m, ok := cur.(map[string]any); ok {
			if last {
				m[seg] = value
				return nil
			}
			next, exists := m[seg]
			if !exists {
				next = map[string]any{}
				m[seg] = next
			}
			cur = next
			continue
		}
		if l, ok := cur.([]any); ok {
			idx, err := indexOf(seg, len(l))
			if err != nil {
				return err
			}
			if last {
				l[idx] = value
				return nil
			}
			var next any
			if idx >= len(l) {
				next = map[string]any{}
				l = append(l, next)
			} else {
				next = l[idx]
			}
			cur = next
			continue
		}
		return errs.InvalidArgument("cannot descend into scalar value at path")
	}
	return nil
}

func removePath(root map[string]any, segs []string) error {
	cur := any(root)
	for i, seg := range segs {
		last := i == len(segs)-1
		switch m := cur.(type) {
		case map[string]any:
			if last {
				if _, ok := m[seg]; !ok {
					return errs.NotFound("path does not exist")
				}
				delete(m, seg)
				return nil
			}
			next, ok := m[seg]
			if !ok {
				return errs.NotFound("path does not exist")
			}
			cur = next
		case []any:
			idx, err := indexOf(seg, len(m))
			if err != nil {
				return err
			}
			if last {
				m = append(m[:idx], m[idx+1:]...)
				return nil
			}
			cur = m[idx]
		default:
			return errs.InvalidArgument("cannot descend into scalar value at path")
		}
	}
	return nil
}

func indexOf(seg string, n int) (int, error) {
	idx, err := strconv.Atoi(seg)
	if err != nil || idx < 0 || idx >= n {
		return 0, errs.InvalidArgument(fmt.Sprintf("invalid array index %q", seg))
	}
	return idx, nil
}

// Clone deep clones a JSON tree.
func Clone(tree map[string]any) map[string]any {
	b, err := json.Marshal(tree)
	if err != nil {
		return map[string]any{}
	}
	out := map[string]any{}
	_ = json.Unmarshal(b, &out)
	return out
}

// Paths is an ordered, de-duplicated list of JSON tree paths.
type Paths []string

// Contains reports whether p is exactly listed.
func (ps Paths) Contains(p string) bool {
	for _, s := range ps {
		if s == p {
			return true
		}
	}
	return false
}

// Normalize trims, de-duplicates and sorts.
func (ps Paths) Normalize() Paths {
	seen := map[string]struct{}{}
	out := Paths{}
	for _, p := range ps {
		p = strings.TrimSpace(p)
		p = strings.TrimSuffix(p, "/")
		p = "/" + strings.TrimPrefix(p, "/")
		if p == "/" {
			continue
		}
		if _, ok := seen[p]; ok {
			continue
		}
		seen[p] = struct{}{}
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// IsPublic determines whether a path is public under a set of public paths.
// A path is public if it equals a public path, is a descendant of one, or has a
// public path as a descendant... Rules (deterministic, root="/" makes all public):
//
//  1. If "/" is listed, everything is public.
//  2. If any public path P is a prefix of candidate C (P == C or P is an
//     ancestor segment of C), then C is public.
//  3. If candidate C is an ancestor of a public path P (C is a prefix of P), C
//     is considered public (an object containing a public child is visible).
func (ps Paths) IsPublic(candidate string) bool {
	if len(ps) == 0 {
		return false
	}
	candidate = "/" + strings.TrimPrefix(strings.TrimSpace(candidate), "/")
	segs := strings.Split(strings.Trim(candidate, "/"), "/")
	if segs[0] == "" {
		segs = []string{}
	}
	for _, pub := range ps {
		pub = "/" + strings.TrimPrefix(strings.TrimSpace(pub), "/")
		if pub == "/" {
			return true
		}
		psegs := strings.Split(strings.Trim(pub, "/"), "/")
		if prefixOf(psegs, segs) || prefixOf(segs, psegs) {
			return true
		}
	}
	return false
}

// PrefixOf reports whether a is a segment-prefix of b.
func prefixOf(a, b []string) bool {
	if len(a) > len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
