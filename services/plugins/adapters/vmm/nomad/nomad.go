// Package nomad implements the VMM port on HashiCorp Nomad (default provider).
// It maps the generic VM lifecycle onto Nomad jobs: docker/wasm drivers are
// selected per VM type, resources map to Nomad resource specs, and metering
// reads live allocation stats.
package nomad

import (
	"context"
	"fmt"
	"io"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/idutil"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/adapters/base"
	"github.com/aseman/aseman/plugins/adapters/cfg"
	"github.com/aseman/aseman/plugins/adapters/vmm/dockerexec"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"

	nomadapi "github.com/hashicorp/nomad/api"
)

const jobPrefix = "aseman-"

// DefaultToolRuntimeImage runs managed Elpian VM and QuickJS tool backends
// (deploy/tool-runtime). The tag is pinned because Nomad always pulls
// ":latest" images.
const DefaultToolRuntimeImage = "aseman/tool-runtime:v1"

// Adapter is the Nomad VMM plugin.
type Adapter struct {
	base.Base
	client     *nomadapi.Client
	region     string
	dc         string
	dockerHost string // docker daemon used for exec into running containers
	// toolRuntime is the image elpian and quickjs tool backends run in.
	toolRuntime string

	mu    sync.Mutex
	specs map[string]vmm.VMSpec // vm id (nomad job name) -> last spec (for pause/resume)
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "nomad",
			Category:    api.CategoryVMM,
			Version:     "1.0.0",
			Description: "HashiCorp Nomad VMM provider (default)",
			Provides:    []string{"vmm"},
			Log:         log,
		},
		specs: map[string]vmm.VMSpec{},
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)

	a.Log = deps.Logger
	c := cfg.VMM(deps.Config)
	if c.NomadURL == "" {
		return errs.InvalidArgument("nomad adapter requires config.nomad_url")
	}
	conf := nomadapi.DefaultConfig()
	conf.Address = c.NomadURL
	if c.Token != "" {
		conf.SecretID = c.Token
	}
	if c.Region != "" {
		conf.Region = c.Region
	}
	client, err := nomadapi.NewClient(conf)
	if err != nil {
		return errs.Wrap(errs.CodeVMM, err, "create nomad client")
	}
	a.client = client
	a.region = c.Region
	a.dc = c.Datacenter
	a.toolRuntime = c.Options["tool_runtime_image"]
	if a.toolRuntime == "" {
		a.toolRuntime = DefaultToolRuntimeImage
	}
	a.dockerHost = c.Options["docker_host"]
	if a.dockerHost == "" {
		a.dockerHost = dockerexec.DefaultHost
	}
	return nil
}

// Start implements api.Plugin.
func (a *Adapter) Start(ctx context.Context) error {
	if _, err := a.client.Status().Leader(); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "nomad leader check")
	}
	return nil
}

// Stop implements api.Plugin.
func (a *Adapter) Stop(ctx context.Context) error {
	for jobID := range a.specs {
		_, _, _ = a.client.Jobs().Deregister(jobID, false, nil)
	}
	a.specs = map[string]vmm.VMSpec{}
	return nil
}

// Name implements vmm.VMM.
func (a *Adapter) Name() string { return "nomad" }

// Open implements vmm.VMM.
func (a *Adapter) Open(ctx context.Context, c vmm.Config) error { return nil }

// Close implements vmm.VMM.
func (a *Adapter) Close(ctx context.Context) error { return nil }

// Health implements vmm.VMM.
func (a *Adapter) Health(ctx context.Context) vmm.Health {
	if a.client == nil {
		return vmm.Health{OK: false, Message: "nomad client not configured"}
	}
	if _, err := a.client.Status().Leader(); err != nil {
		return vmm.Health{OK: false, Message: err.Error()}
	}
	return vmm.Health{OK: true, Message: "nomad healthy"}
}

// SupportedTypes implements vmm.VMM. Docker, plus the two tool backend
// runtimes, which are docker tasks of the tool runtime image. The wasm driver
// is not advertised: it is not available on standard Nomad agents, so wasm
// apps keep running on the in-process wasm adapter.
func (a *Adapter) SupportedTypes() []vmm.Type {
	return []vmm.Type{vmm.TypeDocker, vmm.TypeElpian, vmm.TypeQuickJS}
}

// isToolRuntime reports whether a VM type runs in the tool runtime image.
func isToolRuntime(t vmm.Type) bool { return t == vmm.TypeElpian || t == vmm.TypeQuickJS }

