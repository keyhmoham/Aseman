// Package docker implements the VMM port directly against the Docker Engine
// API over its unix socket (or a TCP endpoint). It is a standalone provider;
// when running on Nomad the nomad adapter's docker driver is preferred instead.
package docker

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
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
)

// Adapter is the Docker Engine VMM plugin.
type Adapter struct {
	base.Base
	client  *http.Client
	baseURL string
	// network, when set, attaches every container to this docker network (the
	// node must be on it too) so proxied sandbox ports are reachable from a
	// containerized daemon. Empty means the default bridge network.
	network string
	mu      sync.Mutex
	vms     map[string]string     // vm id -> container id
	specs   map[string]vmm.VMSpec // vm id -> creation spec (for recreate)
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "docker",
			Category:    api.CategoryVMM,
			Version:     "1.0.0",
			Description: "Docker Engine VMM provider (standalone)",
			Provides:    []string{"vmm"},
			Log:         log,
		},
		vms:   map[string]string{},
		specs: map[string]vmm.VMSpec{},
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)

	a.Log = deps.Logger
	c := cfg.VMM(deps.Config)
	a.baseURL = c.Options["host"]
	if a.baseURL == "" {
		a.baseURL = "http://localhost"
	}
	a.network = c.Options["network"]
	return nil
}

// Start implements api.Plugin.
func (a *Adapter) Start(ctx context.Context) error {
	a.client = a.newClient()
	if err := a.ping(ctx); err != nil {
		return err
	}
	return nil
}

// Stop releases adapter connections. VMs belong to persisted bot records and
// outlive the daemon; deleting them here loses workspace files on a restart.
// Explicit StopVM/DeleteVM operations own the container lifecycle.
func (a *Adapter) Stop(context.Context) error {
	if a.client != nil {
		a.client.CloseIdleConnections()
	}
	return nil
}

func (a *Adapter) newClient() *http.Client {
	if strings.HasPrefix(a.baseURL, "unix://") {
		sock := strings.TrimPrefix(a.baseURL, "unix://")
		return &http.Client{
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					return (&net.Dialer{}).DialContext(ctx, "unix", sock)
				},
			},
		}
	}
	return &http.Client{Timeout: 60 * time.Second}
}

func (a *Adapter) url(path string) string {
	if strings.HasPrefix(a.baseURL, "unix://") {
		return "http://docker" + path
	}
	return a.baseURL + path
}

func (a *Adapter) ping(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.url("/_ping"), nil)
	if err != nil {
		return err
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return errs.Wrap(errs.CodeVMM, err, "docker ping")
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusOK {
		return errs.New(errs.CodeVMM, "docker ping status "+resp.Status)
	}
	return nil
}

// ensureImage verifies the image exists locally, pulling it from the registry
// when it is missing (Docker's create does not auto-pull).
func (a *Adapter) ensureImage(ctx context.Context, ref string) error {
	if ref == "" {
		return errs.InvalidArgument("docker image required")
	}
	if _, err := a.do(ctx, http.MethodGet, "/images/"+ref+"/json", nil); err == nil {
		return nil
	}
	a.Log.Info("pulling docker image", "image", ref)
	if _, err := a.do(ctx, http.MethodPost, "/images/create?fromImage="+url.QueryEscape(ref), nil); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "pull image "+ref)
	}
	return nil
}

func (a *Adapter) do(ctx context.Context, method, path string, body any) ([]byte, error) {
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, a.url(path), r)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "docker "+method+" "+path)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		return nil, errs.New(errs.CodeVMM, fmt.Sprintf("docker %s %s: %s", method, path, string(b)))
	}
	return b, nil
}

// Name implements vmm.VMM.
func (a *Adapter) Name() string { return "docker" }

// Open implements vmm.VMM.
func (a *Adapter) Open(ctx context.Context, c vmm.Config) error { return nil }

// Close implements vmm.VMM.
func (a *Adapter) Close(ctx context.Context) error { return nil }

