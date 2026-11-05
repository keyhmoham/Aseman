package message

import (
	"context"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/pkg/tenancy"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

func TestRequireVisibleBlocksCrossPlatform(t *testing.T) {
	db := memory.New(logger.Global())
	ctx := context.Background()
	for _, m := range []database.Model{
		{Name: "accounts", Table: "accounts", Fields: []database.Field{
			{Name: "id", Kind: database.KindString}, {Name: "handle", Kind: database.KindString},
			{Name: "kind", Kind: database.KindString}, {Name: "platform_id", Kind: database.KindString},
		}},
		{Name: "dev_platforms", Table: "dev_platforms", Fields: []database.Field{
			{Name: "id", Kind: database.KindString}, {Name: "main_access", Kind: database.KindBool},
		}},
	} {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	r := &repo.Repo{DB: db}
	s := &Service{R: r}
	now := time.Now().UTC()
	mainID := identity.MustParse("00000000000000010000000000000a11")
	acmeViewer := identity.MustParse("00000000000000010000000000000b0b")
	acmePeer := identity.MustParse("00000000000000010000000000000c0c")
	put := func(id identity.ID, handle, platform string) {
		acc := &account.Account{
			Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
			Handle: handle, Kind: account.KindUser, PlatformID: platform,
		}
		if err := r.CreateID(ctx, "accounts", id, acc); err != nil {
			t.Fatal(err)
		}
	}
	put(mainID, "alice", tenancy.Main)
	put(acmeViewer, "bob", "acme")
	put(acmePeer, "carol", "acme")

	ok, err := s.resolve(ctx, acmePeer)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.requireVisible(ctx, acmeViewer, ok); err != nil {
		t.Fatalf("same platform: %v", err)
	}
	cross, err := s.resolve(ctx, mainID)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.requireVisible(ctx, acmeViewer, cross); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("cross platform = %v", err)
	}
}
