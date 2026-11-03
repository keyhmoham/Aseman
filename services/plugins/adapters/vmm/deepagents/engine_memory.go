package deepagents

import (
	"context"
	"net/http"
	"net/url"
	"strings"

	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// engineMemoryEngines are the agentic engines that keep a memory of their own
// in the runtime (the others use the node's OpenViking, or none).
var engineMemoryEngines = map[string]bool{"deepseek": true}

// EngineMemoryRead implements vmm.EngineMemory: what DeepSeek Harness's own
// memory (its aseman-memory plugin) holds about a space and an agent.
func (a *Adapter) EngineMemoryRead(ctx context.Context, engine, spaceID, agentID string) (*vmm.EngineMemoryView, error) {
	if !engineMemoryEngines[engine] {
		return nil, errs.InvalidArgument("the " + engine + " engine keeps no memory of its own")
	}
	if strings.TrimSpace(spaceID) == "" {
		return nil, errs.InvalidArgument("engine memory needs a space")
	}
	if err := a.ensureRuntime(ctx); err != nil {
		return nil, err
	}
	q := url.Values{"space": {spaceID}}
	if agentID != "" {
		q.Set("agent", agentID)
	}
	var out vmm.EngineMemoryView
	if err := a.call(ctx, http.MethodGet, "/v1/engines/"+engine+"/memory?"+q.Encode(), nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// EngineMemoryWrite implements vmm.EngineMemory: people correct the notes the
// engine's agents read.
func (a *Adapter) EngineMemoryWrite(ctx context.Context, engine, spaceID, agentID, content string) error {
	if !engineMemoryEngines[engine] {
		return errs.InvalidArgument("the " + engine + " engine keeps no memory of its own")
	}
	if strings.TrimSpace(spaceID) == "" || strings.TrimSpace(content) == "" {
		return errs.InvalidArgument("engine memory needs a space and the notes")
	}
	if err := a.ensureRuntime(ctx); err != nil {
		return err
	}
	return a.call(ctx, http.MethodPost, "/v1/engines/"+engine+"/memory",
		map[string]any{"space": spaceID, "agent": agentID, "content": content}, nil)
}

var _ vmm.EngineMemory = (*Adapter)(nil)
