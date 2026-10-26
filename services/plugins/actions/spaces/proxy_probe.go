package spaces

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
)

const proxyProbeTimeout = 12 * time.Second

// upstreamGet performs a bounded GET of the proxy's persisted tunnel target.
// Credentials stay private; redirects are not followed.
func upstreamGet(ctx context.Context, record *proxy.Proxy, rest string, maxBody int64) (status int, contentType string, body []byte, complete bool, err error) {
	target, err := url.Parse(record.TargetURL)
	if err != nil || target.Host == "" || target.User != nil || (target.Scheme != "http" && target.Scheme != "https") {
		return 0, "", nil, false, errs.InvalidArgument("invalid persisted proxy target")
	}
	upstream := record.TargetURL
	if rest = strings.TrimLeft(rest, "/"); rest != "" {
		upstream = strings.TrimRight(record.TargetURL, "/") + "/" + rest
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, upstream, nil)
	if err != nil {
		return 0, "", nil, false, errs.InvalidArgument("invalid page path")
	}
	req.Header.Set("Authorization", "Bearer "+record.Token)
	req.Header.Set("Accept", "text/html,*/*")
	req.Header.Set("X-Forwarded-Prefix", strings.TrimRight(record.GatewayPath(), "/"))
	client := &http.Client{Timeout: proxyProbeTimeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(req)
	if err != nil {
		return 0, "", nil, false, errs.New(errs.CodeUnavailable, "the preview did not answer; verify the service is listening on the exposed port")
	}
	defer response.Body.Close()
	body, err = io.ReadAll(io.LimitReader(response.Body, maxBody+1))
	if err != nil {
		return 0, "", nil, false, errs.New(errs.CodeUnavailable, "the preview's response could not be read")
	}
	complete = int64(len(body)) <= maxBody
	if !complete {
		body = body[:maxBody]
	}
	return response.StatusCode, response.Header.Get("Content-Type"), body, complete, nil
}

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