// Health implements vmm.VMM.
func (a *Adapter) Health(ctx context.Context) vmm.Health {
	if a.client == nil {
		return vmm.Health{OK: false, Message: "docker client not started"}
	}
	if err := a.ping(ctx); err != nil {
		return vmm.Health{OK: false, Message: err.Error()}
	}
	return vmm.Health{OK: true, Message: "docker healthy"}
}

// SupportedTypes implements vmm.VMM. The "container" type is the per-space
// sandbox backend (standalone docker containers); "docker" keeps standalone
// docker available for generic docker VMs when Nomad is not the active provider.
func (a *Adapter) SupportedTypes() []vmm.Type {
	return []vmm.Type{vmm.TypeDocker, vmm.TypeContainer}
}

// BuildImage implements vmm.VMM.
func (a *Adapter) BuildImage(ctx context.Context, spec vmm.ImageSpec) (vmm.Image, error) {
	if spec.Type != vmm.TypeDocker && spec.Type != vmm.TypeContainer {
		return vmm.Image{}, errs.InvalidArgument("docker provider only builds docker images")
	}
	ref := spec.Name
	if spec.Tag != "" {
		ref = spec.Name + ":" + spec.Tag
	}
	_, err := a.do(ctx, http.MethodPost, "/images/create?fromImage="+spec.Name+"&tag="+spec.Tag, nil)
	if err != nil {
		return vmm.Image{}, errs.Wrap(errs.CodeVMM, err, "pull image "+ref)
	}
	return vmm.Image{ID: ref, Type: vmm.TypeDocker, Name: spec.Name, Ref: ref, CreatedAt: time.Now().UTC()}, nil
}

// DeleteImage implements vmm.VMM.
func (a *Adapter) DeleteImage(ctx context.Context, ref string) error {
	_, err := a.do(ctx, http.MethodDelete, "/images/"+ref+"?force=true", nil)
	if err != nil {
		return errs.Wrap(errs.CodeVMM, err, "remove image "+ref)
	}
	return nil
}

// CreateVM implements vmm.VMM.
func (a *Adapter) CreateVM(ctx context.Context, spec vmm.VMSpec) (vmm.VM, error) {
	if spec.Type != vmm.TypeDocker && spec.Type != vmm.TypeContainer {
		return vmm.VM{}, errs.InvalidArgument("docker provider only runs docker VMs")
	}
	return a.createContainer(ctx, spec)
}

// createContainer provisions a container for the spec, records the mapping and
// returns the VM descriptor. The container is left stopped so StartVM controls
// lifecycle explicitly (a stopped container is never auto-removed).
func (a *Adapter) createContainer(ctx context.Context, spec vmm.VMSpec) (vmm.VM, error) {
	if err := a.ensureImage(ctx, spec.ImageRef); err != nil {
		return vmm.VM{}, err
	}
	vmID, err := idutil.RandomHex(8)
	if err != nil {
		return vmm.VM{}, err
	}
	hostConfig := map[string]any{
		"Memory":     spec.Resources.MemoryMB * 1024 * 1024,
		"MemorySwap": spec.Resources.MemoryMB * 2 * 1024 * 1024,
		"NanoCpus":   int64(spec.Resources.CPU * 1e9),
		"AutoRemove": false,
	}
	if owner := spec.Labels["aseman.bot_id"]; owner != "" {
		hostConfig["Mounts"] = []map[string]any{{"Type": "volume", "Source": "aseman-workspace-" + owner, "Target": "/workspace"}, {"Type": "volume", "Source": "aseman-agent-state-" + owner, "Target": "/var/lib/grok"}}
	}
	if a.network != "" {
		if err := a.ensureNetwork(ctx, a.network); err != nil {
			return vmm.VM{}, err
		}
		hostConfig["NetworkMode"] = a.network
	}
	labels := map[string]string{
		"aseman.vm":    spec.Name,
		"aseman.image": spec.ImageRef,
		"aseman.type":  string(spec.Type),
		"aseman.vmid":  vmID, // enables restart rehydration by label
	}
	create := map[string]any{
		"Image":      spec.ImageRef,
		"Cmd":        spec.Args,
		"Env":        envSlice(spec.Environment),
		"Labels":     labels,
		"HostConfig": hostConfig,
	}
	// A service VM (a managed tool backend) answers by name on its network.
	if alias := spec.Labels[vmm.LabelNetworkAlias]; alias != "" {
		network := spec.Resources.Network
		if network == "" {
			network = a.network
		}
		if network != "" {
			if err := a.ensureNetwork(ctx, network); err != nil {
				return vmm.VM{}, err
			}
			hostConfig["NetworkMode"] = network
			create["NetworkingConfig"] = map[string]any{"EndpointsConfig": map[string]any{network: map[string]any{"Aliases": []string{alias}}}}
		}
		labels[vmm.LabelNetworkAlias] = alias
		labels[vmm.LabelServicePort] = spec.Labels[vmm.LabelServicePort]
	}
	b, err := a.do(ctx, http.MethodPost, "/containers/create?name=aseman-"+spec.Name, create)
	if err != nil {
		return vmm.VM{}, errs.Wrap(errs.CodeVMM, err, "create container")
	}
	var out struct {
		ID string `json:"Id"`
	}
	if err := json.Unmarshal(b, &out); err != nil {
		return vmm.VM{}, errs.Wrap(errs.CodeVMM, err, "decode container id")
	}
	a.mu.Lock()
	a.vms[vmID] = out.ID
	a.specs[vmID] = spec
	a.mu.Unlock()
	return vmm.VM{ID: vmID, Name: spec.Name, Type: spec.Type, Status: vmm.StatusCreating,
		ImageRef: spec.ImageRef, Address: vmm.ServiceAddress(labels), Resources: spec.Resources, CreatedAt: time.Now().UTC()}, nil
}

