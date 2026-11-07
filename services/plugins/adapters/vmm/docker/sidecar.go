package docker

import (
	"context"
	"encoding/json"
	"net/http"
	"regexp"
	"time"

	"github.com/aseman/aseman/pkg/errs"
)

var sidecarName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$`)

// EnsureSidecar implements vmm.SidecarRunner: it runs a container in the
// network namespace of the VM's container ("container:<id>"), so whatever it
// serves answers on the VM's own address. The sandbox is started first (a
// sidecar cannot join the namespace of a stopped container).
func (a *Adapter) EnsureSidecar(ctx context.Context, vmID, name, image string, env map[string]string) error {
	if !sidecarName.MatchString(name) {
		return errs.InvalidArgument("invalid sidecar name")
	}
	cid, err := a.containerID(vmID)
	if err != nil {
		return err
	}
	if err := a.ensureRunning(ctx, cid); err != nil {
		return err
	}
	vmStarted := ""
	if b, err := a.do(ctx, http.MethodGet, "/containers/"+cid+"/json", nil); err == nil {
		var vm struct {
			State struct {
				StartedAt string `json:"StartedAt"`
			} `json:"State"`
		}
		if json.Unmarshal(b, &vm) == nil {
			vmStarted = vm.State.StartedAt
		}
	}
	container := "aseman-sidecar-" + vmID + "-" + name
	if b, err := a.do(ctx, http.MethodGet, "/containers/"+container+"/json", nil); err == nil {
		var state struct {
			State struct {
				Running   bool   `json:"Running"`
				StartedAt string `json:"StartedAt"`
			} `json:"State"`
		}
		// Running, and joined to the computer as it runs now: a sidecar
		// started before the computer's current start holds the namespace
		// of its previous run, where nothing reaches it.
		if json.Unmarshal(b, &state) == nil && state.State.Running && !sidecarStale(state.State.StartedAt, vmStarted) {
			return nil
		}
		// Joined to a namespace that may no longer exist (the sandbox was
		// recreated): start it afresh rather than resurrect it.
		_ = a.remove(ctx, container, true)
	}
	if err := a.ensureImage(ctx, image); err != nil {
		return err
	}
	create := map[string]any{
		"Image": image,
		"Env":   envSlice(env),
		"Labels": map[string]string{
			"aseman.sidecar_of": vmID,
			"aseman.sidecar":    name,
		},
		"HostConfig": map[string]any{
			"NetworkMode": "container:" + cid,
			"AutoRemove":  false,
		},
	}
	// A sidecar shares the computer's network, so it runs under the same
	// runtime (gVisor keeps its own network stack).
	if a.runtime != "" {
		create["HostConfig"].(map[string]any)["Runtime"] = a.runtime
	}
	if _, err := a.do(ctx, http.MethodPost, "/containers/create?name="+container, create); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "create sidecar")
	}
	if _, err := a.do(ctx, http.MethodPost, "/containers/"+container+"/start", nil); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "start sidecar")
	}
	return nil
}

// RemoveSidecar implements vmm.SidecarRunner.
func (a *Adapter) RemoveSidecar(ctx context.Context, vmID, name string) error {
	if !sidecarName.MatchString(name) {
		return errs.InvalidArgument("invalid sidecar name")
	}
	container := "aseman-sidecar-" + vmID + "-" + name
	if _, err := a.do(ctx, http.MethodGet, "/containers/"+container+"/json", nil); err != nil {
		return nil
	}
	return a.remove(ctx, container, true)
}

// sidecarStale reports whether a sidecar started before its computer's
// current start (RFC 3339 times as Docker reports them).
func sidecarStale(sidecarStarted, vmStarted string) bool {
	sc, err1 := time.Parse(time.RFC3339Nano, sidecarStarted)
	vm, err2 := time.Parse(time.RFC3339Nano, vmStarted)
	if err1 != nil || err2 != nil {
		return false
	}
	return sc.Before(vm)
}
