// Package modal implements the VMM port backed by Modal's remote sandbox API,
// using Modal's official Go client (github.com/modal-labs/modal-client/go).
// Each "VM" is a Modal sandbox kept alive (entrypoint `sleep infinity`); shell
// commands run inside it via the sandbox exec API.
package modal

import (
	"context"
	"io"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/adapters/base"
	"github.com/tradera/tradera/plugins/adapters/cfg"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"

	modal "github.com/modal-labs/modal-client/go"
	"google.golang.org/grpc"
)

// defaultSandboxLifetime is how long a sandbox may live before Modal reaps it.
const defaultSandboxLifetime = 24 * time.Hour

// defaultExecTimeout bounds a single sandbox command so it can never block the
// calling agent/workflow forever (mirrors the docker sandbox behaviour).
const defaultExecTimeout = 300 * time.Second

type sandboxState struct {
	sb    *modal.Sandbox
	start time.Time
	slept bool // "slept": retained on Modal but not actively used
	spec  vmm.VMSpec
}

// Adapter is the Modal VMM plugin.
type Adapter struct {
	base.Base
	tokenID     string
	tokenSecret string
	environment string
	client      *modal.Client
	k           api.Kernel
	mu          sync.Mutex
	sandboxes   map[string]*sandboxState
	// conn is the client's own gRPC connection, captured by an interceptor
	// (see workspace.go); volumeIDs caches workspace volume ids by name.
	conn      atomic.Pointer[grpc.ClientConn]
	volumeIDs map[string]string
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "modal",
			Category:    api.CategoryVMM,
			Version:     "1.0.0",
			Description: "Modal remote sandbox provider",
			Provides:    []string{"vmm"},
			Log:         log,
		},
		sandboxes: map[string]*sandboxState{},
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)
	a.Log = deps.Logger
	a.k = deps.Kernel
	c := cfg.VMM(deps.Config)
	a.tokenID = c.Options["modal_token_id"]
	a.tokenSecret = c.Options["modal_token_secret"]
	a.environment = c.Options["modal_environment"]
	if a.tokenID == "" || a.tokenSecret == "" {
		return errs.InvalidArgument("modal adapter requires config.options.modal_token_id and modal_token_secret")
	}
	return nil
}

// Start implements api.Plugin: build the Modal client and verify auth.
func (a *Adapter) Start(ctx context.Context) error {
	client, err := modal.NewClientWithOptions(&modal.ClientParams{
		TokenID:     a.tokenID,
		TokenSecret: a.tokenSecret,
		// Empty keeps the SDK default (MODAL_ENVIRONMENT or the profile).
		Environment: a.environment,
		// Keeps the client's authenticated connection for the volume file calls.
		GRPCUnaryInterceptors: []grpc.UnaryClientInterceptor{func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
			a.conn.Store(cc)
			return invoker(ctx, method, req, reply, cc, opts...)
		}},
	})
	if err != nil {
		return errs.Wrap(errs.CodeVMM, err, "modal client")
	}
	a.client = client
	return nil
}

// Stop implements api.Plugin. Sandboxes are intentionally retained (slept),
// not terminated, so they survive server restarts and idle windows; they are
// only deleted when their owning space is deleted (via DeleteVM).
func (a *Adapter) Stop(ctx context.Context) error { return nil }

// Name implements vmm.VMM.
func (a *Adapter) Name() string { return "modal" }

// Open implements vmm.VMM.
func (a *Adapter) Open(ctx context.Context, c vmm.Config) error { return nil }

// Close implements vmm.VMM.
func (a *Adapter) Close(ctx context.Context) error { return nil }

// Health implements vmm.VMM.
func (a *Adapter) Health(ctx context.Context) vmm.Health {
	if a.client == nil {
		return vmm.Health{OK: false, Message: "modal client not initialized"}
	}
	return vmm.Health{OK: true, Message: "modal healthy"}
}

// SupportedTypes implements vmm.VMM.
func (a *Adapter) SupportedTypes() []vmm.Type { return []vmm.Type{vmm.TypeModal} }