// ensureNetwork creates a user-defined docker network when it does not exist,
// so sandbox containers can join the node's network (idempotent).
func (a *Adapter) ensureNetwork(ctx context.Context, name string) error {
	if _, err := a.do(ctx, http.MethodGet, "/networks/"+url.PathEscape(name), nil); err == nil {
		return nil
	}
	if _, err := a.do(ctx, http.MethodPost, "/networks/create", map[string]any{"Name": name}); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "create docker network "+name)
	}
	return nil
}

// DeleteVM implements vmm.VMM.
func (a *Adapter) DeleteVM(ctx context.Context, id string) error {
	cid, err := a.containerID(id)
	if err != nil {
		return err
	}
	if err := a.remove(ctx, cid, true); err != nil {
		return err
	}
	a.mu.Lock()
	delete(a.vms, id)
	a.mu.Unlock()
	return nil
}

func (a *Adapter) remove(ctx context.Context, cid string, force bool) error {
	_, err := a.do(ctx, http.MethodDelete, "/containers/"+cid+"?force=true&v=true", nil)
	if err != nil {
		return errs.Wrap(errs.CodeVMM, err, "remove container "+cid)
	}
	return nil
}

// StartVM implements vmm.VMM.
func (a *Adapter) StartVM(ctx context.Context, id string) error {
	cid, err := a.containerID(id)
	if err != nil {
		return err
	}
	if fresh, err := a.refreshImage(ctx, id, cid); err != nil {
		a.Log.Warn("container kept on its old image", "vm", id, "error", err)
	} else {
		cid = fresh
	}
	if _, err := a.do(ctx, http.MethodPost, "/containers/"+cid+"/start", nil); err != nil {
		// The container may have been removed (e.g. a manual prune). Recreate
		// it from the stored spec and start it so the VM lifecycle survives.
		a.mu.Lock()
		spec, hasSpec := a.specs[id]
		a.mu.Unlock()
		if hasSpec {
			created, cerr := a.createContainer(ctx, spec)
			if cerr == nil {
				return a.StartVM(ctx, created.ID)
			}
		}
		return errs.Wrap(errs.CodeVMM, err, "start container "+cid)
	}
	return nil
}

