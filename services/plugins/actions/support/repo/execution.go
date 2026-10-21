// Atomic execution leases shared by workflow and routine repositories.
package repo

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
)

type ExecutionLease struct {
	ID        string    `db:"id"`
	Token     string    `db:"token"`
	ExpiresAt time.Time `db:"expires_at"`
}

func ExecutionKey(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:16])
}

func ClaimExecution(ctx context.Context, r *Repo, node identity.NodeID, key string, ttl time.Duration) (*ExecutionLease, error) {
	if err := r.RequireAtomicUpdates(); err != nil {
		return nil, err
	}
	token, err := identity.New(node)
	if err != nil {
		return nil, err
	}
	lease := &ExecutionLease{ID: ExecutionKey(key), Token: token.String(), ExpiresAt: time.Now().UTC().Add(ttl)}
	if err := r.DB.Create(ctx, "execution_leases", lease.ID, lease); err == nil {
		return lease, nil
	} else if errs.CodeOf(err) != errs.CodeAlreadyExists {
		return nil, err
	}
	var old ExecutionLease
	if err := r.DB.Get(ctx, "execution_leases", lease.ID, &old); err != nil {
		return nil, err
	}
	if old.ExpiresAt.After(time.Now().UTC()) {
		return nil, errs.Conflict("execution already claimed")
	}
	changed, err := r.CompareAndSwap(ctx, "execution_leases", lease.ID, map[string]any{"token": old.Token}, lease)
	if err != nil {
		return nil, err
	}
	if !changed {
		return nil, errs.Conflict("execution already claimed")
	}
	return lease, nil
}

func (l *ExecutionLease) Renew(ctx context.Context, r *Repo, ttl time.Duration) error {
	if err := r.RequireAtomicUpdates(); err != nil {
		return err
	}
	updated := *l
	updated.ExpiresAt = time.Now().UTC().Add(ttl)
	changed, err := r.CompareAndSwap(ctx, "execution_leases", l.ID, map[string]any{"token": l.Token}, &updated)
	if err != nil {
		return err
	}
	if !changed {
		return errs.Conflict("execution lease lost")
	}
	return nil
}

func (l *ExecutionLease) Release(ctx context.Context, r *Repo) error { return l.Renew(ctx, r, 0) }

type leaseKey struct{}

func WithExecutionLease(ctx context.Context, l *ExecutionLease) context.Context {
	return context.WithValue(ctx, leaseKey{}, l)
}

func CheckExecutionLease(ctx context.Context, r *Repo) error {
	l, _ := ctx.Value(leaseKey{}).(*ExecutionLease)
	if l == nil {
		return nil
	}
	var current ExecutionLease
	if err := r.DB.Get(ctx, "execution_leases", l.ID, &current); err != nil {
		return err
	}
	if current.Token != l.Token || !current.ExpiresAt.After(time.Now().UTC()) {
		return errs.Conflict("execution lease expired or replaced")
	}
	return nil
}
