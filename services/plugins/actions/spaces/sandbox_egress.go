package spaces

import (
	"context"
	"net/url"
	"os"
	"strings"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
)

// A project computer's network goes through its filtering proxy
// (cmd/aseman-egress): a sidecar in the computer's network namespace that
// applies the project's egress policy (governance). The computer is created
// pointing at the proxy, so until the proxy has its policy nothing leaves.
// Only the docker backend runs sidecars, and only while the governance
// namespace is there to serve the policy.

const egressProxyAddr = "http://127.0.0.1:3128"

// egressImage is the proxy's image; empty turns the proxy off.
func egressImage() string { return strings.TrimSpace(os.Getenv("ASEMAN_EGRESS_IMAGE")) }

// egressEnabled reports whether this node's computers go through the proxy.
func (s *Service) egressEnabled() bool {
	if egressImage() == "" || s.sandboxVMType() != bot.VMTypeContainer {
		return false
	}
	_, err := s.K.Resolve("service/governance")
	return err == nil
}

// sandboxEnv is a new computer's environment.
func (s *Service) sandboxEnv() map[string]string {
	env := sandboxLLMEnv()
	if !s.egressEnabled() {
		return env
	}
	noProxy := []string{"localhost", "127.0.0.1", "::1", "aseman"}
	for _, v := range []string{"ASEMAN_AGENT_NODE_URL", "ASEMAN_SANDBOX_LLM_URL"} {
		if u, err := url.Parse(strings.TrimSpace(os.Getenv(v))); err == nil && u.Hostname() != "" {
			noProxy = append(noProxy, u.Hostname())
		}
	}
	for _, k := range []string{"HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY"} {
		env[k] = egressProxyAddr
	}
	env["NO_PROXY"] = strings.Join(noProxy, ",")
	env["no_proxy"] = env["NO_PROXY"]
	return env
}

// ensureEgress starts the computer's proxy with what it needs to read the
// project's policy from the node.
func (s *Service) ensureEgress(ctx context.Context, spaceID identity.ID) {
	if !s.egressEnabled() {
		return
	}
	var token string
	if err := bridge.Invoke(ctx, s.K, "governance", "EgressToken", []any{spaceID.String()}, &token); err != nil {
		s.L.Warn("egress proxy not started: no token", "space", spaceID.String(), "error", err)
		return
	}
	node := strings.TrimSpace(os.Getenv("ASEMAN_AGENT_NODE_URL"))
	if node == "" {
		node = "http://aseman:8080"
	}
	env := map[string]string{
		"ASEMAN_EGRESS_URL":   strings.TrimRight(node, "/") + "/governance/v1/egress?space=" + url.QueryEscape(spaceID.String()),
		"ASEMAN_EGRESS_TOKEN": token,
	}
	if err := s.SandboxSidecar(ctx, spaceID, "egress", egressImage(), env); err != nil {
		s.L.Warn("egress proxy not started", "space", spaceID.String(), "error", err)
	}
}