// refreshImage recreates a stopped container whose image tag now names a
// newer image (the sandbox image was rebuilt or pulled since), so a machine
// that sleeps and wakes picks up the current tools instead of keeping the
// image it was first created from forever. The new container has the same
// name, labels (its aseman.vmid, so the VM id stays), settings and mounts:
// the named /workspace and agent state volumes carry the work over; what was
// installed outside them comes from the new image. A running container, an
// up-to-date one, or ASEMAN_DOCKER_REFRESH_IMAGES=0 leaves it as it is.
// Returns the container id to start.
func (a *Adapter) refreshImage(ctx context.Context, vmID, cid string) (string, error) {
	if os.Getenv("ASEMAN_DOCKER_REFRESH_IMAGES") == "0" {
		return cid, nil
	}
	raw, err := a.do(ctx, http.MethodGet, "/containers/"+cid+"/json", nil)
	if err != nil {
		return cid, err
	}
	var c struct {
		Name       string         `json:"Name"`
		Image      string         `json:"Image"` // the image id it was created from
		Config     map[string]any `json:"Config"`
		HostConfig map[string]any `json:"HostConfig"`
		State      struct {
			Running bool `json:"Running"`
			Paused  bool `json:"Paused"`
		} `json:"State"`
	}
	if err := json.Unmarshal(raw, &c); err != nil {
		return cid, err
	}
	ref, _ := c.Config["Image"].(string)
	if c.State.Running || c.State.Paused || ref == "" || strings.HasPrefix(ref, "sha256:") {
		return cid, nil
	}
	img, err := a.do(ctx, http.MethodGet, "/images/"+ref+"/json", nil)
	if err != nil {
		return cid, nil // the tag is gone: keep what the container has
	}
	var current struct {
		ID string `json:"Id"`
	}
	if json.Unmarshal(img, &current) != nil || current.ID == "" || current.ID == c.Image {
		return cid, nil
	}
	create := map[string]any{}
	for k, v := range c.Config {
		// The host name was the old container's id.
		if k != "Hostname" {
			create[k] = v
		}
	}
	create["HostConfig"] = c.HostConfig
	labels, _ := c.Config["Labels"].(map[string]any)
	if alias, _ := labels[vmm.LabelNetworkAlias].(string); alias != "" {
		if network, _ := c.HostConfig["NetworkMode"].(string); network != "" {
			create["NetworkingConfig"] = map[string]any{"EndpointsConfig": map[string]any{network: map[string]any{"Aliases": []string{alias}}}}
		}
	}
	// The old container steps aside until the new one exists, so a failure
	// leaves the machine as it was.
	name := strings.TrimPrefix(c.Name, "/")
	if _, err := a.do(ctx, http.MethodPost, "/containers/"+cid+"/rename?name="+url.QueryEscape(name+"-old"), nil); err != nil {
		return cid, err
	}
	b, err := a.do(ctx, http.MethodPost, "/containers/create?name="+url.QueryEscape(name), create)
	var out struct {
		ID string `json:"Id"`
	}
	if err == nil && (json.Unmarshal(b, &out) != nil || out.ID == "") {
		err = errs.New(errs.CodeVMM, "no container id")
	}
	if err != nil {
		_, _ = a.do(ctx, http.MethodPost, "/containers/"+cid+"/rename?name="+url.QueryEscape(name), nil)
		return cid, errs.Wrap(errs.CodeVMM, err, "recreate container on the current image")
	}
	// Its anonymous volumes go with it; named volumes (the workspace) stay.
	if _, err := a.do(ctx, http.MethodDelete, "/containers/"+cid+"?force=true", nil); err != nil {
		a.Log.Warn("old container left behind", "container", cid, "error", err)
	}
	a.mu.Lock()
	a.vms[vmID] = out.ID
	a.mu.Unlock()
	a.Log.Info("container recreated on its image's current version", "vm", vmID, "image", ref)
	return out.ID, nil
}

// StopVM implements vmm.VMM.
func (a *Adapter) StopVM(ctx context.Context, id string) error {
	cid, err := a.containerID(id)
	if err != nil {
		return err
	}
	if _, err := a.do(ctx, http.MethodPost, "/containers/"+cid+"/stop?t=10", nil); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "stop container "+cid)
	}
	return nil
}

