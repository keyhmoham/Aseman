package runtime

import (
	"context"
	"io"
	"time"

	"github.com/aseman/aseman/internal/plugins/lifetime"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

type guardedVMM struct {
	port vmm.VMM
	gate *lifetime.Gate
}

func (p *guardedVMM) Name() string {
	var zero0 string
	operationCtx, release, err := p.gate.Acquire(context.Background())
	if err != nil {
		return zero0
	}
	defer release()
	_ = operationCtx
	return p.port.Name()
}
func (p *guardedVMM) Open(ctx context.Context, cfg vmm.Config) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Open(ctx, cfg)
}
func (p *guardedVMM) Close(ctx context.Context) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Close(ctx)
}
func (p *guardedVMM) Health(ctx context.Context) vmm.Health {
	var zero0 vmm.Health
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0
	}
	defer release()
	ctx = operationCtx
	return p.port.Health(ctx)
}
func (p *guardedVMM) SupportedTypes() []vmm.Type {
	var zero0 []vmm.Type
	operationCtx, release, err := p.gate.Acquire(context.Background())
	if err != nil {
		return zero0
	}
	defer release()
	_ = operationCtx
	return p.port.SupportedTypes()
}
func (p *guardedVMM) BuildImage(ctx context.Context, spec vmm.ImageSpec) (vmm.Image, error) {
	var zero0 vmm.Image
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.BuildImage(ctx, spec)
}
func (p *guardedVMM) DeleteImage(ctx context.Context, ref string) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.DeleteImage(ctx, ref)
}
func (p *guardedVMM) CreateVM(ctx context.Context, spec vmm.VMSpec) (vmm.VM, error) {
	var zero0 vmm.VM
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.CreateVM(ctx, spec)
}
func (p *guardedVMM) DeleteVM(ctx context.Context, id string) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.DeleteVM(ctx, id)
}
func (p *guardedVMM) StartVM(ctx context.Context, id string) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.StartVM(ctx, id)
}
func (p *guardedVMM) StopVM(ctx context.Context, id string) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.StopVM(ctx, id)
}
func (p *guardedVMM) PauseVM(ctx context.Context, id string) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.PauseVM(ctx, id)
}
func (p *guardedVMM) ResumeVM(ctx context.Context, id string) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.ResumeVM(ctx, id)
}
func (p *guardedVMM) ResizeVM(ctx context.Context, id string, res vmm.ResourceSpec) (vmm.VM, error) {
	var zero0 vmm.VM
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.ResizeVM(ctx, id, res)
}
func (p *guardedVMM) GetVM(ctx context.Context, id string) (vmm.VM, error) {
	var zero0 vmm.VM
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.GetVM(ctx, id)
}
func (p *guardedVMM) ListVMs(ctx context.Context, f vmm.Filter) ([]vmm.VM, error) {
	var zero0 []vmm.VM
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.ListVMs(ctx, f)
}
func (p *guardedVMM) Usage(ctx context.Context, id string) (vmm.Usage, error) {
	var zero0 vmm.Usage
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.Usage(ctx, id)
}

func (p *guardedVMM) Send(ctx context.Context, id, message string) (string, error) {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return "", err
	}
	defer release()
	port, ok := p.port.(interface {
		Send(context.Context, string, string) (string, error)
	})
	if !ok {
		return "", errs.New(errs.CodeUnavailable, "adapter does not support sending")
	}
	return port.Send(ctx, id, message)
}
func (p *guardedVMM) CreateTunnel(ctx context.Context, id string, port int) (string, string, error) {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return "", "", err
	}
	defer release()
	adapter, ok := p.port.(interface {
		CreateTunnel(context.Context, string, int) (string, string, error)
	})
	if !ok {
		return "", "", errs.New(errs.CodeUnavailable, "adapter does not support tunnels")
	}
	return adapter.CreateTunnel(ctx, id, port)
}

func (p *guardedVMM) EnsureAgent(ctx context.Context, name, spec string) error {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	port, ok := p.port.(interface {
		EnsureAgent(context.Context, string, string) error
	})
	if !ok {
		return nil
	}
	return port.EnsureAgent(ctx, name, spec)
}

// Attach forwards vmm.Attacher. The stream outlives the call; only the attach
// handshake runs under the operation gate.
func (p *guardedVMM) Attach(ctx context.Context, id string, spec vmm.ExecSpec, stderr io.Writer) (vmm.ExecStream, error) {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer release()
	port, ok := p.port.(vmm.Attacher)
	if !ok {
		return nil, errs.New(errs.CodeUnavailable, "adapter does not support interactive attach")
	}
	return port.Attach(ctx, id, spec, stderr)
}

