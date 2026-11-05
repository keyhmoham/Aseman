package spaces

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

func TestParseWiringReadsAppsJSON(t *testing.T) {
	w := parseWiring(`{"space":{"id":"s"},"apps":[{"bot_id":"t1","name":"Weather","microtools":[{"name":"forecast"},{"name":"now"}]}],"agents":[{"id":"a1","name":"Research"}]}`)
	if len(w.Agents) != 1 || w.Agents[0].ID != "a1" || len(w.Apps) != 1 || len(w.Apps[0].Microtools) != 2 {
		t.Fatalf("wiring: %+v", w)
	}
	if !w.AllowsAgent("research") || !w.AllowsAgent("a1") || w.AllowsAgent("Finance") || w.AllowsAgent("") {
		t.Fatal("agents")
	}
	if !w.AllowsApp("weather", "forecast") || !w.AllowsApp("t1", "") || w.AllowsApp("Weather", "delete") || w.AllowsApp("Payroll", "") {
		t.Fatal("apps")
	}
	if got := parseWiring("not json"); got.Agents == nil || got.Apps == nil || len(got.Agents)+len(got.Apps) != 0 {
		t.Fatalf("broken APPS.json wires nothing: %+v", got)
	}
}

func TestAppuiAudience(t *testing.T) {
	for _, c := range []struct{ asked, existing, want string }{
		{"", "", "space"}, {"", "platform", "platform"}, {"platform", "", "platform"}, {"SPACE", "platform", "space"},
	} {
		if got, err := appuiAudience(c.asked, c.existing); err != nil || got != c.want {
			t.Fatalf("%+v: %q %v", c, got, err)
		}
	}
	if _, err := appuiAudience("public", ""); err == nil {
		t.Fatal("unknown audience accepted")
	}
}

// An app the agents built and published in a space is offered to the space's
// members as a platform frontend; a platform's person using it acts as the
// publisher, while the app is still that platform's frontend.
func TestAPlatformsPeopleUseASpaceAppAsItsPublisher(t *testing.T) {
	s, ctx := appAccessHarness(t)
	publisher := directPerson(t, s, ctx, "00000000000000010000000000000001", "founder")
	shopper := directPerson(t, s, ctx, "00000000000000010000000000000002", "shopper")
	sp, err := s.CreateSpace(ctx, publisher, "studio", "")
	if err != nil {
		t.Fatal(err)
	}
	dir := "/workspace/appui/store"
	if _, err := s.IssueAppKey(ctx, sp.ID, identity.ID{}, publisher, dir, "Store"); err != nil {
		t.Fatal(err)
	}
	p := appPreview(t, s, ctx, sp.ID, "Store")
	wiring, _ := json.Marshal(models.Wiring{Agents: []models.WiredAgent{{ID: "a1", Name: "Research"}}, Apps: []models.WiredApp{}})
	if err := s.BindAppKey(ctx, sp.ID, dir, p.ID, appKeyMeta{UI: "elpian", Entry: "elpian/app.js", Kind: "app", Audience: "platform", Wiring: string(wiring)}); err != nil {
		t.Fatal(err)
	}

	apps, err := s.FrontendApps(ctx, publisher)
	if err != nil || len(apps) != 1 || apps[0].ProxyID != p.ID.String() || apps[0].UI != "elpian" || apps[0].Audience != "platform" ||
		!apps[0].Wiring.AllowsAgent("Research") || apps[0].SpaceName != "studio" {
		t.Fatalf("frontend apps: %+v %v", apps, err)
	}
	if apps, _ := s.FrontendApps(ctx, shopper); len(apps) != 0 {
		t.Fatalf("someone outside the space was offered its apps: %+v", apps)
	}
	if _, err := s.FrontendAppFor(ctx, p.ID.String(), shopper); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("someone outside the space published its app: %v", err)
	}
	if app, err := s.FrontendAppFor(ctx, p.ID.String(), publisher); err != nil || app.Entry != "elpian/app.js" {
		t.Fatalf("publish check: %+v %v", app, err)
	}
	plain := appPreview(t, s, ctx, sp.ID, "Hand-made")
	if _, err := s.FrontendAppFor(ctx, plain.ID.String(), publisher); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("a preview no agent built was accepted: %v", err)
	}

	pf := &models.PlatformFrontend{PlatformID: "pf1", Slug: "acme", Name: "Acme", ProxyID: p.ID.String(),
		SpaceID: sp.ID.String(), Publisher: publisher.String(), Wiring: models.Wiring{Agents: []models.WiredAgent{{ID: "a1", Name: "Research"}}}}
	s.frontendLookup = func(_ context.Context, ref string, viewer identity.ID) (*models.PlatformFrontend, error) {
		if ref != "pf1" {
			return nil, errs.NotFound("platform")
		}
		if viewer != shopper {
			return nil, errs.Permission("not on this platform")
		}
		return pf, nil
	}
	token, err := s.PlatformUserToken(p, shopper, "pf1")
	if err != nil {
		t.Fatal(err)
	}
	who, err := s.AppCaller(ctx, token)
	if err != nil {
		t.Fatal(err)
	}
	if who.Payer.ID != publisher || who.User == nil || who.User.ID != shopper || who.Platform == nil || who.Platform.Slug != "acme" ||
		who.Via != "platform Acme · app Store for @shopper" {
		t.Fatalf("acts as %+v", who)
	}
	// Someone the platform no longer lets in.
	other, _ := s.PlatformUserToken(p, publisher, "pf1")
	if _, err := s.AppCaller(ctx, other); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("someone off the platform: %v", err)
	}
	// Another app became the frontend: the old app's tokens stop.
	pf.ProxyID = plain.ID.String()
	if _, err := s.AppCaller(ctx, token); errs.CodeOf(err) != errs.CodeUnauthenticated {
		t.Fatalf("a replaced frontend's token worked: %v", err)
	}
	pf.ProxyID = p.ID.String()
	// The publisher left the space: nobody to run as.
	var mems []struct {
		ID identity.ID `db:"id"`
	}
	_ = s.R.List(ctx, "memberships", database.Filter{Equal: map[string]any{"member_id": publisher.String()}}, &mems)
	for _, m := range mems {
		_ = s.R.Delete(ctx, "memberships", m.ID)
	}
	if _, err := s.AppCaller(ctx, token); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a publisher who left still pays: %v", err)
	}
}
