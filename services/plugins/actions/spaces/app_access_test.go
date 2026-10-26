package spaces

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/bots"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

func appAccessHarness(t *testing.T) (*Service, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(),
		Env: map[string]string{"node_private_key": strings.Repeat("ab", 64)}})
	s := NewService(k, &repo.Repo{DB: db}, logger.Global())
	s.Bots = bots.NewService(k, s.R, logger.Global())
	return s, ctx
}

func appPreview(t *testing.T, s *Service, ctx context.Context, spaceID identity.ID, title string) *proxy.Proxy {
	t.Helper()
	pid, _ := identity.New(s.K.NodeID())
	p := &proxy.Proxy{Entity: entity.Entity{ID: pid}, SpaceID: spaceID, Port: 8787, Title: title, TargetURL: "http://sbx"}
	if err := s.R.CreateID(ctx, "proxies", pid, p); err != nil {
		t.Fatal(err)
	}
	return p
}

// The person using an app is who its server acts for with the request's
// token, in that app's space only, and only while the token is fresh.
func TestAnAppServerActsForThePersonUsingIt(t *testing.T) {
	s, ctx := appAccessHarness(t)
	owner := directPerson(t, s, ctx, "00000000000000010000000000000001", "owner")
	viewer := directPerson(t, s, ctx, "00000000000000010000000000000002", "viewer")
	sp, err := s.CreateSpace(ctx, owner, "shop", "")
	if err != nil {
		t.Fatal(err)
	}
	p := appPreview(t, s, ctx, sp.ID, "Orders")
	token, err := s.AppUserToken(p, viewer)
	if err != nil {
		t.Fatal(err)
	}
	// Not a member yet: nothing to act for.
	if _, err := s.AppCaller(ctx, token); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a non-member's token worked: %v", err)
	}
	mid, _ := identity.New(s.K.NodeID())
	if err := s.R.CreateID(ctx, "memberships", mid, &membership.Membership{Entity: entity.Entity{ID: mid},
		SpaceID: sp.ID, MemberID: viewer, RoomID: identity.ID{}, Role: membership.RoleMember}); err != nil {
		t.Fatal(err)
	}
	who, err := s.AppCaller(ctx, token)
	if err != nil {
		t.Fatal(err)
	}
	if who.Payer.ID != viewer || who.Proxy.ID != p.ID || who.Via != "app Orders" {
		t.Fatalf("acts as %v for %v via %q", who.Payer.ID, who.Proxy.ID, who.Via)
	}
	body, sig, _ := strings.Cut(token, ".")
	if _, err := s.AppCaller(ctx, body+"x."+sig); errs.CodeOf(err) != errs.CodeUnauthenticated {
		t.Fatalf("a tampered token worked: %v", err)
	}
	if _, err := s.AppCaller(ctx, "nonsense"); errs.CodeOf(err) != errs.CodeUnauthenticated {
		t.Fatalf("garbage worked: %v", err)
	}
	// Expired.
	stale, _ := s.signAppClaims(appUserClaims{Proxy: p.ID.String(), User: viewer.String(), Exp: time.Now().Add(-time.Minute).Unix()})
	if _, err := s.AppCaller(ctx, stale); errs.CodeOf(err) != errs.CodeUnauthenticated {
		t.Fatalf("an expired token worked: %v", err)
	}
	// The preview is gone: so is the token.
	if err := s.R.Delete(ctx, "proxies", p.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AppCaller(ctx, token); err == nil {
		t.Fatal("a deleted preview's token worked")
	}
}

// Background work uses the app's key: it acts for the person who asked for
// the app, rotates on rebuild and ends with the app's preview.
func TestAnAppsKeyActsForThePersonWhoAskedForIt(t *testing.T) {
	s, ctx := appAccessHarness(t)
	owner := directPerson(t, s, ctx, "00000000000000010000000000000001", "owner")
	sp, err := s.CreateSpace(ctx, owner, "shop", "")
	if err != nil {
		t.Fatal(err)
	}
	dir := "/workspace/appui/orders"
	key, err := s.IssueAppKey(ctx, sp.ID, identity.ID{}, owner, dir, "Orders")
	if err != nil {
		t.Fatal(err)
	}
	who, err := s.AppCaller(ctx, key)
	if err != nil {
		t.Fatal(err)
	}
	if who.Payer.ID != owner || who.Proxy.SpaceID != sp.ID || who.Via != "app Orders (background)" {
		t.Fatalf("background key acts as %v in %v via %q", who.Payer.ID, who.Proxy.SpaceID, who.Via)
	}
	var stored []AppKey
	_ = s.R.List(ctx, "app_keys", database.Filter{Equal: map[string]any{"app_id": dir}}, &stored)
	if len(stored) != 1 || strings.Contains(key, stored[0].Hash) || stored[0].Hash == "" {
		t.Fatalf("the key is not stored hashed: %+v", stored)
	}

	p := appPreview(t, s, ctx, sp.ID, "Orders")
	if err := s.BindAppKey(ctx, sp.ID, dir, p.ID); err != nil {
		t.Fatal(err)
	}
	if who, err = s.AppCaller(ctx, key); err != nil || who.Proxy.ID != p.ID {
		t.Fatalf("bound key: %v %v", who, err)
	}
	rotated, err := s.IssueAppKey(ctx, sp.ID, identity.ID{}, owner, dir, "Orders")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.AppCaller(ctx, key); err == nil {
		t.Fatal("the old key still works after a rebuild")
	}
	if _, err := s.AppCaller(ctx, rotated); err != nil {
		t.Fatalf("the new key: %v", err)
	}
	stored = nil
	_ = s.R.List(ctx, "app_keys", database.Filter{Equal: map[string]any{"app_id": dir}}, &stored)
	if len(stored) != 1 {
		t.Fatalf("a rebuild left %d keys", len(stored))
	}
	if err := s.R.Delete(ctx, "proxies", p.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AppCaller(ctx, rotated); err == nil {
		t.Fatal("the key outlived the app's preview")
	}
	if _, err := s.AppCaller(ctx, strings.Replace(rotated, ".", ".x", 1)); err == nil {
		t.Fatal("a wrong secret worked")
	}
}
