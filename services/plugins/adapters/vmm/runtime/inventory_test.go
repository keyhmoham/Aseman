package runtime

import (
	"testing"

	vmm "github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// Every adapter is reached through the guard: an optional capability the guard
// does not forward is invisible to the rest of the node.
func TestGuardForwardsTheProviderInventory(t *testing.T) {
	var guarded any = &guardedVMM{}
	if _, ok := guarded.(vmm.Inventory); !ok {
		t.Fatal("the guard hides vmm.Inventory from callers")
	}
	if _, ok := guarded.(vmm.VolumeDeleter); !ok {
		t.Fatal("the guard hides vmm.VolumeDeleter from callers")
	}
}
