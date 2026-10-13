package local

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestSafePathRelativeBase(t *testing.T) {
	// The default config uses a relative base_path ("./data/files"); safePath
	// must still resolve keys under it (the old code compared a relative join
	// against an absolute base and rejected every key).
	a := &Adapter{basePath: filepath.Join("testdata", "files")}
	_ = os.MkdirAll(a.basePath, 0o755)
	defer os.RemoveAll("testdata")

	p, err := a.safePath("0000000000000001b4ddf519561784ae")
	if err != nil {
		t.Fatalf("safePath with relative base failed: %v", err)
	}
	abs, _ := filepath.Abs(a.basePath)
	want := filepath.Join(abs, "0000000000000001b4ddf519561784ae")
	if p != want {
		t.Fatalf("safePath = %q, want %q", p, want)
	}
}

func TestSafePathNormalizesTraversal(t *testing.T) {
	a := &Adapter{basePath: filepath.Join("testdata", "files")}
	_ = os.MkdirAll(a.basePath, 0o755)
	defer os.RemoveAll("testdata")

	base, _ := filepath.Abs(a.basePath)
	// Traversal attempts are neutralized (Clean strips "..") and must always
	// resolve to a path inside the base directory.
	p, err := a.safePath("../../etc/passwd")
	if err != nil {
		t.Fatalf("safePath should normalize traversal, got error: %v", err)
	}
	if !isWithin(base, p) {
		t.Fatalf("normalized path %q escaped base %q", p, base)
	}
}

func isWithin(base, p string) bool {
	return p == base || len(p) > len(base) && p[:len(base)] == base && (p[len(base)] == '/' || p[len(base)] == '\\')
}

func TestPutGetRoundTrip(t *testing.T) {
	a := &Adapter{basePath: filepath.Join("testdata", "files")}
	_ = os.MkdirAll(a.basePath, 0o755)
	defer os.RemoveAll("testdata")

	payload := []byte("hello attachment")
	if err := a.Put(t.Context(), "file-abc", bytes.NewReader(payload), int64(len(payload)), "text/plain"); err != nil {
		t.Fatalf("put: %v", err)
	}
	rc, err := a.Get(t.Context(), "file-abc")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer rc.Close()
	got := make([]byte, len(payload))
	if _, err := rc.Read(got); err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(got) != string(payload) {
		t.Fatalf("round trip mismatch: %q", string(got))
	}
}
