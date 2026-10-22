package spaces

import (
	"strings"
	"testing"
	"time"
)

func TestDeskFileWindows(t *testing.T) {
	d := Desktop{Viewport: DeskViewport{W: 1600, H: 900}}
	now := time.Now()
	id, err := d.Apply(DeskOp{Op: "open", Kind: DeskFile, Tool: "ignored", Microtool: "ignored", Args: map[string]any{"path": "/workspace/src/../src/main.go", "extra": 1}}, "ann", now)
	if err != nil {
		t.Fatal(err)
	}
	w := d.window(id)
	if w.Tool != DeskFileTool || w.Frontend != DeskFileFrontend || w.Microtool != "" || len(w.Args) != 1 || w.FilePath() != "/workspace/src/main.go" || w.Title != "main.go" {
		t.Fatalf("file window = %+v", w)
	}
	// The same file again is the same window; a relative path is in the workspace.
	again, err := d.Apply(DeskOp{Op: "open", Kind: DeskFile, Args: map[string]any{"path": "src/main.go"}}, "ann", now)
	if err != nil || again != id || len(d.Windows) != 1 {
		t.Fatalf("reopen = %q, %v, %d windows", again, err, len(d.Windows))
	}
	for _, bad := range []any{"", "/workspace", "/workspace/../etc/passwd", browserProfileDir + "/Cookies", 7} {
		if _, err := d.Apply(DeskOp{Op: "open", Kind: DeskFile, Args: map[string]any{"path": bad}}, "ann", now); err == nil {
			t.Fatalf("opened %v", bad)
		}
	}
	if _, err := d.Apply(DeskOp{Op: "pin", ID: id}, "ann", now); err != nil || d.Pins[0].Kind != DeskFile || d.Pins[0].Args["path"] != "/workspace/src/main.go" {
		t.Fatalf("pin = %v, %+v", err, d.Pins)
	}
	if s := d.Summary(); !strings.Contains(s, "file /workspace/src/main.go") {
		t.Fatalf("summary = %s", s)
	}
}

func TestDeskStoredFileWindows(t *testing.T) {
	d := Desktop{Viewport: DeskViewport{W: 1600, H: 900}}
	now := time.Now()
	const file = "0123456789ABCDEF0123456789abcdef"
	id, err := d.Apply(DeskOp{Op: "open", Kind: DeskFile, Title: "clip.mp4", Args: map[string]any{"file_id": file, "path": "/workspace/x", "extra": 1}}, "ann", now)
	if err != nil {
		t.Fatal(err)
	}
	w := d.window(id)
	if w.Tool != DeskFileTool || w.Frontend != DeskFileFrontend || len(w.Args) != 1 || w.FileID() != strings.ToLower(file) || w.FilePath() != "" || w.Title != "clip.mp4" {
		t.Fatalf("file window = %+v", w)
	}
	// The same file again is the same window.
	again, err := d.Apply(DeskOp{Op: "open", Kind: DeskFile, Args: map[string]any{"file_id": strings.ToLower(file)}}, "ann", now)
	if err != nil || again != id || len(d.Windows) != 1 {
		t.Fatalf("reopen = %q, %v, %d windows", again, err, len(d.Windows))
	}
	for _, bad := range []any{"", "abc", "../0123456789abcdef0123456789abcd", "0123456789abcdef0123456789abcdeg", 7} {
		if _, err := d.Apply(DeskOp{Op: "open", Kind: DeskFile, Args: map[string]any{"file_id": bad}}, "ann", now); err == nil {
			t.Fatalf("opened %v", bad)
		}
	}
	if s := d.Summary(); !strings.Contains(s, "shared file "+strings.ToLower(file)) {
		t.Fatalf("summary = %s", s)
	}
}
