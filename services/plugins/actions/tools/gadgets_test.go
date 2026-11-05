package tools

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/actions/tools/models"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

const (
	pAnn    = "00000000000000010000000000000a11"
	pBob    = "00000000000000010000000000000b0b"
	pCarol  = "00000000000000010000000000000c0c"
	pSpaceA = "0000000000000001000000000000a001"
)

func gadgetHarness(t *testing.T) (*Service, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range append(append(dbmodel.Models(), models.Models()...), gadgetModel()) {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	r := &repo.Repo{DB: db}
	n := 0
	member := func(space, who string) {
		n++
		id := identity.MustParse("00000000000000010000000000" + []string{"", "00e001", "00e002", "00e003"}[n])
		m := &membership.Membership{Entity: entity.Entity{ID: id, CreatedAt: time.Now().UTC()}, SpaceID: identity.MustParse(space),
			MemberID: identity.MustParse(who), Role: membership.RoleMember, JoinedAt: time.Now().UTC()}
		if err := r.CreateID(ctx, "memberships", id, m); err != nil {
			t.Fatal(err)
		}
	}
	member(pSpaceA, pAnn)
	member(pSpaceA, pBob)
	s := &Service{R: r}
	put := func(p Gadget) {
		p.CreatedAt, p.UpdatedAt = time.Now().UTC(), time.Now().UTC()
		if err := db.Create(ctx, gadgetsTable, p.ID, &p); err != nil {
			t.Fatal(err)
		}
	}
	put(Gadget{ID: "acct", Owner: pAnn, Scope: GadgetAccount, Name: "Budget", Placement: PlacementPage, Status: gadgetInstalled,
		Preview: "/v1/proxy/0123456789abcdef0123456789abcdef/", Entry: "elpian/app.js", AppID: "budget"})
	put(Gadget{ID: "space", Owner: pAnn, Scope: GadgetSpace, SpaceID: pSpaceA, Name: "Board", Placement: PlacementChat, Status: gadgetInstalled,
		Preview: "/v1/proxy/abcdef0123456789abcdef0123456789/", Entry: "elpian/app.js", AppID: "board"})
	put(Gadget{ID: "gone", Owner: pAnn, Scope: GadgetSpace, SpaceID: pSpaceA, Name: "Old", Status: gadgetRemoved,
		Preview: "/v1/proxy/fedcba9876543210fedcba9876543210/", Entry: "elpian/app.js"})
	return s, ctx
}

func TestGadgetListShowsMineAndMySpaces(t *testing.T) {
	s, ctx := gadgetHarness(t)
	list := func(who string, body string) ([]string, error) {
		resp, err := s.gadgetList(ctx, &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(who), Kind: "user"}, Body: []byte(body)})
		if err != nil {
			return nil, err
		}
		var out struct{ Gadgets []Gadget }
		_ = json.Unmarshal(resp.Body, &out)
		ids := []string{}
		for _, p := range out.Gadgets {
			ids = append(ids, p.ID)
		}
		return ids, nil
	}
	if ids, _ := list(pAnn, `{"space":"`+pSpaceA+`"}`); len(ids) != 2 {
		// account + space installed; the removed "gone" gadget stays hidden
		t.Fatalf("ann sees %v", ids)
	}
	if ids, _ := list(pBob, `{"space":"`+pSpaceA+`"}`); len(ids) != 1 || ids[0] != "space" {
		t.Fatalf("bob sees %v", ids)
	}
	if _, err := list(pCarol, `{"space":"`+pSpaceA+`"}`); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a non-member lists a space's gadgets: %v", err)
	}
}

