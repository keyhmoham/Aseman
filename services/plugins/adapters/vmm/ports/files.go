package vmm

import (
	"context"
	"errors"
	"time"
)

type WorkspaceEntry struct {
	Name string `json:"name"`
	Type string `json:"type"`
	Size int64  `json:"size"`
}

// WorkspaceReader reads persistent VM files without starting a stopped machine.
type WorkspaceReader interface {
	ReadWorkspace(context.Context, string, string) ([]byte, error)
	ListWorkspace(context.Context, string, string) ([]WorkspaceEntry, error)
}

// ErrTooLarge tells the caller a file is too big to write to a stopped machine's
// files directly; start the machine and write through it.
var ErrTooLarge = errors.New("file too large to write while the machine is stopped")

// WorkspaceWriter changes persistent VM files without starting a stopped machine.
type WorkspaceWriter interface {
	WriteWorkspace(ctx context.Context, id, path string, data []byte) error
	DeleteWorkspace(ctx context.Context, id, path string) error
}

// ProviderCost is what a VM provider billed for one day.
type ProviderCost struct {
	Day        time.Time          `json:"day"`
	USD        float64            `json:"usd"`
	ByResource map[string]float64 `json:"by_resource,omitempty"` // CPU, Memory, ...
}

// CostReporter reports what the provider actually billed for this platform's VMs,
// so the admin can set it against what customers were charged.
type CostReporter interface {
	CostReport(ctx context.Context, since, until time.Time) ([]ProviderCost, error)
}

// ProviderSandbox is a machine the provider is running for this platform now.
type ProviderSandbox struct {
	ID        string    `json:"id"`
	Name      string    `json:"name,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	StartedAt time.Time `json:"started_at,omitempty"`
	// Machine is the name of the computer the node runs this as ("sbx-…" for a
	// project's). Empty means the node does not know it: it is running, and
	// billed, without the node using it.
	Machine string `json:"machine,omitempty"`
}

// ProviderVolume is a stored disk the provider keeps for this platform.
type ProviderVolume struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

// Inventory lists what the provider itself holds for this platform: the
// machines running right now and the stored volumes, whatever the node's own
// records say.
type Inventory interface {
	Sandboxes(ctx context.Context) ([]ProviderSandbox, error)
	Volumes(ctx context.Context) ([]ProviderVolume, error)
}

// VolumeDeleter deletes the persistent storage of a project computer ("sbx-…")
// for good. A computer comes and goes while its storage lives with the project,
// so this is separate from DeleteVM and only a project's deletion calls it.
type VolumeDeleter interface {
	DeleteWorkspaceVolume(ctx context.Context, machine string) error
}

// FailureExplainer tells why a VM that never came up is not running (for
// Nomad: the placement failure or the task's last events), so the error a
// person sees names the real problem.
type FailureExplainer interface {
	Explain(ctx context.Context, id string) string
}