// Prompt, Observe and Reply forward vmm.AgentRuntime.
func (p *guardedVMM) Prompt(ctx context.Context, id string, turn vmm.AgentTurn) (string, error) {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return "", err
	}
	defer release()
	port, ok := p.port.(vmm.AgentRuntime)
	if !ok {
		return "", errs.New(errs.CodeUnavailable, "adapter is not an agent runtime")
	}
	return port.Prompt(ctx, id, turn)
}
func (p *guardedVMM) Observe(ctx context.Context, id string, turn vmm.AgentTurn) error {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	port, ok := p.port.(vmm.AgentRuntime)
	if !ok {
		return nil
	}
	return port.Observe(ctx, id, turn)
}
func (p *guardedVMM) Reply(ctx context.Context, id string, turn vmm.AgentTurn) (bool, string, error) {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return false, "", err
	}
	defer release()
	port, ok := p.port.(vmm.AgentRuntime)
	if !ok {
		return false, "", nil
	}
	return port.Reply(ctx, id, turn)
}
func (p *guardedVMM) Questions(ctx context.Context, id, spaceID string) ([]vmm.AgentQuestion, error) {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer release()
	port, ok := p.port.(vmm.QuestionLister)
	if !ok {
		return nil, nil
	}
	return port.Questions(ctx, id, spaceID)
}
func (p *guardedVMM) ForgetRoom(ctx context.Context, spaceID, roomID string) error {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	port, ok := p.port.(vmm.RoomForgetter)
	if !ok {
		return nil
	}
	return port.ForgetRoom(ctx, spaceID, roomID)
}

// PersonalChat forwards vmm.PersonalChatter (Aseman self-chat / Talk under a CLI engine).
func (p *guardedVMM) PersonalChat(ctx context.Context, chat vmm.PersonalChat) (string, error) {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return "", err
	}
	defer release()
	port, ok := p.port.(vmm.PersonalChatter)
	if !ok {
		return "", errs.New(errs.CodeUnavailable, "adapter cannot answer personal chats")
	}
	return port.PersonalChat(ctx, chat)
}

// EngineMemoryRead forwards vmm.EngineMemory (an engine's own memory).
func (p *guardedVMM) EngineMemoryRead(ctx context.Context, engine, spaceID, agentID string) (*vmm.EngineMemoryView, error) {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer release()
	port, ok := p.port.(vmm.EngineMemory)
	if !ok {
		return nil, errs.New(errs.CodeUnavailable, "adapter keeps no engine memory")
	}
	return port.EngineMemoryRead(ctx, engine, spaceID, agentID)
}

// EngineMemoryWrite forwards vmm.EngineMemory.
func (p *guardedVMM) EngineMemoryWrite(ctx context.Context, engine, spaceID, agentID, content string) error {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	port, ok := p.port.(vmm.EngineMemory)
	if !ok {
		return errs.New(errs.CodeUnavailable, "adapter keeps no engine memory")
	}
	return port.EngineMemoryWrite(ctx, engine, spaceID, agentID, content)
}

func Guard(port vmm.VMM, gate *lifetime.Gate) vmm.VMM {
	return &guardedVMM{port: port, gate: gate}
}

func (p *guardedVMM) ReadWorkspace(ctx context.Context, id, path string) ([]byte, error) {
	ctx, release, e := p.gate.Acquire(ctx)
	if e != nil {
		return nil, e
	}
	defer release()
	reader, ok := p.port.(vmm.WorkspaceReader)
	if !ok {
		return nil, errs.New(errs.CodeUnavailable, "provider cannot read sleeping workspace files")
	}
	return reader.ReadWorkspace(ctx, id, path)
}
func (p *guardedVMM) ListWorkspace(ctx context.Context, id, path string) ([]vmm.WorkspaceEntry, error) {
	ctx, release, e := p.gate.Acquire(ctx)
	if e != nil {
		return nil, e
	}
	defer release()
	reader, ok := p.port.(vmm.WorkspaceReader)
	if !ok {
		return nil, errs.New(errs.CodeUnavailable, "provider cannot list sleeping workspace files")
	}
	return reader.ListWorkspace(ctx, id, path)
}

