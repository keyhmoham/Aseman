package router

import (
	"context"
	"testing"

	"github.com/aseman/aseman/internal/plugins/api"
)

type act struct{ name string }

func (a *act) Meta() api.ActionMeta { return api.ActionMeta{Name: a.name} }
func (a *act) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	return &api.ActionResponse{Status: 200, Body: []byte(`{"ok":true}`)}, nil
}

func TestRegisterDispatchDeregister(t *testing.T) {
	r := New()
	if err := r.Register("ns", &act{name: "x"}); err != nil {
		t.Fatal(err)
	}
	if err := r.Register("ns", &act{name: "x"}); err == nil {
		t.Fatal("duplicate should fail")
	}
	resp, err := r.Dispatch(context.Background(), "ns", "x", &api.ActionRequest{})
	if err != nil || resp.Status != 200 {
		t.Fatalf("dispatch failed: %v %+v", err, resp)
	}
	if _, err := r.Dispatch(context.Background(), "ns", "missing", nil); err == nil {
		t.Fatal("expected not found")
	}
	if err := r.Deregister("ns", "x"); err != nil {
		t.Fatal(err)
	}
	if _, ok := r.Resolve("ns", "x"); ok {
		t.Fatal("should be deregistered")
	}
	if len(r.Namespaces()) != 0 {
		t.Fatal("empty namespace should be removed")
	}
}

func TestListMeta(t *testing.T) {
	r := New()
	_ = r.Register("users", &act{name: "get"})
	_ = r.Register("users", &act{name: "list"})
	_ = r.Register("spaces", &act{name: "create"})
	metas := r.List("users")
	if len(metas) != 2 {
		t.Fatalf("expected 2 actions, got %d", len(metas))
	}
	if len(r.Namespaces()) != 2 {
		t.Fatal("expected 2 namespaces")
	}
}
