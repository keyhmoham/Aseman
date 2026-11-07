package workflow

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// docs/workflows/aseman-arena.json — the 3D gaming platform — stays a valid
// workflow that plans, and its assets carry the whole platform: the server
// and Elpian frontend (app/) and the games' sources (games/).
func TestAsemanArenaWorkflowIsValid(t *testing.T) {
	raw, err := os.ReadFile("../../../../../docs/workflows/aseman-arena.json")
	if err != nil {
		t.Fatal(err)
	}
	wf, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	if issues := Validate(wf, nil); len(issues) > 0 {
		t.Fatalf("issues: %+v", issues)
	}
	const root = "../../../../../docs/workflows/aseman-arena"
	skipDirs := map[string]bool{"__pycache__": true, ".data": true, ".aseman": true, ".godot": true, ".cache": true, "build": true, "models": true, ".deploy": true, "node_modules": true}
	skipFiles := map[string]bool{"config.json": true, "READY.json": true, "APPS.json": true, "STATUS.json": true, "REPAIR.md": true, "WIRING.md": true, "verify.log": true, ".elpian-served.js": true}
	files := 0
	for _, top := range []string{"app", "games"} {
		err = filepath.WalkDir(filepath.Join(root, top), func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				if skipDirs[d.Name()] || (d.Name() == "assets" && filepath.Base(filepath.Dir(path)) == "public") {
					return filepath.SkipDir
				}
				return nil
			}
			rel, _ := filepath.Rel(root, path)
			rel = filepath.ToSlash(rel)
			name := d.Name()
			if skipFiles[name] || rel == "app/elpian/app.js" || rel == "app/elpian/widget.js" ||
				strings.HasSuffix(name, ".pyc") || strings.HasSuffix(name, ".tmp") || strings.HasSuffix(name, ".import") || strings.HasSuffix(name, ".uid") {
				return nil // written or downloaded on the project's computer (bundle.py skips them too)
			}
			want, _ := os.ReadFile(path)
			a, ok := wf.Assets[rel]
			if !ok || a.Content == nil || *a.Content != string(want) {
				t.Errorf("asset %s is missing or stale: run python3 docs/workflows/aseman-arena/bundle.py", rel)
			}
			files++
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	if files < 50 || len(wf.Assets) != files {
		t.Fatalf("assets: %d files on disk, %d in the workflow", files, len(wf.Assets))
	}
	rep := Run(context.Background(), wf, newFake(), nil, Options{Mode: ModePlan, ErrorCode: codeOf,
		Inputs: map[string]any{"developer_api_url": "http://aseman:8080/dev/v1", "public_url": "https://arena.example.com", "team": []any{"bob"}}})
	if rep.Status != StatusPlanned {
		t.Fatalf("plan: %s %s\n%s", rep.Status, rep.Error, dump(rep))
	}
	// The frontend says it is the platform's (appui_publish reads READY.json).
	if !strings.Contains(string(raw), `"audience": "platform"`) {
		t.Fatal("READY.json does not name the platform as the frontend's audience")
	}
	text := dump(rep)
	for _, want := range []string{"Forge", "Steward", "appui_publish", "platform_publish", "READY.json", "build.sh all", "arena_smoke.py",
		"https://arena.example.com/v1/platforms/aseman-arena/app/"} {
		if !strings.Contains(text, want) {
			t.Fatalf("the plan has no %q", want)
		}
	}
}
