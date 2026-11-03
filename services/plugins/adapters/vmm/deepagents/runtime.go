package deepagents

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// runtimeTuning are node environment variables passed on to the runtime: the
// model calls a turn may make, the window assumed for a model whose window is
// unknown, the self-hosted OpenViking server that keeps the agents' memory
// (its URL, root key and how much is recalled with each message), how many
// swarm tasks run at once, and how agents improve their playbook (GEPA).
var runtimeTuning = []string{"ASEMAN_MAX_MODEL_CALLS", "ASEMAN_DEFAULT_CONTEXT_WINDOW",
	"ASEMAN_SUMMARIZE_MAX_TOKENS",
	"ASEMAN_OPENVIKING_URL", "ASEMAN_OPENVIKING_API_KEY", "ASEMAN_OPENVIKING_RECALL_TOKENS",
	"ASEMAN_OPENVIKING_QUERY_EXPANSION",
	"ASEMAN_SWARM_PARALLEL", "ASEMAN_IMPROVE", "ASEMAN_IMPROVE_EVERY", "ASEMAN_IMPROVE_COOLDOWN",
	"ASEMAN_IMPROVE_LOOP_COOLDOWN", "ASEMAN_IMPROVE_BUDGET", "ASEMAN_IMPROVE_MAX_AGE_DAYS",
	// OpenCode agentic engine credential (Go API key or mounted auth.json).
	"ASEMAN_OPENCODE_ENGINE_API_KEY", "ASEMAN_OPENCODE_ENGINE_AUTH",
	"ASEMAN_OPENCODE_ENGINE_AUTH_HOME", "ASEMAN_OPENCODE_ENGINE_HOME",
	"ASEMAN_OPENCODE_ENGINE_TIMEOUT", "ASEMAN_OPENCODE_ENGINE_RETRY_DELAY",
	"ASEMAN_OPENCODE_BIN",
	// DeepSeek Harness agentic engine: its binary and home, how long a run may
	// take, and optionally its own DeepSeek key (ASEMAN_DSH_ENGINE_LLM=deepseek;
	// by default it runs on the agents' platform models) and web tools.
	"ASEMAN_DSH_BIN", "ASEMAN_DSH_ENGINE_HOME", "ASEMAN_DSH_ENGINE_TIMEOUT",
	"ASEMAN_DSH_ENGINE_TOOL_TIMEOUT", "ASEMAN_DSH_ENGINE_LLM", "ASEMAN_DSH_ENGINE_API_KEY",
	"ASEMAN_DSH_ENGINE_MODEL", "ASEMAN_DSH_ENGINE_WEB"}

// healthTTL is how long a successful health check is trusted.
const healthTTL = 30 * time.Second

// runtimeStartTimeout bounds waiting for a freshly scheduled runtime VM.
const runtimeStartTimeout = 3 * time.Minute

// serviceHost is the VMM the runtime runs on: the Nomad provider (docker VMs).
func (a *Adapter) serviceHost() vmm.VMM {
	if a.k == nil {
		return nil
	}
	return a.k.VMMFor(vmm.TypeDocker)
}

// runtimeBase is the runtime's base URL.
func (a *Adapter) runtimeBase() string {
	if a.runtimeURL != "" {
		return a.runtimeURL
	}
	return "http://" + a.alias + ":" + a.port
}

