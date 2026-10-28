package deepagents

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// SVIDHeader carries the agent runtime's JWT-SVID (SPIFFE workload identity)
// on every gateway call, when the deployment runs SPIRE.
const SVIDHeader = "X-Aseman-SVID"

// workloadRequired is the enterprise setting, reread at most every 30s.
type workloadPolicy struct {
	mu       sync.Mutex
	required bool
	checked  time.Time
}

func (a *Adapter) workloadRequired(ctx context.Context) bool {
	p := &a.workload
	p.mu.Lock()
	defer p.mu.Unlock()
	if time.Since(p.checked) < 30*time.Second {
		return p.required
	}
	var required bool
	if a.k != nil {
		if err := bridge.Invoke(ctx, a.k, "enterprise", "WorkloadRequired", []any{ctx}, &required); err != nil {
			required = false
		}
	}
	p.required, p.checked = required, time.Now()
	return required
}

// withWorkload refuses a gateway call whose workload identity does not
// verify, or that has none while the node requires one. Without SPIRE (and
// without the enterprise namespace) calls go through on their turn token.
func (a *Adapter) withWorkload(h network.Handler) network.Handler {
	return func(ctx context.Context, req *network.Request) (*network.Response, error) {
		svid := ""
		for k, v := range req.Header {
			if strings.EqualFold(k, SVIDHeader) {
				svid = v
			}
		}
		if svid == "" {
			if a.workloadRequired(ctx) {
				return errorResponse(errs.Unauthenticated("workload identity required")), nil
			}
			return h(ctx, req)
		}
		var id string
		if a.k == nil {
			return h(ctx, req)
		}
		if err := bridge.Invoke(ctx, a.k, "enterprise", "VerifyWorkload", []any{ctx, svid}, &id); err != nil {
			if a.workloadRequired(ctx) {
				return errorResponse(errs.Unauthenticated("workload identity: " + err.Error())), nil
			}
		}
		return h(ctx, req)
	}
}
