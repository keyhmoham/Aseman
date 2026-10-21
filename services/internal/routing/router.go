// Package router dispatches actions grouped in namespaces. Namespaces are
// runtime-modifiable: action plugins register/unregister their actions while
// the system runs, and the router reflects that immediately.
package router

import (
	"context"
	"fmt"
	"sync"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
)

// Namespace is a group of related actions.
type Namespace struct {
	Name    string
	Actions map[string]api.Action
}

// Router holds all namespaces and dispatches actions.
type Router struct {
	mu         sync.RWMutex
	namespaces map[string]*Namespace
	order      []string
}

// New creates an empty router.
func New() *Router {
	return &Router{namespaces: map[string]*Namespace{}}
}

// Register adds an action to a namespace, creating the namespace if needed.
func (r *Router) Register(namespace string, a api.Action) error {
	if a == nil || a.Meta().Name == "" {
		return errs.InvalidArgument("action must have a name")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	ns, ok := r.namespaces[namespace]
	if !ok {
		ns = &Namespace{Name: namespace, Actions: map[string]api.Action{}}
		r.namespaces[namespace] = ns
		r.order = append(r.order, namespace)
	}
	if _, exists := ns.Actions[a.Meta().Name]; exists {
		return errs.AlreadyExists(fmt.Sprintf("action %s/%s already registered", namespace, a.Meta().Name))
	}
	ns.Actions[a.Meta().Name] = a
	return nil
}

// Deregister removes an action from a namespace.
func (r *Router) Deregister(namespace, name string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	ns, ok := r.namespaces[namespace]
	if !ok {
		return errs.NotFound("namespace " + namespace)
	}
	if _, ok := ns.Actions[name]; !ok {
		return errs.NotFound(fmt.Sprintf("action %s/%s", namespace, name))
	}
	delete(ns.Actions, name)
	if len(ns.Actions) == 0 {
		delete(r.namespaces, namespace)
		for i, n := range r.order {
			if n == namespace {
				r.order = append(r.order[:i], r.order[i+1:]...)
				break
			}
		}
	}
	return nil
}

// List returns the action metadata of a namespace.
func (r *Router) List(namespace string) []api.ActionMeta {
	r.mu.RLock()
	defer r.mu.RUnlock()
	ns, ok := r.namespaces[namespace]
	if !ok {
		return nil
	}
	out := make([]api.ActionMeta, 0, len(ns.Actions))
	for name, a := range ns.Actions {
		m := a.Meta()
		m.Namespace = namespace
		m.Name = name
		out = append(out, m)
	}
	return out
}

// Namespaces returns all namespace names in registration order.
func (r *Router) Namespaces() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]string, 0, len(r.order))
	for _, n := range r.order {
		if _, ok := r.namespaces[n]; ok {
			out = append(out, n)
		}
	}
	return out
}

// Resolve finds an action without executing it.
func (r *Router) Resolve(namespace, name string) (api.Action, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	ns, ok := r.namespaces[namespace]
	if !ok {
		return nil, false
	}
	a, ok := ns.Actions[name]
	return a, ok
}

// Dispatch executes an action. It returns INVALID_ARGUMENT when the action is
// unknown and delegates authorization to the action itself (fine-grained
// permission logic lives next to the domain it protects).
func (r *Router) Dispatch(ctx context.Context, namespace, name string, req *api.ActionRequest) (*api.ActionResponse, error) {
	a, ok := r.Resolve(namespace, name)
	if !ok {
		return nil, errs.NotFound(fmt.Sprintf("action %s/%s", namespace, name))
	}
	return a.Handle(ctx, req)
}
