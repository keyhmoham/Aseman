package timeline

import (
	"context"
	"sync"
	"time"

	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// names turns the ids in the node's records into the names things carry on
// the timeline: a person by handle, an agent, room or project by its name and
// the end of its id. The same thing gets the same name in every feed, so its
// whole history gathers on one entity. Read only, cached for an hour.
type names struct {
	r *repo.Repo

	mu      sync.Mutex
	cache   map[string]thing
	flushed time.Time
}

func newNames(r *repo.Repo) *names {
	return &names{r: r, cache: map[string]thing{}, flushed: time.Now()}
}

func (n *names) cached(key string, resolve func() thing) thing {
	n.mu.Lock()
	if time.Since(n.flushed) > time.Hour {
		n.cache, n.flushed = map[string]thing{}, time.Now()
	}
	t, ok := n.cache[key]
	n.mu.Unlock()
	if ok {
		return t
	}
	t = resolve()
	n.mu.Lock()
	n.cache[key] = t
	n.mu.Unlock()
	return t
}

func (n *names) request(id string) thing { return thing{label("request", id), "request"} }

// account names a person by handle, and an agent's account as its agent.
func (n *names) account(ctx context.Context, id string) thing {
	if id == "" {
		return thing{"someone", "person"}
	}
	return n.cached("account:"+id, func() thing {
		var bots []struct {
			ID   string `db:"id"`
			Name string `db:"name"`
		}
		if n.r.List(ctx, "bots", database.Filter{Equal: map[string]any{"account_id": id}, Limit: 1}, &bots) == nil && len(bots) > 0 {
			return thing{label(bots[0].Name, bots[0].ID), "agent"}
		}
		var acc []struct {
			Handle string `db:"handle"`
			Kind   string `db:"kind"`
		}
		if n.r.List(ctx, "accounts", database.Filter{Equal: map[string]any{"id": id}, Limit: 1}, &acc) == nil && len(acc) > 0 && acc[0].Handle != "" {
			return thing{"@" + acc[0].Handle, "person"}
		}
		return thing{label("account", id), "person"}
	})
}

// bot names an agent (or tool bot) by its bot id.
func (n *names) bot(ctx context.Context, id, fallback string) thing {
	if id == "" {
		return thing{label(fallback, ""), "agent"}
	}
	return n.cached("bot:"+id, func() thing {
		var bots []struct {
			Name string `db:"name"`
		}
		if n.r.List(ctx, "bots", database.Filter{Equal: map[string]any{"id": id}, Limit: 1}, &bots) == nil && len(bots) > 0 && bots[0].Name != "" {
			return thing{label(bots[0].Name, id), "agent"}
		}
		return thing{label(fallback, id), "agent"}
	})
}

func (n *names) room(ctx context.Context, id string) thing {
	return n.named(ctx, "rooms", id, "room", "room")
}

func (n *names) space(ctx context.Context, id string) thing {
	return n.named(ctx, "spaces", id, "project", "project")
}

func (n *names) routine(ctx context.Context, id string) thing {
	t := n.named(ctx, "routines", id, "routine", "routine")
	if t.name != label("routine", id) {
		t.name = "routine " + t.name
	}
	return t
}

func (n *names) named(ctx context.Context, model, id, fallback, kind string) thing {
	if id == "" {
		return thing{fallback, kind}
	}
	return n.cached(model+":"+id, func() thing {
		var rows []struct {
			Name string `db:"name"`
		}
		if n.r.List(ctx, model, database.Filter{Equal: map[string]any{"id": id}, Limit: 1}, &rows) == nil && len(rows) > 0 && rows[0].Name != "" {
			return thing{label(rows[0].Name, id), kind}
		}
		return thing{label(fallback, id), kind}
	})
}
