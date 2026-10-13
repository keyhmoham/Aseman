// Package kvs implements isolated key-value storage used by bots (global,
// space-scoped, room-scoped). Every value is owned by one account within its
// scope, so bots cannot read each other's data.
package kvs

import (
	"context"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/support/models/kv"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// Service implements KV operations.
type Service struct {
	K api.Kernel
	R *repo.Repo
}

// Get returns an item isolated to the owner within a scope.
func (s *Service) Get(ctx context.Context, scope kv.Scope, scopeID, owner identity.ID, key string) (*kv.Item, error) {
	var list []kv.Item
	if err := s.R.List(ctx, "kv", database.Filter{
		Equal: map[string]any{
			"scope": string(scope), "scope_id": scopeID.String(), "owner_id": owner.String(), "key": key,
		},
	}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, errs.NotFound("kv key " + key)
	}
	return &list[0], nil
}

// Set upserts an item isolated per owner.
func (s *Service) Set(ctx context.Context, scope kv.Scope, scopeID, owner identity.ID, key, value string) error {
	existing, err := s.Get(ctx, scope, scopeID, owner, key)
	if err != nil && errs.CodeOf(err) != errs.CodeNotFound {
		return err
	}
	now := time.Now().UTC()
	if existing != nil {
		existing.Value = value
		existing.UpdatedAt = now
		return s.R.Update(ctx, "kv", existing.ID, existing)
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	item := &kv.Item{
		Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		Scope:  scope, ScopeID: scopeID, OwnerID: owner, Key: key, Value: value,
	}
	return s.R.CreateID(ctx, "kv", id, item)
}

// Range lists keys owned by a member in a scope.
func (s *Service) Range(ctx context.Context, scope kv.Scope, scopeID, owner identity.ID) ([]kv.Item, error) {
	var out []kv.Item
	if err := s.R.List(ctx, "kv", database.Filter{
		Equal: map[string]any{"scope": string(scope), "scope_id": scopeID.String(), "owner_id": owner.String()},
	}, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// Delete removes an item.
func (s *Service) Delete(ctx context.Context, scope kv.Scope, scopeID, owner identity.ID, key string) error {
	item, err := s.Get(ctx, scope, scopeID, owner, key)
	if err != nil {
		return err
	}
	return s.R.Delete(ctx, "kv", item.ID)
}
