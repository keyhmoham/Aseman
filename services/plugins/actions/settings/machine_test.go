package settings

import (
	"testing"

	"github.com/tradera/tradera/plugins/actions/settings/models"
)

func TestMachineDefaultsFollowTheNodeConfigAndDeriveTheReserve(t *testing.T) {
	m := effectiveMachine(models.Machine{}, nil)
	if m.CPU != 2 || m.MemoryMB != 2048 || m.DiskMB != 4096 {
		t.Fatalf("sold size = %v / %v / %v; want 2 / 2048 / 4096", m.CPU, m.MemoryMB, m.DiskMB)
	}
	if m.ReserveCPU != 0.25 || m.ReserveMemoryMB != 512 || m.MaxCPU != 4 || m.MaxMemoryMB != 8192 {
		t.Fatalf("reserve/ceiling = %+v", m)
	}
	// The node's configured sandbox size is the starting point.
	m = effectiveMachine(models.Machine{}, map[string]string{"sandbox_cpu": "8", "sandbox_memory_mb": "16384", "sandbox_disk_mb": "10000"})
	if m.CPU != 8 || m.MemoryMB != 16384 || m.DiskMB != 10000 || m.ReserveCPU != 1 || m.ReserveMemoryMB != 4096 {
		t.Fatalf("configured size = %+v", m)
	}
	// The ceiling is never below the sold size.
	if m.MaxCPU != 8 || m.MaxMemoryMB != 16384 {
		t.Fatalf("ceiling %v / %v is below the sold size", m.MaxCPU, m.MaxMemoryMB)
	}
	// What the admin sets wins.
	m = effectiveMachine(models.Machine{CPU: 1, MemoryMB: 1024, ReserveCPU: 0.5, MaxCPU: 6, MaxMemoryMB: 12288}, nil)
	if m.CPU != 1 || m.ReserveCPU != 0.5 || m.MaxCPU != 6 || m.MaxMemoryMB != 12288 || m.ReserveMemoryMB != 512 {
		t.Fatalf("admin size = %+v", m)
	}
}

func TestParseMachineRefusesNonsense(t *testing.T) {
	if m, err := parseMachine(nil); err != nil || m != (models.Machine{}) {
		t.Fatalf("missing machine = %+v, %v", m, err)
	}
	if _, err := parseMachine(map[string]any{"cpu": 2, "memory_mb": 4096, "reserve_cpu": 0.5, "max_cpu": 8}); err != nil {
		t.Fatalf("valid machine refused: %v", err)
	}
	for _, bad := range []any{
		map[string]any{"cpu": -1},
		map[string]any{"cpu": 100},
		map[string]any{"memory_mb": 99999999},
		map[string]any{"cpu": 1, "reserve_cpu": 2}, // reserve above what it is sold at
		map[string]any{"gpu": 1},
	} {
		if _, err := parseMachine(bad); err == nil {
			t.Fatalf("accepted invalid machine %v", bad)
		}
	}
}
