// Package deepagents runs aseman's agents on LangChain Deep Agents
// (deepagents on LangGraph) as a VM runtime.
//
// A deepagents VM is an agent definition (instructions, skills, LLM backbone).
// Agents execute in the deep agents runtime: a Python service (./runtime) the
// node supervises as a Nomad job through the VMM port. Every agent of every
// space is served by it, each turn in its own LangGraph thread.
//
// Aseman stays the only bridge between an agent and the platform, and the
// platform's own action API is the transport:
//   - people and agents talk to agents through space messaging
//     (spaces.message_send) and direct messages (users.dm_send); the lead hands
//     tasks to the space's agents by messaging them in the room and reads their
//     answers (reply_to) from it;
//   - tools — the shared space sandbox (shell and files), app
//     bots, and platform tools — are called through spaces.ask;
//   - work logs and live status go through spaces.agent_log;
//   - model calls go through the node's metered LLM proxy, so provider keys
//     never leave the node and every token is billed to the turn;
//   - agents improve their own playbook between turns (GEPA) through the learn
//     endpoints, billed to their project (learn.go).
//
// Each turn gets a token scoped to that turn: the runtime calls the node's
// action API through this adapter's gateway, which dispatches the real actions
// as the agent's account inside the turn's execution scope.
package deepagents

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/idutil"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/pkg/openviking"
	"github.com/aseman/aseman/plugins/adapters/base"
	"github.com/aseman/aseman/plugins/adapters/cfg"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Environment fallbacks for the adapter options.
const (
	EnvNodeURL        = "ASEMAN_AGENT_NODE_URL"
	EnvRuntimeImage   = "ASEMAN_AGENT_RUNTIME_IMAGE"
	EnvRuntimeURL     = "ASEMAN_AGENT_RUNTIME_URL"
	EnvRuntimeSecret  = "ASEMAN_AGENT_RUNTIME_SECRET"
	EnvRuntimeNetwork = "ASEMAN_AGENT_RUNTIME_NETWORK"
	// EnvRuntimeMemoryMB is the memory the runtime reserves on Nomad (MB).
	EnvRuntimeMemoryMB = "ASEMAN_AGENT_RUNTIME_MEMORY_MB"
	// Model calls have a generous total deadline, but a provider must start and
	// keep producing its OpenAI-compatible stream. All three accept Go duration
	// strings (for example "2m" or "45s").
	EnvLLMCallTimeout       = "ASEMAN_LLM_CALL_TIMEOUT"
	EnvLLMFirstEventTimeout = "ASEMAN_LLM_FIRST_EVENT_TIMEOUT"
	EnvLLMStreamIdleTimeout = "ASEMAN_LLM_STREAM_IDLE_TIMEOUT"
)

const (
	// A pinned tag: Nomad always pulls ":latest", so a locally built runtime
	// image must carry another tag.
	defaultImage   = "aseman/deepagents:v2"
	defaultAlias   = "aseman-deepagents"
	defaultPort    = "8000"
	defaultVolume  = "aseman-deepagents:/data"
	defaultNetwork = "aseman_default"
	// defaultRuntimeMemoryMB fits a 4 GB server next to the database, the node and
	// Nomad; raise it (EnvRuntimeMemoryMB) on a larger one.
	defaultRuntimeMemoryMB      int64 = 2048
	runtimeService                    = "deepagents-runtime"
	defaultLLMCallTimeout             = 5 * time.Minute
	defaultLLMFirstEventTimeout       = 2 * time.Minute
	defaultLLMStreamIdleTimeout       = 45 * time.Second
)

func envDuration(name string, fallback time.Duration) time.Duration {
	if parsed, err := time.ParseDuration(strings.TrimSpace(os.Getenv(name))); err == nil && parsed > 0 {
		return parsed
	}
	return fallback
}

// agentDef is a registered deepagents VM.
type agentDef struct {
	mu        sync.Mutex
	vm        vmm.VM
	spec      Spec
	tokensIn  int64
	tokensOut int64
}

