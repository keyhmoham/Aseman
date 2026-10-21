package spaces

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
)

// computerHold is how long a computer watch waits for a change before
// answering anyway; computerRecheck is how often it reads the computer again
// meanwhile, for the changes nothing announces (a stop for an empty wallet, a
// machine its provider ended), and computerProbeEvery how many rechecks
// pass between asking the provider whether the machine is still there.
const (
	computerHold       = 20 * time.Second
	computerRecheck    = 3 * time.Second
	computerProbeEvery = 5
)

// computerChanged wakes everyone watching a computer: one of them changed.
// Watchers read their own computer again and answer only if it is theirs.
func (s *Service) computerChanged() {
	s.computerMu.Lock()
	defer s.computerMu.Unlock()
	if s.computerCh != nil {
		close(s.computerCh)
	}
	s.computerCh = make(chan struct{})
}

// computerWait returns a channel closed at the next change of any computer.
func (s *Service) computerWait() <-chan struct{} {
	s.computerMu.Lock()
	defer s.computerMu.Unlock()
	if s.computerCh == nil {
		s.computerCh = make(chan struct{})
	}
	return s.computerCh
}

// computerBusy records what a person asked a project's computer to do while
// it does it (waking, sleeping, replacing, opening), so everyone watching it
// sees the change coming; done clears it.
func (s *Service) computerBusy(sp identity.ID, op string) (done func()) {
	key := sp.String()
	s.computerMu.Lock()
	if s.computerOps == nil {
		s.computerOps = map[string]string{}
	}
	s.computerOps[key] = op
	s.computerMu.Unlock()
	s.computerChanged()
	return func() {
		s.computerMu.Lock()
		if s.computerOps[key] == op {
			delete(s.computerOps, key)
		}
		s.computerMu.Unlock()
		s.computerChanged()
	}
}

func (s *Service) computerOp(sp identity.ID) string {
	s.computerMu.Lock()
	defer s.computerMu.Unlock()
	return s.computerOps[sp.String()]
}

// computerState names a computer's state as people see it: none (never
// started), starting, awake, asleep or failed; or, while someone's request
// runs, waking, sleeping, replacing or opening.
func computerState(status any, op string) string {
	if op != "" {
		return op
	}
	switch status {
	case "unprovisioned", "":
		return "none"
	case bot.StatusRunning, "running":
		return "awake"
	case bot.StatusPending, bot.StatusCreating, "pending", "creating":
		return "starting"
	case bot.StatusFailed, "failed":
		return "failed"
	}
	return "asleep"
}

// watchComputer answers once the computer's revision differs from [since]
// (at once when there is none), or after computerHold with the same one.
func (s *Service) watchComputer(ctx context.Context, sp identity.ID, since string) (map[string]any, error) {
	deadline := time.NewTimer(computerHold)
	defer deadline.Stop()
	for i := 0; ; i++ {
		changed := s.computerWait()
		out, err := s.computerStatus(ctx, sp, i%computerProbeEvery == 0)
		if err != nil {
			return nil, err
		}
		if since == "" || out["rev"] != since {
			return out, nil
		}
		recheck := time.NewTimer(computerRecheck)
		select {
		case <-changed:
		case <-recheck.C:
		case <-deadline.C:
			recheck.Stop()
			return out, nil
		case <-ctx.Done():
			recheck.Stop()
			return nil, ctx.Err()
		}
		recheck.Stop()
	}
}
