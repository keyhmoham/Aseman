package app_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/app"
	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/plugins/adapters/base"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
	"github.com/tradera/tradera/plugins/config"
)

type protocolProvider struct {
	base.Base
	network.Network
	mu     sync.Mutex
	stop   chan struct{}
	served chan struct{}
}

func (p *protocolProvider) Name() string                                  { return p.Base.Name }
func (p *protocolProvider) Init(context.Context, *api.Dependencies) error { return nil }
func (p *protocolProvider) Start(context.Context) error                   { return nil }
func (p *protocolProvider) Stop(ctx context.Context) error                { return p.Close(ctx) }
func (p *protocolProvider) Serve(ctx context.Context) error {
	p.mu.Lock()
	stop := make(chan struct{})
	p.stop = stop
	p.mu.Unlock()
	p.served <- struct{}{}
	select {
	case <-ctx.Done():
	case <-stop:
	}
	return nil
}
func (p *protocolProvider) Close(context.Context) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.stop != nil {
		close(p.stop)
		p.stop = nil
	}
	return nil
}
func TestNetworkSupervisorSurvivesProviderRestart(t *testing.T) {
	k := kernel.New(kernel.Options{Config: dconfig.NewProvider(&dconfig.Config{})})
	p := &protocolProvider{Base: base.Base{Name: "test-protocol", Category: api.CategoryNetwork}, served: make(chan struct{}, 4)}
	for _, fn := range []func() error{func() error { return k.Register(p) }, func() error { return k.Init(p.Info().Name) }, func() error { return k.Start(p.Info().Name) }} {
		if err := fn(); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- (&app.App{K: k}).Serve(ctx) }()
	await := func() {
		t.Helper()
		select {
		case <-p.served:
		case <-time.After(time.Second):
			t.Fatal("provider did not serve")
		}
	}
	await()
	if err := k.Stop(p.Info().Name); err != nil {
		t.Fatal(err)
	}
	if err := k.Start(p.Info().Name); err != nil {
		t.Fatal(err)
	}
	await()
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("supervisor did not shut down")
	}
}
