// Package vmm defines the driven port for virtual-machine / sandbox plugins.
// A VMM provider is responsible for images, the full VM lifecycle and live
// resource metering. Providers are swappable (Nomad by default, plus docker,
// wasm, modal and the deep agents runtime).
package vmm

import (
	"context"
	"time"
)

// Type identifies a supported VM kind.
type Type string

const (
	TypeDocker Type = "docker"
	// TypeContainer is a standalone Docker Engine container (the per-space
	// sandbox backend). It is distinct from TypeDocker so the shared sandbox
	// always routes to the standalone docker adapter rather than Nomad's
	// docker driver.
	TypeContainer Type = "container"
	TypeWASM      Type = "wasm"
	TypeMCP       Type = "mcp"
	TypeModal     Type = "modal"
	// TypeDeepAgents is an agent served by the deep agents runtime (LangChain
	// deepagents on LangGraph). Agents reach people and each other through
	// space messaging, tools through spaces.ask, and share the space sandbox.
	TypeDeepAgents Type = "deepagents"
)

// Status of a VM.
type Status string

const (
	StatusPending  Status = "pending"
	StatusCreating Status = "creating"
	StatusRunning  Status = "running"
	StatusStopped  Status = "stopped"
	StatusPaused   Status = "paused"
	StatusEnded    Status = "ended"
	StatusFailed   Status = "failed"
)

// StatusFromNomad maps a Nomad job status onto the generic VM status.
func StatusFromNomad(s string) Status {
	switch s {
	case "running":
		return StatusRunning
	case "pending", "running_pending":
		return StatusPending
	case "dead", "stopped":
		return StatusStopped
	case "failed":
		return StatusFailed
	case "complete":
		return StatusEnded
	default:
		return StatusPending
	}
}

// ResourceSpec is the resource request/limit profile applied at create time.
type ResourceSpec struct {
	CPU           float64 `json:"cpu"` // vCPU
	MemoryMB      int64   `json:"memory_mb"`
	DiskMB        int64   `json:"disk_mb"`
	MaxRuntimeSec int64   `json:"max_runtime_sec,omitempty"`
	Network       string  `json:"network,omitempty"`
	// Pinned describes host constraints (e.g. Nomad constraints).
	Pinned map[string]string `json:"pinned,omitempty"`
}

// Config for a VMM plugin.
type Config struct {
	// NomadURL is the Nomad API endpoint.
	NomadURL   string            `json:"nomad_url,omitempty"`
	Token      string            `json:"token,omitempty"`
	Region     string            `json:"region,omitempty"`
	Datacenter string            `json:"datacenter,omitempty"`
	Options    map[string]string `json:"options,omitempty"`
}

// Health of the VMM plugin.
type Health struct {
	OK      bool   `json:"ok"`
	Message string `json:"message,omitempty"`
}

// Image is a built/registered VM image. Ref is the image reference used at VM
// create time.
type Image struct {
	ID        string    `json:"id"`
	Type      Type      `json:"type"`
	Name      string    `json:"name"`
	Ref       string    `json:"ref"`
	Size      int64     `json:"size"`
	CreatedAt time.Time `json:"created_at"`
}

// ImageSpec describes how to build an image. YML is the raw image definition
// (Dockerfile-adjacent, wasm module path, modal function ref or an agent
// spec yml). Providers interpret it for their type.
type ImageSpec struct {
	Type Type              `json:"type"`
	Name string            `json:"name"`
	Tag  string            `json:"tag"`
	YML  string            `json:"yml"`
	Env  map[string]string `json:"env,omitempty"`
}

// VMSpec describes a VM to create.
type VMSpec struct {
	Name        string            `json:"name"`
	Type        Type              `json:"type"`
	ImageRef    string            `json:"image_ref"`
	Resources   ResourceSpec      `json:"resources"`
	Environment map[string]string `json:"environment,omitempty"`
	Entrypoint  string            `json:"entrypoint,omitempty"`
	Args        []string          `json:"args,omitempty"`
	YML         string            `json:"yml,omitempty"` // full config yml
	Labels      map[string]string `json:"labels,omitempty"`
}

// Labels a VMSpec can carry to run a long-lived service VM (such as the agent
// runtime). Providers that support them honour them; others ignore them.
const (
	// LabelServiceID gives the VM a stable id: creating it again replaces the
	// running one instead of starting a second copy.
	LabelServiceID = "tradera.service_id"
	// LabelNetworkAlias is the DNS name the VM answers to on
	// ResourceSpec.Network.
	LabelNetworkAlias = "tradera.network_alias"
	// LabelVolume mounts a named volume, "name:/path", so the VM's state
	// survives restarts.
	LabelVolume = "tradera.volume"
)

