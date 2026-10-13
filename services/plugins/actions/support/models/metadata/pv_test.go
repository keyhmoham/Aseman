package metadata

import "testing"

func TestPublicViewShowsOnlyPublicPaths(t *testing.T) {
	r := &Record{Tree: Tree{
		"profile":    map[string]any{"name": "a"},
		"descriptor": map[string]any{"username": "bob", "category": "dev"},
		"auth":       map[string]any{"secret": 1},
	}}
	r.SetPublicPaths([]string{"/profile", "/descriptor"})
	v := r.PublicView()
	d, ok := v["descriptor"].(map[string]any)
	if !ok || d["username"] != "bob" || d["category"] != "dev" {
		t.Fatalf("descriptor not public: %v", v)
	}
	if _, leaked := v["auth"]; leaked {
		t.Fatalf("private path leaked: %v", v)
	}
	if _, ok := v["profile"].(map[string]any); !ok {
		t.Fatalf("profile not public: %v", v)
	}
	r.SetPublicPaths([]string{"/profile/name"})
	v = r.PublicView()
	if p, _ := v["profile"].(map[string]any); p["name"] != "a" || v["descriptor"] != nil {
		t.Fatalf("nested public path: %v", v)
	}
}
