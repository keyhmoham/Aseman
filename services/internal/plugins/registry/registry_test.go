package registry

import (
	"context"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
)

type testPlugin struct{ info api.Info }

func (p *testPlugin) Info() api.Info { return p.info }
func (p *testPlugin) Init(ctx context.Context, deps *api.Dependencies) error {
	return nil
}
func (p *testPlugin) Start(ctx context.Context) error  { return nil }
func (p *testPlugin) Stop(ctx context.Context) error   { return nil }
func (p *testPlugin) Unload(ctx context.Context) error { return nil }
func (p *testPlugin) UpdateConfig(ctx context.Context, cfg map[string]any) error {
	return nil
}
func (p *testPlugin) CheckHealth(ctx context.Context) api.Health {
	return api.Health{OK: true, Checked: time.Now()}
}

func newTest(name string) api.Plugin {
	return &testPlugin{info: api.Info{Name: name, Type: api.TypeModule}}
}

func TestRegisterGetUnregister(t *testing.T) {
	r := New()
	if err := r.Register(newTest("a")); err != nil {
		t.Fatal(err)
	}
	if err := r.Register(newTest("a")); err == nil {
		t.Fatal("duplicate register should fail")
	}
	if _, ok := r.Get("a"); !ok {
		t.Fatal("a should be registered")
	}
	if err := r.Unregister("a"); err != nil {
		t.Fatal(err)
	}
	if _, ok := r.Get("a"); ok {
		t.Fatal("a should be gone")
	}
	if err := r.Unregister("a"); err == nil {
		t.Fatal("unregister missing should fail")
	}
}

func TestListByTypeAndState(t *testing.T) {
	r := New()
	_ = r.Register(&testPlugin{info: api.Info{Name: "db", Type: api.TypeAdapter, Category: api.CategoryDatabase}})
	_ = r.Register(&testPlugin{info: api.Info{Name: "act", Type: api.TypeAction}})
	if got := len(r.ListByType(api.TypeAdapter)); got != 1 {
		t.Fatalf("expected 1 adapter, got %d", got)
	}
	_ = r.SetState("db", api.StateStarted, nil)
	e, _ := r.Get("db")
	if e.State != api.StateStarted {
		t.Fatal("state not updated")
	}
	if e.State.String() != "started" {
		t.Fatalf("bad state string: %s", e.State.String())
	}
	_ = r.SetState("db", api.StateFailed, context.DeadlineExceeded)
	e, _ = r.Get("db")
	if e.LastError == "" {
		t.Fatal("last error not recorded")
	}
}