// VM is the provider-agnostic VM representation.
type VM struct {
	ID        string            `json:"id"`
	Name      string            `json:"name"`
	Type      Type              `json:"type"`
	Status    Status            `json:"status"`
	ImageRef  string            `json:"image_ref"`
	Address   string            `json:"address,omitempty"` // reachable endpoint
	Resources ResourceSpec      `json:"resources"`
	Labels    map[string]string `json:"labels,omitempty"`
	CreatedAt time.Time         `json:"created_at"`
	StartedAt *time.Time        `json:"started_at,omitempty"`
	EndedAt   *time.Time        `json:"ended_at,omitempty"`
}

// Usage is live metering data used for cost calculation.
type Usage struct {
	VMID            string    `json:"vm_id"`
	CPUUsed         float64   `json:"cpu_used"` // percentage
	MemoryUsedMB    int64     `json:"memory_used_mb"`
	DiskUsedMB      int64     `json:"disk_used_mb"`
	NetworkInBytes  int64     `json:"network_in_bytes"`
	NetworkOutBytes int64     `json:"network_out_bytes"`
	UptimeSeconds   int64     `json:"uptime_seconds"`
	MeasuredAt      time.Time `json:"measured_at"`
	// TokensIn/Out are cumulative LLM tokens consumed by the VM (agents),
	// used to price token-based execution cost.
	TokensIn  int64 `json:"tokens_in"`
	TokensOut int64 `json:"tokens_out"`
	// ImageCredits is the cumulative credit cost of images the VM generated
	// (priced per image by the image model's provider).
	ImageCredits float64 `json:"image_credits,omitempty"`
}

// FileAttachment describes a file attached to a message so conversational VMs
// (agents) can see what was sent in chat. Text-based documents carry
// their extracted content inline so the agent can reason over them without an
// extra fetch; binary/media files carry metadata plus the streaming content URL,
// and images additionally carry downscaled pixel data so the agent can actually
// *see* them through the vision-capable model.
type FileAttachment struct {
	// ID is the logical file id (also the storage key prefix).
	ID string `json:"id"`
	// Name is the sanitized file name.
	Name string `json:"name"`
	// Mime is the stored content type (image/png, audio/mpeg, video/mp4, ...).
	Mime string `json:"mime"`
	// Size in bytes.
	Size int64 `json:"size"`
	// URL is the relative content endpoint (/v1/files/{id}/content) that
	// streams the raw bytes with the correct Content-Type.
	URL string `json:"url"`
	// Content carries extracted text for text-based documents (txt, md, json,
	// csv, yaml, code, ...) so the agent understands the file inline. It is
	// omitted for binary/media files.
	Content string `json:"content,omitempty"`
	// ImageData is downscaled image pixels (JPEG) for multimodal input so the
	// agent can see the photo/gif. Empty for non-images.
	ImageData []byte `json:"image_data,omitempty"`
	// ImageMime is the content type of [ImageData] (usually image/jpeg).
	ImageMime string `json:"image_mime,omitempty"`
}

// ChatMessage is a single conversational turn (a prior user or assistant
// message) replayed to a conversational VM so the agent has access to the
// conversation history and can remember earlier context. Files attached to the
// turn travel in [Attachments] so the VM manager sees what was sent in chat.
type ChatMessage struct {
	Role    string `json:"role"`    // "user" | "assistant"
	Content string `json:"content"` // message body
	// Attachments are the files sent with this turn (photos, gifs, audio,
	// voice, video, documents).
	Attachments []FileAttachment `json:"attachments,omitempty"`
}

// Filter narrows VM listing.
type Filter struct {
	Status Status
	Labels map[string]string
	Limit  int
	Offset int
}

// VMM is the driven port implemented by VMM plugins.
type VMM interface {
	Name() string
	Open(ctx context.Context, cfg Config) error
	Close(ctx context.Context) error
	Health(ctx context.Context) Health
	SupportedTypes() []Type

	BuildImage(ctx context.Context, spec ImageSpec) (Image, error)
	DeleteImage(ctx context.Context, ref string) error

	CreateVM(ctx context.Context, spec VMSpec) (VM, error)
	DeleteVM(ctx context.Context, id string) error
	StartVM(ctx context.Context, id string) error
	StopVM(ctx context.Context, id string) error
	PauseVM(ctx context.Context, id string) error
	ResumeVM(ctx context.Context, id string) error
	// ResizeVM applies new resource limits to a running VM (live control).
	ResizeVM(ctx context.Context, id string, res ResourceSpec) (VM, error)
	GetVM(ctx context.Context, id string) (VM, error)
	ListVMs(ctx context.Context, f Filter) ([]VM, error)
	Usage(ctx context.Context, id string) (Usage, error)
}