// Adapter is the deep agents VMM plugin.
type Adapter struct {
	// workload is the SPIFFE workload-identity policy (workload.go).
	workload workloadPolicy
	base.Base
	k        api.Kernel
	platform platform

	// nodeURL is the node as the runtime reaches it (gateway + LLM proxy).
	nodeURL string
	// runtimeURL is set for an externally run runtime; otherwise the adapter
	// runs the runtime as a Nomad service VM reachable at alias:port.
	runtimeURL string
	image      string
	network    string
	alias      string
	port       string
	volume     string
	secret     string
	// memoryKey is the OpenViking root key: the memory server calls its models
	// through the node with it.
	memoryKey string
	// memoryMB is what the runtime asks Nomad to reserve for it.
	memoryMB int64
	client   *http.Client
	// The total model-call deadline and the two liveness deadlines inside it.
	// Kept on the adapter so tests can exercise timeout behaviour in milliseconds.
	llmCallTimeout       time.Duration
	llmFirstEventTimeout time.Duration
	llmStreamIdleTimeout time.Duration

	mu       sync.Mutex
	agents   map[string]*agentDef
	sessions map[string]*session

	runtimeMu sync.Mutex
	runtimeVM string
	healthyAt time.Time

	unbind func()

	// gateFn replaces the node's mid-run budget check (tests).
	gateFn func(ctx context.Context, payer, bot identity.ID, seconds, tokensIn, tokensOut int64) error
	// draftFn, when set, receives the answer in progress instead of the spaces service (tests).
	draftFn func(room, agent, text string)

	// memory meters what each project's memory uses of the memory models.
	memory *memoryMeter
	// learn meters what each project's agents use of the models to improve
	// their playbook (learn.go); charged like memory.
	learn *memoryMeter
	// memoryChargeFn / memoryOwnerFn replace finance and the spaces service in
	// charging for memory (tests).
	memoryRecordFn func(space identity.ID, tokens, tokensIn, amount int64)
	memoryChargeFn func(ctx context.Context, space, payer, payee identity.ID, amount int64, desc string) error
	memoryOwnerFn  func(ctx context.Context, space identity.ID) identity.ID
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "deepagents",
			Category:    api.CategoryVMM,
			Version:     "1.0.0",
			Description: "Deep agents runtime (LangChain deepagents on LangGraph) for every agent",
			Provides:    []string{"vmm"},
			Log:         log,
		},
		image: defaultImage, alias: defaultAlias, port: defaultPort, volume: defaultVolume, memory: newMemoryMeter(),
		learn:                newMemoryMeter(),
		client:               &http.Client{},
		llmCallTimeout:       envDuration(EnvLLMCallTimeout, defaultLLMCallTimeout),
		llmFirstEventTimeout: envDuration(EnvLLMFirstEventTimeout, defaultLLMFirstEventTimeout),
		llmStreamIdleTimeout: envDuration(EnvLLMStreamIdleTimeout, defaultLLMStreamIdleTimeout),
		agents:               map[string]*agentDef{},
		sessions:             map[string]*session{},
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)
	a.Log = deps.Logger
	a.k = deps.Kernel
	if a.platform == nil {
		a.platform = kernelPlatform{K: deps.Kernel}
	}
	o := cfg.VMM(deps.Config).Options
	a.nodeURL = firstNonEmpty(o["node_url"], os.Getenv(EnvNodeURL))
	if a.nodeURL == "" && deps.Kernel != nil {
		a.nodeURL = deps.Kernel.Env()["node_url"]
	}
	a.nodeURL = strings.TrimRight(a.nodeURL, "/")
	a.runtimeURL = strings.TrimRight(firstNonEmpty(o["runtime_url"], os.Getenv(EnvRuntimeURL)), "/")
	a.image = firstNonEmpty(o["image"], os.Getenv(EnvRuntimeImage), a.image)
	a.network = firstNonEmpty(o["network"], os.Getenv(EnvRuntimeNetwork), os.Getenv("ASEMAN_SANDBOX_DOCKER_NETWORK"), defaultNetwork)
	a.alias = firstNonEmpty(o["alias"], a.alias)
	a.port = firstNonEmpty(o["port"], a.port)
	a.volume = firstNonEmpty(o["volume"], a.volume)
	a.secret = firstNonEmpty(o["runtime_secret"], os.Getenv(EnvRuntimeSecret))
	a.memoryKey = strings.TrimSpace(os.Getenv(openviking.EnvKey))
	a.memoryMB = defaultRuntimeMemoryMB
	if v, err := strconv.ParseInt(firstNonEmpty(o["memory_mb"], os.Getenv(EnvRuntimeMemoryMB)), 10, 64); err == nil && v >= 256 {
		a.memoryMB = v
	}
	if a.secret == "" {
		// The runtime started here learns the secret from its environment.
		raw := make([]byte, 24)
		if _, err := rand.Read(raw); err != nil {
			return err
		}
		a.secret = hex.EncodeToString(raw)
	}
	return nil
}