// BuildImage implements vmm.VMM. For Nomad, the "image" is a driver artifact
// reference (docker registry image or wasm module) plus a stored definition.
func (a *Adapter) BuildImage(ctx context.Context, spec vmm.ImageSpec) (vmm.Image, error) {
	if spec.Name == "" {
		return vmm.Image{}, errs.InvalidArgument("image name required")
	}
	if spec.Type != vmm.TypeDocker && spec.Type != vmm.TypeWASM && !isToolRuntime(spec.Type) {
		return vmm.Image{}, errs.InvalidArgument("nomad provider supports docker, wasm, elpian and quickjs images")
	}
	id, err := idutil.RandomHex(8)
	if err != nil {
		return vmm.Image{}, err
	}
	ref := spec.Name
	if spec.Tag != "" {
		ref = spec.Name + ":" + spec.Tag
	}
	a.Log.Info("image registered", "name", spec.Name, "type", spec.Type)
	return vmm.Image{ID: id, Type: spec.Type, Name: spec.Name, Ref: ref, CreatedAt: time.Now().UTC()}, nil
}

// DeleteImage implements vmm.VMM.
func (a *Adapter) DeleteImage(ctx context.Context, ref string) error {
	return nil // Nomad has no global image registry; nothing to delete here.
}

// CreateVM implements vmm.VMM.
func (a *Adapter) CreateVM(ctx context.Context, spec vmm.VMSpec) (vmm.VM, error) {
	if a.client == nil {
		return vmm.VM{}, errs.New(errs.CodeUnavailable, "nomad not configured")
	}
	if spec.Type != vmm.TypeDocker && spec.Type != vmm.TypeWASM && !isToolRuntime(spec.Type) {
		return vmm.VM{}, errs.InvalidArgument("nomad supports docker, wasm, elpian and quickjs VMs")
	}
	job, err := a.buildJob(spec)
	if err != nil {
		return vmm.VM{}, err
	}
	if _, _, err := a.client.Jobs().Register(job, nil); err != nil {
		return vmm.VM{}, errs.Wrap(errs.CodeVMM, err, "register nomad job")
	}
	jobID := *job.ID
	a.mu.Lock()
	a.specs[jobID] = spec
	a.mu.Unlock()
	a.Log.Info("vm created", "vm_id", jobID, "job", jobID, "type", spec.Type)
	return vmm.VM{
		ID:        jobID,
		Name:      spec.Name,
		Type:      spec.Type,
		Status:    vmm.StatusPending,
		ImageRef:  spec.ImageRef,
		Address:   vmm.ServiceAddress(spec.Labels),
		Resources: spec.Resources,
		Labels:    spec.Labels,
		CreatedAt: time.Now().UTC(),
	}, nil
}

// buildJob converts a VMSpec into a Nomad job.
func (a *Adapter) buildJob(spec vmm.VMSpec) (*nomadapi.Job, error) {
	jobName := jobPrefix + spec.Name + "-" + mustToken()
	if id := spec.Labels[vmm.LabelServiceID]; id != "" {
		jobName = jobPrefix + id
	}
	job := nomadapi.NewServiceJob(jobName, "aseman", a.region, 1)
	dc := []string{"dc1"}
	if a.dc != "" {
		dc = []string{a.dc}
	}
	job.Datacenters = dc
	job.Meta = spec.Labels

	image, env := spec.ImageRef, spec.Environment
	if isToolRuntime(spec.Type) {
		// An Elpian VM or QuickJS backend is a program, not an image: the
		// runtime image hosts it and learns which engine runs it from its
		// environment (the program itself it fetches from the node).
		image = a.toolRuntime
		env = map[string]string{}
		for k, v := range spec.Environment {
			env[k] = v
		}
		env["ASEMAN_TOOL_ENGINE"] = string(spec.Type)
	}
	task := &nomadapi.Task{
		Name:   "main",
		Driver: "docker",
		Config: map[string]any{"image": image, "force_pull": false},
		Env:    env,
		Resources: &nomadapi.Resources{
			CPU:      intPtr(int(nomadCPU(spec.Resources.CPU))),
			MemoryMB: intPtr(int(nomadMem(spec.Resources.MemoryMB))),
			DiskMB:   intPtr(int(nomadDisk(spec.Resources.DiskMB))),
		},
	}
	if spec.Entrypoint != "" {
		task.Config["command"] = spec.Entrypoint
	}
	// Service VMs join a docker network (where other services reach them by
	// alias) and keep their state on a named volume.
	if spec.Resources.Network != "" {
		task.Config["network_mode"] = spec.Resources.Network
		if alias := spec.Labels[vmm.LabelNetworkAlias]; alias != "" {
			task.Config["network_aliases"] = []string{alias}
		}
	}
	if volume := spec.Labels[vmm.LabelVolume]; volume != "" {
		if name, target, ok := strings.Cut(volume, ":"); ok && name != "" && target != "" {
			task.Config["mount"] = []map[string]any{{"type": "volume", "source": name, "target": target, "readonly": false}}
		}
	}
	if len(spec.Args) > 0 {
		task.Config["args"] = spec.Args
	}
	if spec.Type == vmm.TypeWASM {
		task.Driver = "wasm"
		task.Config = map[string]any{"image": spec.ImageRef, "args": spec.Args}
	}
	tg := &nomadapi.TaskGroup{
		Name:  stringPtr("tg"),
		Tasks: []*nomadapi.Task{task},
	}
	job.TaskGroups = []*nomadapi.TaskGroup{tg}
	return job, nil
}

