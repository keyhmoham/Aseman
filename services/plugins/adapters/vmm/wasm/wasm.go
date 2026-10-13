// Package wasm implements the VMM port with a real in-process WebAssembly
// runtime (wazero). Each VM is an instantiated WASM module; images are
// pre-compiled modules; lifecycle maps to instantiating/closing modules.
package wasm

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/adapters/base"
	"github.com/tradera/tradera/plugins/adapters/cfg"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"

	"github.com/tetratelabs/wazero"
	wazeroapi "github.com/tetratelabs/wazero/api"
)

type vmRuntime struct {
	cancel context.CancelFunc
	start  time.Time
	mod    wazeroapi.Module
	done   chan struct{}
}

// Adapter is the WASM VMM plugin.
type Adapter struct {
	base.Base
	mu      sync.Mutex
	runtime wazero.Runtime
	ctx     context.Context
	images  map[string]vmm.Image
	vms     map[string]*vmRuntime
	roots   string
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "wasm",
			Category:    api.CategoryVMM,
			Version:     "1.0.0",
			Description: "In-process WebAssembly VM provider (wazero)",
			Provides:    []string{"vmm"},
			Log:         log,
		},
		images: map[string]vmm.Image{},
		vms:    map[string]*vmRuntime{},
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)

	a.Log = deps.Logger
	c := cfg.VMM(deps.Config)
	a.roots = c.Options["module_root"]
	if a.roots == "" {
		a.roots = "./data/wasm"
	}
	return nil
}

// Start implements api.Plugin.
func (a *Adapter) Start(ctx context.Context) error {
	a.ctx = context.Background()
	a.runtime = wazero.NewRuntime(a.ctx)
	return nil
}

// Stop implements api.Plugin.
func (a *Adapter) Stop(ctx context.Context) error {
	if a.runtime != nil {
		return a.runtime.Close(ctx)
	}
	return nil
}

// Name implements vmm.VMM.
func (a *Adapter) Name() string { return "wasm" }

// Open implements vmm.VMM.
func (a *Adapter) Open(ctx context.Context, c vmm.Config) error { return nil }

// Close implements vmm.VMM.
func (a *Adapter) Close(ctx context.Context) error { return a.Stop(ctx) }

// Health implements vmm.VMM.
func (a *Adapter) Health(ctx context.Context) vmm.Health {
	if a.runtime == nil {
		return vmm.Health{OK: false, Message: "wasm runtime not started"}
	}
	return vmm.Health{OK: true, Message: "wasm runtime healthy"}
}

// SupportedTypes implements vmm.VMM.
func (a *Adapter) SupportedTypes() []vmm.Type { return []vmm.Type{vmm.TypeWASM} }

// BuildImage implements vmm.VMM: compiles the module found by Ref.
func (a *Adapter) BuildImage(ctx context.Context, spec vmm.ImageSpec) (vmm.Image, error) {
	if spec.Type != vmm.TypeWASM {
		return vmm.Image{}, errs.InvalidArgument("wasm provider only builds wasm images")
	}
	path := spec.YML
	if path == "" {
		return vmm.Image{}, errs.InvalidArgument("wasm image requires yml (module path)")
	}
	if !filepath.IsAbs(path) {
		path = filepath.Join(a.roots, path)
	}
	bytes, err := os.ReadFile(path)
	if err != nil {
		return vmm.Image{}, errs.Wrap(errs.CodeVMM, err, "read wasm module "+path)
	}
	if _, err := a.runtime.CompileModule(a.ctx, bytes); err != nil {
		return vmm.Image{}, errs.Wrap(errs.CodeVMM, err, "compile wasm module")
	}
	img := vmm.Image{ID: spec.Name, Type: vmm.TypeWASM, Name: spec.Name, Ref: path,
		Size: int64(len(bytes)), CreatedAt: time.Now().UTC()}
	a.mu.Lock()
	a.images[img.Ref] = img
	a.mu.Unlock()
	a.Log.Info("wasm image compiled", "name", spec.Name, "path", path)
	return img, nil
}