// Start implements api.Plugin: it binds the gateway routes and starts the
// session reaper. The runtime VM itself starts on the first turn.
func (a *Adapter) Start(ctx context.Context) error {
	if binder, ok := a.k.(api.NetworkBindings); ok {
		release, err := binder.BindRoutes("deepagents", a.registerRoutes, a.unregisterRoutes)
		if err != nil {
			return err
		}
		a.unbind = release
	} else {
		a.Log.Warn("network route binding unavailable; agents cannot reach the platform")
	}
	a.startMemoryBilling()
	return nil
}

// Stop implements api.Plugin: it revokes every turn token and stops the
// runtime VM this node started. Threads and their checkpoints stay on the
// runtime's volume and resume on the next turn.
func (a *Adapter) Stop(ctx context.Context) error {
	a.stopMemoryBilling(ctx)
	if a.unbind != nil {
		a.unbind()
		a.unbind = nil
	}
	a.mu.Lock()
	a.sessions = map[string]*session{}
	a.mu.Unlock()
	a.runtimeMu.Lock()
	vmID := a.runtimeVM
	a.runtimeVM = ""
	a.runtimeMu.Unlock()
	if vmID != "" {
		if host := a.serviceHost(); host != nil {
			if err := host.DeleteVM(ctx, vmID); err != nil {
				a.Log.Warn("stop agent runtime", "vm_id", vmID, "error", err)
			}
		}
	}
	return nil
}

// Name implements vmm.VMM.
func (a *Adapter) Name() string { return "deepagents" }

// Open implements vmm.VMM.
func (a *Adapter) Open(context.Context, vmm.Config) error { return nil }

// Close implements vmm.VMM.
func (a *Adapter) Close(context.Context) error { return nil }

// Health implements vmm.VMM.
func (a *Adapter) Health(context.Context) vmm.Health {
	if a.nodeURL == "" {
		return vmm.Health{OK: false, Message: "agent runtime has no node url (" + EnvNodeURL + ")"}
	}
	if a.runtimeURL == "" && a.serviceHost() == nil {
		return vmm.Health{OK: false, Message: "no Nomad VMM to run the agent runtime on, and no " + EnvRuntimeURL}
	}
	return vmm.Health{OK: true, Message: "deep agents runtime ready"}
}

// SupportedTypes implements vmm.VMM.
func (a *Adapter) SupportedTypes() []vmm.Type { return []vmm.Type{vmm.TypeDeepAgents} }

// BuildImage validates an agent spec; the "image" is the definition itself.
func (a *Adapter) BuildImage(ctx context.Context, spec vmm.ImageSpec) (vmm.Image, error) {
	if spec.Type != vmm.TypeDeepAgents {
		return vmm.Image{}, errs.InvalidArgument("the deep agents runtime builds agent images only")
	}
	if _, err := ParseSpec(spec.YML); err != nil {
		return vmm.Image{}, err
	}
	id, err := idutil.RandomHex(8)
	if err != nil {
		return vmm.Image{}, err
	}
	return vmm.Image{ID: id, Type: vmm.TypeDeepAgents, Name: spec.Name, Ref: "deepagent:" + spec.Name, CreatedAt: time.Now().UTC()}, nil
}

// DeleteImage implements vmm.VMM.
func (a *Adapter) DeleteImage(context.Context, string) error { return nil }

// CreateVM registers an agent.
func (a *Adapter) CreateVM(ctx context.Context, spec vmm.VMSpec) (vmm.VM, error) {
	if spec.Type != vmm.TypeDeepAgents {
		return vmm.VM{}, errs.InvalidArgument("the deep agents runtime runs agents only")
	}
	def, err := ParseSpec(spec.YML)
	if err != nil {
		return vmm.VM{}, err
	}
	id, err := idutil.RandomHex(8)
	if err != nil {
		return vmm.VM{}, err
	}
	now := time.Now().UTC()
	vm := vmm.VM{ID: "deepagent-" + id, Name: spec.Name, Type: vmm.TypeDeepAgents, Status: vmm.StatusRunning,
		ImageRef: spec.ImageRef, Resources: spec.Resources, Labels: spec.Labels, CreatedAt: now, StartedAt: &now}
	a.mu.Lock()
	a.agents[vm.ID] = &agentDef{vm: vm, spec: def}
	a.mu.Unlock()
	a.Log.Info("agent registered", "vm_id", vm.ID, "name", def.Name)
	return vm, nil
}

