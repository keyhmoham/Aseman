package module_test

import (
	"context"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/module"
	"github.com/aseman/aseman/plugins/config"
)

type blockingService struct{ entered chan struct{} }

func (s *blockingService) Wait(ctx context.Context) error {
	close(s.entered)
	<-ctx.Done()
	return ctx.Err()
}
func TestStopCancelsAndDrainsBridgeCalls(t *testing.T) {
	k := kernel.New(kernel.Options{Config: dconfig.NewProvider(&dconfig.Config{})})
	service := &blockingService{entered: make(chan struct{})}
	plugin := module.New(api.Info{Name: "blocking-ns", Provides: []string{"service/blocking"}}, func(context.Context, *api.Dependencies) (module.Instance, error) {
		return module.Instance{Service: service}, nil
	})
	if err := k.Register(plugin); err != nil {
		t.Fatal(err)
	}
	if err := k.Init("blocking-ns"); err != nil {
		t.Fatal(err)
	}
	if err := k.Start("blocking-ns"); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { ctx := context.Background(); done <- bridge.Invoke(ctx, k, "blocking", "Wait", []any{ctx}) }()
	<-service.entered
	if err := k.Stop("blocking-ns"); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != context.Canceled {
			t.Fatalf("got %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("bridge did not drain")
	}
	if _, err := k.Resolve("service/blocking"); err == nil {
		t.Fatal("stopped namespace resolves")
	}
	if err := k.Unload("blocking-ns"); err != nil {
		t.Fatal(err)
	}
}