// DeleteImage implements vmm.VMM.
func (a *Adapter) DeleteImage(ctx context.Context, ref string) error {
	a.mu.Lock()
	delete(a.images, ref)
	a.mu.Unlock()
	return nil
}

// CreateVM implements vmm.VMM.
func (a *Adapter) CreateVM(ctx context.Context, spec vmm.VMSpec) (vmm.VM, error) {
	if spec.Type != vmm.TypeWASM {
		return vmm.VM{}, errs.InvalidArgument("wasm provider only runs wasm VMs")
	}
	path := spec.ImageRef
	if !filepath.IsAbs(path) {
		path = filepath.Join(a.roots, path)
	}
	bytes, err := os.ReadFile(path)
	if err != nil {
		return vmm.VM{}, errs.Wrap(errs.CodeVMM, err, "read wasm module "+path)
	}
	compiled, err := a.runtime.CompileModule(a.ctx, bytes)
	if err != nil {
		return vmm.VM{}, errs.Wrap(errs.CodeVMM, err, "compile wasm module")
	}
	id := spec.Name
	cfg := wazero.NewModuleConfig().
		WithName("tradera-" + id).
		WithArgs(spec.Args...).
		WithStdout(os.Stdout).WithStderr(os.Stderr).WithStdin(os.Stdin)
	for k, v := range spec.Environment {
		cfg = cfg.WithEnv(k, v)
	}
	mod, err := a.runtime.InstantiateModule(a.ctx, compiled, cfg)
	if err != nil {
		return vmm.VM{}, errs.Wrap(errs.CodeVMM, err, "instantiate wasm module")
	}
	vctx, cancel := context.WithCancel(a.ctx)
	run := &vmRuntime{cancel: cancel, start: time.Now(), mod: mod, done: make(chan struct{})}
	a.mu.Lock()
	a.vms[id] = run
	a.mu.Unlock()
	if start := mod.ExportedFunction("_start"); start != nil {
		go func() {
			defer close(run.done)
			_, _ = start.Call(vctx)
		}()
	}
	a.Log.Info("wasm vm created", "vm", id)
	return vmm.VM{ID: id, Name: spec.Name, Type: vmm.TypeWASM, Status: vmm.StatusRunning,
		ImageRef: spec.ImageRef, Resources: spec.Resources, CreatedAt: time.Now().UTC()}, nil
}

// DeleteVM implements vmm.VMM.
func (a *Adapter) DeleteVM(ctx context.Context, id string) error {
	a.mu.Lock()
	run, ok := a.vms[id]
	delete(a.vms, id)
	a.mu.Unlock()
	if !ok {
		return errs.NotFound("vm " + id)
	}
	run.cancel()
	if err := run.mod.Close(ctx); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "close wasm module")
	}
	return nil
}

// StartVM implements vmm.VMM (no-op: wasm runs on create).
func (a *Adapter) StartVM(ctx context.Context, id string) error { return nil }

// StopVM implements vmm.VMM.
func (a *Adapter) StopVM(ctx context.Context, id string) error {
	a.mu.Lock()
	run, ok := a.vms[id]
	a.mu.Unlock()
	if !ok {
		return errs.NotFound("vm " + id)
	}
	run.cancel()
	return nil
}

// PauseVM implements vmm.VMM.
func (a *Adapter) PauseVM(ctx context.Context, id string) error {
	a.mu.Lock()
	run, ok := a.vms[id]
	a.mu.Unlock()
	if !ok {
		return errs.NotFound("vm " + id)
	}
	run.cancel()
	return nil
}

// ResumeVM implements vmm.VMM (wasm cannot truly resume; returns the VM).
func (a *Adapter) ResumeVM(ctx context.Context, id string) error {
	a.mu.Lock()
	_, ok := a.vms[id]
	a.mu.Unlock()
	if !ok {
		return errs.NotFound("vm " + id)
	}
	return nil
}

// ResizeVM implements vmm.VMM: live resize is not supported by this provider.
func (a *Adapter) ResizeVM(ctx context.Context, id string, res vmm.ResourceSpec) (vmm.VM, error) {
	return vmm.VM{}, errs.New(errs.CodeUnavailable, "live resize not supported by "+a.Name()+" provider")
}

