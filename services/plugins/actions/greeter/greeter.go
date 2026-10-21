// Package greeter is a self-contained sample action namespace.
package greeter

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/module"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// GreetingProvider is the consumer-owned port supplied by example-adapter.
type GreetingProvider interface {
	Greeting(context.Context, string) (string, error)
}
type Request struct {
	Name string `json:"name"`
}
type Response struct {
	Greeting string `json:"greeting"`
}
type Service struct{ K api.Kernel }

func (s *Service) Hello(ctx context.Context, name string) (Response, error) {
	provider, err := s.K.Resolve("example/greeting")
	if err != nil {
		return Response{}, err
	}
	greeting, ok := provider.(GreetingProvider)
	if !ok {
		return Response{}, errs.New(errs.CodeUnavailable, "greeting capability incompatible")
	}
	value, err := greeting.Greeting(ctx, name)
	return Response{Greeting: value}, err
}
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "greeter-ns", Version: "1.0.0", Provides: []string{"service/greeter"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		s := &Service{K: d.Kernel}
		return module.Instance{Service: s, Actions: []api.Action{&helloAction{s: s}}}, nil
	})
}

type helloAction struct{ s *Service }

func (a *helloAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "greeter", Name: "hello", Summary: "Greet using the example adapter"}
}
func (a *helloAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in Request
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.Name == "" {
		in.Name = "aseman"
	}
	result, err := a.s.Hello(ctx, in.Name)
	if err != nil {
		return nil, err
	}
	return helper.JSON(result)
}