// BuildImage implements vmm.VMM: registry-based images are used directly, so
// this just records the reference.
func (a *Adapter) BuildImage(ctx context.Context, spec vmm.ImageSpec) (vmm.Image, error) {
	if spec.Type != vmm.TypeModal {
		return vmm.Image{}, errs.InvalidArgument("modal provider only builds modal images")
	}
	if spec.Name == "" {
		return vmm.Image{}, errs.InvalidArgument("image name required")
	}
	return vmm.Image{ID: spec.Name, Type: vmm.TypeModal, Name: spec.Name, Ref: spec.Name,
		CreatedAt: time.Now().UTC()}, nil
}

// DeleteImage implements vmm.VMM.
func (a *Adapter) DeleteImage(ctx context.Context, ref string) error { return nil }

// CreateVM implements vmm.VMM: create a persistent Modal sandbox running the
// spec's entrypoint (e.g. `sleep infinity`), ready for shell exec.
func (a *Adapter) CreateVM(ctx context.Context, spec vmm.VMSpec) (vmm.VM, error) {
	st, vm, err := a.create(ctx, spec)
	if err != nil {
		return vmm.VM{}, err
	}
	a.mu.Lock()
	a.sandboxes[vm.ID] = st
	a.mu.Unlock()
	a.Log.Info("modal sandbox created", "sandbox", vm.ID, "image", vm.ImageRef)
	return vm, nil
}

// create provisions a new Modal sandbox for the spec and returns its state and
// VM descriptor. The sandbox entrypoint keeps the instance alive for its full
// lifetime; an idle stop terminates it, and its /workspace volume brings the
// files to the next sandbox.
func (a *Adapter) create(ctx context.Context, spec vmm.VMSpec) (*sandboxState, vmm.VM, error) {
	if a.client == nil {
		return nil, vmm.VM{}, errs.New(errs.CodeUnavailable, "modal client not initialized")
	}
	if spec.Type != vmm.TypeModal {
		return nil, vmm.VM{}, errs.InvalidArgument("modal provider only runs modal VMs")
	}
	imageRef := spec.ImageRef
	if imageRef == "" {
		imageRef = "node:20-alpine"
	}
	app, err := a.client.Apps.FromName(ctx, sandboxApp, &modal.AppFromNameParams{CreateIfMissing: true})
	if err != nil {
		return nil, vmm.VM{}, errs.Wrap(errs.CodeVMM, err, "modal app")
	}
	// A tag is resolved to its digest so a newly pushed image is actually used.
	img := a.client.Images.FromRegistry(pinImage(ctx, imageRef), nil)
	cmd := spec.Args
	if len(cmd) == 0 {
		cmd = []string{"sleep", "infinity"}
	}
	// A project's files live on a volume, not on the sandbox: the sandbox is
	// terminated when idle (so Modal stops billing it) and a new one mounts the
	// same volume when work resumes.
	var volumes map[string]*modal.Volume
	if name := workspaceVolumeName(spec); name != "" {
		vol, verr := a.client.Volumes.FromName(ctx, name, &modal.VolumeFromNameParams{CreateIfMissing: true})
		if verr != nil {
			return nil, vmm.VM{}, errs.Wrap(errs.CodeVMM, verr, "modal workspace volume")
		}
		volumes = map[string]*modal.Volume{"/workspace": vol}
	}
	cpuRequest, cpuLimit, memRequest, memLimit := burstSizes(spec.Resources, a.sizes(ctx))
	sb, err := a.client.Sandboxes.Create(ctx, app, img, &modal.SandboxCreateParams{
		Command: cmd,
		Volumes: volumes,
		Timeout: defaultSandboxLifetime,
		// The platform decides when a sandbox is idle (spaces: sandboxIdleTTL) and
		// terminates it itself; Modal's own idle window must not cut a long
		// command short, so it is set explicitly rather than left at its default.
		IdleTimeout: defaultSandboxLifetime,
		CPU:         cpuRequest,
		CPULimit:    cpuLimit,
		MemoryMiB:   memRequest,
		// The request is only what Modal must guarantee (and bill) while it
		// idles; the limit is how far a busy computer may go.
		MemoryLimitMiB: memLimit,
	})
	if err != nil {
		return nil, vmm.VM{}, errs.Wrap(errs.CodeVMM, err, "modal sandbox create")
	}
	now := time.Now().UTC()
	return &sandboxState{sb: sb, start: now, spec: spec},
		vmm.VM{ID: sb.SandboxID, Name: spec.Name, Type: vmm.TypeModal, Status: vmm.StatusRunning,
			ImageRef: imageRef, Resources: spec.Resources, CreatedAt: now}, nil
}

