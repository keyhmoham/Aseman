// Package hostaccess lets a person's agents use the person's own computer,
// through the Aseman desktop app, limited to the folders the person shares.
//
// The desktop app registers the computer as a host and long-polls for calls
// (hostaccess.next); an agent's host_exec, host_read, host_write and
// host_list wait here until the app answers (hostaccess.result). Every call
// has already passed the governance gate, which by default asks the person
// before anything that changes their computer; the app checks every path
// against the shared folders again and can ask once more on the desktop
// itself. Only the person's own agents, working for them, reach their host.
package hostaccess

import (
	"context"
	"encoding/json"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/pkg/untrusted"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	hm "github.com/aseman/aseman/plugins/actions/hostaccess/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// onlineFor is how recently a host must have polled to take calls.
const onlineFor = 90 * time.Second

// Service is the hostaccess namespace.
type Service struct {
	K api.Kernel
	R *repo.Repo
	L *logger.Logger
	// CallTimeout bounds how long an agent waits on the desktop app;
	// PollWait how long one long poll waits for a call.
	CallTimeout, PollWait time.Duration
	now                   func() time.Time

	mu      sync.Mutex
	waiters map[string][]chan struct{}
}

// NewService builds the namespace's service.
func NewService(k api.Kernel, r *repo.Repo, log *logger.Logger) *Service {
	return &Service{K: k, R: r, L: log.Named("hostaccess"), CallTimeout: 10 * time.Minute, PollWait: 25 * time.Second, now: time.Now,
		waiters: map[string][]chan struct{}{}}
}

func (s *Service) wait(key string) (<-chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	s.mu.Lock()
	s.waiters[key] = append(s.waiters[key], ch)
	s.mu.Unlock()
	return ch, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		list := s.waiters[key]
		for i, c := range list {
			if c == ch {
				s.waiters[key] = append(list[:i], list[i+1:]...)
				break
			}
		}
	}
}

