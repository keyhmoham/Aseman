package spaces

import (
	"context"
	"testing"

	vmm "github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// storedFiles is a provider that changes a stopped computer's files and
// records how.
type storedFiles struct {
	vmm.VMM
	calls []string
	err   error
}

func (f *storedFiles) WriteWorkspace(_ context.Context, _, p string, data []byte) error {
	f.calls = append(f.calls, "write "+p+" "+string(data))
	return f.err
}
func (f *storedFiles) DeleteWorkspace(_ context.Context, _, p string) error {
	f.calls = append(f.calls, "delete "+p)
	return f.err
}
func (f *storedFiles) MakeWorkspaceDir(_ context.Context, _, p string) error {
	f.calls = append(f.calls, "mkdir "+p)
	return f.err
}
func (f *storedFiles) MoveWorkspace(_ context.Context, _, from, to string) error {
	f.calls = append(f.calls, "move "+from+" "+to)
	return f.err
}

// readOnly can only read a stopped computer's files.
type readOnly struct{ vmm.VMM }

func TestStoppedComputerFilesChangeWithoutWakingIt(t *testing.T) {
	ctx := context.Background()
	f := &storedFiles{}
	for _, c := range []struct{ op, rel, to, data string }{
		{"write", "notes/a.md", "", "hi"},
		{"delete", "old", "", ""},
		{"mkdir", "docs", "", ""},
		{"move", "a.md", "docs/a.md", ""},
	} {
		if err := changeStoredFiles(ctx, f, "vm", c.op, c.rel, c.to, []byte(c.data)); err != nil {
			t.Fatalf("%s: %v", c.op, err)
		}
	}
	want := []string{"write notes/a.md hi", "delete old", "mkdir docs", "move a.md docs/a.md"}
	for i := range want {
		if f.calls[i] != want[i] {
			t.Fatalf("calls = %v", f.calls)
		}
	}
	if err := changeStoredFiles(ctx, f, "vm", "delete", "", "", nil); err == nil || vmm.NeedsMachine(err) {
		t.Fatalf("deleting the root = %v", err)
	}
	// What the provider cannot do asleep says it needs the computer.
	for _, op := range []string{"write", "mkdir", "move"} {
		if err := changeStoredFiles(ctx, readOnly{}, "vm", op, "a", "b", nil); !vmm.NeedsMachine(err) {
			t.Fatalf("%s on a read-only provider = %v", op, err)
		}
	}
	f.err = vmm.ErrTooLarge
	if err := changeStoredFiles(ctx, f, "vm", "write", "big.bin", "", nil); !vmm.NeedsMachine(err) {
		t.Fatalf("too large = %v", err)
	}
}
