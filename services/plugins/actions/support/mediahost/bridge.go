package mediahost

import (
	"context"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
)

// hostedDTO mirrors users.HostMarkupResult across the plugin bridge.
type hostedDTO struct {
	Body    string   `json:"body"`
	FileIDs []string `json:"file_ids"`
}

// HostBody asks the users service to download every remote image/video/audio
// in [body] into public storage and rewrite the markup to Aseman file paths.
// Bodies with no remote media are returned unchanged.
func HostBody(ctx context.Context, k api.Kernel, owner identity.ID, body string) (string, []string, error) {
	body = strings.TrimSpace(body)
	if body == "" || len(ExternalURLs(body)) == 0 {
		return body, nil, nil
	}
	var res *hostedDTO
	if err := bridge.Invoke(ctx, k, "users", "HostMarkup", []any{ctx, owner, body}, &res); err != nil {
		return "", nil, err
	}
	if res == nil {
		return body, nil, nil
	}
	return res.Body, res.FileIDs, nil
}
