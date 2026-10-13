package modal

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"

	modal "github.com/modal-labs/modal-client/go"
)

// Runs against the real Modal account in the environment (a throwaway volume,
// deleted afterwards): MODAL_LIVE_TEST=1 TRADERA_MODAL_TOKEN_ID=... go test -run Live
func TestLiveWorkspaceFilesWithoutAComputer(t *testing.T) {
	if os.Getenv("MODAL_LIVE_TEST") != "1" {
		t.Skip("set MODAL_LIVE_TEST=1 to run against Modal")
	}
	a := New(logger.Global())
	a.tokenID, a.tokenSecret = os.Getenv("TRADERA_MODAL_TOKEN_ID"), os.Getenv("TRADERA_MODAL_TOKEN_SECRET")
	if err := a.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	name := fmt.Sprintf("sbx-live%d", time.Now().Unix())
	id := "vm-live"
	a.sandboxes[id] = &sandboxState{spec: vmm.VMSpec{Name: name, Type: vmm.TypeModal}, slept: true}
	defer func() { _ = a.client.Volumes.Delete(context.Background(), "tradera-"+name, nil) }()

	if err := a.WriteWorkspace(ctx, id, "uploads/menu.txt", []byte("flat white\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := a.WriteWorkspace(ctx, id, "notes.md", []byte("# notes")); err != nil {
		t.Fatalf("write root file: %v", err)
	}
	root, err := a.ListWorkspace(ctx, id, "")
	if err != nil || len(root) != 2 || root[0].Name != "notes.md" || root[1].Name != "uploads" || root[1].Type != "dir" {
		t.Fatalf("list root = %+v, %v", root, err)
	}
	sub, err := a.ListWorkspace(ctx, id, "uploads")
	if err != nil || len(sub) != 1 || sub[0].Name != "menu.txt" || sub[0].Size != 11 {
		t.Fatalf("list uploads = %+v, %v", sub, err)
	}
	got, err := a.ReadWorkspace(ctx, id, "uploads/menu.txt")
	if err != nil || string(got) != "flat white\n" {
		t.Fatalf("read = %q, %v", got, err)
	}
	if err := a.DeleteWorkspace(ctx, id, "uploads"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if _, err := a.ReadWorkspace(ctx, id, "uploads/menu.txt"); err == nil {
		t.Fatal("a deleted file can still be read")
	}
	var _ modal.Volume
}