// Send executes a shell command inside a running nomad docker allocation and
// returns its output. This backs the shared per-space sandbox exec.
func (a *Adapter) Send(ctx context.Context, vmID, command string) (string, error) {
	cid, err := a.allocContainer(ctx, vmID)
	if err != nil {
		return "", err
	}
	return dockerexec.New(a.dockerHost).Exec(ctx, cid, command)
}

// Attach implements vmm.Attacher: it starts an interactive process inside the
// VM's running nomad docker allocation and returns its stdio, so agent engines
// can run inside nomad-hosted sandboxes too.
func (a *Adapter) Attach(ctx context.Context, vmID string, spec vmm.ExecSpec, stderr io.Writer) (vmm.ExecStream, error) {
	cid, err := a.allocContainer(ctx, vmID)
	if err != nil {
		return nil, err
	}
	return dockerexec.New(a.dockerHost).Attach(ctx, cid, spec, stderr)
}

// allocContainer resolves the docker container backing the VM's running
// allocation.
func (a *Adapter) allocContainer(ctx context.Context, vmID string) (string, error) {
	jobID, err := a.jobIDFor(vmID)
	if err != nil {
		return "", err
	}
	allocs, _, err := a.client.Jobs().Allocations(jobID, true, nil)
	if err != nil {
		return "", errs.Wrap(errs.CodeVMM, err, "list allocations for "+jobID)
	}
	if len(allocs) == 0 {
		return "", errs.New(errs.CodeUnavailable, "no allocation running for "+vmID)
	}
	// Prefer the running allocation; older/stopped allocations may exist.
	allocID := allocs[0].ID
	for _, alloc := range allocs {
		if alloc.ClientStatus == "running" {
			allocID = alloc.ID
			break
		}
	}
	docker := dockerexec.New(a.dockerHost)
	// The docker container for a freshly started allocation may take a moment
	// to appear (image pull / container create). Poll for it.
	var cid string
	var lastErr error
	for attempt := 0; attempt < 20; attempt++ {
		cid, lastErr = docker.FindContainerByLabel(ctx, "com.hashicorp.nomad.alloc_id="+allocID)
		if lastErr == nil {
			return cid, nil
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
	return "", lastErr
}

func mustToken() string {
	s, err := idutil.RandomString(6)
	if err != nil {
		return "x"
	}
	return s
}

// nomadCPU converts vCPU (1.0 = one vCPU) into Nomad MHz, enforcing the
// driver's 1 MHz minimum.
func nomadCPU(cpu float64) float64 {
	if cpu <= 0 {
		return 100
	}
	return cpu * 100
}

// nomadMem enforces Nomad's minimum MemoryMB of 10.
func nomadMem(mem int64) int64 {
	if mem < 10 {
		return 256
	}
	return mem
}

func nomadDisk(disk int64) int64 {
	if disk < 10 {
		return 512
	}
	return disk
}

// DeleteVM implements vmm.VMM.
func (a *Adapter) DeleteVM(ctx context.Context, id string) error {
	jobID, err := a.jobIDFor(id)
	if err != nil {
		return err
	}
	if _, _, err := a.client.Jobs().Deregister(jobID, true, nil); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "deregister job "+jobID)
	}
	a.mu.Lock()
	delete(a.specs, jobID)
	a.mu.Unlock()
	return nil
}

