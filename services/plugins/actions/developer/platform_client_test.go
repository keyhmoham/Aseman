package developer

import (
	"context"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/developer/models"
)

type fakeClients struct {
	started []models.PlatformClientTarget
}

func (f *fakeClients) StartPlatformClientBuild(_ context.Context, _ identity.ID, target models.PlatformClientTarget, _ models.PlatformClientOptions) (models.PlatformClientBuild, error) {
	f.started = append(f.started, target)
	return models.PlatformClientBuild{Platform: target.Slug, State: "building"}, nil
}

func (f *fakeClients) PlatformClientBuildStatus(_ context.Context, _ identity.ID, target models.PlatformClientTarget) (models.PlatformClientBuild, error) {
	return models.PlatformClientBuild{Platform: target.Slug, State: "none"}, nil
}

// A built Android app is recorded on its platform: the console shows it, and
// the public description offers its download to anyone.
func TestAPlatformsAndroidAppIsOfferedOnceBuilt(t *testing.T) {
	f := harness(t)
	sc := f.personal(t)
	store := models.FrontendApp{ProxyID: "p1", SpaceID: "s1", Title: "Store", UI: "elpian", Entry: "elpian/app.js"}
	f.s.Frontends = fakeFrontends{apps: map[string]models.FrontendApp{"p1": store}}
	clients := &fakeClients{}
	f.s.Clients = clients
	created, err := f.s.CreatePlatform(f.ctx, sc, "Acme", "acme")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.PlatformClientTarget(f.ctx, f.me, "", "acme"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.PlatformClientFile(f.ctx, "acme"); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("an app before one is built: %v", err)
	}
	if _, err := f.s.BuildPlatformClient(f.ctx, sc, f.me, "acme", models.PlatformClientOptions{}); err != nil {
		t.Fatal(err)
	}
	if len(clients.started) != 1 || clients.started[0].ProxyID != "" {
		t.Fatalf("a build with no frontend is still handed on (the spaces namespace refuses it): %+v", clients.started)
	}
	if _, err := f.s.PublishFrontend(f.ctx, sc, f.me, "acme", "p1"); err != nil {
		t.Fatal(err)
	}
	target, err := f.s.PlatformClientTarget(f.ctx, f.me, "", "acme")
	if err != nil || target.ProxyID != "p1" || target.UI != "elpian" || target.SpaceID != "s1" || target.Client != nil {
		t.Fatalf("target: %+v %v", target, err)
	}
	viewer := sc
	viewer.Role = models.RoleViewer
	if _, err := f.s.BuildPlatformClient(f.ctx, viewer, f.me, "acme", models.PlatformClientOptions{}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a viewer built the app: %v", err)
	}

	if err := f.s.RecordPlatformClient(f.ctx, created.ID, models.PlatformClient{FileID: "f1", Version: "1.0.0", Size: 42, SHA256: "abc",
		AppID: "io.aseman.platform.acme", BuiltBy: f.me.String()}); err != nil {
		t.Fatal(err)
	}
	c, err := f.s.PlatformClientFile(f.ctx, "acme")
	if err != nil || c.FileID != "f1" || c.Version != "1.0.0" {
		t.Fatalf("client: %+v %v", c, err)
	}
	pub, err := f.s.PublicFrontend(f.ctx, "acme")
	if err != nil {
		t.Fatal(err)
	}
	android, _ := pub["client"].(map[string]any)["android"].(*ClientView)
	if android == nil || android.URL != "/v1/platforms/acme/client/android.apk" || android.Version != "1.0.0" {
		t.Fatalf("public client: %+v", pub["client"])
	}
	frontend, _ := pub["frontend"].(map[string]any)
	if frontend["wake"] != "/v1/platforms/acme/app/_aseman/wake" {
		t.Fatalf("public frontend: %+v", frontend)
	}
	target, _ = f.s.PlatformClientTarget(f.ctx, f.me, "", "acme")
	if target.Client == nil || target.Client.AppID != "io.aseman.platform.acme" {
		t.Fatalf("a rebuild keeps the app id: %+v", target.Client)
	}
	if err := f.s.RecordPlatformClient(f.ctx, created.ID, models.PlatformClient{}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("a record with no file: %v", err)
	}
}