// A sandbox asks Modal for a small guaranteed share, the "reserve", and may use
// far more when it needs to, up to a generous ceiling. Modal bills the greater of
// what is reserved and what is used, so an awake-but-idle computer costs the
// reserve, while a build, a browser or the desktop takes what it needs.
//
// The reserve and the ceiling are the admin's Machine settings (settings.Machine).
// Without them, the reserve is a fraction of the size the project is sold at, with
// a floor, and the ceiling is 4 CPU and 8 GB (the size computers had before
// reserves existed), never below the sold size.
type machineSizes struct {
	ReserveCPU      float64 `json:"reserve_cpu"`
	ReserveMemoryMB int64   `json:"reserve_memory_mb"`
	MaxCPU          float64 `json:"max_cpu"`
	MaxMemoryMB     int64   `json:"max_memory_mb"`
}

const (
	burstMinCPU       = 0.25
	burstCPUDivisor   = 8.0 // reserve = sold size / 8, at least burstMinCPU
	burstMinMemoryMiB = 512
	burstMemDivisor   = 4 // reserve = sold size / 4, at least burstMinMemoryMiB

	defaultMaxCPU       = 4.0
	defaultMaxMemoryMiB = 8192
)

// sizes reads the admin's reserve and ceiling; zero values mean "automatic".
func (a *Adapter) sizes(ctx context.Context) machineSizes {
	var m machineSizes
	if a.k != nil {
		_ = bridge.Invoke(ctx, a.k, "settings", "Machine", []any{ctx}, &m)
	}
	return m
}

// burstSizes returns the CPU and memory (reserve, ceiling) pairs for a sandbox
// sold at [res]. A size of zero means "unspecified" and is passed through.
func burstSizes(res vmm.ResourceSpec, m machineSizes) (cpuRequest, cpuLimit float64, memRequest, memLimit int) {
	if res.CPU > 0 {
		cpuLimit = max(res.CPU, m.MaxCPU, defaultMaxCPUIfUnset(m.MaxCPU))
		cpuRequest = m.ReserveCPU
		if cpuRequest <= 0 {
			cpuRequest = max(burstMinCPU, res.CPU/burstCPUDivisor)
		}
		cpuRequest = min(cpuRequest, res.CPU, cpuLimit)
	}
	if res.MemoryMB > 0 {
		sold := int(res.MemoryMB)
		memLimit = max(sold, int(m.MaxMemoryMB), defaultMaxMemoryIfUnset(int(m.MaxMemoryMB)))
		memRequest = int(m.ReserveMemoryMB)
		if memRequest <= 0 {
			memRequest = max(burstMinMemoryMiB, sold/burstMemDivisor)
		}
		memRequest = min(memRequest, sold, memLimit)
	}
	return
}

func defaultMaxCPUIfUnset(v float64) float64 {
	if v > 0 {
		return 0
	}
	return defaultMaxCPU
}

func defaultMaxMemoryIfUnset(v int) int {
	if v > 0 {
		return 0
	}
	return defaultMaxMemoryMiB
}

// DeleteVM implements vmm.VMM: permanently terminate the Modal sandbox. This is
// only invoked when the owning space is deleted (or the bot is removed); idle
// stops use StopVM, which sleeps the sandbox instead of deleting it.
func (a *Adapter) DeleteVM(ctx context.Context, id string) error {
	st, _ := a.take(id)
	var sb *modal.Sandbox
	if st != nil {
		sb = st.sb
	}
	if a.client == nil {
		return errs.New(errs.CodeUnavailable, "modal client not initialized")
	}
	// A sandbox the daemon no longer tracks (restart, or it was slept) may
	// still be alive: find it so it is ended before its volume is deleted.
	if sb == nil {
		if found, err := a.client.Sandboxes.FromID(ctx, id, nil); err == nil {
			sb = found
		}
	}
	if sb != nil {
		if code, perr := sb.Poll(ctx, &modal.SandboxPollParams{}); perr != nil || code == nil {
			if _, err := sb.Terminate(ctx, &modal.SandboxTerminateParams{Wait: true}); err != nil {
				return errs.Wrap(errs.CodeVMM, err, "terminate modal sandbox")
			}
			a.Log.Info("modal sandbox terminated", "sandbox", id)
		}
	}
	return nil
}

