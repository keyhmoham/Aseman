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
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

const (
	pAnn    = "00000000000000010000000000000a11"
	pBob    = "00000000000000010000000000000b0b"
	pCarol  = "00000000000000010000000000000c0c"
	pSpaceA = "0000000000000001000000000000a001"
)

func pluginHarness(t *testing.T) (*Service, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range append(append(dbmodel.Models(), models.Models()...), pluginModel()) {
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
	put := func(p Plugin) {
		p.CreatedAt, p.UpdatedAt = time.Now().UTC(), time.Now().UTC()
		if err := db.Create(ctx, pluginsTable, p.ID, &p); err != nil {
			t.Fatal(err)
		}
	}
	put(Plugin{ID: "acct", Owner: pAnn, Scope: PluginAccount, Name: "Budget", Placement: PlacementPage, Status: pluginInstalled,
		Preview: "/v1/proxy/0123456789abcdef0123456789abcdef/", Entry: "elpian/app.js", AppID: "budget"})
	put(Plugin{ID: "space", Owner: pAnn, Scope: PluginSpace, SpaceID: pSpaceA, Name: "Board", Placement: PlacementChat, Status: pluginInstalled,
		Preview: "/v1/proxy/abcdef0123456789abcdef0123456789/", Entry: "elpian/app.js", AppID: "board"})
	put(Plugin{ID: "gone", Owner: pAnn, Scope: PluginSpace, SpaceID: pSpaceA, Name: "Old", Status: pluginRemoved,
		Preview: "/v1/proxy/fedcba9876543210fedcba9876543210/", Entry: "elpian/app.js"})
	return s, ctx
}

func TestPluginListShowsMineAndMySpaces(t *testing.T) {
	s, ctx := pluginHarness(t)
	list := func(who string, body string) ([]string, error) {
		resp, err := s.pluginList(ctx, &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(who), Kind: "user"}, Body: []byte(body)})
		if err != nil {
			return nil, err
		}
		var out struct{ Plugins []Plugin }
		_ = json.Unmarshal(resp.Body, &out)
		ids := []string{}
		for _, p := range out.Plugins {
			ids = append(ids, p.ID)
		}
		return ids, nil
	}
	if ids, _ := list(pAnn, `{"space":"`+pSpaceA+`"}`); len(ids) != 2 {
		t.Fatalf("ann sees %v", ids)
	}
	if ids, _ := list(pAnn, `{"space":"`+pSpaceA+`","removed":true}`); len(ids) != 3 {
		t.Fatalf("ann with removed sees %v", ids)
	}
	if ids, _ := list(pBob, `{"space":"`+pSpaceA+`"}`); len(ids) != 1 || ids[0] != "space" {
		t.Fatalf("bob sees %v", ids)
	}
	if _, err := list(pCarol, `{"space":"`+pSpaceA+`"}`); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a non-member lists a space's plugins: %v", err)
	}
}

func TestOnlyTheOwnerRemovesAnAppWidePlugin(t *testing.T) {
	s, ctx := pluginHarness(t)
	remove := s.pluginSetStatus(pluginRemoved)
	if _, err := remove(ctx, &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(pBob), Kind: "user"}, Body: []byte(`{"plugin":"acct"}`)}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("someone else removed it: %v", err)
	}
	if _, err := remove(ctx, &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(pAnn), Kind: "user"}, Body: []byte(`{"plugin":"acct"}`)}); err != nil {
		t.Fatal(err)
	}
	restore := s.pluginSetStatus(pluginInstalled)
	if _, err := restore(ctx, &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(pAnn), Kind: "user"}, Body: []byte(`{"plugin":"acct"}`)}); err != nil {
		t.Fatal(err)
	}
	p, err := s.plugin(ctx, "acct")
	if err != nil || p.Status != pluginInstalled || p.Preview == "" {
		t.Fatalf("restored = %+v, %v", p, err)
	}
}

func TestRegisterAppPluginCreatesAndUpdates(t *testing.T) {
	s, ctx := pluginHarness(t)
	// Creating a real tool bot needs more of the tools service; exercise
	// validation and update of an existing app_id row instead.
	p, err := s.RegisterAppPlugin(ctx, pAnn, "", "Budget", "updated", PlacementDesk, PluginUIElpian,
		"/v1/proxy/0123456789abcdef0123456789abcdef/", "elpian/app.js", "budget", "agent")
	if err != nil {
		t.Fatal(err)
	}
	if p.ID != "acct" || p.Placement != PlacementDesk || p.Name != "Budget" {
		t.Fatalf("update by app_id = %+v", p)
	}
	if _, err := s.RegisterAppPlugin(ctx, pAnn, "", "X", "", PlacementChat, PluginUIElpian, "not-a-proxy", "", "new", ""); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("bad preview = %v", err)
	}
	if _, err := s.RegisterAppPlugin(ctx, pAnn, "", "X", "", "dock", PluginUIElpian, "/v1/proxy/0123456789abcdef0123456789abcdef/", "", "new", ""); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("bad placement = %v", err)
	}
}