// EnsureAgent (re-)registers an agent from its persisted spec, picking up
// instruction and model edits. Agents recorded on retired engines keep their
// vm ids.
func (a *Adapter) EnsureAgent(ctx context.Context, vmID, specYML string) error {
	spec, err := ParseSpec(specYML)
	if err != nil {
		return err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if def, ok := a.agents[vmID]; ok {
		def.mu.Lock()
		def.spec = spec
		def.mu.Unlock()
		return nil
	}
	now := time.Now().UTC()
	a.agents[vmID] = &agentDef{spec: spec, vm: vmm.VM{ID: vmID, Name: spec.Name, Type: vmm.TypeDeepAgents,
		Status: vmm.StatusRunning, CreatedAt: now, StartedAt: &now}}
	return nil
}

func (a *Adapter) agent(vmID string) (*agentDef, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	def, ok := a.agents[vmID]
	if !ok {
		return nil, errs.NotFound("agent " + vmID)
	}
	return def, nil
}

// DeleteVM unregisters the agent.
func (a *Adapter) DeleteVM(ctx context.Context, id string) error {
	a.mu.Lock()
	delete(a.agents, id)
	a.mu.Unlock()
	return nil
}

// StartVM implements vmm.VMM.
func (a *Adapter) StartVM(ctx context.Context, id string) error {
	return a.setStatus(id, vmm.StatusRunning)
}

// StopVM stops the agent from taking turns; it stays registered.
func (a *Adapter) StopVM(ctx context.Context, id string) error {
	return a.setStatus(id, vmm.StatusStopped)
}

// PauseVM implements vmm.VMM.
func (a *Adapter) PauseVM(ctx context.Context, id string) error {
	return a.setStatus(id, vmm.StatusPaused)
}

// ResumeVM implements vmm.VMM.
func (a *Adapter) ResumeVM(ctx context.Context, id string) error {
	return a.setStatus(id, vmm.StatusRunning)
}

func (a *Adapter) setStatus(id string, st vmm.Status) error {
	def, err := a.agent(id)
	if err != nil {
		return err
	}
	def.mu.Lock()
	def.vm.Status = st
	def.mu.Unlock()
	return nil
}

// ResizeVM records the requested resources; agents work on the space sandbox,
// whose resources the space manages.
func (a *Adapter) ResizeVM(ctx context.Context, id string, res vmm.ResourceSpec) (vmm.VM, error) {
	def, err := a.agent(id)
	if err != nil {
		return vmm.VM{}, err
	}
	def.mu.Lock()
	defer def.mu.Unlock()
	def.vm.Resources = res
	return def.vm, nil
}

// GetVM implements vmm.VMM.
func (a *Adapter) GetVM(ctx context.Context, id string) (vmm.VM, error) {
	def, err := a.agent(id)
	if err != nil {
		return vmm.VM{}, err
	}
	def.mu.Lock()
	defer def.mu.Unlock()
	return def.vm, nil
}

// ListVMs implements vmm.VMM.
func (a *Adapter) ListVMs(ctx context.Context, f vmm.Filter) ([]vmm.VM, error) {
	a.mu.Lock()
	defs := make([]*agentDef, 0, len(a.agents))
	for _, d := range a.agents {
		defs = append(defs, d)
	}
	a.mu.Unlock()
	var out []vmm.VM
	for _, d := range defs {
		d.mu.Lock()
		vm := d.vm
		d.mu.Unlock()
		if f.Status != "" && vm.Status != f.Status {
			continue
		}
		out = append(out, vm)
	}
	return out, nil
}

// Usage reports the agent's cumulative model tokens.
func (a *Adapter) Usage(ctx context.Context, id string) (vmm.Usage, error) {
	def, err := a.agent(id)
	if err != nil {
		return vmm.Usage{}, err
	}
	def.mu.Lock()
	defer def.mu.Unlock()
	u := vmm.Usage{VMID: id, TokensIn: def.tokensIn, TokensOut: def.tokensOut, MeasuredAt: time.Now().UTC()}
	if def.vm.StartedAt != nil {
		u.UptimeSeconds = int64(time.Since(*def.vm.StartedAt).Seconds())
	}
	return u, nil
}

func (a *Adapter) registerRoutes(n network.Network) error {
	for _, r := range routes(a) {
		if err := n.Handle(r.method, r.path, r.handler); err != nil {
			return err
		}
	}
	return nil
}

func (a *Adapter) unregisterRoutes(n network.Network) error {
	var first error
	for _, r := range routes(a) {
		if err := n.Unhandle(r.method, r.path); err != nil && first == nil {
			first = err
		}
	}
	return first
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}
