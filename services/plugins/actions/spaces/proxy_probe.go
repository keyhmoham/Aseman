package spaces

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
)

// probeProxy checks only the persisted, workspace-authorized tunnel target.
// Credentials stay inside this namespace; redirects cannot forward them.
// This is HTTP evidence, not a browser check or a gateway authentication test.
func probeProxy(ctx context.Context, record *proxy.Proxy) (string, error) {
	const maxBody = 2 * 1024 * 1024
	status, contentType, body, complete, err := upstreamGet(ctx, record, "", maxBody)
	if err != nil {
		if errs.CodeOf(err) == errs.CodeUnavailable {
			return "", errs.New(errs.CodeUnavailable, "proxy HTTP probe failed; verify the service is listening on the exposed port")
		}
		return "", err
	}
	result := map[string]any{
		"gateway_path": record.GatewayPath(), "status": status,
		"content_type": contentType, "complete": complete,
		"passed": status >= 200 && status < 300 && complete,
		"scope":  "HTTP GET of the gateway's persisted upstream tunnel; node gateway authentication and browser behavior are not tested (opening the page with web_show reviews and tests it)",
	}
	if complete {
		sum := sha256.Sum256(body)
		result["bytes"] = len(body)
		result["sha256"] = hex.EncodeToString(sum[:])
	} else {
		result["limitation"] = "response exceeds the 2 MiB inspection limit; no complete-body fingerprint is available"
	}
	data, err := json.Marshal(result)
	return string(data), err
}
