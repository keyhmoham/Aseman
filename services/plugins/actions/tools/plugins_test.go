package tools

import (
	"context"
	"encoding/json"
	"sync"
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
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

const (
	pAnn    = "00000000000000010000000000000a11"
	pBob    = "00000000000000010000000000000b0b"
	pCarol  = "00000000000000010000000000000c0c"
	pSpaceA = "0000000000000001000000000000a001"
	pSpaceB = "0000000000000001000000000000b001"
)

type pluginRouter struct {
	api.ActionRouter
	mu    sync.Mutex
	calls []map[string]any
}

func (r *pluginRouter) Dispatch(_ context.Context, ns, name string, req *api.ActionRequest) (*api.ActionResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var body map[string]any
	_ = json.Unmarshal(req.Body, &body)
	r.calls = append(r.calls, map[string]any{"name": ns + "." + name, "caller": req.Caller.ID.String(), "body": body})
	return &api.ActionResponse{Status: 200, Body: []byte(`{"ok":true}`)}, nil
}

type pluginKernel struct {
	api.Kernel
	router *pluginRouter
}

func (k pluginKernel) Actions() api.ActionRouter { return k.router }

func pluginHarness(t *testing.T) (*Service, *pluginRouter, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range append(dbmodel.Models(), pluginModel()) {
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
	router := &pluginRouter{}
	s := &Service{K: pluginKernel{router: router}, R: r}
	put := func(p Plugin) {
		p.CreatedAt, p.UpdatedAt = time.Now().UTC(), time.Now().UTC()
		if err := db.Create(ctx, pluginsTable, p.ID, &p); err != nil {
			t.Fatal(err)
		}
	}
	put(Plugin{ID: "acct", Owner: pAnn, Scope: PluginAccount, Name: "Budget", Placement: PlacementPage, Status: pluginInstalled,
		Permissions: []string{"spaces.message_list", "themes.*"}})
	put(Plugin{ID: "admin", Owner: pAnn, Scope: PluginAccount, Name: "Sneaky", Status: pluginInstalled, Permissions: []string{"admin.*", "finance.transfer"}})
	put(Plugin{ID: "space", Owner: pAnn, Scope: PluginSpace, SpaceID: pSpaceA, Name: "Board", Placement: PlacementPanel, Status: pluginInstalled,
		Permissions: []string{"spaces.message_list", "themes.apply"}})
	put(Plugin{ID: "gone", Owner: pAnn, Scope: PluginSpace, SpaceID: pSpaceA, Name: "Old", Status: pluginRemoved, Permissions: []string{"spaces.message_list"}})
	return s, router, ctx
}

func call(s *Service, ctx context.Context, who string, body map[string]any) (*api.ActionResponse, error) {
	raw, _ := json.Marshal(body)
	return s.pluginCall(ctx, &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(who), Kind: "user"}, Body: raw})
}

func TestAnAppWidePluginActsAsItsOwnerWithinWhatItDeclared(t *testing.T) {
	s, router, ctx := pluginHarness(t)
	if _, err := call(s, ctx, pAnn, map[string]any{"plugin": "acct", "namespace": "themes", "action": "apply", "body": map[string]any{"theme": "sky"}}); err != nil {
		t.Fatal(err)
	}
	if len(router.calls) != 1 || router.calls[0]["name"] != "themes.apply" || router.calls[0]["caller"] != pAnn {
		t.Fatalf("dispatched %+v", router.calls)
	}
	if _, err := call(s, ctx, pAnn, map[string]any{"plugin": "acct", "namespace": "spaces", "action": "message_send"}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("an undeclared action = %v", err)
	}
	if _, err := call(s, ctx, pBob, map[string]any{"plugin": "acct", "namespace": "themes", "action": "apply"}); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("someone else's app-wide plugin = %v", err)
	}
	for _, action := range []string{"health", "transfer"} {
		ns := "admin"
		if action == "transfer" {
			ns = "finance"
		}
		if _, err := call(s, ctx, pAnn, map[string]any{"plugin": "admin", "namespace": ns, "action": action}); errs.CodeOf(err) != errs.CodePermission {
			t.Fatalf("%s.%s declared but outside the policy = %v", ns, action, err)
		}
	}
	if len(router.calls) != 1 {
		t.Fatalf("refused calls were dispatched: %+v", router.calls)
	}
}

func TestASpacePluginWorksForItsMembersInsideItsSpaceOnly(t *testing.T) {
	s, router, ctx := pluginHarness(t)
	if _, err := call(s, ctx, pBob, map[string]any{"plugin": "space", "namespace": "spaces", "action": "message_list", "body": map[string]any{"room": "r1"}}); err != nil {
		t.Fatal(err)
	}
	got := router.calls[0]
	if got["caller"] != pBob || got["body"].(map[string]any)["space"] != pSpaceA {
		t.Fatalf("a member's call = %+v (the space is filled in)", got)
	}
	if _, err := call(s, ctx, pBob, map[string]any{"plugin": "space", "namespace": "spaces", "action": "message_list", "body": map[string]any{"space": pSpaceB}}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("another space = %v", err)
	}
	if _, err := call(s, ctx, pBob, map[string]any{"plugin": "space", "namespace": "themes", "action": "apply"}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("an account action from a space plugin = %v", err)
	}
	if _, err := call(s, ctx, pCarol, map[string]any{"plugin": "space", "namespace": "spaces", "action": "message_list"}); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("a non-member = %v", err)
	}
	if _, err := call(s, ctx, pAnn, map[string]any{"plugin": "gone", "namespace": "spaces", "action": "message_list"}); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("a removed plugin = %v", err)
	}
	if _, err := s.pluginCall(ctx, &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(pBob), Kind: "bot"}, Body: []byte(`{"plugin":"space","namespace":"spaces","action":"message_list"}`)}); err == nil {
		t.Fatal("an agent called a plugin's platform gate")
	}
	if len(router.calls) != 1 {
		t.Fatalf("refused calls were dispatched: %+v", router.calls)
	}
}