// DeleteWorkspaceVolume permanently deletes the /workspace volume of the project
// computer called machine ("sbx-…"). It is separate from DeleteVM on purpose:
// a computer comes and goes (idle stop, rebuild, replacement) while its volume
// is the project's persistent storage, so only deleting the project calls this.
// A volume that is already gone is not an error.
var _ vmm.VolumeDeleter = (*Adapter)(nil)

func (a *Adapter) DeleteWorkspaceVolume(ctx context.Context, machine string) error {
	if a.client == nil {
		return errs.New(errs.CodeUnavailable, "modal client not initialized")
	}
	name := workspaceVolumeName(vmm.VMSpec{Name: machine})
	if name == "" {
		return nil
	}
	var err error
	// Modal may still see the volume as in use for a moment after the sandbox ends.
	for i := 0; i < 5; i++ {
		if err = a.client.Volumes.Delete(ctx, name, &modal.VolumeDeleteParams{AllowMissing: true}); err == nil {
			a.mu.Lock()
			delete(a.volumeIDs, name)
			a.mu.Unlock()
			a.Log.Info("modal workspace volume deleted", "volume", name)
			return nil
		}
		select {
		case <-ctx.Done():
			return errs.Wrap(errs.CodeVMM, ctx.Err(), "delete modal workspace volume")
		case <-time.After(2 * time.Second):
		}
	}
	a.Log.Warn("modal workspace volume not deleted", "volume", name, "error", err)
	return errs.Wrap(errs.CodeVMM, err, "delete modal workspace volume")
}

func (a *Adapter) take(id string) (*sandboxState, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	st, ok := a.sandboxes[id]
	if ok {
		delete(a.sandboxes, id)
	}
	return st, ok
}

// StartVM implements vmm.VMM: wake a slept sandbox so it can be used again.
// Liveness is probed so a sandbox Modal already shut down (e.g. its lifetime
// expired while idle) surfaces as an error and the caller recreates it.
func (a *Adapter) StartVM(ctx context.Context, id string) error {
	st, err := a.ensure(ctx, id)
	if err != nil {
		return err
	}
	if code, perr := st.sb.Poll(ctx, &modal.SandboxPollParams{}); perr == nil && code != nil {
		// Modal ended it (lifetime reached, crash): start a new one on the volume.
		a.mu.Lock()
		st.sb = nil
		a.mu.Unlock()
		if st, err = a.ensure(ctx, id); err != nil {
			return err
		}
	} else if perr != nil {
		return errs.Wrap(errs.CodeVMM, perr, "modal sandbox probe")
	}
	a.mu.Lock()
	st.slept = false
	a.mu.Unlock()
	return nil
}

