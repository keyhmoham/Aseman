package deepagents

import (
	"context"
	"net/http"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// Code Mode (Cloudflare search-and-execute MCP) — the turn's capability-calling
// system (apps, platform tools, timeline):
//
//	POST {gateway}/codemode/mcp   (Bearer: turn token; body: one JSON-RPC message)
//
// The tools namespace builds one OpenAPI document and runs model-written
// JavaScript in an isolated sandbox; codemode.request dispatches to
// InvokeTool (apps), ToolDispatch (platform), or timeline.MCP.

func (p kernelPlatform) CodeModeMCP(ctx context.Context, spaceID string, body []byte) ([]byte, error) {
	var out []byte
	err := bridge.Invoke(ctx, p.K, "tools", "CodeModeMCP", []any{ctx, spaceID, body}, &out)
	return out, err
}

func (a *Adapter) serveCodeMode(ctx context.Context, req *network.Request) (*network.Response, error) {
	s := a.byToken(bearer(req.Header))
	if s == nil {
		return errorResponse(errs.Unauthenticated("invalid or expired agent turn token")), nil
	}
	defer s.begin()()
	if a.platform == nil || s.spaceID == "" {
		return jsonResponse(http.StatusServiceUnavailable, map[string]any{"error": "Code Mode is not available"}), nil
	}
	out, err := a.platform.CodeModeMCP(scoped{Context: ctx, values: s.base}, s.spaceID, req.Body)
	if err != nil {
		if errs.CodeOf(err) == errs.CodeUnavailable {
			return jsonResponse(http.StatusServiceUnavailable, map[string]any{"code": string(errs.CodeUnavailable), "error": err.Error()}), nil
		}
		return errorResponse(err), nil
	}
	return &network.Response{Status: http.StatusOK, Header: map[string]string{"Content-Type": "application/json"}, Body: out}, nil
}
