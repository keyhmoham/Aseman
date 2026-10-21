package modal

import (
	"context"
	"time"

	pb "github.com/modal-labs/modal-client/go/proto/modal_proto"

	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

var _ vmm.Inventory = (*Adapter)(nil)

// inventoryLimit bounds how much of the account one listing reads.
const inventoryLimit = 500

func unixTime(seconds float64) time.Time {
	if seconds <= 0 {
		return time.Time{}
	}
	return time.Unix(0, int64(seconds*float64(time.Second))).UTC()
}

// Sandboxes (vmm.Inventory): the sandboxes Modal is running in this
// platform's app right now, newest first.
func (a *Adapter) Sandboxes(ctx context.Context) ([]vmm.ProviderSandbox, error) {
	api, err := a.api(ctx)
	if err != nil {
		return nil, err
	}
	app, err := a.client.Apps.FromName(ctx, sandboxApp, nil)
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "modal app")
	}
	a.mu.Lock()
	machines := map[string]string{}
	for id, st := range a.sandboxes {
		if st != nil && st.sb != nil {
			name := st.spec.Name
			if name == "" {
				name = id
			}
			machines[st.sb.SandboxID] = name
		}
	}
	a.mu.Unlock()
	out := []vmm.ProviderSandbox{}
	var before float64
	for len(out) < inventoryLimit {
		resp, err := api.SandboxList(ctx, pb.SandboxListRequest_builder{AppId: app.AppID, BeforeTimestamp: before}.Build())
		if err != nil {
			return nil, errs.Wrap(errs.CodeVMM, err, "list modal sandboxes")
		}
		page := resp.GetSandboxes()
		if len(page) == 0 {
			break
		}
		for _, info := range page {
			out = append(out, vmm.ProviderSandbox{
				ID: info.GetId(), Name: info.GetName(), CreatedAt: unixTime(info.GetCreatedAt()),
				StartedAt: unixTime(info.GetTaskInfo().GetStartedAt()), Machine: machines[info.GetId()],
			})
		}
		before = page[len(page)-1].GetCreatedAt()
	}
	return out, nil
}

// Volumes (vmm.Inventory): the volumes Modal stores in this environment,
// newest first. Each project's files live on one.
func (a *Adapter) Volumes(ctx context.Context) ([]vmm.ProviderVolume, error) {
	api, err := a.api(ctx)
	if err != nil {
		return nil, err
	}
	out := []vmm.ProviderVolume{}
	var before float64
	for len(out) < inventoryLimit {
		resp, err := api.VolumeList(ctx, pb.VolumeListRequest_builder{
			EnvironmentName: a.environment,
			Pagination:      pb.ListPagination_builder{MaxObjects: 100, CreatedBefore: before}.Build(),
		}.Build())
		if err != nil {
			return nil, errs.Wrap(errs.CodeVMM, err, "list modal volumes")
		}
		page := resp.GetItems()
		if len(page) == 0 {
			break
		}
		for _, v := range page {
			out = append(out, vmm.ProviderVolume{ID: v.GetVolumeId(), Name: v.GetLabel(), CreatedAt: unixTime(v.GetCreatedAt())})
		}
		if len(page) < 100 {
			break
		}
		before = page[len(page)-1].GetCreatedAt()
	}
	return out, nil
}