// GetVM implements vmm.VMM.
func (a *Adapter) GetVM(ctx context.Context, id string) (vmm.VM, error) {
	a.mu.Lock()
	run, ok := a.vms[id]
	a.mu.Unlock()
	if !ok {
		return vmm.VM{}, errs.NotFound("vm " + id)
	}
	status := vmm.StatusRunning
	select {
	case <-run.done:
		status = vmm.StatusStopped
	default:
	}
	return vmm.VM{ID: id, Name: id, Type: vmm.TypeWASM, Status: status, CreatedAt: run.start}, nil
}

// ListVMs implements vmm.VMM.
func (a *Adapter) ListVMs(ctx context.Context, f vmm.Filter) ([]vmm.VM, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	var out []vmm.VM
	for id, run := range a.vms {
		vm := vmm.VM{ID: id, Name: id, Type: vmm.TypeWASM, Status: vmm.StatusRunning, CreatedAt: run.start}
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
	run, ok := a.vms[id]
	a.mu.Unlock()
	if !ok {
		return vmm.Usage{}, errs.NotFound("vm " + id)
	}
	return vmm.Usage{
		VMID:          id,
		MemoryUsedMB:  safeMemMB(run.mod),
		UptimeSeconds: int64(time.Since(run.start).Seconds()),
		MeasuredAt:    time.Now().UTC(),
	}, nil
}

// wasmAskInPtr / wasmAskOutPtr are the linear-memory offsets used by the
// miniapp backend ABI. A backend module exporting `ask` receives the JSON
// request string at wasmAskInPtr and writes its JSON reply at wasmAskOutPtr,
// returning the reply length (or a negative error code).
const (
	wasmAskInPtr  = 4096
	wasmAskOutPtr = 65536
)

// Send delivers an ask to a wasm miniapp backend and returns its reply. It is
// part of the message/ask protocol: an elpian frontend asks its backend
// through message.ask, which lands here as a host call into the module.
func (a *Adapter) Send(ctx context.Context, vmID, message string) (string, error) {
	a.mu.Lock()
	run, ok := a.vms[vmID]
	a.mu.Unlock()
	if !ok {
		return "", errs.NotFound("vm " + vmID)
	}
	ask := run.mod.ExportedFunction("ask")
	if ask == nil {
		return "", errs.New(errs.CodeUnavailable,
			"wasm module does not export ask (miniapp backend ABI)")
	}
	mem := run.mod.Memory()
	if mem == nil {
		return "", errs.New(errs.CodeUnavailable, "wasm module has no memory")
	}
	body := []byte(message)
	if !mem.Write(wasmAskInPtr, body) {
		return "", errs.New(errs.CodeVMM, "wasm ask: cannot write input buffer")
	}
	out, err := ask.Call(ctx, wasmAskInPtr, uint64(len(body)))
	if err != nil {
		return "", errs.Wrap(errs.CodeVMM, err, "wasm ask call")
	}
	if len(out) == 0 {
		return "", errs.New(errs.CodeVMM, "wasm ask returned no value")
	}
	n := int64(out[0])
	if n < 0 {
		return "", errs.New(errs.CodeVMM, "wasm ask returned error code "+strconv.FormatInt(n, 10))
	}
	if n == 0 {
		return "", nil
	}
	reply, ok := mem.Read(wasmAskOutPtr, uint32(n))
	if !ok {
		return "", errs.New(errs.CodeVMM, "wasm ask: cannot read reply buffer")
	}
	return string(reply), nil
}

// safeMemMB reads the module memory size, tolerating modules without an
// initialized memory section.
func safeMemMB(mod wazeroapi.Module) (out int64) {
	defer func() {
		if recover() != nil {
			out = 0
		}
	}()
	if mod == nil {
		return 0
	}
	mem := mod.Memory()
	if mem == nil {
		return 0
	}
	return int64(mem.Size()*64*1024) / (1024 * 1024)
}
