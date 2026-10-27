package deepagents

import (
	"context"
	"net/http"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// The space's timeline (the timeline namespace, kept in the node's Utopia
// server) is served to every agent as a built-in MCP server: the runtime
// lists its tools and calls them here, and the node forwards each message to
// the knowledge base of the turn's space. An agent never names the space,
// holds a Utopia key or reaches another space's timeline.
//
//	POST {gateway}/timeline/mcp   (Bearer: the turn token; body: one JSON-RPC message)

func (p kernelPlatform) TimelineEnabled(ctx context.Context) (bool, error) {
	var on bool
	err := bridge.Invoke(ctx, p.K, "timeline", "Enabled", []any{ctx}, &on)
	return on, err
}

func (p kernelPlatform) TimelineMCP(ctx context.Context, spaceID string, body []byte) ([]byte, error) {
	var out []byte
	err := bridge.Invoke(ctx, p.K, "timeline", "MCP", []any{ctx, spaceID, body}, &out)
	return out, err
}

func (p kernelPlatform) OpenCodeEnabled(ctx context.Context) (bool, error) {
	var on bool
	err := bridge.Invoke(ctx, p.K, "spaces", "OpenCodeEnabled", []any{ctx}, &on)
	return on, err
}

// timelineOn reports whether turns get the timeline (an error means the
// timeline namespace is not loaded: off).
func (a *Adapter) timelineOn(ctx context.Context) bool {
	if a.platform == nil {
		return false
	}
	on, err := a.platform.TimelineEnabled(ctx)
	return err == nil && on
}

func (a *Adapter) serveTimeline(ctx context.Context, req *network.Request) (*network.Response, error) {
	s := a.byToken(bearer(req.Header))
	if s == nil {
		return errorResponse(errs.Unauthenticated("invalid or expired agent turn token")), nil
	}
	if vmm.ExecutionFrom(s.base).NoMemory {
		// A request processed freshly reads nothing of the project's past.
		return errorResponse(errs.Permission("this request is processed without the project's history")), nil
	}
	if a.platform == nil || s.spaceID == "" {
		return jsonResponse(http.StatusServiceUnavailable, map[string]any{"error": "the timeline is not available"}), nil
	}
	out, err := a.platform.TimelineMCP(scoped{Context: ctx, values: s.base}, s.spaceID, req.Body)
	if err != nil {
		if errs.CodeOf(err) == errs.CodeUnavailable {
			return jsonResponse(http.StatusServiceUnavailable, map[string]any{"code": string(errs.CodeUnavailable), "error": err.Error()}), nil
		}
		return errorResponse(err), nil
	}
	return &network.Response{Status: http.StatusOK, Header: map[string]string{"Content-Type": "application/json"}, Body: out}, nil
}
