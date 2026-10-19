package spaces

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
	"github.com/tradera/tradera/plugins/actions/spaces/models/proxy"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	vmm "github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

func TestPublicPreviewAndSandboxActionsEnforceAccessBeforeEffects(t *testing.T) {
	s, internal := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	outsider := idFromHex(t, "00000000000000010000000000000002")
	guest := idFromHex(t, "00000000000000010000000000000003")
	sp, err := s.CreateSpace(internal, owner, "private previews", "")
	if err != nil {
		t.Fatal(err)
	}
	room := testWorkerRoom(t, s, internal, sp.ID, "private")
	pid, _ := identity.New(s.K.NodeID())
	p := &proxy.Proxy{Entity: entity.Entity{ID: pid}, SpaceID: sp.ID, RoomID: room, OwnerID: owner, Port: 3000, TargetURL: "http://internal", Token: "private-tunnel-token"}
	if err := s.R.CreateID(internal, "proxies", pid, p); err != nil {
		t.Fatal(err)
	}
	mid, _ := identity.New(s.K.NodeID())
	if err := s.R.CreateID(internal, "memberships", mid, &membership.Membership{Entity: entity.Entity{ID: mid}, SpaceID: sp.ID, MemberID: guest, Role: membership.RoleGuest}); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		action api.Action
		body   map[string]any
		write  bool
	}{
		{&proxyCreateAction{s}, map[string]any{"space": sp.ID.String(), "room": room.String(), "port": 3000}, true},
		{&proxyListAction{s}, map[string]any{"space": sp.ID.String()}, false},
		{&proxyGetAction{s}, map[string]any{"proxy": pid.String()}, false},
		{&proxyDeleteAction{s}, map[string]any{"proxy": pid.String()}, true},
		{&sandboxStatusAction{s}, map[string]any{"space": sp.ID.String()}, false},
		{&sandboxStartAction{s}, map[string]any{"space": sp.ID.String()}, true},
		{&sandboxStopAction{s}, map[string]any{"space": sp.ID.String()}, true},
		{&sandboxExecAction{s}, map[string]any{"space": sp.ID.String(), "command": "true"}, true},
		{&toolsListAction{s}, map[string]any{"space": sp.ID.String(), "room": room.String()}, false},
	}
	for _, tc := range cases {
		t.Run(tc.action.Meta().Name, func(t *testing.T) {
			body, _ := json.Marshal(tc.body)
			for _, actor := range []identity.ID{outsider, guest} {
				if actor == guest && !tc.write {
					continue
				}
				_, err := tc.action.Handle(context.Background(), &api.ActionRequest{Caller: api.Caller{ID: actor, Kind: "user"}, Body: body})
				if errs.CodeOf(err) != errs.CodePermission {
					t.Fatalf("unauthorized action got %v", err)
				}
			}
		})
	}
	// No denied request may provision a sandbox, expose credentials or delete the preview.
	if len(s.sandboxes) != 0 {
		t.Fatal("denied action provisioned a sandbox")
	}
	if _, err := s.ProxyGet(internal, pid); err != nil {
		t.Fatal("denied delete changed the preview", err)
	}
	for _, action := range []api.Action{&proxyListAction{s}, &proxyGetAction{s}} {
		body, _ := json.Marshal(map[string]any{"space": sp.ID.String(), "proxy": pid.String()})
		response, err := action.Handle(context.Background(), &api.ActionRequest{Caller: api.Caller{ID: owner, Kind: "user"}, Body: body})
		if err != nil || response.Status != 200 {
			t.Fatalf("owner access failed: %v", err)
		}
		var public map[string]any
		if err := json.Unmarshal(response.Body, &public); err != nil {
			t.Fatal(err)
		}
		if _, ok := public["token"]; ok {
			t.Fatal("exposed tunnel token")
		}
	}
	// A valid membership does not authorize addressing a room in a different space.
	other, err := s.CreateSpace(internal, owner, "other", "")
	if err != nil {
		t.Fatal(err)
	}
	otherRoom := testWorkerRoom(t, s, internal, other.ID, "elsewhere")
	body, _ := json.Marshal(map[string]any{"space": sp.ID.String(), "room": otherRoom.String(), "port": 3000})
	if _, err := (&proxyCreateAction{s}).Handle(context.Background(), &api.ActionRequest{Caller: api.Caller{ID: owner, Kind: "user"}, Body: body}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("cross-space room: %v", err)
	}
	body, _ = json.Marshal(map[string]any{"proxy": pid.String()})
	if _, err := (&proxyDeleteAction{s}).Handle(context.Background(), &api.ActionRequest{Caller: api.Caller{ID: owner, Kind: "user"}, Body: body}); err != nil {
		t.Fatal("owner delete failed", err)
	}
}

func TestProxyToolsCannotReachAnUnauthorizedRoom(t *testing.T) {
	s, internal := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	member := idFromHex(t, "00000000000000010000000000000002")
	sp, err := s.CreateSpace(internal, owner, "room scoped", "")
	if err != nil {
		t.Fatal(err)
	}
	allowed := testWorkerRoom(t, s, internal, sp.ID, "allowed")
	private := testWorkerRoom(t, s, internal, sp.ID, "private")
	mid, _ := identity.New(s.K.NodeID())
	if err := s.R.CreateID(internal, "memberships", mid, &membership.Membership{Entity: entity.Entity{ID: mid}, SpaceID: sp.ID, RoomID: allowed, MemberID: member, Role: membership.RoleMember}); err != nil {
		t.Fatal(err)
	}
	pid, _ := identity.New(s.K.NodeID())
	p := &proxy.Proxy{Entity: entity.Entity{ID: pid}, SpaceID: sp.ID, RoomID: private, OwnerID: owner, TargetURL: "http://127.0.0.1:1/private"}
	if err := s.R.CreateID(internal, "proxies", pid, p); err != nil {
		t.Fatal(err)
	}
	ctx := vmm.WithRoom(helper.WithActor(context.Background(), member), allowed.String())
	for _, name := range []string{"proxy_get", "proxy_delete"} {
		if _, err := s.proxyManageTool(ctx, sp.ID, name, `{"id":"`+pid.String()+`","probe":true}`); errs.CodeOf(err) != errs.CodePermission {
			t.Fatalf("%s crossed room boundary: %v", name, err)
		}
	}
	if _, err := s.proxyCreateTool(ctx, sp.ID, "agent", `{"room":"`+private.String()+`","port":3000}`); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("creation crossed room boundary: %v", err)
	}
	if _, err := s.ProxyGet(internal, pid); err != nil {
		t.Fatal("denied management changed the record", err)
	}
}

func TestPreviewProbeRestoresFiniteLeaseAfterDaemonRestart(t *testing.T) {
	s, internal := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(internal, owner, "retained preview", "")
	if err != nil {
		t.Fatal(err)
	}
	botID := idFromHex(t, "00000000000000010000000000000004")
	if err := s.M.Patch(internal, sp.ID, jsonpatchSet("sandbox/bot_id", botID.String())); err != nil {
		t.Fatal(err)
	}
	s.holdPreview(sp.ID)
	defer s.cancelTimer(sp.ID)
	st := s.sandboxes[sp.ID.String()]
	if st.botID != botID || st.timer == nil {
		t.Fatal("retained sandbox was not rehydrated")
	}
	delay := sandboxIdleDelay(st, time.Now())
	if delay < sandboxPreviewTTL-time.Second || delay > sandboxPreviewTTL {
		t.Fatalf("preview lease: %s", delay)
	}
}