// StartVM implements vmm.VMM.
func (a *Adapter) StartVM(ctx context.Context, id string) error {
	jobID, err := a.jobIDFor(id)
	if err != nil {
		return err
	}
	job, _, err := a.client.Jobs().Info(jobID, nil)
	if err != nil {
		return errs.Wrap(errs.CodeVMM, err, "info job "+jobID)
	}
	job.Stop = boolPtr(false)
	if _, _, err := a.client.Jobs().Register(job, nil); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "start job "+jobID)
	}
	return nil
}

// StopVM implements vmm.VMM.
func (a *Adapter) StopVM(ctx context.Context, id string) error {
	jobID, err := a.jobIDFor(id)
	if err != nil {
		return err
	}
	if _, _, err := a.client.Jobs().Deregister(jobID, false, nil); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "stop job "+jobID)
	}
	return nil
}

// PauseVM implements vmm.VMM (scale to zero, spec retained for resume).
func (a *Adapter) PauseVM(ctx context.Context, id string) error {
	jobID, err := a.jobIDFor(id)
	if err != nil {
		return err
	}
	if _, _, err := a.client.Jobs().Deregister(jobID, false, nil); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "pause job "+jobID)
	}
	return nil
}

// ResumeVM implements vmm.VMM (re-register the retained spec).
func (a *Adapter) ResumeVM(ctx context.Context, id string) error {
	a.mu.Lock()
	spec, ok := a.specs[id]
	a.mu.Unlock()
	if !ok {
		return errs.NotFound("vm " + id)
	}
	job, err := a.buildJob(spec)
	if err != nil {
		return err
	}
	if _, _, err := a.client.Jobs().Register(job, nil); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "resume job "+id)
	}
	return nil
}

// ResizeVM implements vmm.VMM: update the job's resource limits live.
func (a *Adapter) ResizeVM(ctx context.Context, id string, res vmm.ResourceSpec) (vmm.VM, error) {
	jobID, err := a.jobIDFor(id)
	if err != nil {
		return vmm.VM{}, err
	}
	job, _, err := a.client.Jobs().Info(jobID, nil)
	if err != nil {
		return vmm.VM{}, errs.Wrap(errs.CodeVMM, err, "info job "+jobID)
	}
	for _, tg := range job.TaskGroups {
		for _, task := range tg.Tasks {
			task.Resources.CPU = intPtr(int(nomadCPU(res.CPU)))
			task.Resources.MemoryMB = intPtr(int(nomadMem(res.MemoryMB)))
			task.Resources.DiskMB = intPtr(int(nomadDisk(res.DiskMB)))
		}
	}
	if _, _, err := a.client.Jobs().Register(job, nil); err != nil {
		return vmm.VM{}, errs.Wrap(errs.CodeVMM, err, "resize job "+jobID)
	}
	// Persist the new spec for pause/resume consistency.
	a.mu.Lock()
	if spec, ok := a.specs[jobID]; ok {
		spec.Resources = res
		a.specs[jobID] = spec
	}
	a.mu.Unlock()
	a.Log.Info("vm resized", "vm_id", id, "cpu", res.CPU, "memory_mb", res.MemoryMB)
	return a.GetVM(ctx, id)
}

// GetVM implements vmm.VMM.
func (a *Adapter) GetVM(ctx context.Context, id string) (vmm.VM, error) {
	jobID, err := a.jobIDFor(id)
	if err != nil {
		return vmm.VM{}, err
	}
	job, _, err := a.client.Jobs().Info(jobID, nil)
	if err != nil {
		return vmm.VM{}, errs.Wrap(errs.CodeVMM, err, "info job "+jobID)
	}
	status := vmm.StatusPending
	if job.Status != nil {
		status = vmm.StatusFromNomad(*job.Status)
	}
	vm := vmm.VM{
		ID:        id,
		Name:      strings.TrimPrefix(id, jobPrefix),
		Status:    status,
		CreatedAt: time.Now().UTC(),
	}
	if job.Meta != nil {
		vm.Labels = job.Meta
		vm.Address = vmm.ServiceAddress(job.Meta)
	}
	return vm, nil
}

// ListVMs implements vmm.VMM.
func (a *Adapter) ListVMs(ctx context.Context, f vmm.Filter) ([]vmm.VM, error) {
	jobs, _, err := a.client.Jobs().List(nil)
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "list jobs")
	}
	var out []vmm.VM
	for _, j := range jobs {
		if !strings.HasPrefix(j.ID, jobPrefix) {
			continue
		}
		vm := vmm.VM{ID: j.ID, Name: strings.TrimPrefix(j.ID, jobPrefix), Status: vmm.StatusFromNomad(j.Status)}
		if f.Status != "" && vm.Status != f.Status {
			continue
		}
		out = append(out, vm)
	}
	return out, nil
}

