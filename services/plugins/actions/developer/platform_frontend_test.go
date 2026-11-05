package developer

import (
	"context"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/developer/models"
)

type fakeFrontends struct {
	apps map[string]models.FrontendApp
}

func (f fakeFrontends) FrontendApps(context.Context, identity.ID) ([]models.FrontendApp, error) {
	out := []models.FrontendApp{}
	for _, a := range f.apps {
		out = append(out, a)
	}
	return out, nil
}

func (f fakeFrontends) FrontendAppFor(_ context.Context, ref string, _ identity.ID) (*models.FrontendApp, error) {
	a, ok := f.apps[ref]
	if !ok {
		return nil, errs.NotFound("no such app")
	}
	return &a, nil
}

// An owner publishes an app the agents built as the platform's frontend; the
// platform's people (and nobody else) may use it, as the publisher.
func TestPublishAnAppAsThePlatformsFrontend(t *testing.T) {
	f := harness(t)
	sc := f.personal(t)
	store := models.FrontendApp{ProxyID: "p1", SpaceID: "s1", App: "/workspace/appui/store", Title: "Store", UI: "elpian",
		Entry: "elpian/app.js", Wiring: models.Wiring{Agents: []models.WiredAgent{{ID: "a1", Name: "Research"}}}}
	f.s.Frontends = fakeFrontends{apps: map[string]models.FrontendApp{"p1": store}}

	if _, err := f.s.PublishFrontend(f.ctx, sc, f.me, "p1"); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("published before the platform exists: %v", err)
	}
	if _, err := f.s.CreatePlatform(f.ctx, sc, "Acme", "acme"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.PlatformFrontendFor(f.ctx, "acme", identity.ID{}); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("a frontend before one is published: %v", err)
	}
	if pub, _ := f.s.PublicFrontend(f.ctx, "acme"); pub["frontend"] != nil {
		t.Fatalf("public: %+v", pub)
	}
	viewer := sc
	viewer.Role = models.RoleViewer
	if _, err := f.s.PublishFrontend(f.ctx, viewer, f.me, "p1"); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a viewer published: %v", err)
	}
	if _, err := f.s.PublishFrontend(f.ctx, sc, f.me, "nope"); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("an unknown app: %v", err)
	}
	view, err := f.s.PublishFrontend(f.ctx, sc, f.me, "p1")
	if err != nil || view.Frontend == nil || view.Frontend.URL != "/v1/platforms/acme/app/" || view.Frontend.UI != "elpian" ||
		view.Frontend.PublishedBy != f.me.String() || !view.Frontend.Wiring.AllowsAgent("research") {
		t.Fatalf("publish: %+v %v", view.Frontend, err)
	}
	apps, err := f.s.FrontendApps(f.ctx, sc, f.me)
	if err != nil || len(apps) != 1 {
		t.Fatalf("apps: %+v %v", apps, err)
	}

	// Who may use it: the platform's people, the organization, main Aseman
	// only when bridged.
	local := f.person(t, f.s.R.DB, "local")
	var acc account.Account
	_ = f.s.R.Get(f.ctx, "accounts", local, &acc)
	acc.PlatformID = view.ID
	_ = f.s.R.Update(f.ctx, "accounts", local, &acc)
	outsider := f.person(t, f.s.R.DB, "outsider")
	pf, err := f.s.PlatformFrontendFor(f.ctx, "acme", local)
	if err != nil || pf.ProxyID != "p1" || pf.Publisher != f.me.String() || pf.Entry != "elpian/app.js" {
		t.Fatalf("for a person of the platform: %+v %v", pf, err)
	}
	if _, err := f.s.PlatformFrontendFor(f.ctx, "acme", f.me); err != nil {
		t.Fatalf("the organization's owner: %v", err)
	}
	if _, err := f.s.PlatformFrontendFor(f.ctx, "acme", outsider); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("main Aseman got in unbridged: %v", err)
	}
	if _, err := f.s.SetMainAccess(f.ctx, "acme", true); err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.PlatformFrontendFor(f.ctx, "acme", outsider); err != nil {
		t.Fatalf("bridged main Aseman: %v", err)
	}
	if pub, _ := f.s.PublicFrontend(f.ctx, "acme"); pub["frontend"] == nil {
		t.Fatalf("public: %+v", pub)
	}

	view, err = f.s.UnpublishFrontend(f.ctx, sc)
	if err != nil || view.Frontend != nil {
		t.Fatalf("unpublish: %+v %v", view, err)
	}
	if _, err := f.s.PlatformFrontendFor(f.ctx, "acme", local); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("after unpublish: %v", err)
	}
}
