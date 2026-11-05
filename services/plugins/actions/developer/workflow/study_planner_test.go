package workflow

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// docs/workflows/study-planner.json — the agentic study planner — stays a
// valid workflow that plans, and its assets carry the whole app.
func TestStudyPlannerWorkflowIsValid(t *testing.T) {
	raw, err := os.ReadFile("../../../../../docs/workflows/study-planner.json")
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
	// The assets are the app's source, file for file (bundle.py writes them).
	const app = "../../../../../docs/workflows/study-planner/app"
	files := 0
	err = filepath.WalkDir(app, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || strings.Contains(path, "__pycache__") || strings.Contains(path, ".data") || d.Name() == "config.json" {
			return err
		}
		rel, _ := filepath.Rel(app, path)
		key := "app/" + filepath.ToSlash(rel)
		want, _ := os.ReadFile(path)
		a, ok := wf.Assets[key]
		if !ok || a.Content == nil || *a.Content != string(want) {
			t.Errorf("asset %s is missing or stale: run python3 docs/workflows/study-planner/bundle.py", key)
		}
		files++
		return nil
	})
	if err != nil || files < 12 || len(wf.Assets) != files {
		t.Fatalf("assets: %d files on disk, %d in the workflow (%v)", files, len(wf.Assets), err)
	}
	rep := Run(context.Background(), wf, newFake(), nil, Options{Mode: ModePlan, ErrorCode: codeOf,
		Inputs: map[string]any{"developer_api_url": "http://aseman:8080/dev/v1", "team": []any{"bob"}}})
	if rep.Status != StatusPlanned {
		t.Fatalf("plan: %s %s\n%s", rep.Status, rep.Error, dump(rep))
	}
	if !strings.Contains(dump(rep), "Planner") {
		t.Fatal("the plan does not make the Planner agent")
	}
}