func (p *guardedVMM) WriteWorkspace(ctx context.Context, id, path string, data []byte) error {
	ctx, release, e := p.gate.Acquire(ctx)
	if e != nil {
		return e
	}
	defer release()
	writer, ok := p.port.(vmm.WorkspaceWriter)
	if !ok {
		return vmm.ErrUnsupported
	}
	return writer.WriteWorkspace(ctx, id, path, data)
}
func (p *guardedVMM) DeleteWorkspace(ctx context.Context, id, path string) error {
	ctx, release, e := p.gate.Acquire(ctx)
	if e != nil {
		return e
	}
	defer release()
	writer, ok := p.port.(vmm.WorkspaceWriter)
	if !ok {
		return vmm.ErrUnsupported
	}
	return writer.DeleteWorkspace(ctx, id, path)
}

func (p *guardedVMM) MakeWorkspaceDir(ctx context.Context, id, path string) error {
	ctx, release, e := p.gate.Acquire(ctx)
	if e != nil {
		return e
	}
	defer release()
	organizer, ok := p.port.(vmm.WorkspaceOrganizer)
	if !ok {
		return vmm.ErrUnsupported
	}
	return organizer.MakeWorkspaceDir(ctx, id, path)
}
func (p *guardedVMM) MoveWorkspace(ctx context.Context, id, from, to string) error {
	ctx, release, e := p.gate.Acquire(ctx)
	if e != nil {
		return e
	}
	defer release()
	organizer, ok := p.port.(vmm.WorkspaceOrganizer)
	if !ok {
		return vmm.ErrUnsupported
	}
	return organizer.MoveWorkspace(ctx, id, from, to)
}

func (p *guardedVMM) CostReport(ctx context.Context, since, until time.Time) ([]vmm.ProviderCost, error) {
	reporter, ok := p.port.(vmm.CostReporter)
	if !ok {
		return nil, errs.New(errs.CodeUnavailable, "provider cannot report its costs")
	}
	return reporter.CostReport(ctx, since, until)
}

// Sandboxes and Volumes (vmm.Inventory) pass through to a provider that can
// list what it holds; every adapter is reached through this guard, so an
// optional capability the guard does not forward does not exist to callers.
func (p *guardedVMM) Sandboxes(ctx context.Context) ([]vmm.ProviderSandbox, error) {
	ctx, release, e := p.gate.Acquire(ctx)
	if e != nil {
		return nil, e
	}
	defer release()
	inv, ok := p.port.(vmm.Inventory)
	if !ok {
		return nil, errs.New(errs.CodeUnavailable, "this node's sandbox provider cannot list what it holds")
	}
	return inv.Sandboxes(ctx)
}

func (p *guardedVMM) Volumes(ctx context.Context) ([]vmm.ProviderVolume, error) {
	ctx, release, e := p.gate.Acquire(ctx)
	if e != nil {
		return nil, e
	}
	defer release()
	inv, ok := p.port.(vmm.Inventory)
	if !ok {
		return nil, errs.New(errs.CodeUnavailable, "this node's sandbox provider cannot list what it holds")
	}
	return inv.Volumes(ctx)
}

// DeleteWorkspaceVolume (vmm.VolumeDeleter) passes through to a provider that
// keeps project storage; one that keeps none has nothing to delete.
func (p *guardedVMM) DeleteWorkspaceVolume(ctx context.Context, machine string) error {
	ctx, release, e := p.gate.Acquire(ctx)
	if e != nil {
		return e
	}
	defer release()
	d, ok := p.port.(vmm.VolumeDeleter)
	if !ok {
		return nil
	}
	return d.DeleteWorkspaceVolume(ctx, machine)
}

func (p *guardedVMM) Explain(ctx context.Context, id string) string {
	if e, ok := p.port.(vmm.FailureExplainer); ok {
		return e.Explain(ctx, id)
	}
	return ""
}

func (p *guardedVMM) EnsureSidecar(ctx context.Context, id, name, image string, env map[string]string) error {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	adapter, ok := p.port.(vmm.SidecarRunner)
	if !ok {
		return errs.New(errs.CodeUnavailable, "adapter does not support sidecars")
	}
	return adapter.EnsureSidecar(ctx, id, name, image, env)
}

func (p *guardedVMM) RemoveSidecar(ctx context.Context, id, name string) error {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	adapter, ok := p.port.(vmm.SidecarRunner)
	if !ok {
		return errs.New(errs.CodeUnavailable, "adapter does not support sidecars")
	}
	return adapter.RemoveSidecar(ctx, id, name)
}
