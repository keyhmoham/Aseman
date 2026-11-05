package developer

import (
	"testing"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/tenancy"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

func TestCreatePlatformAndMainAccessBridge(t *testing.T) {
	f := harness(t)
	sc := f.personal(t)
	view, err := f.s.CreatePlatform(f.ctx, sc, "Acme Labs", "acme")
	if err != nil || view.Slug != "acme" || view.MainAccess {
		t.Fatalf("create: %v %+v", err, view)
	}
	if _, err := f.s.CreatePlatform(f.ctx, sc, "Again", "acme-2"); errs.CodeOf(err) != errs.CodeAlreadyExists {
		t.Fatalf("one platform per org: %v", err)
	}
	if _, err := f.s.CreatePlatform(f.ctx, sc, "X", "main"); err == nil {
		t.Fatal("reserved slug")
	}

	got, err := f.s.PlatformOfOrg(f.ctx, sc.Org)
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

	users, err := f.s.PlatformUsers(f.ctx, sc, "", 10)
	if err != nil || len(users) != 0 {
		t.Fatalf("no local users yet: %v %+v", err, users)
	}
	stats, err := f.s.PlatformStats(f.ctx, sc)
	if err != nil || stats["users"] != 0 {
		t.Fatalf("stats: %v %+v", err, stats)
	}
}
