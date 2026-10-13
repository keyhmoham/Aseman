// Package metadata models the JSON-tree metadata attached to accounts and
// spaces. Each tree carries a version and a set of public paths. Paths not
// listed as public are private and invisible to other nodes/users.
package metadata

import (
	"encoding/json"
	"time"

	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/jsonpatch"
)

// Tree is a JSON object tree.
type Tree map[string]any

// Record is the persisted metadata for one owner (account or space).
type Record struct {
	// ID is the record key; it always equals Owner (universal id of the owner).
	ID          string          `db:"id" json:"id"`
	Owner       string          `db:"owner" json:"owner"` // universal id of owner
	Tree        Tree            `db:"tree" json:"tree"`
	PublicPaths jsonpatch.Paths `db:"public_paths" json:"public_paths"`
	Version     int64           `db:"version" json:"version"`
	UpdatedAt   time.Time       `db:"updated_at" json:"updated_at"`
}

// ApplyPatch applies partial add/update/delete ops and bumps the version.
func (r *Record) ApplyPatch(p jsonpatch.Patch) error {
	if err := p.Validate(); err != nil {
		return err
	}
	tree, err := p.Apply(r.Tree)
	if err != nil {
		return err
	}
	r.Tree = tree
	r.Version++
	return nil
}

// SetPublicPaths replaces the public path list.
func (r *Record) SetPublicPaths(ps []string) {
	r.PublicPaths = jsonpatch.Paths(ps).Normalize()
}

// PublicView returns the sub-tree visible to others under the public path list.
func (r *Record) PublicView() Tree {
	out := Tree{}
	var rec func(prefix []string, node any)
	rec = func(prefix []string, node any) {
		m, ok := node.(map[string]any)
		if !ok {
			return
		}
		for k, v := range m {
			path := append(append([]string{}, prefix...), k)
			pstr := jsonpatch.PathString(path)
			if r.PublicPaths.IsPublic(pstr) {
				_ = setDeep(out, path, v)
				rec(path, v)
			}
		}
	}
	rec(nil, map[string]any(r.Tree))
	return out
}

// MarshalJSON renders the tree compactly.
func (t Tree) MarshalJSON() ([]byte, error) { return json.Marshal(map[string]any(t)) }

// UnmarshalJSON accepts arbitrary JSON objects.
func (t *Tree) UnmarshalJSON(b []byte) error {
	m := map[string]any{}
	if err := json.Unmarshal(b, &m); err != nil {
		return errs.Wrap(errs.CodeInvalidArgument, err, "metadata must be a JSON object")
	}
	*t = Tree(m)
	return nil
}

func setDeep(root Tree, path []string, v any) error {
	cur := any(map[string]any(root))
	for i, seg := range path {
		last := i == len(path)-1
		m, ok := cur.(map[string]any)
		if !ok {
			return errs.InvalidArgument("cannot descend through non-object")
		}
		if last {
			m[seg] = v
			return nil
		}
		next, ok := m[seg]
		if !ok {
			next = map[string]any{}
			m[seg] = next
		}
		cur = next
	}
	return nil
}