func TestOnlyTheOwnerRemovesAnAppWideGadget(t *testing.T) {
	s, ctx := gadgetHarness(t)
	if _, err := s.gadgetRemove(ctx, &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(pBob), Kind: "user"}, Body: []byte(`{"gadget":"acct"}`)}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("someone else removed it: %v", err)
	}
	if _, err := s.gadgetRemove(ctx, &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(pAnn), Kind: "bot"}, Body: []byte(`{"gadget":"acct"}`)}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a bot removed it: %v", err)
	}
	if _, err := s.gadgetRemove(ctx, &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(pAnn), Kind: "user"}, Body: []byte(`{"gadget":"acct"}`)}); err != nil {
		t.Fatal(err)
	}
	p, err := s.gadget(ctx, "acct")
	if err != nil || p.Status != gadgetRemoved {
		t.Fatalf("removed = %+v, %v", p, err)
	}
}

func TestRegisterAppGadgetCreatesAndUpdates(t *testing.T) {
	s, ctx := gadgetHarness(t)
	// Creating a real tool bot needs more of the tools service; exercise
	// validation and update of an existing app_id row instead.
	p, err := s.RegisterAppGadget(ctx, pAnn, "", "Budget", "updated", PlacementDesk, GadgetUIElpian,
		"/v1/proxy/0123456789abcdef0123456789abcdef/", "elpian/app.js", "budget", "agent")
	if err != nil {
		t.Fatal(err)
	}
	if p.ID != "acct" || p.Placement != PlacementDesk || p.Name != "Budget" {
		t.Fatalf("update by app_id = %+v", p)
	}
	if _, err := s.RegisterAppGadget(ctx, pAnn, "", "X", "", PlacementChat, GadgetUIElpian, "not-a-proxy", "", "new", ""); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("bad preview = %v", err)
	}
	if _, err := s.RegisterAppGadget(ctx, pAnn, "", "X", "", "dock", GadgetUIElpian, "/v1/proxy/0123456789abcdef0123456789abcdef/", "", "new", ""); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("bad placement = %v", err)
	}
}

func TestMigrateGadgetsFromPluginsCopiesLegacyRows(t *testing.T) {
	db := memory.New(logger.Global())
	ctx := context.Background()
	for _, m := range []database.Model{gadgetModel(), legacyPluginsModel()} {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	s := &Service{R: &repo.Repo{DB: db}}
	legacy := Gadget{
		ID: "legacy1", Owner: pAnn, Scope: GadgetAccount, Name: "Old", Placement: PlacementPage,
		Status: gadgetInstalled, Preview: "/v1/proxy/0123456789abcdef0123456789abcdef/",
		CreatedAt: time.Now().UTC(), UpdatedAt: time.Now().UTC(),
	}
	if err := db.Create(ctx, legacyPluginsTable, legacy.ID, &legacy); err != nil {
		t.Fatal(err)
	}
	// Already on the new table — must not be overwritten.
	kept := Gadget{
		ID: "kept", Owner: pAnn, Scope: GadgetAccount, Name: "Kept", Placement: PlacementChat,
		Status: gadgetInstalled, Preview: "/v1/proxy/abcdef0123456789abcdef0123456789/",
		CreatedAt: time.Now().UTC(), UpdatedAt: time.Now().UTC(),
	}
	if err := db.Create(ctx, gadgetsTable, kept.ID, &kept); err != nil {
		t.Fatal(err)
	}
	if err := db.Create(ctx, legacyPluginsTable, kept.ID, &Gadget{
		ID: kept.ID, Owner: pAnn, Scope: GadgetAccount, Name: "Stale", Placement: PlacementChat,
		Status: gadgetInstalled, Preview: kept.Preview, CreatedAt: kept.CreatedAt, UpdatedAt: kept.UpdatedAt,
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.migrateGadgetsFromPlugins(ctx); err != nil {
		t.Fatal(err)
	}
	var got Gadget
	if err := db.Get(ctx, gadgetsTable, "legacy1", &got); err != nil || got.Name != "Old" {
		t.Fatalf("copied = %+v, %v", got, err)
	}
	if err := db.Get(ctx, gadgetsTable, "kept", &got); err != nil || got.Name != "Kept" {
		t.Fatalf("existing overwritten = %+v, %v", got, err)
	}
	// Second pass is a no-op.
	if err := s.migrateGadgetsFromPlugins(ctx); err != nil {
		t.Fatal(err)
	}
}
