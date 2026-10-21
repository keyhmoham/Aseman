// Package helper provides shared helpers for action implementations.
package helper

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
)

// ProxyIfRemote forwards the action to the node owning entityRef when the ref
// is a universal id belonging to another node. Returns ok=true when the request
// was proxied (the caller must return the response).
func ProxyIfRemote(ctx context.Context, k api.Kernel, entityRef, namespace, name string, req *api.ActionRequest) (*api.ActionResponse, bool, error) {
	id, err := identity.Parse(entityRef)
	if err != nil {
		return nil, false, nil
	}
	if id.Node == k.NodeID() {
		return nil, false, nil
	}
	resp, err := k.Proxy(ctx, entityRef, namespace, name, req.Caller, req.Body)
	return resp, true, err
}

// StatusOf maps an aseman error to an HTTP status code.
func StatusOf(err error) int {
	switch errs.CodeOf(err) {
	case errs.CodeNotFound:
		return http.StatusNotFound
	case errs.CodeAlreadyExists, errs.CodeConflict:
		return http.StatusConflict
	case errs.CodeInvalidArgument:
		return http.StatusBadRequest
	case errs.CodeUnauthenticated:
		return http.StatusUnauthorized
	case errs.CodePermission:
		return http.StatusForbidden
	case errs.CodeUnavailable:
		return http.StatusServiceUnavailable
	default:
		return http.StatusInternalServerError
	}
}

// JSON builds a 200 response with a JSON body.
func JSON(v any) (*api.ActionResponse, error) {
	return JSONStatus(200, v)
}

// JSONStatus builds a response with an explicit HTTP status.
func JSONStatus(status int, v any) (*api.ActionResponse, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, errs.Wrap(errs.CodeInternal, err, "encode response")
	}
	return &api.ActionResponse{Status: status, Body: b}, nil
}

// JSONBytes wraps already-serialized JSON.
func JSONBytes(status int, b []byte) (*api.ActionResponse, error) {
	return &api.ActionResponse{Status: status, Body: b}, nil
}

// Decode unmarshals the request body into out.
func Decode(req *api.ActionRequest, out any) error {
	if len(req.Body) == 0 {
		return errs.InvalidArgument("empty request body")
	}
	if err := json.Unmarshal(req.Body, out); err != nil {
		return errs.Wrap(errs.CodeInvalidArgument, err, "invalid request body")
	}
	return nil
}

// Paging normalizes limit/offset query parameters for list actions.
// A zero/negative limit becomes the default; limits are capped at max.
func Paging(limit, offset, def, max int) (int, int) {
	if limit <= 0 {
		limit = def
	}
	if limit > max {
		limit = max
	}
	if offset < 0 {
		offset = 0
	}
	return limit, offset
}

// RequireUser rejects requests from unauthenticated or bot callers.
func RequireUser(req *api.ActionRequest) error {
	if req.Caller.ID.IsZero() {
		return errs.Unauthenticated("authentication required")
	}
	if req.Caller.Kind != "user" {
		return errs.Permission("action requires a user account")
	}
	return nil
}

// RequireAuthenticated rejects unauthenticated callers (users and bots both ok).
func RequireAuthenticated(req *api.ActionRequest) error {
	if req.Caller.ID.IsZero() {
		return errs.Unauthenticated("authentication required")
	}
	return nil
}

// RequireBot rejects calls that do not come from a bot VM.
func RequireBot(req *api.ActionRequest) error {
	if req.Caller.ID.IsZero() {
		return errs.Unauthenticated("authentication required")
	}
	if req.Caller.Kind != "bot" {
		return errs.Permission("action requires a bot account")
	}
	return nil
}
