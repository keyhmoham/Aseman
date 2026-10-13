package spaces

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/jsonpatch"
	"github.com/tradera/tradera/plugins/actions/spaces/models/proxy"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	vmm "github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// A preview is a page the project's computer serves. The computer sleeps when
// it is idle, and a new one starts from the project's files with nothing
// running on it: the page is gone and so is the tunnel that reached it. So a
// preview remembers the command that starts its service, and opening it brings
// it back: wake the computer, start the service if it is not answering, and
// point the gateway at the new machine.

// previewStartWait is how long a service is given to answer after it is
// started. A computer that has just woken reads the project's files slowly at
// first, so a Node app can need a minute or two.
const previewStartWait = 150 * time.Second

func previewStartPath(id identity.ID) string { return "previews/" + id.String() + "/start" }

// setPreviewStart remembers the command that starts a preview's service.
func (s *Service) setPreviewStart(ctx context.Context, p *proxy.Proxy, command string) error {
	command = strings.TrimSpace(command)
	if command == "" {
		return nil
	}
	if len(command) > 2000 {
		return errs.InvalidArgument("the start command is too long (2000 characters at most)")
	}
	return s.M.Patch(ctx, p.SpaceID, jsonpatch.Patch{{Op: "set", Path: previewStartPath(p.ID), Value: command}})
}

// previewStart is the command that starts a preview's service ("" when the
// preview was published without one).
func (s *Service) previewStart(ctx context.Context, p *proxy.Proxy) string {
	m, err := s.M.Get(ctx, p.SpaceID)
	if err != nil || m == nil {
		return ""
	}
	previews, _ := m.Tree["previews"].(map[string]any)
	one, _ := previews[p.ID.String()].(map[string]any)
	command, _ := one["start"].(string)
	return command
}

func shellQuote(v string) string { return "'" + strings.ReplaceAll(v, "'", `'\''`) + "'" }

// answering is a command that exits 0 when something answers HTTP on the port.
func answering(port int) string {
	return fmt.Sprintf("curl -s -o /dev/null -m 3 http://127.0.0.1:%d/", port)
}

// servePreview makes sure something answers on a port of the project's
// computer: if nothing does and a start command is known, it is run detached
// from the project's files and given [wait] to answer. It reports whether the
// port answers, whether the command was run, and the service's last output
// when it did not come up.
func (s *Service) servePreview(ctx context.Context, spaceID identity.ID, port int, start string, wait time.Duration) (up, started bool, log string) {
	probe, _ := s.SandboxExec(ctx, spaceID, answering(port))
	if strings.HasPrefix(probe, "exit=0") || start == "" {
		return strings.HasPrefix(probe, "exit=0"), false, ""
	}
	file := fmt.Sprintf("/tmp/tradera-preview-%d.log", port)
	command := fmt.Sprintf("cd /workspace && (nohup sh -c %s >%s 2>&1 </dev/null &); for i in $(seq 1 %d); do %s && exit 0; sleep 1; done; tail -n 20 %s; exit 1",
		shellQuote(start), file, int(wait.Seconds()), answering(port), file)
	out, _ := s.SandboxExec(ctx, spaceID, command)
	if strings.HasPrefix(out, "exit=0") {
		return true, true, ""
	}
	return false, true, clipText(strings.TrimSpace(strings.TrimPrefix(out, "exit=1")), 1500)
}

// ProxyOpen makes a preview ready to be looked at and reports whether it is.
func (s *Service) ProxyOpen(ctx context.Context, id, actor identity.ID) (map[string]any, error) {
	p, err := s.ProxyGet(ctx, id)
	if err != nil {
		return nil, err
	}
	ctx = helper.WithActor(ctx, actor)
	// Opening a preview may start the computer, which costs money while awake.
	if err := s.requireFundsForComputer(ctx, p.SpaceID, actor); err != nil {
		return nil, err
	}
	rec, err := s.SandboxStart(ctx, p.SpaceID)
	if err != nil {
		return nil, err
	}
	out := map[string]any{"id": p.ID.String(), "title": p.Title, "port": p.Port, "url": p.GatewayPath()}
	start := s.previewStart(ctx, p)
	out["can_start"] = start != ""

	up, started, log := s.servePreview(ctx, p.SpaceID, p.Port, start, previewStartWait)
	if started {
		out["started"] = up
	}
	if log != "" {
		out["log"] = log
	}
	// The computer may be a new machine since the preview was published: the
	// gateway is pointed at this one.
	vm := s.K.VMMFor(vmm.Type(rec.VMType))
	tv, ok := vm.(tunnelVM)
	if !ok {
		return nil, errs.New(errs.CodeUnavailable, "sandbox provider does not support proxying")
	}
	target, token, err := tv.CreateTunnel(ctx, rec.VMID, p.Port)
	if err != nil {
		return nil, err
	}
	preserve := p.PreservesPath()
	p.TargetURL, p.Token, p.UpdatedAt = target, token, time.Now().UTC()
	if preserve {
		p.TargetURL = strings.TrimRight(target, "/") + p.GatewayPath()
	}
	if err := s.saveProxy(ctx, p, false); err != nil {
		return nil, err
	}
	s.holdPreview(p.SpaceID)
	out["ready"] = up
	return out, nil
}

// proxyOpenAction implements spaces.proxy_open.
type proxyOpenAction struct{ s *Service }

func (a *proxyOpenAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "proxy_open", Summary: "Make a preview ready to view: wake the computer and start its service again if needed"}
}

func (a *proxyOpenAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Proxy string `json:"proxy"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Proxy)
	if err != nil {
		return nil, errs.InvalidArgument("invalid proxy id")
	}
	p, err := a.s.ProxyGet(ctx, id)
	if err != nil {
		return nil, err
	}
	// It can start the computer: the same right as running something on it.
	if err := helper.CheckSpaceAccess(ctx, a.s.R, req.Caller.ID, p.SpaceID, p.RoomID, true); err != nil {
		return nil, err
	}
	out, err := a.s.ProxyOpen(ctx, id, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(out)
}