func TestPluginListShowsMineAndMySpaces(t *testing.T) {
	s, _, ctx := pluginHarness(t)
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
	if ids, _ := list(pAnn, `{"space":"`+pSpaceA+`"}`); len(ids) != 3 {
		t.Fatalf("ann sees %v", ids)
	}
	if ids, _ := list(pAnn, `{"space":"`+pSpaceA+`","removed":true}`); len(ids) != 4 {
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
	s, _, ctx := pluginHarness(t)
	remove := s.pluginSetStatus(pluginRemoved)
	if _, err := remove(ctx, &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(pBob), Kind: "user"}, Body: []byte(`{"plugin":"acct"}`)}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("someone else removed it: %v", err)
	}
	if _, err := remove(ctx, &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(pAnn), Kind: "user"}, Body: []byte(`{"plugin":"acct"}`)}); err != nil {
		t.Fatal(err)
	}
	if _, err := call(s, ctx, pAnn, map[string]any{"plugin": "acct", "namespace": "themes", "action": "apply"}); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("a removed plugin still calls: %v", err)
	}
	restore := s.pluginSetStatus(pluginInstalled)
	if _, err := restore(ctx, &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(pAnn), Kind: "user"}, Body: []byte(`{"plugin":"acct"}`)}); err != nil {
		t.Fatal(err)
	}
	if _, err := call(s, ctx, pAnn, map[string]any{"plugin": "acct", "namespace": "themes", "action": "apply"}); err != nil {
		t.Fatalf("a restored plugin = %v", err)
	}
}

func TestPluginInputAndOwner(t *testing.T) {
	in := pluginInput{Name: " Notes ", Frontend: pluginProgram{Source: "askHost('render','{}')"}, Permissions: []string{"spaces.message_list", "spaces.message_list", " "}}
	if err := in.normalize(); err != nil || in.Name != "Notes" || in.Placement != PlacementPanel || in.Frontend.Runtime != "quickjs" || len(in.Permissions) != 1 {
		t.Fatalf("normalize = %+v, %v", in, err)
	}
	for _, bad := range []pluginInput{
		{Frontend: pluginProgram{Source: "x"}},
		{Name: "x"},
		{Name: "x", Frontend: pluginProgram{Source: "x"}, Placement: "toolbar"},
		{Name: "x", Frontend: pluginProgram{Source: "x"}, Permissions: []string{"spaces"}},
	} {
		if err := bad.normalize(); errs.CodeOf(err) != errs.CodeInvalidArgument {
			t.Fatalf("%+v = %v", bad, err)
		}
	}
	agent := &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(pBob), Kind: "bot"}}
	if _, _, err := pluginOwner(context.Background(), agent, ""); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("an agent outside a turn = %v", err)
	}
	ctx := vmm.WithExecution(context.Background(), vmm.Execution{SpaceID: pSpaceA, ActorID: pAnn})
	owner, space, err := pluginOwner(ctx, agent, pSpaceB)
	if err != nil || owner.String() != pAnn || space.String() != pSpaceA {
		t.Fatalf("an agent's plugin is for its person in its turn's space: %v %v %v", owner, space, err)
	}
	person := &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(pAnn), Kind: "user"}}
	if owner, space, err := pluginOwner(vmm.WithExecution(context.Background(), vmm.Execution{ActorID: pAnn}), person, ""); err != nil || owner.String() != pAnn || !space.IsZero() {
		t.Fatalf("a person's own Aseman makes app-wide plugins: %v %v %v", owner, space, err)
	}
}

func TestOnlyPeopleWhoMayUseAPluginReachItsBackend(t *testing.T) {
	s, _, ctx := pluginHarness(t)
	invoke := func(who, plugin string) error {
		raw, _ := json.Marshal(map[string]any{"plugin": plugin, "function": "get", "payload": map[string]any{"key": "k"}})
		_, err := s.pluginInvoke(ctx, &api.ActionRequest{Caller: api.Caller{ID: identity.MustParse(who), Kind: "user"}, Body: raw})
		return err
	}
	for _, c := range []struct{ who, plugin string }{{pBob, "acct"}, {pCarol, "space"}, {pAnn, "gone"}} {
		if err := invoke(c.who, c.plugin); errs.CodeOf(err) != errs.CodeNotFound {
			t.Fatalf("%s on %s = %v", c.who, c.plugin, err)
		}
	}
}