// StopVM implements vmm.VMM: terminate the Modal sandbox so it stops running
// (and billing). Files are on the workspace volume; the next StartVM, Send or
// tunnel creates a new sandbox from the same spec.
func (a *Adapter) StopVM(ctx context.Context, id string) error {
	a.mu.Lock()
	st, ok := a.sandboxes[id]
	var sb *modal.Sandbox
	if ok {
		sb = st.sb
	}
	a.mu.Unlock()
	if !ok && a.client != nil {
		// Not tracked (the daemon restarted): stop whatever instance is still alive.
		found, err := a.client.Sandboxes.FromID(ctx, id, nil)
		if err != nil {
			return errs.Wrap(errs.CodeVMM, err, "find modal sandbox to stop")
		}
		sb = found
	}
	if sb == nil {
		if !ok {
			return errs.New(errs.CodeUnavailable, "modal client unavailable for sandbox stop")
		}
		return nil
	}
	if code, perr := sb.Poll(ctx, &modal.SandboxPollParams{}); perr == nil && code != nil {
		return a.finishSandboxStop(id, sb, func() error { return nil }) // already ended
	}
	// Only a sandbox whose /workspace is a volume can be terminated without
	// losing the project's files; one made before volumes existed is left running
	// (and keeps its files) until it is replaced.
	// /workspace is a link to the volume's mount under /__modal/volumes.
	marker := strconv.FormatInt(time.Now().UnixNano(), 10)
	out, err := a.exec(ctx, sb, `readlink -f /workspace | grep -q '^/__modal/volumes/' && mkdir -p /workspace/.tradera && echo `+marker+` > /workspace/.tradera/sync && sync`)
	if err != nil || !strings.HasPrefix(out, "exit=0") {
		if err != nil {
			return errs.Wrap(errs.CodeVMM, err, "prepare modal sandbox for stop")
		}
		return errs.New(errs.CodeVMM, "sandbox stop could not verify and sync its workspace volume; replace legacy machines to enable idle shutdown")
	}
	if err := a.finishSandboxStop(id, sb, func() error {
		_, err := sb.Terminate(ctx, nil)
		return err
	}); err != nil {
		return err
	}
	// Modal commits the volume a few seconds after the sandbox ends. Wait for
	// this stop's marker to be readable, so files read right after "sleep" are
	// the files the computer left.
	a.waitForCommit(ctx, id, marker)
	a.Log.Info("modal sandbox stopped (idle)", "vm", id)
	return nil
}

// Only detach a running instance after the provider confirms termination.
// Failed stops stay live, so status, metering and the idle retry remain accurate.
func (a *Adapter) finishSandboxStop(id string, expected *modal.Sandbox, terminate func() error) error {
	if err := terminate(); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "terminate modal sandbox")
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if st := a.sandboxes[id]; st != nil && st.sb == expected {
		st.sb, st.slept = nil, true
	}
	return nil
}

// PauseVM implements vmm.VMM (unsupported).
func (a *Adapter) PauseVM(ctx context.Context, id string) error {
	return errs.New(errs.CodeUnavailable, "pause not supported by "+a.Name()+" provider")
}

// ResumeVM implements vmm.VMM (unsupported).
func (a *Adapter) ResumeVM(ctx context.Context, id string) error {
	return errs.New(errs.CodeUnavailable, "resume not supported by "+a.Name()+" provider")
}

// ResizeVM implements vmm.VMM: a Modal sandbox cannot change size while it
// runs, so the new size is kept and applies from the next time the computer
// wakes (idle stops end the sandbox, so that is soon). The workspace volume
// carries the files across.
func (a *Adapter) ResizeVM(ctx context.Context, id string, res vmm.ResourceSpec) (vmm.VM, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	st, ok := a.sandboxes[id]
	if !ok {
		return vmm.VM{}, errs.NotFound("vm " + id)
	}
	st.spec.Resources = res
	return vmm.VM{ID: id, Name: st.spec.Name, Type: vmm.TypeModal, Status: vmm.StatusRunning, Resources: res, CreatedAt: st.start}, nil
}

// GetVM implements vmm.VMM.
func (a *Adapter) GetVM(ctx context.Context, id string) (vmm.VM, error) {
	a.mu.Lock()
	st, ok := a.sandboxes[id]
	a.mu.Unlock()
	if !ok {
		return vmm.VM{}, errs.NotFound("vm " + id)
	}
	status := vmm.StatusRunning
	if st.slept || st.sb == nil {
		status = vmm.StatusStopped
	}
	return vmm.VM{ID: id, Name: id, Type: vmm.TypeModal, Status: status,
		CreatedAt: st.start}, nil
}

// ListVMs implements vmm.VMM.
func (a *Adapter) ListVMs(ctx context.Context, f vmm.Filter) ([]vmm.VM, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	var out []vmm.VM
	for id, st := range a.sandboxes {
		status := vmm.StatusRunning
		if st.slept || st.sb == nil {
			status = vmm.StatusStopped
		}
		vm := vmm.VM{ID: id, Name: id, Type: vmm.TypeModal, Status: status, CreatedAt: st.start}
		if f.Status != "" && vm.Status != f.Status {
			continue
		}
		out = append(out, vm)
	}
	return out, nil
}

