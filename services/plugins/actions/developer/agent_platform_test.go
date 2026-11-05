package developer

import (
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/developer/models"
)

// An agent sets the person up as them: an organization (made once, reused
// after), its platform, a developer key for an app's server, and the app as
// the platform's frontend.
func TestAgentsSetUpAPlatformForThePerson(t *testing.T) {
	f := harness(t)
	f.s.Frontends = fakeFrontends{apps: map[string]models.FrontendApp{"p1": {ProxyID: "p1", SpaceID: "s1", Title: "Store", UI: "web"}}}

	if _, err := f.s.SetupPlatform(f.ctx, identity.ID{}, "", "Acme Labs", "Acme", "acme"); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("set up for nobody: %v", err)
	}
	if _, err := f.s.PublishFrontendAs(f.ctx, f.me, "", "p1"); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("published before a platform exists: %v", err)
	}
	setup, err := f.s.SetupPlatform(f.ctx, f.me, "", "Acme Labs", "Acme", "acme")
	if err != nil || !setup.OrgCreated || !setup.PlatformCreated || setup.Org.Kind != "team" || setup.Platform.Slug != "acme" {
		t.Fatalf("setup: %+v %v", setup, err)
	}
	again, err := f.s.SetupPlatform(f.ctx, f.me, "", "acme labs", "Other", "other")
	if err != nil || again.OrgCreated || again.PlatformCreated || again.Platform.ID != setup.Platform.ID {
		t.Fatalf("a second setup must reuse the organization and its platform: %+v %v", again, err)
	}
	orgs, _ := f.s.Orgs(f.ctx, f.me)
	if len(orgs) != 2 {
		t.Fatalf("one team organization, made once: %+v", orgs)
	}

	access, err := f.s.AppDeveloperKey(f.ctx, f.me, "", "Store", true, "")
	if err != nil || !strings.HasPrefix(access.Secret, KeyPrefix) || access.Platform != "acme" || access.Org != setup.Org.ID {
		t.Fatalf("access: %+v %v", access, err)
	}
	p, err := f.s.Authenticate(f.ctx, access.Secret)
	if err != nil || p.Key.CreatedBy != f.me || p.Org.String() != setup.Org.ID {
		t.Fatalf("the key acts as the person in their organization: %+v %v", p, err)
	}
	perms := p.Permissions
	if perms.Platform != LevelWrite || perms.Models != LevelRead || perms.Chat != LevelWrite || perms.Computers != LevelNone || perms.Files != LevelNone {
		t.Fatalf("an app key gets models, chat and the platform collection only: %+v", perms)
	}
	replaced, err := f.s.AppDeveloperKey(f.ctx, f.me, "", "Store", false, access.KeyID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.Authenticate(f.ctx, access.Secret); err == nil {
		t.Fatal("the replaced key still works")
	}
	if p, err := f.s.Authenticate(f.ctx, replaced.Secret); err != nil || p.Permissions.Platform != LevelNone {
		t.Fatalf("the new key (no platform collection): %+v %v", p, err)
	}

	view, err := f.s.PublishFrontendAs(f.ctx, f.me, "", "p1")
	if err != nil || view.Frontend == nil || view.Frontend.URL != "/v1/platforms/acme/app/" {
		t.Fatalf("publish: %+v %v", view, err)
	}

	// A second platform: the person must say which.
	if _, err := f.s.SetupPlatform(f.ctx, f.me, PersonalOrg, "", "Mine", "mine"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.PublishFrontendAs(f.ctx, f.me, "", "p1"); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("which platform is ambiguous: %v", err)
	}
	if view, err := f.s.PublishFrontendAs(f.ctx, f.me, PersonalOrg, "p1"); err != nil || view.Slug != "mine" {
		t.Fatalf("named platform: %+v %v", view, err)
	}

	// Someone else's organization is not theirs to use.
	other := f.person(t, f.s.R.DB, "mallory")
	if _, err := f.s.AppDeveloperKey(f.ctx, other, setup.Org.ID, "x", true, ""); err == nil {
		t.Fatal("a key in someone else's organization")
	}
}