func (s *Service) wake(key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, ch := range s.waiters[key] {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

// Register adds (or refreshes) one of the person's computers.
func (s *Service) Register(ctx context.Context, owner identity.ID, hostID, name, platform string, folders []string) (*hm.Host, error) {
	clean := []string{}
	for _, f := range folders {
		f = strings.TrimSpace(f)
		if f == "" {
			continue
		}
		if !strings.HasPrefix(f, "/") && !strings.HasPrefix(f, "~") && !(len(f) > 2 && f[1] == ':') {
			return nil, errs.InvalidArgument("shared folders are absolute paths: " + f)
		}
		if f == "/" || f == "~" || strings.EqualFold(f, `C:\`) {
			return nil, errs.InvalidArgument("share folders, not a whole disk or home")
		}
		clean = append(clean, strings.TrimRight(f, `/\`))
	}
	now := s.now().UTC()
	var h hm.Host
	id, err := identity.Parse(hostID)
	if err == nil && s.R.Get(ctx, "hosts", id, &h) == nil {
		if h.OwnerID != owner.String() {
			return nil, errs.Permission("this computer is registered to someone else")
		}
		h.Name, h.Platform, h.Folders, h.LastSeen, h.UpdatedAt = clip(name, 80), clip(platform, 40), clean, now, now
		return &h, s.R.Update(ctx, "hosts", id, &h)
	}
	if id, err = identity.New(s.K.NodeID()); err != nil {
		return nil, err
	}
	h = hm.Host{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, OwnerID: owner.String(), Name: clip(name, 80),
		Platform: clip(platform, 40), Folders: clean, Enabled: true, LastSeen: now}
	return &h, s.R.CreateID(ctx, "hosts", id, &h)
}

func (s *Service) host(ctx context.Context, owner identity.ID, id string) (*hm.Host, error) {
	hid, err := identity.Parse(id)
	if err != nil {
		return nil, errs.InvalidArgument("invalid host")
	}
	var h hm.Host
	if err := s.R.Get(ctx, "hosts", hid, &h); err != nil {
		return nil, err
	}
	if h.OwnerID != owner.String() {
		return nil, errs.NotFound("host")
	}
	return &h, nil
}

// Hosts lists the person's computers.
func (s *Service) Hosts(ctx context.Context, owner identity.ID) ([]hm.Host, error) {
	var rows []hm.Host
	return rows, s.R.List(ctx, "hosts", database.Filter{Equal: map[string]any{"owner_id": owner.String()}, OrderBy: "last_seen", Limit: 20}, &rows)
}

// online is the person's most recently seen enabled host.
func (s *Service) online(ctx context.Context, owner string) (*hm.Host, bool) {
	var rows []hm.Host
	if err := s.R.List(ctx, "hosts", database.Filter{Equal: map[string]any{"owner_id": owner, "enabled": true},
		GreaterThan: map[string]any{"last_seen": s.now().UTC().Add(-onlineFor)}, OrderBy: "last_seen", Limit: 1}, &rows); err != nil || len(rows) == 0 {
		return nil, false
	}
	return &rows[0], true
}

// Next waits for the host's next call and claims it (the desktop app's long
// poll). No call is not an error: the app polls again.
func (s *Service) Next(ctx context.Context, owner identity.ID, hostID string) (*hm.Call, error) {
	h, err := s.host(ctx, owner, hostID)
	if err != nil {
		return nil, err
	}
	h.LastSeen = s.now().UTC()
	_ = s.R.Update(ctx, "hosts", h.ID, h)
	woke, done := s.wait("host-" + hostID)
	defer done()
	deadline := time.NewTimer(s.PollWait)
	defer deadline.Stop()
	for {
		var rows []hm.Call
		if err := s.R.List(ctx, "host_calls", database.Filter{Equal: map[string]any{"host_id": hostID, "status": hm.CallPending},
			OrderBy: "created_at", Asc: true, Limit: 5}, &rows); err != nil {
			return nil, err
		}
		for i := range rows {
			c := rows[i]
			if !s.now().Before(c.ExpiresAt) {
				continue
			}
			c.Status, c.UpdatedAt = hm.CallClaimed, s.now().UTC()
			ok := true
			if s.R.RequireAtomicUpdates() == nil {
				ok, err = s.R.CompareAndSwap(ctx, "host_calls", c.ID.String(), map[string]any{"status": hm.CallPending}, &c)
				if err != nil {
					return nil, err
				}
			} else if err := s.R.Update(ctx, "host_calls", c.ID, &c); err != nil {
				return nil, err
			}
			if ok {
				return &c, nil
			}
		}
		select {
		case <-ctx.Done():
			return nil, nil
		case <-deadline.C:
			return nil, nil
		case <-woke:
		case <-time.After(2 * time.Second):
		}
	}
}

// Result records what the desktop app did with a call.
func (s *Service) Result(ctx context.Context, owner identity.ID, callID, output, failure string) error {
	cid, err := identity.Parse(callID)
	if err != nil {
		return errs.InvalidArgument("invalid call")
	}
	var c hm.Call
	if err := s.R.Get(ctx, "host_calls", cid, &c); err != nil {
		return err
	}
	if c.OwnerID != owner.String() {
		return errs.NotFound("call")
	}
	if c.Status != hm.CallClaimed {
		return errs.Conflict("this call is " + c.Status)
	}
	c.Status, c.Output, c.Error, c.UpdatedAt = hm.CallDone, clip(output, 200000), clip(failure, 2000), s.now().UTC()
	if failure != "" {
		c.Status = hm.CallFailed
	}
	if err := s.R.Update(ctx, "host_calls", cid, &c); err != nil {
		return err
	}
	s.wake("call-" + callID)
	return nil
}

// inside reports a path within one of the shared folders (lexically; the
// desktop app checks the real path again, links resolved).
func inside(p string, folders []string) bool {
	clean := path.Clean(strings.ReplaceAll(p, `\`, "/"))
	for _, f := range folders {
		root := path.Clean(strings.ReplaceAll(f, `\`, "/"))
		if clean == root || strings.HasPrefix(clean, root+"/") {
			return true
		}
	}
	return false
}

// AvailableTools: host tools for a person with a connected computer.
func (s *Service) AvailableTools(ctx context.Context, actor, space string) ([]string, error) {
	if _, ok := s.online(ctx, actor); !ok {
		return []string{}, nil
	}
	return []string{"host_exec", "host_read", "host_write", "host_list"}, nil
}

// AgentTool sends an agent's call to the person's computer and waits for it.
func (s *Service) AgentTool(ctx context.Context, call gate.ToolCall) (string, error) {
	h, ok := s.online(ctx, call.ActorID)
	if !ok {
		return "", errs.New(errs.CodeUnavailable, "the person's computer is not connected: they open the Aseman desktop app and turn on \"Let agents use this computer\"")
	}
	var args map[string]any
	_ = json.Unmarshal([]byte(call.Args), &args)
	p, _ := args["path"].(string)
	if dir, _ := args["dir"].(string); call.Tool == "host_exec" {
		p = dir
		if p == "" && len(h.Folders) > 0 {
			p = h.Folders[0]
			args["dir"] = p
		}
	}
	if !(call.Tool == "host_list" && p == "") && !inside(p, h.Folders) {
		return "", errs.Permission("outside the folders the person shared: " + strings.Join(h.Folders, ", "))
	}
	raw, _ := json.Marshal(args)
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return "", err
	}
	now := s.now().UTC()
	c := &hm.Call{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, HostID: h.ID.String(), OwnerID: call.ActorID,
		AgentName: call.AgentName, Tool: call.Tool, Args: string(raw), Status: hm.CallPending, ExpiresAt: now.Add(s.CallTimeout)}
	if err := s.R.CreateID(ctx, "host_calls", id, c); err != nil {
		return "", err
	}
	s.wake("host-" + h.ID.String())
	woke, done := s.wait("call-" + id.String())
	defer done()
	for {
		var cur hm.Call
		if err := s.R.Get(ctx, "host_calls", id, &cur); err != nil {
			return "", err
		}
		switch cur.Status {
		case hm.CallDone:
			// What comes back from the person's files is data, not instructions.
			return untrusted.Wrap("the person's computer ("+h.Name+")", cur.Output), nil
		case hm.CallFailed:
			return "", errs.New(errs.CodeUnavailable, "on the person's computer: "+cur.Error)
		}
		if !s.now().Before(cur.ExpiresAt) {
			cur.Status, cur.UpdatedAt = hm.CallExpired, s.now().UTC()
			_ = s.R.Update(context.WithoutCancel(ctx), "host_calls", id, &cur)
			return "", errs.New(errs.CodeUnavailable, "the person's computer did not answer in time")
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-woke:
		case <-time.After(2 * time.Second):
		}
	}
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n]
}
