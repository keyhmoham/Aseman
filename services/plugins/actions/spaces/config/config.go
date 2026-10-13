package config

type SandboxConfig struct {
	// Backend is the sandbox backbone: "docker" (default) creates one docker
	// container per space; "modal" keeps using Modal remote sandboxes.
	Backend string `json:"backend" yaml:"backend"`
	// DockerNetwork optionally attaches docker sandbox containers to a shared
	// docker network the node is also on (e.g. the compose default network),
	// so proxied sandbox ports are reachable from a containerized node.
	DockerNetwork string `json:"docker_network" yaml:"docker_network"`
	// Image is the sandbox computer image. It defaults to the sandbox
	// computer image (deploy/sandbox-computer) with a dev toolchain.
	Image    string  `json:"image" yaml:"image"`
	CPU      float64 `json:"cpu" yaml:"cpu"`
	MemoryMB int64   `json:"memory_mb" yaml:"memory_mb"`
	DiskMB   int64   `json:"disk_mb" yaml:"disk_mb"`
}
