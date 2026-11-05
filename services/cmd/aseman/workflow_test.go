package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWorkflowCLIHelpers(t *testing.T) {
	got := reorder([]string{"wf.json", "product=Acme", "--async", "--key", "dk_live_x", "--secret=A=1"})
	want := []string{"--async", "--key", "dk_live_x", "--secret=A=1", "wf.json", "product=Acme"}
	if len(got) != len(want) {
		t.Fatalf("%v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("%v", got)
		}
	}

	t.Setenv("FROM_ENV", "env-value")
	s := collectSecrets(map[string]any{"secrets": []any{"GIVEN", "FROM_ENV", map[string]any{"name": "MISSING"}}}, []string{"GIVEN=x=y"})
	if s["GIVEN"] != "x=y" || s["FROM_ENV"] != "env-value" || len(s) != 2 {
		t.Fatalf("%v", s)
	}

	dir := t.TempDir()
	_ = os.MkdirAll(filepath.Join(dir, "src", "node_modules"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, "src", "main.py"), []byte("print(1)"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, "src", "logo.bin"), []byte{0, 1, 2}, 0o644)
	_ = os.WriteFile(filepath.Join(dir, "src", "node_modules", "big.js"), []byte("x"), 0o644)
	wf := filepath.Join(dir, "wf.json")
	_ = os.WriteFile(wf, []byte(`{"aseman_workflow":"1","name":"x","steps":[],"assets":{"keep":"me"}}`), 0o644)
	doc := loadDocument(wf, []string{filepath.Join(dir, "src") + "=app/"})
	assets := doc["assets"].(map[string]any)
	if assets["keep"] != "me" || len(assets) != 3 {
		t.Fatalf("assets: %v", assets)
	}
	if m := assets["app/main.py"].(map[string]any); m["content"] != "print(1)" || m["mode"] != "0755" {
		t.Fatalf("text: %v", m)
	}
	if m := assets["app/logo.bin"].(map[string]any); m["base64"] != "AAEC" {
		t.Fatalf("binary: %v", m)
	}
}
