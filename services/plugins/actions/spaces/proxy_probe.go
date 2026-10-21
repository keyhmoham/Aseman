package spaces

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
)

// probeProxy checks only the persisted, workspace-authorized tunnel target.
// Credentials stay inside this namespace; redirects cannot forward them.
// This is HTTP evidence, not a browser check or a gateway authentication test.
func probeProxy(ctx context.Context, record *proxy.Proxy) (string, error) {
	target, err := url.Parse(record.TargetURL)
	if err != nil || target.Host == "" || target.User != nil || (target.Scheme != "http" && target.Scheme != "https") {
		return "", errs.InvalidArgument("invalid persisted proxy target")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return "", errs.InvalidArgument("invalid persisted proxy target")
	}
	req.Header.Set("Authorization", "Bearer "+record.Token)
	client := &http.Client{
		Timeout:       15 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	response, err := client.Do(req)
	if err != nil {
		// net/http errors can contain the private upstream URL. Do not expose it.
		return "", errs.New(errs.CodeUnavailable, "proxy HTTP probe failed; verify the service is listening on the exposed port")
	}
	defer response.Body.Close()
	const maxBody = 2 * 1024 * 1024
	body, err := io.ReadAll(io.LimitReader(response.Body, maxBody+1))
	if err != nil {
		return "", errs.New(errs.CodeUnavailable, "proxy HTTP response could not be read")
	}
	complete := len(body) <= maxBody
	result := map[string]any{
		"gateway_path": record.GatewayPath(), "status": response.StatusCode,
		"content_type": response.Header.Get("Content-Type"), "complete": complete,
		"passed": response.StatusCode >= 200 && response.StatusCode < 300 && complete,
		"scope":  "HTTP GET of the gateway's persisted upstream tunnel; node gateway authentication and browser behavior are not tested",
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