// Usage implements vmm.VMM.
func (a *Adapter) Usage(ctx context.Context, id string) (vmm.Usage, error) {
	a.mu.Lock()
	st, ok := a.sandboxes[id]
	a.mu.Unlock()
	if !ok {
		return vmm.Usage{}, errs.NotFound("vm " + id)
	}
	return vmm.Usage{VMID: id, UptimeSeconds: int64(time.Since(st.start).Seconds()),
		MeasuredAt: time.Now().UTC()}, nil
}

// ensure returns a live sandbox for an id. A sandbox stopped for idleness (or
// lost with the daemon) is brought back by creating a new one from the spec on
// the same volume, so the id the platform holds stays valid. An error means it
// cannot be recreated (no spec is known for it).
func (a *Adapter) ensure(ctx context.Context, id string) (*sandboxState, error) {
	a.mu.Lock()
	st, ok := a.sandboxes[id]
	a.mu.Unlock()
	if ok && st.sb != nil {
		return st, nil
	}
	if a.client == nil {
		return nil, errs.New(errs.CodeUnavailable, "modal client not initialized")
	}
	// The instance may still be alive (the daemon restarted, or an older
	// version kept it running): reattach instead of paying for a second one.
	if sb, err := a.client.Sandboxes.FromID(ctx, id, nil); err == nil {
		if code, perr := sb.Poll(ctx, &modal.SandboxPollParams{}); perr == nil && code == nil {
			a.mu.Lock()
			defer a.mu.Unlock()
			if st, ok := a.sandboxes[id]; ok {
				st.sb, st.slept = sb, false
				return st, nil
			}
			st = &sandboxState{sb: sb, start: time.Now()}
			a.sandboxes[id] = st
			return st, nil
		}
	}
	if !ok || !specHasType(st.spec) {
		return nil, errs.NotFound("modal sandbox " + id + " is gone and its spec is unknown (recreate)")
	}
	fresh, vm, err := a.create(ctx, st.spec)
	if err != nil {
		return nil, err
	}
	a.mu.Lock()
	st.sb, st.start, st.slept = fresh.sb, fresh.start, false
	a.mu.Unlock()
	a.Log.Info("modal sandbox woken", "vm", id, "sandbox", vm.ID)
	return st, nil
}

// Alive reports whether the Modal sandbox behind a VM id is really running (the
// platform's stored status can be wrong: Modal ends sandboxes on its own, and
// people end them from its dashboard). A stopped or unknown sandbox is not alive.
func (a *Adapter) Alive(ctx context.Context, id string) bool {
	a.mu.Lock()
	st, ok := a.sandboxes[id]
	var sb *modal.Sandbox
	if ok {
		sb = st.sb
	}
	a.mu.Unlock()
	if ok && sb == nil {
		return false
	}
	if sb == nil {
		if a.client == nil {
			return false
		}
		found, err := a.client.Sandboxes.FromID(ctx, id, nil)
		if err != nil {
			return false
		}
		sb = found
	}
	code, err := sb.Poll(ctx, &modal.SandboxPollParams{})
	if err != nil {
		return true // cannot tell: do not call a possibly running computer asleep
	}
	return code == nil
}

// Adopt tells the adapter what a VM id was created from, so it can recreate the
// sandbox after the daemon restarted (it implements the optional adopter used by
// the bots service before it starts a VM).
func (a *Adapter) Adopt(id string, spec vmm.VMSpec) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if st, ok := a.sandboxes[id]; ok {
		if !specHasType(st.spec) {
			st.spec = spec
		}
		return
	}
	a.sandboxes[id] = &sandboxState{spec: spec, slept: true, start: time.Now()}
}

// workspaceVolumeName is the Modal volume holding a project sandbox's /workspace
// ("" for VMs that keep no state).
func workspaceVolumeName(spec vmm.VMSpec) string {
	if v := spec.Labels[vmm.LabelVolume]; v != "" {
		if name, _, ok := strings.Cut(v, ":"); ok && name != "" {
			return name
		}
	}
	if strings.HasPrefix(spec.Name, "sbx-") {
		return "tradera-" + spec.Name
	}
	return ""
}

