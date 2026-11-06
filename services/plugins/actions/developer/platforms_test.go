package developer

import (
	"testing"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/tenancy"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

func TestCreatePlatformAndMainAccessBridge(t *testing.T) {
	f := harness(t)
	sc := f.personal(t)
	view, err := f.s.CreatePlatform(f.ctx, sc, "Acme Labs", "acme")
	if err != nil || view.Slug != "acme" || view.MainAccess {
		t.Fatalf("create: %v %+v", err, view)
	}
	if _, err := f.s.CreatePlatform(f.ctx, sc, "Again", "acme"); errs.CodeOf(err) != errs.CodeAlreadyExists {
		t.Fatalf("slugs are unique: %v", err)
	}
	if _, err := f.s.CreatePlatform(f.ctx, sc, "X", "main"); err == nil {
		t.Fatal("reserved slug")
	}

	got, err := f.s.OrgPlatform(f.ctx, sc.Org, "")
	if err != nil || got == nil || got.Slug != "acme" {
		t.Fatalf("of org: %v %+v", err, got)
	}

	bridged, _ := helper.BridgedPlatforms(f.ctx, f.s.R)
	if bridged[view.ID] {
		t.Fatal("isolated by default")
	}
	if tenancy.Sees(tenancy.Main, view.ID, bridged) {
		t.Fatal("main must not see an isolated platform")
	}
	if tenancy.Sees(view.ID, tenancy.Main, bridged) {
		t.Fatal("isolated platform must not see main")
	}

	opened, err := f.s.SetMainAccess(f.ctx, "acme", true)
	if err != nil || !opened.MainAccess {
		t.Fatalf("bridge: %v %+v", err, opened)
	}
	bridged, _ = helper.BridgedPlatforms(f.ctx, f.s.R)
	if !tenancy.Sees(tenancy.Main, view.ID, bridged) || !tenancy.Sees(view.ID, tenancy.Main, bridged) {
		t.Fatal("bridge is both ways with main only")
	}
	if tenancy.Sees(view.ID, "other", bridged) {
		t.Fatal("platforms never see each other through the bridge")
	}

	users, err := f.s.PlatformUsers(f.ctx, sc, "", "", 10)
	if err != nil || len(users) != 0 {
		t.Fatalf("no local users yet: %v %+v", err, users)
	}
	stats, err := f.s.PlatformStats(f.ctx, sc, "")
	if err != nil || stats["users"] != 0 {
		t.Fatalf("stats: %v %+v", err, stats)
	}
}

// An organization may own several platforms; actions on one name it.
func TestOrganizationHasSeveralPlatforms(t *testing.T) {
	f := harness(t)
	sc := f.personal(t)
	a, err := f.s.CreatePlatform(f.ctx, sc, "Acme", "acme")
	if err != nil {
		t.Fatal(err)
	}
	b, err := f.s.CreatePlatform(f.ctx, sc, "Acme Shop", "acme-shop")
	if err != nil || b.ID == a.ID {
		t.Fatalf("a second platform: %+v %v", b, err)
	}
	list, err := f.s.ListPlatforms(f.ctx, sc)
	if err != nil || len(list) != 2 || list[0].Slug != "acme" || list[1].Slug != "acme-shop" {
		t.Fatalf("list: %+v %v", list, err)
	}
	if _, err := f.s.OrgPlatform(f.ctx, sc.Org, ""); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("no ref with several platforms: %v", err)
	}
	if _, err := f.s.PlatformStats(f.ctx, sc, ""); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("stats without naming one: %v", err)
	}
	renamed, err := f.s.RenamePlatform(f.ctx, sc, "acme-shop", "The Shop")
	if err != nil || renamed.ID != b.ID || renamed.Name != "The Shop" {
		t.Fatalf("rename by slug: %+v %v", renamed, err)
	}
	if got, err := f.s.OrgPlatform(f.ctx, sc.Org, a.ID); err != nil || got.Name != "Acme" {
		t.Fatalf("the other is untouched: %+v %v", got, err)
	}

	// Another organization's platform is not this one's to manage.
	other := f.person(t, f.s.R.DB, "mallory")
	osc, _ := f.s.Scope(f.ctx, other, "")
	if _, err := f.s.CreatePlatform(f.ctx, osc, "Theirs", "theirs"); err != nil {
		t.Fatal(err)
	}
	if err := f.s.DeletePlatform(f.ctx, sc, "theirs"); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("delete another org's platform: %v", err)
	}

	if err := f.s.DeletePlatform(f.ctx, sc, "acme"); err != nil {
		t.Fatal(err)
	}
	if got, err := f.s.OrgPlatform(f.ctx, sc.Org, ""); err != nil || got == nil || got.ID.String() != b.ID {
		t.Fatalf("one platform left: %+v %v", got, err)
	}
}

// A key is bound to one of its organization's platforms: what it makes on
// the developer host joins that one.
func TestKeyIsBoundToAPlatform(t *testing.T) {
	f := harness(t)
	sc := f.personal(t)
	a, _ := f.s.CreatePlatform(f.ctx, sc, "Acme", "acme")
	if _, _, err := f.s.CreateKey(f.ctx, f.me, sc, KeyInput{Name: "plain"}); err != nil {
		t.Fatal(err)
	}
	keys, _ := f.s.Keys(f.ctx, sc)
	if p, err := f.s.KeyPlatform(f.ctx, mustKey(t, f, keys[0].ID)); err != nil || p == nil || p.ID.String() != a.ID {
		t.Fatalf("an unbound key of an organization with one platform uses it: %+v %v", p, err)
	}
	b, _ := f.s.CreatePlatform(f.ctx, sc, "Shop", "shop")
	if _, err := f.s.KeyPlatform(f.ctx, mustKey(t, f, keys[0].ID)); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("an unbound key with several platforms: %v", err)
	}
	shop := "shop"
	view, err := f.s.UpdateKey(f.ctx, sc, keys[0].ID, KeyInput{Name: "plain", Platform: &shop})
	if err != nil || view.Platform != b.ID {
		t.Fatalf("bind: %+v %v", view, err)
	}
	if p, err := f.s.KeyPlatform(f.ctx, mustKey(t, f, keys[0].ID)); err != nil || p.ID.String() != b.ID {
		t.Fatalf("bound key: %+v %v", p, err)
	}
	if view, err := f.s.UpdateKey(f.ctx, sc, keys[0].ID, KeyInput{Name: "renamed"}); err != nil || view.Platform != b.ID {
		t.Fatalf("an update that names no platform keeps the binding: %+v %v", view, err)
	}
	nope := "nope"
	if _, _, err := f.s.CreateKey(f.ctx, f.me, sc, KeyInput{Name: "x", Platform: &nope}); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("bound to an unknown platform: %v", err)
	}
}

func mustKey(t *testing.T, f *fixture, id string) models.Key {
	t.Helper()
	k, err := f.s.loadKey(f.ctx, f.personal(t), id)
	if err != nil {
		t.Fatal(err)
	}
	return *k
}
