package spaces

import (
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
)

func TestSandboxPreviewLeaseDefersIdleStopAndExpires(t *testing.T) {
	now := time.Now().UTC()
	st := &sandboxState{lastActive: now.Add(-3 * time.Minute), previewUntil: now.Add(sandboxPreviewTTL)}
	if delay := sandboxIdleDelay(st, now); delay != sandboxPreviewTTL {
		t.Fatalf("preview lease lost: %v", delay)
	}
	if delay := sandboxIdleDelay(st, now.Add(sandboxPreviewTTL+time.Second)); delay != 0 {
		t.Fatalf("expired preview kept sandbox alive: %v", delay)
	}
	st.previewUntil = time.Time{}
	st.lastActive = now
	if delay := sandboxIdleDelay(st, now); delay != sandboxIdleTTL {
		t.Fatalf("ordinary idle deadline changed: %v", delay)
	}
}

// TestSandboxVMTypeByBackend verifies one config variable (sandbox.backend)
// switches the shared per-space sandbox between a docker container and a Modal
// remote sandbox, defaulting to docker.
func TestSandboxVMTypeByBackend(t *testing.T) {
	s := &Service{}
	if v := s.sandboxVMType(); v != bot.VMTypeContainer {
		t.Fatalf("default backend should provision docker containers, got %q", v)
	}
	s.SandboxBackend = "docker"
	if v := s.sandboxVMType(); v != bot.VMTypeContainer {
		t.Fatalf("docker backend should provision docker containers, got %q", v)
	}
	s.SandboxBackend = "DOCKER"
	if v := s.sandboxVMType(); v != bot.VMTypeContainer {
		t.Fatalf("backend switch should be case-insensitive, got %q", v)
	}
	s.SandboxBackend = "modal"
	if v := s.sandboxVMType(); v != bot.VMTypeModal {
		t.Fatalf("modal backend should provision modal sandboxes, got %q", v)
	}
	s.SandboxBackend = "unknown"
	if v := s.sandboxVMType(); v != bot.VMTypeContainer {
		t.Fatalf("unknown backend should fall back to docker, got %q", v)
	}
}

func TestComputerTimeIsMeteredFromWhenItWokeAndAdvances(t *testing.T) {
	woke := time.Now().Add(-90 * time.Second)
	payer, _ := identity.New(1)
	st := &sandboxState{billedUntil: woke, payer: payer}
	d, who := takeComputeTime(st, woke.Add(90*time.Second))
	if d != 90*time.Second || who != payer {
		t.Fatalf("took %v for %v; want 90s for the payer", d, who)
	}
	// Taking again charges only what is new, and a meter that is off charges nothing.
	if d, _ := takeComputeTime(st, woke.Add(90*time.Second+500*time.Millisecond)); d != 0 {
		t.Fatalf("charged %v twice", d)
	}
	if d, _ := takeComputeTime(&sandboxState{}, time.Now()); d != 0 {
		t.Fatalf("an asleep computer was charged %v", d)
	}
}

func TestOnlyAMachineNoProjectUsesCanBeTerminatedFromTheAdminList(t *testing.T) {
	if err := strayTerminateError(map[string]any{"id": "sb-1", "machine": "sbx-gone"}); err != nil {
		t.Fatalf("a stray machine was refused: %v", err)
	}
	if err := strayTerminateError(map[string]any{"id": "sb-2", "project": map[string]any{"id": "p", "name": "Shop"}}); err == nil {
		t.Fatal("a project's machine must be stopped from its project")
	}
	if err := strayTerminateError(nil); err == nil {
		t.Fatal("a machine that is not running cannot be terminated")
	}
}
