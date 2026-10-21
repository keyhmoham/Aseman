package modal

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func TestLiveSandboxBurstsAboveItsRequestUpToItsLimit(t *testing.T) {
	if os.Getenv("MODAL_LIVE_TEST") != "1" {
		t.Skip("set MODAL_LIVE_TEST=1 to run against Modal")
	}
	a := New(logger.Global())
	a.tokenID, a.tokenSecret = os.Getenv("ASEMAN_MODAL_TOKEN_ID"), os.Getenv("ASEMAN_MODAL_TOKEN_SECRET")
	if err := a.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	name := fmt.Sprintf("sbx-burst%d", time.Now().Unix())
	vm, err := a.CreateVM(ctx, vmm.VMSpec{Name: name, Type: vmm.TypeModal, ImageRef: "node:20-slim", Args: []string{"sleep", "infinity"}, Resources: vmm.ResourceSpec{CPU: 2, MemoryMB: 2048}})
	if err != nil {
		t.Fatalf("create with request<limit: %v", err)
	}
	defer func() {
		_ = a.DeleteVM(context.Background(), vm.ID)
		_ = a.client.Volumes.Delete(context.Background(), "aseman-"+name, nil)
	}()
	run := func(label, cmd string) string {
		out, err := a.Send(ctx, vm.ID, cmd)
		t.Logf("[%s] err=%v\n%s", label, err, out)
		return out
	}
	run("limits", "cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max 2>&1; nproc")
	// 3 GiB is six times the 512 MiB reserve and above the 2 GiB the project is sold at,
	// but under the 8 GiB ceiling: must work.
	out := run("use 3GiB", `node -e "const b=Buffer.alloc(3000*1024*1024,1); console.log('allocated', Math.floor(b.length/1048576), 'MiB')"`)
	if !strings.Contains(out, "allocated 3000 MiB") {
		t.Fatal("a computer could not use more than it is sold at")
	}
}
