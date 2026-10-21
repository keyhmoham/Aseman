package spaces

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func TestSourceSearchSupportsRegexAndExplicitLiteralMode(t *testing.T) {
	source := []byte("unrelated\n@media (max-width: 400px) {}\nconst form = document.querySelector('#contact-form');\nform.addEventListener('submit', validate);\n@media|contact-form\n")
	pattern := `@media|contact-form|addEventListener\('submit'`
	match, err := sourceMatcher(pattern, false)
	if err != nil {
		t.Fatal(err)
	}
	result := searchMatchingSource(source, "index.html", pattern, "regex", 0, 2000, match)
	for _, want := range []string{"2: @media", "3: const form", "4: form.addEventListener"} {
		if !strings.Contains(result, want) {
			t.Fatalf("regex search lost %q: %s", want, result)
		}
	}
	literal, err := sourceMatcher("@media|contact-form", true)
	if err != nil || literal("@media") || !literal("@media|contact-form") {
		t.Fatal("literal search interpreted regex syntax")
	}
	if _, err := sourceMatcher("[", false); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("malformed regex was not rejected: %v", err)
	}
}

func TestTargetedEditRejectsAmbiguousOrMissingSource(t *testing.T) {
	for _, source := range []string{"no match", "target target"} {
		if _, err := exactFileEdit([]byte(source), "target", "replacement"); err == nil {
			t.Fatal("ambiguous or absent match accepted")
		}
	}
	if _, err := exactFileEdit([]byte{0xff}, "target", "replacement"); err == nil {
		t.Fatal("binary file accepted")
	}
}

func TestSandboxEditCommitsOnceAndRejectsStaleSource(t *testing.T) {
	path := filepath.Join(t.TempDir(), "source 'quoted' $(echo forbidden).txt")
	before := []byte("unchanged prefix\ntarget\nunchanged suffix\n")
	after, err := exactFileEdit(before, "target", "localized replacement")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, before, 0644); err != nil {
		t.Fatal(err)
	}
	command := fileEditCommand(path, before, after)
	if output, err := exec.Command("sh", "-c", command).CombinedOutput(); err != nil {
		t.Fatalf("commit: %s: %v", output, err)
	}
	actual, _ := os.ReadFile(path)
	info, _ := os.Stat(path)
	if string(actual) != string(after) || info.Mode().Perm() != 0644 {
		t.Fatal("file contents or permissions corrupted")
	}
	if output, err := exec.Command("sh", "-c", command).CombinedOutput(); err == nil {
		t.Fatalf("stale edit committed: %s", output)
	}
	actual, _ = os.ReadFile(path)
	if string(actual) != string(after) {
		t.Fatal("stale edit overwrote new work")
	}
	temporary, _ := filepath.Glob(path + ".aseman-edit.*")
	if len(temporary) != 0 {
		t.Fatal("edit left temporary files")
	}
}

func TestAttachmentReadGrantDoesNotGrantSandboxAccess(t *testing.T) {
	s := &Service{}
	ctx := vmm.WithExecution(context.Background(), vmm.Execution{Capabilities: []string{"file_read", "file_edit"}})
	if _, err := s.readFileForAgent(ctx, identity.ID{}, `{"path":"private.txt"}`); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("sandbox read bypassed capability policy: %v", err)
	}
	if _, err := s.fileEditTool(ctx, identity.ID{}, `{"path":"private.txt","old_text":"a","new_text":"b"}`); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("sandbox edit bypassed capability policy: %v", err)
	}
}

func TestMissingReplacementDoesNotDeleteSource(t *testing.T) {
	s := &Service{}
	if _, err := s.fileEditTool(context.Background(), identity.ID{}, `{"path":"source.txt","old_text":"keep this"}`); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("missing replacement accepted as deletion: %v", err)
	}
}

func TestExactEditMismatchReturnsFocusedObservedSource(t *testing.T) {
	source := []byte(strings.Repeat("unrelated CSS declaration\n", 300) + "const messages = {\n  name: 'Enter your name',\n  email: 'Enter a valid email'\n};\n")
	_, err := exactFileEdit(source, "const messages = {name: 'Please add your name'};", "replacement")
	if err == nil || !strings.Contains(err.Error(), "301: const messages = {") || !strings.Contains(err.Error(), "Enter your name") || strings.Count(err.Error(), "unrelated CSS declaration") > 3 {
		t.Fatal("edit failure lost focused source context", err)
	}
	if len(err.Error()) > 4500 || !strings.Contains(err.Error(), "source was not changed") {
		t.Fatal("unbounded or misleading failure context")
	}
	after, err := exactFileEdit(source, "const messages = {\n  name: 'Enter your name',", "const messages = {\n  name: 'Provide a name',")
	if err != nil || !bytes.Contains(after, []byte("Provide a name")) || bytes.Contains(source, []byte("Provide a name")) {
		t.Fatal("observed conflict was not usable for exact retry")
	}
	if diagnostic := editConflictContext(source, "totally different needle"); diagnostic != "" {
		t.Fatal("invented related source")
	}
}

func TestLiteralSourceSearchReturnsRelevantNumberedContext(t *testing.T) {
	source := []byte(strings.Repeat("unrelated CSS\n", 300) + "<main id=\"main\">\nhero\n</main>\n" + strings.Repeat("unrelated footer\n", 200))
	result := searchSource(source, "index.html", "<main", 1, 12000)
	if !strings.Contains(result, "301: <main") || !strings.Contains(result, "302: hero") || strings.Count(result, "unrelated CSS") != 1 || strings.Contains(result, "unrelated footer") {
		t.Fatalf("search did not focus on the relevant source: %s", result)
	}
	if missing := searchSource(source, "index.html", "not-in-source", 3, 12000); !strings.Contains(missing, "No matching lines") {
		t.Fatal("search invented evidence")
	}
	// Metacharacters are literal, and huge source lines cannot exhaust context.
	if literal := searchSource([]byte("x.*y\nxy\n"), "index.html", ".*", 0, 12000); strings.Contains(literal, "2: xy") {
		t.Fatal("literal search interpreted a regular expression")
	}
	if huge := searchSource([]byte(strings.Repeat("x", 100000)), "index.html", "x", 3, 1000); len(huge) > 1300 || !strings.Contains(huge, "truncated") {
		t.Fatal("search output was unbounded")
	}
	if excerpt := numberedSource(source, 301, 301, 2, 4096); !strings.Contains(excerpt, "301: <main") || !strings.Contains(excerpt, "303: </main>") || len(excerpt) > 4200 {
		t.Fatal("edit evidence was missing or unbounded")
	}
}
