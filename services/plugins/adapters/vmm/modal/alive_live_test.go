package modal

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

func TestLiveAliveSeesASandboxEndedOutsideTheNode(t *testing.T) {
	if os.Getenv("MODAL_LIVE_TEST") != "1" {
		t.Skip("set MODAL_LIVE_TEST=1 to run against Modal")
	}
	a := New(logger.Global())
	a.tokenID, a.tokenSecret = os.Getenv("TRADERA_MODAL_TOKEN_ID"), os.Getenv("TRADERA_MODAL_TOKEN_SECRET")
	if err := a.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	name := fmt.Sprintf("sbx-alive%d", time.Now().Unix())
	vm, err := a.CreateVM(ctx, vmm.VMSpec{Name: name, Type: vmm.TypeModal, ImageRef: "node:20-alpine", Args: []string{"sleep", "infinity"}, Resources: vmm.ResourceSpec{CPU: 0.25, MemoryMB: 256}})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = a.DeleteVM(context.Background(), vm.ID)
		_ = a.client.Volumes.Delete(context.Background(), "tradera-"+name, nil)
	}()
	if !a.Alive(ctx, vm.ID) {
		t.Fatal("a running sandbox reads as not alive")
	}
	// ended from outside (like Modal's dashboard)
	if _, err := a.sandboxes[vm.ID].sb.Terminate(ctx, nil); err != nil {
		t.Fatal(err)
	}
	// Modal reports the end a moment later.
	ended := time.Now()
	deadline := ended.Add(40 * time.Second)
	for a.Alive(ctx, vm.ID) && time.Now().Before(deadline) {
		time.Sleep(500 * time.Millisecond)
	}
	t.Logf("reported not alive after %v", time.Since(ended).Round(time.Millisecond))
	if a.Alive(ctx, vm.ID) {
		t.Fatal("a sandbox ended outside the node still reads as alive")
	}
	// and a fresh adapter (node restart) that only knows the id
	b := New(logger.Global())
	b.tokenID, b.tokenSecret = a.tokenID, a.tokenSecret
	if err := b.Start(ctx); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 20 && b.Alive(ctx, vm.ID); i++ {
		time.Sleep(time.Second)
	}
	if b.Alive(ctx, vm.ID) {
		t.Fatal("after a restart, an ended sandbox reads as alive")
	}
}