// CreateTunnel exposes a port of the sandbox through Modal's HTTP connect
// tunnel. It returns the public target URL and the bearer token the gateway
// uses to reach the sandbox port. This powers the platform proxy: the gateway
// reverse-proxies /v1/proxy/{id}/* to this target so users can open pages served
// from the sandbox (e.g. a Next.js landing page) in a webview.
func (a *Adapter) CreateTunnel(ctx context.Context, id string, port int) (string, string, error) {
	st, err := a.ensure(ctx, id)
	if err != nil {
		return "", "", err
	}
	if port <= 0 {
		port = 8080
	}
	creds, err := st.sb.CreateConnectToken(ctx, &modal.SandboxCreateConnectTokenParams{Port: port})
	if err != nil {
		return "", "", errs.Wrap(errs.CodeVMM, err, "modal connect token")
	}
	return creds.URL, creds.Token, nil
}

// Send executes a shell command inside the sandbox and returns its output with
// the exit code (sandbox exec entry point for agents/tools). If the underlying
// Modal sandbox shut down, it is recreated from its stored spec (the caller
// never has to know the instance was replaced).
func (a *Adapter) Send(ctx context.Context, id, command string) (string, error) {
	st, err := a.ensure(ctx, id)
	if err != nil {
		return "", err
	}
	a.mu.Lock()
	st.slept = false
	spec := st.spec
	a.mu.Unlock()

	out, execErr := a.exec(ctx, st.sb, command)
	if execErr == nil || !specHasType(spec) {
		return out, execErr
	}
	// The Modal instance is gone: recreate a fresh one and retry once.
	a.Log.Warn("modal sandbox dead, recreating", "sandbox", id)
	st2, vm, cerr := a.create(ctx, spec)
	if cerr != nil {
		return out, execErr
	}
	a.mu.Lock()
	a.sandboxes[id] = st2
	a.mu.Unlock()
	if _, perr := st2.sb.Poll(ctx, &modal.SandboxPollParams{}); perr != nil {
		return out, execErr
	}
	a.Log.Info("modal sandbox recreated", "sandbox", vm.ID)
	return a.exec(ctx, st2.sb, command)
}

func specHasType(spec vmm.VMSpec) bool { return spec.Type == vmm.TypeModal }

// exec runs a command in a sandbox, returning its output and exit code.
func (a *Adapter) exec(ctx context.Context, sb *modal.Sandbox, command string) (string, error) {
	// The sandbox may still be starting right after creation; retry briefly.
	var cp *modal.ContainerProcess
	var lastErr error
	for attempt := 0; attempt < 10; attempt++ {
		cp, lastErr = sb.Exec(ctx, []string{"/bin/sh", "-c", command}, &modal.SandboxExecParams{
			Stdout:  modal.Pipe,
			Stderr:  modal.Pipe,
			Timeout: defaultExecTimeout,
		})
		if lastErr == nil {
			break
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(time.Second):
		}
	}
	if lastErr != nil {
		return "", errs.Wrap(errs.CodeVMM, lastErr, "modal exec")
	}
	out, _ := io.ReadAll(cp.Stdout)
	er, _ := io.ReadAll(cp.Stderr)
	code := 0
	if ec, werr := cp.Wait(ctx, nil); werr == nil {
		code = ec
	}
	text := string(out)
	if er := string(er); er != "" {
		if text != "" {
			text += "\n"
		}
		text += er
	}
	if text == "" {
		text = "(no output)"
	}
	return "exit=" + itoa(code) + "\n" + text, nil
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

// waitForCommit waits (briefly) until the marker a stopping computer wrote is
// readable from its volume, which means the volume holds everything it wrote.
func (a *Adapter) waitForCommit(ctx context.Context, id, marker string) {
	if _, _, err := a.volume(ctx, id); err != nil {
		return // nothing to read it with (the computer's spec is unknown)
	}
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		a.mu.Lock()
		if st, ok := a.sandboxes[id]; ok {
			st.slept = true // reads below go to the volume API
		}
		a.mu.Unlock()
		if got, err := a.ReadWorkspace(ctx, id, ".tradera/sync"); err == nil && strings.TrimSpace(string(got)) == marker {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}
	a.Log.Warn("modal workspace volume not yet committed after stop", "vm", id)
}