// PauseVM implements vmm.VMM.
func (a *Adapter) PauseVM(ctx context.Context, id string) error {
	cid, err := a.containerID(id)
	if err != nil {
		return err
	}
	if _, err := a.do(ctx, http.MethodPost, "/containers/"+cid+"/pause", nil); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "pause container "+cid)
	}
	return nil
}

// ResumeVM implements vmm.VMM.
func (a *Adapter) ResumeVM(ctx context.Context, id string) error {
	cid, err := a.containerID(id)
	if err != nil {
		return err
	}
	if _, err := a.do(ctx, http.MethodPost, "/containers/"+cid+"/unpause", nil); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "unpause container "+cid)
	}
	return nil
}

// ResizeVM implements vmm.VMM via the Docker update endpoint.
func (a *Adapter) ResizeVM(ctx context.Context, id string, res vmm.ResourceSpec) (vmm.VM, error) {
	cid, err := a.containerID(id)
	if err != nil {
		return vmm.VM{}, err
	}
	_, err = a.do(ctx, http.MethodPost, "/containers/"+cid+"/update", map[string]any{
		"Memory":     res.MemoryMB * 1024 * 1024,
		"MemorySwap": res.MemoryMB * 2 * 1024 * 1024,
		"NanoCpus":   int64(res.CPU * 1e9),
	})
	if err != nil {
		return vmm.VM{}, errs.Wrap(errs.CodeVMM, err, "resize container "+cid)
	}
	return a.GetVM(ctx, id)
}

// GetVM implements vmm.VMM.
func (a *Adapter) GetVM(ctx context.Context, id string) (vmm.VM, error) {
	cid, err := a.containerID(id)
	if err != nil {
		return vmm.VM{}, err
	}
	b, err := a.do(ctx, http.MethodGet, "/containers/"+cid+"/json", nil)
	if err != nil {
		return vmm.VM{}, errs.Wrap(errs.CodeVMM, err, "inspect container "+cid)
	}
	var spec struct {
		State struct {
			Status     string `json:"Status"`
			StartedAt  string `json:"StartedAt"`
			FinishedAt string `json:"FinishedAt"`
		} `json:"State"`
		Config struct {
			Image  string            `json:"Image"`
			Cmd    []string          `json:"Cmd"`
			Labels map[string]string `json:"Labels"`
		} `json:"Config"`
	}
	if err := json.Unmarshal(b, &spec); err != nil {
		return vmm.VM{}, errs.Wrap(errs.CodeVMM, err, "decode inspect")
	}
	status := statusFromDocker(spec.State.Status)
	return vmm.VM{ID: id, Name: spec.Config.Labels["aseman.vm"], Type: vmm.Type(spec.Config.Labels["aseman.type"]),
		Status: status, ImageRef: spec.Config.Image, Address: vmm.ServiceAddress(spec.Config.Labels), CreatedAt: time.Now().UTC()}, nil
}

// ListVMs implements vmm.VMM.
func (a *Adapter) ListVMs(ctx context.Context, f vmm.Filter) ([]vmm.VM, error) {
	b, err := a.do(ctx, http.MethodGet, "/containers/json?all=true&filters="+jsonFilter("aseman.vm"), nil)
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "list containers")
	}
	var list []struct {
		ID     string            `json:"Id"`
		Names  []string          `json:"Names"`
		State  string            `json:"State"`
		Labels map[string]string `json:"Labels"`
	}
	if err := json.Unmarshal(b, &list); err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "decode containers")
	}
	var out []vmm.VM
	for _, c := range list {
		vm := vmm.VM{ID: c.ID, Name: c.Labels["aseman.vm"], Type: vmm.Type(c.Labels["aseman.type"]),
			Status: statusFromDocker(c.State)}
		if f.Status != "" && vm.Status != f.Status {
			continue
		}
		out = append(out, vm)
	}
	return out, nil
}

