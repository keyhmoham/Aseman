package vmm

import (
	"context"
	"io"
)

// ExecSpec describes an interactive process started inside a running VM.
type ExecSpec struct {
	Cmd     []string          `json:"cmd"`
	Env     map[string]string `json:"env,omitempty"`
	WorkDir string            `json:"work_dir,omitempty"`
	User    string            `json:"user,omitempty"`
}

// ExecStream is the live stdio of a process attached inside a VM: writes go to
// its stdin, reads return its stdout. Stderr is delivered to the optional sink
// given at attach time. Close terminates the stream (and the process' stdin).
type ExecStream interface {
	io.ReadWriteCloser
}

// Attacher is implemented by VMM providers hosting long-running VMs (docker
// containers, nomad docker allocations) that can start an interactive process
// inside a VM and hand back its stdio. Agent engines use it to run inside the
// shared space sandbox without exposing the provider to them.
type Attacher interface {
	Attach(ctx context.Context, vmID string, spec ExecSpec, stderr io.Writer) (ExecStream, error)
}
