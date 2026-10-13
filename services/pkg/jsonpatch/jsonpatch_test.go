package jsonpatch

import "testing"

func TestApplySetAndRemove(t *testing.T) {
	tree := map[string]any{"a": map[string]any{"b": 1}, "list": []any{"x", "y"}}
	p := Patch{
		{Op: "set", Path: "/a/c", Value: "new"},
		{Op: "remove", Path: "/list/0"},
		{Op: "add", Path: "/d", Value: 42},
	}
	out, err := p.Apply(tree)
	if err != nil {
		t.Fatal(err)
	}
	if out["a"].(map[string]any)["c"] != "new" {
		t.Fatal("set failed")
	}
	if _, ok := out["a"].(map[string]any)["b"]; !ok {
		t.Fatal("clone should keep untouched siblings")
	}
	if tree["a"].(map[string]any)["b"] != 1 {
		t.Fatal("input tree was mutated")
	}
	if got := out["d"]; got != 42 {
		t.Fatalf("add failed: %v", got)
	}
	if out["list"].([]any)[0] != "y" {
		t.Fatal("remove failed")
	}
}

func TestApplyErrors(t *testing.T) {
	tree := map[string]any{"a": 1}
	if _, err := (Patch{{Op: "remove", Path: "/a"}}).Apply(map[string]any{}); err == nil {
		t.Fatal("expected error removing missing path")
	}
	if _, err := (Patch{{Op: "bogus", Path: "/a"}}).Apply(tree); err == nil {
		t.Fatal("expected error for unknown op")
	}
	if err := (Patch{{Op: "set", Path: "/a//b"}}).Validate(); err == nil {
		t.Fatal("expected error for empty segment")
	}
}

func TestPublicPaths(t *testing.T) {
	public := Paths{"/profile", "/settings/pin"}.Normalize()
	if !public.IsPublic("/profile") {
		t.Fatal("/profile should be public")
	}
	if !public.IsPublic("/profile/displayName") {
		t.Fatal("descendant of public path should be public")
	}
	if public.IsPublic("/private") {
		t.Fatal("/private should be private")
	}
	if !public.IsPublic("/settings") {
		t.Fatal("ancestor of a public path should be visible")
	}
	root := Paths{"/"}
	if !root.IsPublic("/anything/deep") {
		t.Fatal("root path makes everything public")
	}
	empty := Paths{}
	if empty.IsPublic("/x") {
		t.Fatal("empty public paths should expose nothing")
	}
}

func TestNormalize(t *testing.T) {
	ps := Paths{"/b", "a", "/b", "/c/"}.Normalize()
	if len(ps) != 3 {
		t.Fatalf("expected 3 unique paths, got %v", ps)
	}
	if ps[0] != "/a" || ps[1] != "/b" || ps[2] != "/c" {
		t.Fatalf("bad normalization: %v", ps)
	}
}

func TestCloneDeep(t *testing.T) {
	src := map[string]any{"a": map[string]any{"b": []any{1, 2}}}
	c := Clone(src)
	c["a"].(map[string]any)["b"].([]any)[0] = 99
	if src["a"].(map[string]any)["b"].([]any)[0] != 1 {
		t.Fatal("clone should be deep")
	}
}
