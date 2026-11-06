package apihttp

// A platform's own Android app (spaces/platform_client.go): the lightweight
// Elpian client built for its published frontend. Anyone downloads it, signed
// in or not, at /v1/platforms/<slug>/client/android.apk — it is what the
// platform hands its people. The APK is a file the node stores, so the link
// works while the platform's computer sleeps.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	network "github.com/aseman/aseman/plugins/adapters/network/ports"
)

// platformClients finds a platform's Android app.
type platformClients interface {
	PlatformClientFile(ctx context.Context, ref string) (*models.PlatformClient, error)
}

func (p gatewayBridge) PlatformClientFile(ctx context.Context, ref string) (*models.PlatformClient, error) {
	var out *models.PlatformClient
	err := bridge.Invoke(ctx, p.k, "developer", "PlatformClientFile", []any{ctx, ref}, &out)
	return out, err
}

var _ platformClients = gatewayBridge{}

// platformClientDownload answers GET /v1/platforms/{slug}/client/android.apk.
func (a *API) platformClientDownload(ctx context.Context, req *network.Request) (*network.Response, error) {
	params := map[string]string{}
	if raw := req.Header["x-route-params"]; raw != "" {
		_ = json.Unmarshal([]byte(raw), &params)
	}
	slug := strings.ToLower(strings.TrimSpace(params["slug"]))
	if slug == "" {
		return nil, errs.NotFound("name the platform")
	}
	if file := params["file"]; file != "android.apk" && file != slug+".apk" {
		return nil, errs.NotFound("a platform's app is at client/android.apk")
	}
	pcs, ok := a.Spaces.(platformClients)
	if !ok || a.Spaces == nil {
		return nil, errs.New(errs.CodeUnavailable, "platform apps are unavailable")
	}
	client, err := pcs.PlatformClientFile(ctx, slug)
	if err != nil {
		return nil, err
	}
	id, err := identity.Parse(client.FileID)
	if err != nil {
		return nil, errs.NotFound("the platform's app")
	}
	file, err := a.Spaces.GetFile(ctx, id)
	if err != nil {
		return nil, errs.NotFound("the platform's app was deleted; build it again")
	}
	data, err := a.Spaces.ReadFileBytes(ctx, file)
	if err != nil {
		return nil, err
	}
	name := slug + ".apk"
	if client.Version != "" {
		name = slug + "-" + client.Version + ".apk"
	}
	hdr := map[string]string{
		"Content-Type":        "application/vnd.android.package-archive",
		"Content-Disposition": fmt.Sprintf("attachment; filename=%q", name),
		// A new build replaces it at the same address.
		"Cache-Control": "public, max-age=300",
	}
	if client.SHA256 != "" {
		hdr["ETag"] = `"` + client.SHA256 + `"`
	}
	return &network.Response{Status: http.StatusOK, Body: data, Header: hdr}, nil
}
