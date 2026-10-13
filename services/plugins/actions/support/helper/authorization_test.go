package helper

import (
	"context"
	"testing"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
	"github.com/tradera/tradera/plugins/actions/spaces/models/space"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	dbmodel "github.com/tradera/tradera/plugins/testutil"
)

func TestSpaceAccessKeepsNamespacePermissionsScoped(t *testing.T) {
	ctx := context.Background()
	db := memory.New(logger.Global())
	for _, model := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, model); err != nil {
			t.Fatal(err)
		}
	}
	r := &repo.Repo{DB: db}
	actor := identity.ID{Node: 1, Entity: 1}
	workspace := identity.ID{Node: 1, Entity: 2}
	roomID := identity.ID{Node: 1, Entity: 3}
	memberID := identity.ID{Node: 1, Entity: 4}
	room := &space.Room{Entity: entity.Entity{ID: roomID}, SpaceID: workspace}
	member := &membership.Membership{Entity: entity.Entity{ID: memberID}, SpaceID: workspace, MemberID: actor, Role: membership.RoleGuest, Permissions: []string{"workflow.write"}}
	if err := r.CreateID(ctx, "rooms", roomID, room); err != nil {
		t.Fatal(err)
	}
	if err := r.CreateID(ctx, "memberships", memberID, member); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name       string
		actor      identity.ID
		space      identity.ID
		write      bool
		permission string
		want       errs.Code
	}{
		{name: "read", actor: actor, space: workspace},
		{name: "workflow grant", actor: actor, space: workspace, write: true, permission: "workflow.write"},
		{name: "routine denied", actor: actor, space: workspace, write: true, permission: "routine.write", want: errs.CodePermission},
		{name: "ungranted write", actor: actor, space: workspace, write: true, want: errs.CodePermission},
		{name: "unauthenticated", space: workspace, want: errs.CodeUnauthenticated},
		{name: "foreign room", actor: actor, space: identity.ID{Node: 1, Entity: 5}, want: errs.CodePermission},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := CheckSpaceAccess(ctx, r, tc.actor, tc.space, roomID, tc.write, tc.permission)
			if errs.CodeOf(err) != tc.want {
				t.Fatalf("access error = %v, want code %s", err, tc.want)
			}
		})
	}
}