// ensureRuntime makes sure the runtime answers, starting it as a Nomad
// service VM when this node runs it. The VM has a stable id, so starting it
// again (after a node restart) replaces the old one instead of adding one.
func (a *Adapter) ensureRuntime(ctx context.Context) error {
	a.runtimeMu.Lock()
	defer a.runtimeMu.Unlock()
	if time.Since(a.healthyAt) < healthTTL {
		return nil
	}
	if a.healthy(ctx) {
		a.healthyAt = time.Now()
		return nil
	}
	if a.runtimeURL != "" {
		return errs.New(errs.CodeUnavailable, "the agent runtime at "+a.runtimeURL+" is not answering")
	}
	if a.runtimeVM == "" {
		host := a.serviceHost()
		if host == nil {
			return errs.New(errs.CodeUnavailable, "no Nomad VMM to run the agent runtime on")
		}
		labels := map[string]string{vmm.LabelServiceID: runtimeService, vmm.LabelNetworkAlias: a.alias}
		if a.volume != "" {
			labels[vmm.LabelVolume] = a.volume
		}
		env := map[string]string{
			"ASEMAN_NODE_URL":       a.nodeURL,
			"ASEMAN_RUNTIME_SECRET": a.secret,
			"ASEMAN_RUNTIME_PORT":   a.port,
			"ASEMAN_DATA_DIR":       "/data",
		}
		// The runtime's turn limits and memory server, when the node sets them.
		for _, key := range runtimeTuning {
			if v := strings.TrimSpace(os.Getenv(key)); v != "" {
				env[key] = v
			}
		}
		// OpenCode Go key for the agentic engine: prefer the dedicated var, else
		// the programmer OPENCODE_API_KEY already used by this node.
		if strings.TrimSpace(env["ASEMAN_OPENCODE_ENGINE_API_KEY"]) == "" {
			if v := strings.TrimSpace(os.Getenv("OPENCODE_API_KEY")); v != "" {
				env["ASEMAN_OPENCODE_ENGINE_API_KEY"] = v
			}
		}
		vm, err := host.CreateVM(ctx, vmm.VMSpec{
			Name: runtimeService, Type: vmm.TypeDocker, ImageRef: a.image,
			Resources:   vmm.ResourceSpec{CPU: 10, MemoryMB: a.memoryMB, DiskMB: 1024, Network: a.network},
			Environment: env,
			Labels:      labels,
		})
		if err != nil {
			return errs.Wrap(errs.CodeUnavailable, err, "start the agent runtime")
		}
		a.runtimeVM = vm.ID
		a.Log.Info("agent runtime scheduled on nomad", "vm_id", vm.ID, "image", a.image, "alias", a.alias)
	}
	deadline := time.Now().Add(runtimeStartTimeout)
	for time.Now().Before(deadline) {
		if a.healthy(ctx) {
			a.healthyAt = time.Now()
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
	// Say why before giving up on it (deleting the job loses the evidence).
	reason := ""
	if host := a.serviceHost(); host != nil && a.runtimeVM != "" {
		if explainer, ok := host.(vmm.FailureExplainer); ok {
			reason = explainer.Explain(context.WithoutCancel(ctx), a.runtimeVM)
		}
	}
	if reason != "" {
		a.Log.Warn("agent runtime did not become healthy", "vm_id", a.runtimeVM, "reason", reason)
	}
	// Give up on this VM: the next turn schedules the runtime afresh.
	if host := a.serviceHost(); host != nil && a.runtimeVM != "" {
		if err := host.DeleteVM(context.WithoutCancel(ctx), a.runtimeVM); err != nil {
			a.Log.Warn("remove unhealthy agent runtime", "vm_id", a.runtimeVM, "error", err)
		}
	}
	a.runtimeVM = ""
	msg := "the agent runtime did not become healthy at " + a.runtimeBase()
	if reason != "" {
		msg += " (" + reason + ")"
	}
	return errs.New(errs.CodeUnavailable, msg)
}

func (a *Adapter) healthy(ctx context.Context) bool {
	hctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	var out struct {
		OK bool `json:"ok"`
	}
	return a.call(hctx, http.MethodGet, "/healthz", nil, &out) == nil && out.OK
}

// call performs one request to the runtime, authenticated with the runtime
// secret.
func (a *Adapter) call(ctx context.Context, method, path string, body, out any) error {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, a.runtimeBase()+path, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Aseman-Runtime", a.secret)
	resp, err := a.client.Do(req)
	if err != nil {
		return errs.Wrap(errs.CodeUnavailable, err, "agent runtime unreachable")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return errs.Wrap(errs.CodeUnavailable, err, "agent runtime response")
	}
	if resp.StatusCode >= 300 {
		var e struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(data, &e)
		if e.Error == "" {
			e.Error = string(data)
		}
		return errs.New(errs.CodeVMM, fmt.Sprintf("agent runtime %d: %s", resp.StatusCode, clip(e.Error, 500)))
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(data, out); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "decode agent runtime response")
	}
	return nil
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
