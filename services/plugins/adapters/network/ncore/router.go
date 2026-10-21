// Package ncore provides the shared route matcher used by all network
// adapters. Routes use a small, deterministic pattern syntax:
//
//	/users/{id}          -> literal + named segment
//	/spaces/*            -> prefix wildcard
//	/spaces/{id}/rooms   -> exact
//
// Matching returns captured path parameters.
package ncore

import (
	"strings"
	"sync"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

type segment struct {
	literal string
	param   string
	wild    bool
}

type route struct {
	pattern string
	segs    []segment
	handler network.Handler
}

// Router maps method+route patterns to handlers.
type Router struct {
	mu     sync.RWMutex
	routes map[network.Method][]route
}

// NewRouter creates an empty router.
func NewRouter() *Router {
	return &Router{routes: map[network.Method][]route{}}
}

// Handle registers a handler.
func (r *Router) Handle(method network.Method, pattern string, h network.Handler) error {
	if h == nil {
		return errs.InvalidArgument("handler required")
	}
	segs, err := parsePattern(pattern)
	if err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	list := r.routes[method]
	for i, rt := range list {
		if rt.pattern == pattern {
			list[i].handler = h
			r.routes[method] = list
			return nil
		}
	}
	r.routes[method] = append(list, route{pattern: pattern, segs: segs, handler: h})
	return nil
}

// Unhandle removes a handler.
func (r *Router) Unhandle(method network.Method, pattern string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	list := r.routes[method]
	for i, rt := range list {
		if rt.pattern == pattern {
			r.routes[method] = append(list[:i], list[i+1:]...)
			return nil
		}
	}
	return errs.NotFound("route " + string(method) + " " + pattern)
}

// Match resolves a method+path to a handler and captured params.
func (r *Router) Match(method network.Method, path string) (network.Handler, map[string]string, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, rt := range r.routes[method] {
		params, ok := matchSegments(rt.segs, splitPath(path))
		if ok {
			return rt.handler, params, true
		}
	}
	return nil, nil, false
}

// List returns registered patterns for a method.
func (r *Router) List(method network.Method) []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var out []string
	for _, rt := range r.routes[method] {
		out = append(out, rt.pattern)
	}
	return out
}

func parsePattern(pattern string) ([]segment, error) {
	parts := splitPath(pattern)
	if len(parts) == 0 {
		return nil, errs.InvalidArgument("empty route pattern")
	}
	segs := make([]segment, 0, len(parts))
	for _, p := range parts {
		if p == "*" {
			segs = append(segs, segment{wild: true})
			continue
		}
		if strings.HasPrefix(p, "{") && strings.HasSuffix(p, "}") && len(p) > 2 {
			segs = append(segs, segment{param: p[1 : len(p)-1]})
			continue
		}
		segs = append(segs, segment{literal: p})
	}
	return segs, nil
}

func splitPath(path string) []string {
	path = strings.TrimPrefix(path, "/")
	if path == "" {
		return nil
	}
	return strings.Split(path, "/")
}

func matchSegments(pattern []segment, path []string) (map[string]string, bool) {
	params := map[string]string{}
	for i := 0; i < len(pattern); i++ {
		seg := pattern[i]
		if seg.wild {
			// Wildcard consumes the rest (only valid as final segment).
			rest := strings.Join(path[i:], "/")
			params["*"] = rest
			return params, true
		}
		if i >= len(path) {
			return nil, false
		}
		if seg.param != "" {
			params[seg.param] = path[i]
			continue
		}
		if seg.literal != path[i] {
			return nil, false
		}
	}
	if len(path) != len(pattern) {
		return nil, false
	}
	return params, true
}
