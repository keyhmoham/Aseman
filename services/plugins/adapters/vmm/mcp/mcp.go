// Package mcp represents tool backends without a machine of their own as
// logical VMs: external MCP servers (type mcp) and backends installed into the
// sandbox of each space that adds them (type installed). Connection ownership,
// credentials and where a backend answers stay in the tools action namespace.
package mcp

import (
	"context"
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/idutil"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/adapters/base"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
	"strings"
	"sync"
	"time"
)

type Adapter struct {
	base.Base
	K   api.Kernel
	mu  sync.Mutex
	vms map[string]vmm.VM
}

func New(log *logger.Logger) *Adapter {
	return &Adapter{Base: base.Base{Name: "mcp", Category: api.CategoryVMM, Version: "1.0.0", Description: "Connected remote MCP tools and space-installed tool backends", Provides: []string{"vmm"}, Log: log}, vms: map[string]vmm.VM{}}
}
func (a *Adapter) Init(ctx context.Context, d *api.Dependencies) error {
	a.K = d.Kernel
	a.Log = d.Logger
	a.HealthCheck = base.WireHealth(a.Health)
	return nil
}
func (a *Adapter) Start(context.Context) error            { return nil }
func (a *Adapter) Stop(ctx context.Context) error         { return a.Close(ctx) }
func (a *Adapter) Name() string                           { return "mcp" }
func (a *Adapter) Open(context.Context, vmm.Config) error { return nil }
func (a *Adapter) Close(context.Context) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.vms = map[string]vmm.VM{}
	return nil
}
func (a *Adapter) Health(context.Context) vmm.Health { return vmm.Health{OK: true} }
func (a *Adapter) SupportedTypes() []vmm.Type {
	return []vmm.Type{vmm.TypeMCP, vmm.TypeInstalled}
}
func supported(t vmm.Type) bool { return t == vmm.TypeMCP || t == vmm.TypeInstalled }
func (a *Adapter) BuildImage(ctx context.Context, s vmm.ImageSpec) (vmm.Image, error) {
	t := s.Type
	if !supported(t) {
		t = vmm.TypeMCP
	}
	return vmm.Image{ID: s.Name, Name: s.Name, Type: t, Ref: s.YML, CreatedAt: time.Now().UTC()}, nil
}
func (a *Adapter) DeleteImage(context.Context, string) error { return nil }
func (a *Adapter) CreateVM(ctx context.Context, s vmm.VMSpec) (vmm.VM, error) {
	if !supported(s.Type) {
		return vmm.VM{}, errs.InvalidArgument("MCP runtime only supports MCP and installed tools")
	}
	id, e := idutil.RandomHex(16)
	if e != nil {
		return vmm.VM{}, e
	}
	vm := vmm.VM{ID: string(s.Type) + "-" + id, Type: s.Type, Name: s.Name, ImageRef: s.ImageRef, Status: vmm.StatusRunning, CreatedAt: time.Now().UTC()}
	a.mu.Lock()
	a.vms[vm.ID] = vm
	a.mu.Unlock()
	return vm, nil
}
func (a *Adapter) EnsureAgent(ctx context.Context, id, spec string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if _, ok := a.vms[id]; !ok {
		t := vmm.TypeMCP
		if strings.HasPrefix(id, string(vmm.TypeInstalled)+"-") {
			t = vmm.TypeInstalled
		}
		a.vms[id] = vmm.VM{ID: id, Type: t, ImageRef: spec, Status: vmm.StatusRunning, CreatedAt: time.Now().UTC()}
	}
	return nil
}
func (a *Adapter) DeleteVM(ctx context.Context, id string) error {
	a.mu.Lock()
	delete(a.vms, id)
	a.mu.Unlock()
	return nil
}
func (a *Adapter) lifecycle(id string, status vmm.Status) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	vm, ok := a.vms[id]
	if !ok {
		return errs.NotFound("MCP VM")
	}
	vm.Status = status
	a.vms[id] = vm
	return nil
}
func (a *Adapter) StartVM(ctx context.Context, id string) error {
	return a.lifecycle(id, vmm.StatusRunning)
}
func (a *Adapter) StopVM(ctx context.Context, id string) error {
	return a.lifecycle(id, vmm.StatusStopped)
}
func (a *Adapter) PauseVM(ctx context.Context, id string) error {
	return a.lifecycle(id, vmm.StatusPaused)
}
func (a *Adapter) ResumeVM(ctx context.Context, id string) error { return a.StartVM(ctx, id) }
func (a *Adapter) ResizeVM(ctx context.Context, id string, res vmm.ResourceSpec) (vmm.VM, error) {
	return vmm.VM{}, errs.InvalidArgument("remote MCP connections and installed tools have no allocatable VM resources")
}
func (a *Adapter) GetVM(ctx context.Context, id string) (vmm.VM, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	vm, ok := a.vms[id]
	if !ok {
		return vm, errs.NotFound("MCP VM")
	}
	return vm, nil
}
func (a *Adapter) ListVMs(ctx context.Context, f vmm.Filter) ([]vmm.VM, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := []vmm.VM{}
	for _, v := range a.vms {
		out = append(out, v)
	}
	return out, nil
}
func (a *Adapter) Usage(ctx context.Context, id string) (vmm.Usage, error) {
	if _, e := a.GetVM(ctx, id); e != nil {
		return vmm.Usage{}, e
	}
	return vmm.Usage{VMID: id, MeasuredAt: time.Now().UTC()}, nil
}
func (a *Adapter) Send(ctx context.Context, id, body string) (string, error) {
	vm, e := a.GetVM(ctx, id)
	if e != nil {
		return "", e
	}
	if vm.Status != vmm.StatusRunning {
		return "", errs.New(errs.CodeUnavailable, "tool is stopped")
	}
	var out string
	e = bridge.Invoke(ctx, a.K, "tools", "InvokeMCP", []any{ctx, id, body}, &out)
	return out, e
}
