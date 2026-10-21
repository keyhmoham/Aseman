package kernel_test

import (
	"context"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/config"
)

type blockingDatabase struct {
	*memory.Adapter
	entered chan struct{}
}

func (p *blockingDatabase) Transaction(ctx context.Context, fn func(context.Context, database.Tx) error) error {
	close(p.entered)
	<-ctx.Done()
	return ctx.Err()
}
func TestAdapterStopCancelsOperations(t *testing.T) {
	k := kernel.New(kernel.Options{Config: dconfig.NewProvider(&dconfig.Config{})})
	provider := &blockingDatabase{Adapter: memory.New(logger.Global()), entered: make(chan struct{})}
	if err := k.Register(provider); err != nil {
		t.Fatal(err)
	}
	if err := k.Init("memory"); err != nil {
		t.Fatal(err)
	}
	if err := k.Start("memory"); err != nil {
		t.Fatal(err)
	}
	held := k.DB()
	done := make(chan error, 1)
	go func() { done <- held.Transaction(context.Background(), nil) }()
	<-provider.entered
	if err := k.Stop("memory"); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != context.Canceled {
			t.Fatalf("got %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("operation did not drain")
	}
	if err := held.Create(context.Background(), "unused", "id", struct{}{}); err == nil {
		t.Fatal("stale provider reference remains callable")
	}
}
func TestDatabaseSwapPreservesSchemasAndUsesCurrentProvider(t *testing.T) {
	ctx := context.Background()
	k := kernel.New(kernel.Options{Config: dconfig.NewProvider(&dconfig.Config{})})
	first := memory.New(logger.Global())
	second := memory.New(logger.Global())
	second.Base.Name = "second-memory"
	for _, p := range []api.Plugin{first, second} {
		if err := k.Register(p); err != nil {
			t.Fatal(err)
		}
		if err := k.Init(p.Info().Name); err != nil {
			t.Fatal(err)
		}
		if err := k.Start(p.Info().Name); err != nil {
			t.Fatal(err)
		}
	}
	model := database.Model{Name: "sample", Table: "sample", Fields: []database.Field{{Name: "id", Kind: database.KindString}}}
	if err := k.DB().RegisterModel(ctx, model); err != nil {
		t.Fatal(err)
	}
	r := repo.New(k)
	if err := r.DB.Create(ctx, "sample", "first", map[string]any{"id": "first"}); err != nil {
		t.Fatal(err)
	}
	if err := k.SetActive(api.CategoryDatabase, "second-memory"); err != nil {
		t.Fatal(err)
	}
	count, err := r.DB.Count(ctx, "sample", database.Filter{})
	if err != nil || count != 0 {
		t.Fatalf("count=%d err=%v", count, err)
	}
	if len(second.Models()) != 1 {
		t.Fatal("model registry not copied")
	}
	if err := k.Stop("second-memory"); err != nil {
		t.Fatal(err)
	}
	if err := k.SetActive(api.CategoryDatabase, "second-memory"); err == nil {
		t.Fatal("stopped adapter bound")
	}
}
