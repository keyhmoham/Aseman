package spaces

import (
	"bytes"
	"context"
	"io"
	"strings"
	"sync"
	"testing"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/spaces/models/filedata"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/filesystem/ports"
	dbmodel "github.com/tradera/tradera/plugins/testutil"
)

// objects is an object store in memory.
type objects struct {
	mu   sync.Mutex
	data map[string][]byte
}

func (o *objects) Name() string                                  { return "mem" }
func (o *objects) Open(context.Context, filesystem.Config) error { return nil }
func (o *objects) Close(context.Context) error                   { return nil }
func (o *objects) Health(context.Context) filesystem.Health      { return filesystem.Health{OK: true} }
func (o *objects) Put(_ context.Context, k string, r io.Reader, _ int64, _ string) error {
	b, _ := io.ReadAll(r)
	o.mu.Lock()
	o.data[k] = b
	o.mu.Unlock()
	return nil
}
func (o *objects) Get(_ context.Context, k string) (io.ReadCloser, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	b, ok := o.data[k]
	if !ok {
		return nil, errs.NotFound("object")
	}
	return io.NopCloser(bytes.NewReader(b)), nil
}
func (o *objects) Delete(_ context.Context, k string) error {
	o.mu.Lock()
	delete(o.data, k)
	o.mu.Unlock()
	return nil
}
func (o *objects) Stat(context.Context, string) (filesystem.ObjectInfo, error) {
	return filesystem.ObjectInfo{}, nil
}
func (o *objects) Exists(_ context.Context, k string) (bool, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	_, ok := o.data[k]
	return ok, nil
}
func (o *objects) List(context.Context, string) ([]filesystem.ObjectInfo, error) { return nil, nil }

// storeKernel is a kernel with a file store.
type storeKernel struct {
	*kernel.Kernel
	store filesystem.FileStorage
}

func (k storeKernel) FS() filesystem.FileStorage { return k.store }

func TestAProjectsFilesLiveUnderItAndGoWithIt(t *testing.T) {
	db := memory.New(logger.Global())
	ctx := context.Background()
	for _, m := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	store := &objects{data: map[string][]byte{}}
	k := storeKernel{Kernel: kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()}), store: store}
	s := NewService(k, &repo.Repo{DB: db}, logger.Global())
	owner := idFromHex(t, "00000000000000010000000000000001")
	a, err := s.CreateSpace(ctx, owner, "first", "")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := s.CreateSpace(ctx, owner, "second", "")
	zero := idFromHex(t, "00000000000000000000000000000000")
	up := func(sp, who string, data string) *filedata.File {
		spID := zero
		if sp != "" {
			spID = idFromHex(t, sp)
		}
		f, err := s.UploadFile(ctx, owner, spID, zero, who, "text/plain", []byte(data))
		if err != nil {
			t.Fatal(err)
		}
		return f
	}
	f1, f2, g := up(a.ID.String(), "one.txt", "in the first"), up(a.ID.String(), "two.txt", "also first"), up(b.ID.String(), "three.txt", "in the second")
	loose := up("", "loose.txt", "no project")
	for _, f := range []*filedata.File{f1, f2} {
		if !strings.HasPrefix(f.StorageKey, "projects/"+a.ID.String()+"/") {
			t.Fatalf("a project's file is stored in its folder: %q", f.StorageKey)
		}
	}
	if !strings.HasPrefix(g.StorageKey, "projects/"+b.ID.String()+"/") || loose.StorageKey != loose.ID.String() {
		t.Fatalf("keys: %q %q", g.StorageKey, loose.StorageKey)
	}
	if rc, err := s.ReadFileBytes(ctx, f1); err != nil || string(rc) != "in the first" {
		t.Fatalf("a file is read from where it was stored: %v %q", err, rc)
	}

	s.deleteSpaceFiles(ctx, a.ID)
	if len(store.data) != 2 {
		t.Fatalf("only the deleted project's bytes go: %d objects left", len(store.data))
	}
	var rows []filedata.File
	_ = s.R.List(ctx, "files", database.Filter{Equal: map[string]any{"space_id": a.ID.String()}}, &rows)
	if len(rows) != 0 {
		t.Fatalf("and its records: %d", len(rows))
	}
	if _, err := s.GetFile(ctx, g.ID); err != nil {
		t.Fatalf("another project's file stays: %v", err)
	}

	// A project deleted before its files went with it: the sweep removes what it left, and nothing else.
	if err := s.R.Delete(ctx, "spaces", b.ID); err != nil {
		t.Fatal(err)
	}
	s.sweepOrphanFiles(ctx)
	if _, err := s.GetFile(ctx, g.ID); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("the orphan is gone: %v", err)
	}
	if _, err := s.GetFile(ctx, loose.ID); err != nil {
		t.Fatalf("a file that was never in a project stays: %v", err)
	}
	if len(store.data) != 1 {
		t.Fatalf("one object left: %d", len(store.data))
	}
}