// Usage implements vmm.VMM (live stats).
func (a *Adapter) Usage(ctx context.Context, id string) (vmm.Usage, error) {
	cid, err := a.containerID(id)
	if err != nil {
		return vmm.Usage{}, err
	}
	b, err := a.do(ctx, http.MethodGet, "/containers/"+cid+"/stats?stream=false&one-shot=true", nil)
	if err != nil {
		return vmm.Usage{}, errs.Wrap(errs.CodeVMM, err, "stats container "+cid)
	}
	var s struct {
		CPUPerc struct {
			Total  float64  `json:"total_usage"`
			Prev   float64  `json:"prv_cpu_usage"`
			System float64  `json:"system_cpu_usage"`
			Percpu []uint64 `json:"percpu_usage"`
		} `json:"cpu_stats"`
		Memory struct {
			Usage uint64 `json:"usage"`
			Limit uint64 `json:"limit"`
		} `json:"memory_stats"`
	}
	if err := json.Unmarshal(b, &s); err != nil {
		return vmm.Usage{}, errs.Wrap(errs.CodeVMM, err, "decode stats")
	}
	cpuPct := 0.0
	if s.CPUPerc.System > 0 {
		cpuPct = float64(s.CPUPerc.Total-s.CPUPerc.Prev) / s.CPUPerc.System * float64(len(s.CPUPerc.Percpu)) * 100
		if cpuPct < 0 {
			cpuPct = 0
		}
	}
	return vmm.Usage{
		VMID:         id,
		CPUUsed:      cpuPct,
		MemoryUsedMB: int64(s.Memory.Usage / (1024 * 1024)),
		MeasuredAt:   time.Now().UTC(),
	}, nil
}

func (a *Adapter) containerID(vmID string) (string, error) {
	a.mu.Lock()
	cid, ok := a.vms[vmID]
	a.mu.Unlock()
	if ok {
		return cid, nil
	}
	// The daemon may have restarted and lost the in-memory vm->container map.
	// Rehydrate it from the container label recorded at creation time so
	// existing sandboxes survive node restarts without being recreated.
	found, err := a.findContainerByVM(vmID)
	if err != nil {
		return "", err
	}
	a.mu.Lock()
	a.vms[vmID] = found
	a.mu.Unlock()
	return found, nil
}

// findContainerByVM locates the container id of a VM via its aseman.vmid
// label (the mapping recorded at creation, stable across restarts).
func (a *Adapter) findContainerByVM(vmID string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	b, err := a.do(ctx, http.MethodGet,
		"/containers/json?all=true&filters="+url.QueryEscape(`{"label":["aseman.vmid=`+vmID+`"]}`), nil)
	if err != nil {
		return "", errs.Wrap(errs.CodeVMM, err, "find container by vm label")
	}
	var list []struct {
		ID string `json:"Id"`
	}
	if err := json.Unmarshal(b, &list); err != nil || len(list) == 0 {
		return "", errs.NotFound("vm " + vmID)
	}
	return list[0].ID, nil
}

func statusFromDocker(s string) vmm.Status {
	switch s {
	case "running":
		return vmm.StatusRunning
	case "paused":
		return vmm.StatusPaused
	case "created":
		return vmm.StatusCreating
	case "exited", "dead":
		return vmm.StatusStopped
	default:
		return vmm.StatusPending
	}
}

func envSlice(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k, v := range m {
		out = append(out, k+"="+v)
	}
	return out
}

func jsonFilter(label string) string {
	b, _ := json.Marshal(map[string][][]string{"label": {{label}}})
	return string(b)
}

