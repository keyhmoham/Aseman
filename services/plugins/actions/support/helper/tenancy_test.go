package helper

import (
	"context"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/pkg/tenancy"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

func tenancyHarness(t *testing.T) (*repo.Repo, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := context.Background()
	models := []database.Model{
		{Name: "accounts", Table: "accounts", Fields: []database.Field{
			{Name: "id", Kind: database.KindString}, {Name: "handle", Kind: database.KindString, Index: true},
			{Name: "email", Kind: database.KindString, Index: true}, {Name: "kind", Kind: database.KindString},
			{Name: "status", Kind: database.KindString}, {Name: "platform_id", Kind: database.KindString},
		}},
		{Name: "dev_platforms", Table: "dev_platforms", Fields: []database.Field{
			{Name: "id", Kind: database.KindString}, {Name: "slug", Kind: database.KindString},
			{Name: "main_access", Kind: database.KindBool},
		}},
	}
	for _, m := range models {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	return &repo.Repo{DB: db}, ctx
}

func putAccount(t *testing.T, r *repo.Repo, ctx context.Context, id, handle, email, platform string) {
	t.Helper()
	uid := identity.MustParse(id)
	now := time.Now().UTC()
	acc := &account.Account{
		Entity: entity.Entity{ID: uid, CreatedAt: now, UpdatedAt: now},
		Handle: handle, Email: email, Kind: account.KindUser, Status: account.StatusActive,
		PlatformID: platform,
	}
	if err := r.CreateID(ctx, "accounts", uid, acc); err != nil {
		t.Fatal(err)
	}
}

func TestFindAccountByHandlePrefersViewerPlatform(t *testing.T) {
	r, ctx := tenancyHarness(t)
	const (
		mainID = "00000000000000010000000000000a11"
		acmeID = "00000000000000010000000000000a22"
		viewID = "00000000000000010000000000000b0b"
	)
	putAccount(t, r, ctx, mainID, "alice", "a@main.test", tenancy.Main)
	putAccount(t, r, ctx, acmeID, "alice", "a@acme.test", "acme")
	putAccount(t, r, ctx, viewID, "bob", "b@acme.test", "acme")

	got, err := FindAccountByHandle(ctx, r, identity.MustParse(viewID), "alice")
	if err != nil || got.ID.String() != acmeID {
		t.Fatalf("acme viewer got %+v, %v", got, err)
	}
	mainViewer := identity.MustParse(mainID)
	got, err = FindAccountByHandle(ctx, r, mainViewer, "alice")
	if err != nil || got.ID.String() != mainID {
		t.Fatalf("main viewer got %+v, %v", got, err)
	}
}

func TestHandleTakenIsPerPlatform(t *testing.T) {
	r, ctx := tenancyHarness(t)
	const mainID = "00000000000000010000000000000a11"
	putAccount(t, r, ctx, mainID, "alice", "a@main.test", tenancy.Main)
	taken, err := HandleTaken(ctx, r, "alice", tenancy.Main, identity.ID{})
	if err != nil || !taken {
		t.Fatalf("main taken = %v, %v", taken, err)
	}
	taken, err = HandleTaken(ctx, r, "alice", "acme", identity.ID{})
	if err != nil || taken {
		t.Fatalf("acme should be free = %v, %v", taken, err)
	}
}

func TestFindAccountByEmailMainOnly(t *testing.T) {
	r, ctx := tenancyHarness(t)
	const (
		mainID = "00000000000000010000000000000a11"
		acmeID = "00000000000000010000000000000a22"
	)
	putAccount(t, r, ctx, mainID, "alice", "same@test", tenancy.Main)
	putAccount(t, r, ctx, acmeID, "alice", "same@test", "acme")
	got, err := FindAccountByEmail(ctx, r, "same@test", tenancy.Main)
	if err != nil || got.ID.String() != mainID {
		t.Fatalf("main email = %+v, %v", got, err)
	}
}
