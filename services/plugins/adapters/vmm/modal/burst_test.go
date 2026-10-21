package modal

import (
	"testing"

	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func TestSandboxReservesLittleAndMayUseFarMoreThanItIsSoldAt(t *testing.T) {
	sold := vmm.ResourceSpec{CPU: 2, MemoryMB: 2048}
	// No admin settings: the reserve follows the sold size, the ceiling is the old generous one.
	cpuReq, cpuLim, memReq, memLim := burstSizes(sold, machineSizes{})
	if cpuReq != 0.25 || memReq != 512 || cpuLim != 4 || memLim != 8192 {
		t.Fatalf("automatic = reserve %v/%v, ceiling %v/%v; want 0.25/512 and 4/8192", cpuReq, memReq, cpuLim, memLim)
	}
	// The admin's reserve and ceiling win.
	cpuReq, cpuLim, memReq, memLim = burstSizes(sold, machineSizes{ReserveCPU: 0.5, ReserveMemoryMB: 1024, MaxCPU: 8, MaxMemoryMB: 16384})
	if cpuReq != 0.5 || memReq != 1024 || cpuLim != 8 || memLim != 16384 {
		t.Fatalf("admin = reserve %v/%v, ceiling %v/%v", cpuReq, memReq, cpuLim, memLim)
	}
	// A ceiling below the sold size is raised to it, and a reserve never exceeds what is sold.
	cpuReq, cpuLim, memReq, memLim = burstSizes(sold, machineSizes{ReserveCPU: 6, ReserveMemoryMB: 9000, MaxCPU: 1, MaxMemoryMB: 512})
	if cpuLim != 2 || memLim != 2048 || cpuReq != 2 || memReq != 2048 {
		t.Fatalf("clamped = reserve %v/%v, ceiling %v/%v", cpuReq, memReq, cpuLim, memLim)
	}
	// A computer sold below the floor never reserves more than its size.
	if cpuReq, _, memReq, _ = burstSizes(vmm.ResourceSpec{CPU: 0.125, MemoryMB: 256}, machineSizes{}); cpuReq != 0.125 || memReq != 256 {
		t.Fatalf("tiny sandbox reserves %v / %v", cpuReq, memReq)
	}
	// Unspecified sizes stay unspecified.
	if a, b, c, d := burstSizes(vmm.ResourceSpec{}, machineSizes{}); a != 0 || b != 0 || c != 0 || d != 0 {
		t.Fatal("zero sizes must pass through")
	}
}
