package docker

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

var _ vmm.Inventory = (*Adapter)(nil)

// Sandboxes returns the running Aseman containers known to Docker. The
// stable VM id and project-computer name come from the labels written when the
// container is created, so the inventory remains useful after a daemon restart.
func (a *Adapter) Sandboxes(ctx context.Context) ([]vmm.ProviderSandbox, error) {
	filters, _ := json.Marshal(map[string][]string{"label": {"aseman.vmid"}})
	b, err := a.do(ctx, http.MethodGet,
		"/containers/json?all=false&filters="+url.QueryEscape(string(filters)), nil)
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "list docker sandboxes")
	}
	var rows []struct {
		ID      string            `json:"Id"`
		Names   []string          `json:"Names"`
		Created int64             `json:"Created"`
		Labels  map[string]string `json:"Labels"`
	}
	if err := json.Unmarshal(b, &rows); err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "decode docker sandboxes")
	}
	out := make([]vmm.ProviderSandbox, 0, len(rows))
	for _, row := range rows {
		vmID := row.Labels["aseman.vmid"]
		if vmID == "" {
			continue
		}
		name := row.Labels["aseman.vm"]
		if name == "" && len(row.Names) > 0 {
			name = strings.TrimPrefix(row.Names[0], "/")
		}
		created := time.Unix(row.Created, 0).UTC()
		started := created
		if inspected, inspectErr := a.do(ctx, http.MethodGet,
			"/containers/"+url.PathEscape(row.ID)+"/json", nil); inspectErr == nil {
			var detail struct {
				State struct {
					StartedAt string `json:"StartedAt"`
				} `json:"State"`
			}
			if json.Unmarshal(inspected, &detail) == nil {
				if parsed, parseErr := time.Parse(time.RFC3339Nano, detail.State.StartedAt); parseErr == nil {
					started = parsed.UTC()
				}
			}
		}
		out = append(out, vmm.ProviderSandbox{
			ID: vmID, Name: name, Machine: row.Labels["aseman.vm"],
			CreatedAt: created, StartedAt: started,
		})
	}
	return out, nil
}

// Volumes returns the durable project workspaces managed by this adapter.
// Agent runtime state is intentionally excluded: the admin Storage page is
// the project-file inventory, not an internal cache inventory.
func (a *Adapter) Volumes(ctx context.Context) ([]vmm.ProviderVolume, error) {
	b, err := a.do(ctx, http.MethodGet, "/volumes", nil)
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "list docker volumes")
	}
	var response struct {
		Volumes []struct {
			Name      string `json:"Name"`
			CreatedAt string `json:"CreatedAt"`
		} `json:"Volumes"`
	}
	if err := json.Unmarshal(b, &response); err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "decode docker volumes")
	}
	out := make([]vmm.ProviderVolume, 0, len(response.Volumes))
	for _, volume := range response.Volumes {
		if !strings.HasPrefix(volume.Name, "aseman-workspace-") {
			continue
		}
		created := time.Time{}
		if parsed, parseErr := time.Parse(time.RFC3339Nano, volume.CreatedAt); parseErr == nil {
			created = parsed.UTC()
		}
		out = append(out, vmm.ProviderVolume{
			ID: volume.Name, Name: volume.Name, CreatedAt: created,
		})
	}
	return out, nil
}