// Send delivers a shell command into a running container and returns its
// combined output. This is the sandbox entry point: a shared per-space docker
// sandbox bot is asked through the spaces.ask action and its commands execute
// here via the Docker Engine exec API.
func (a *Adapter) Send(ctx context.Context, vmID, command string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	cid, err := a.containerID(vmID)
	if err != nil {
		return "", err
	}
	if command == "" {
		command = "/bin/sh"
	}
	// Bound every sandbox command so an exec stream can never block forever.
	// Long-running processes (dev servers, tunnels, watchers) would otherwise
	// hold the docker exec open indefinitely and hang the calling agent/workflow.
	// `timeout` sends SIGTERM then SIGKILL after a grace period; exit code 124
	// signals a timed-out command. Launch long-lived daemons with "&" instead.
	//
	// Default 5 minutes when the caller set no deadline. When a deadline is
	// present (e.g. appui_create's 12m build budget), honor the remaining time
	// instead of capping below it — min(300s, 12m) used to kill OpenCode builds.
	duration := 5 * time.Minute
	if deadline, ok := ctx.Deadline(); ok {
		remaining := time.Until(deadline) - 3*time.Second
		if remaining <= 0 {
			return "", errs.New(errs.CodeUnavailable, "insufficient remaining execution time to start a sandbox command")
		}
		duration = remaining
	}
	execCmd := []string{"timeout", "-k", "2s", fmt.Sprintf("%.3fs", duration.Seconds()), "/bin/sh", "-c", command}
	// 1. create the exec instance.
	create := map[string]any{
		"AttachStdout": true,
		"AttachStderr": true,
		"AttachStdin":  false,
		"Tty":          false,
		"Cmd":          execCmd,
	}
	cb, err := a.do(ctx, http.MethodPost, "/containers/"+cid+"/exec", create)
	if err != nil {
		return "", errs.Wrap(errs.CodeVMM, err, "create exec")
	}
	var exec struct {
		ID string `json:"Id"`
	}
	if err := json.Unmarshal(cb, &exec); err != nil || exec.ID == "" {
		return "", errs.New(errs.CodeVMM, "docker exec: bad create response")
	}
	// 2. start the exec and capture the multiplexed output stream.
	raw, err := a.execStream(ctx, "/exec/"+exec.ID+"/start", map[string]any{"Detach": false, "Tty": false})
	if err != nil {
		return demuxStream(raw), a.commandFailure(ctx, cid, err)
	}
	// 3. fetch the exit code.
	jb, err := a.do(ctx, http.MethodGet, "/exec/"+exec.ID+"/json", nil)
	text := demuxStream(raw)
	if text == "" {
		text = "(no output)"
	}
	if err != nil {
		return text, a.commandFailure(ctx, cid, errs.Wrap(errs.CodeVMM, err, "cannot inspect command outcome"))
	}
	var info struct {
		ExitCode int  `json:"ExitCode"`
		Running  bool `json:"Running"`
	}
	if err := json.Unmarshal(jb, &info); err != nil || info.Running {
		return text, errs.New(errs.CodeVMM, "sandbox command outcome is not yet confirmed; inspect it before retrying")
	}
	code := fmt.Sprint(info.ExitCode)
	if info.ExitCode == 137 {
		if failure := a.commandFailure(ctx, cid, nil); failure != nil {
			return "exit=" + code + "\n" + text, failure
		}
	}
	return fmt.Sprintf("exit=%s\n%s", code, text), nil
}

func (a *Adapter) commandFailure(ctx context.Context, cid string, original error) error {
	probe, cancel := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
	defer cancel()
	data, err := a.do(probe, http.MethodGet, "/containers/"+cid+"/json", nil)
	if err == nil {
		var state struct {
			State struct {
				OOMKilled bool `json:"OOMKilled"`
			} `json:"State"`
		}
		if json.Unmarshal(data, &state) == nil && state.State.OOMKilled {
			return errs.New(vmm.CodeSandboxMemoryLimit, "Docker reports the sandbox was killed after exceeding its memory limit")
		}
	}
	return original
}

// CreateTunnel exposes a port of the sandbox container to the node/gateway. It
// returns the http target (the container's IP on the configured network, or its
// default bridge IP) and a token (unused — the target needs no auth). The node
// must be able to reach that IP: with sandbox.docker_network set the container
// joins the node's network; otherwise (daemon on the docker host) the bridge IP
// is reachable directly.
func (a *Adapter) CreateTunnel(ctx context.Context, vmID string, port int) (string, string, error) {
	cid, err := a.containerID(vmID)
	if err != nil {
		return "", "", err
	}
	if err := a.ensureRunning(ctx, cid); err != nil {
		return "", "", err
	}
	ip, err := a.containerIP(ctx, cid)
	if err != nil {
		return "", "", err
	}
	if port <= 0 {
		port = 8080
	}
	return fmt.Sprintf("http://%s:%d", ip, port), "", nil
}

