package vmm

import "context"

// SidecarRunner is implemented by VMM providers that can run a second
// container inside a VM's network namespace. A space sandbox uses it to host a
// tool backend packaged as a docker image: the sidecar answers on the
// sandbox's own ports, so it is reached the way any service in the sandbox is
// (CreateTunnel), and it belongs to that space alone.
type SidecarRunner interface {
	// EnsureSidecar starts the named sidecar of a VM from an image, creating
	// it when missing. It is idempotent: a running sidecar is left alone.
	EnsureSidecar(ctx context.Context, vmID, name, image string, env map[string]string) error
	// RemoveSidecar removes the named sidecar of a VM (no error when absent).
	RemoveSidecar(ctx context.Context, vmID, name string) error
}