// Usage implements vmm.VMM (live metering from allocation stats).
func (a *Adapter) Usage(ctx context.Context, id string) (vmm.Usage, error) {
	jobID, err := a.jobIDFor(id)
	if err != nil {
		return vmm.Usage{}, err
	}
	allocs, _, err := a.client.Jobs().Allocations(jobID, true, nil)
	if err != nil {
		return vmm.Usage{}, errs.Wrap(errs.CodeVMM, err, "list allocations")
	}
	if len(allocs) == 0 {
		return vmm.Usage{VMID: id, MeasuredAt: time.Now().UTC()}, nil
	}
	alloc := allocs[0]
	stats, err := a.client.Allocations().Stats(&nomadapi.Allocation{ID: alloc.ID}, nil)
	if err != nil {
		return vmm.Usage{}, errs.Wrap(errs.CodeVMM, err, "alloc stats")
	}
	u := vmm.Usage{
		VMID:         id,
		CPUUsed:      stats.ResourceUsage.CpuStats.Percent,
		MemoryUsedMB: int64(stats.ResourceUsage.MemoryStats.RSS) / (1024 * 1024),
		MeasuredAt:   time.Now().UTC(),
	}
	if t := startedAt(alloc); !t.IsZero() {
		u.UptimeSeconds = int64(time.Since(t).Seconds())
	}
	return u, nil
}

func startedAt(alloc *nomadapi.AllocationListStub) time.Time {
	for _, ts := range alloc.TaskStates {
		if !ts.StartedAt.IsZero() {
			return ts.StartedAt
		}
	}
	return time.Time{}
}

func (a *Adapter) jobIDFor(id string) (string, error) {
	if id == "" {
		return "", errs.NotFound("vm " + id)
	}
	// The vm id is the nomad job name, so it resolves across restarts without
	// any in-memory mapping.
	if _, _, err := a.client.Jobs().Info(id, nil); err != nil {
		return "", errs.Wrap(errs.CodeVMM, err, "info job "+id)
	}
	return id, nil
}

func intPtr(i int) *int          { return &i }
func stringPtr(s string) *string { return &s }
func boolPtr(b bool) *bool       { return &b }

// Explain (vmm.FailureExplainer) says why a job is not running: the scheduler's
// placement failure (for example not enough free memory on the node) or the
// failing task's last events (for example an image that could not be pulled).
// Empty when nothing is known.
func (a *Adapter) Explain(ctx context.Context, id string) string {
	jobID, err := a.jobIDFor(id)
	if err != nil {
		return ""
	}
	var parts []string
	if evals, _, err := a.client.Jobs().Evaluations(jobID, nil); err == nil {
		for _, e := range evals {
			for group, m := range e.FailedTGAllocs {
				if m == nil {
					continue
				}
				var why []string
				for dim, n := range m.DimensionExhausted {
					why = append(why, fmt.Sprintf("%s exhausted on %d node(s)", dim, n))
				}
				for c, n := range m.ConstraintFiltered {
					why = append(why, fmt.Sprintf("constraint %q filtered %d node(s)", c, n))
				}
				if len(why) == 0 {
					why = append(why, fmt.Sprintf("%d node(s) evaluated, none fit", m.NodesEvaluated))
				}
				parts = append(parts, "nomad could not place "+group+": "+strings.Join(why, "; "))
			}
			if len(parts) > 0 {
				break // the newest evaluation that failed is enough
			}
		}
	}
	if allocs, _, err := a.client.Jobs().Allocations(jobID, true, nil); err == nil && len(allocs) > 0 {
		alloc := allocs[0]
		for _, x := range allocs {
			if x.CreateTime > alloc.CreateTime {
				alloc = x
			}
		}
		parts = append(parts, "allocation "+alloc.ClientStatus)
		for task, ts := range alloc.TaskStates {
			if ts == nil {
				continue
			}
			events := ts.Events
			if len(events) > 3 {
				events = events[len(events)-3:]
			}
			var msgs []string
			for _, ev := range events {
				if ev.DisplayMessage != "" {
					msgs = append(msgs, ev.DisplayMessage)
				}
			}
			if len(msgs) > 0 {
				parts = append(parts, fmt.Sprintf("task %s is %s: %s", task, ts.State, strings.Join(msgs, " | ")))
			}
		}
	}
	return strings.Join(parts, "; ")
}