// ensureRunning starts the container when it is not running (the caller usually
// starts the sandbox first; this is a backstop for tunnel opens).
func (a *Adapter) ensureRunning(ctx context.Context, cid string) error {
	b, err := a.do(ctx, http.MethodGet, "/containers/"+cid+"/json", nil)
	if err != nil {
		return errs.Wrap(errs.CodeVMM, err, "inspect container")
	}
	var spec struct {
		State struct {
			Running bool `json:"Running"`
		} `json:"State"`
	}
	if err := json.Unmarshal(b, &spec); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "decode container state")
	}
	if spec.State.Running {
		return nil
	}
	if _, err := a.do(ctx, http.MethodPost, "/containers/"+cid+"/start", nil); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "start container for tunnel")
	}
	return nil
}

// containerIP returns the container's IP on the configured docker network, or
// its default bridge IP when no network is configured.
func (a *Adapter) containerIP(ctx context.Context, cid string) (string, error) {
	b, err := a.do(ctx, http.MethodGet, "/containers/"+cid+"/json", nil)
	if err != nil {
		return "", errs.Wrap(errs.CodeVMM, err, "inspect container ip")
	}
	var spec struct {
		NetworkSettings struct {
			IPAddress string `json:"IPAddress"`
			Networks  map[string]struct {
				IPAddress string `json:"IPAddress"`
			} `json:"Networks"`
		} `json:"NetworkSettings"`
	}
	if err := json.Unmarshal(b, &spec); err != nil {
		return "", errs.Wrap(errs.CodeVMM, err, "decode container ip")
	}
	if a.network != "" {
		if n, ok := spec.NetworkSettings.Networks[a.network]; ok && n.IPAddress != "" {
			return n.IPAddress, nil
		}
	}
	if spec.NetworkSettings.IPAddress != "" {
		return spec.NetworkSettings.IPAddress, nil
	}
	return "", errs.New(errs.CodeVMM, "container has no reachable ip")
}

// execStream performs a POST to a docker endpoint returning a raw byte stream
// (used by exec start). It reads the whole body without JSON parsing.
func (a *Adapter) execStream(ctx context.Context, path string, body any) ([]byte, error) {
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.url(path), r)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	streamClient := *a.client
	streamClient.Timeout = 0 // The command/context deadline bounds this stream.
	resp, err := streamClient.Do(req)
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "docker stream "+path)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return b, err
	}
	if resp.StatusCode >= 400 {
		return nil, errs.New(errs.CodeVMM, fmt.Sprintf("docker %s: %s", path, string(b)))
	}
	return b, nil
}

// demuxStream decodes the Docker stdio multiplexed stream (8-byte headers per
// frame) back into a plain text buffer, tolerant of plain (non-muxed) bodies.
func demuxStream(raw []byte) string {
	var sb strings.Builder
	i := 0
	for i+8 <= len(raw) {
		streamType := raw[i]
		frameLen := int(raw[i+4])<<24 | int(raw[i+5])<<16 | int(raw[i+6])<<8 | int(raw[i+7])
		i += 8
		if i+frameLen > len(raw) {
			frameLen = len(raw) - i
		}
		if frameLen < 0 {
			break
		}
		if streamType == 1 || streamType == 2 {
			sb.Write(raw[i : i+frameLen])
		}
		i += frameLen
	}
	if sb.Len() == 0 {
		return string(raw)
	}
	return strings.TrimSpace(sb.String())
}

// Attach implements vmm.Attacher: it starts an interactive process inside the
// VM's container (starting the container when needed) and returns its stdio.
// Agent engines use it to run inside the shared space sandbox.
func (a *Adapter) Attach(ctx context.Context, vmID string, spec vmm.ExecSpec, stderr io.Writer) (vmm.ExecStream, error) {
	cid, err := a.containerID(vmID)
	if err != nil {
		return nil, err
	}
	if err := a.ensureRunning(ctx, cid); err != nil {
		return nil, err
	}
	return dockerexec.New(a.baseURL).Attach(ctx, cid, spec, stderr)
}
