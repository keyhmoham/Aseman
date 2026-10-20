package spaces

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// A turn's run is the whole team's work on it: the agents the turn was
// addressed to, every agent they bring in (by mentioning or messaging it, and
// so on down the chain), and the commands they run in the project computer.
// All of it carries the turn's id as its run id (vmm.Execution.RunID), joins
// the run here, and stops with it: Stop on a turn stops the team.

// runGrace is how long a stopped run keeps refusing work that arrives late
// (an agent's message already on its way when Stop came).
const runGrace = 10 * time.Minute

// teamRunDeadline bounds work started inside a run, which otherwise has no
// deadline of its own.
const teamRunDeadline = 30 * time.Minute

type teamRun struct {
	mu      sync.Mutex
	spaceID identity.ID
	cancels map[int]context.CancelFunc
	next    int
	stopped bool
	members sync.WaitGroup
}

type teamRuns struct {
	mu   sync.Mutex
	runs map[string]*teamRun
}

func (r *teamRuns) get(id string) *teamRun {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.runs[id]
}

// openRun starts the run of a turn; cancel stops the turn's own work.
func (s *Service) openRun(id string, spaceID identity.ID, cancel context.CancelFunc) *teamRun {
	run := &teamRun{spaceID: spaceID, cancels: map[int]context.CancelFunc{0: cancel}, next: 1}
	s.teams.mu.Lock()
	if s.teams.runs == nil {
		s.teams.runs = map[string]*teamRun{}
	}
	s.teams.runs[id] = run
	s.teams.mu.Unlock()
	return run
}

// closeRun forgets a finished run. A stopped one is kept a while so work that
// arrives late is still refused.
func (s *Service) closeRun(id string, run *teamRun) {
	run.mu.Lock()
	stopped := run.stopped
	run.mu.Unlock()
	forget := func() {
		s.teams.mu.Lock()
		if s.teams.runs[id] == run {
			delete(s.teams.runs, id)
		}
		s.teams.mu.Unlock()
	}
	if stopped {
		time.AfterFunc(runGrace, forget)
		return
	}
	forget()
}

// joinRun makes work started on behalf of a run (an agent brought in by a
// teammate) part of it: the returned context ends when the run is stopped,
// the run's turn waits for it, and done must be called when it ends. Work of
// a run already stopped gets an ended context. Work outside any run on this
// node is left as it is.
func (s *Service) joinRun(ctx context.Context) (context.Context, func()) {
	id := vmm.ExecutionFrom(ctx).RunID
	if id == "" {
		return ctx, func() {}
	}
	run := s.teams.get(id)
	if run == nil {
		return ctx, func() {}
	}
	ctx, cancel := context.WithTimeout(ctx, teamRunDeadline)
	run.mu.Lock()
	if run.stopped {
		run.mu.Unlock()
		cancel()
		return ctx, func() {}
	}
	key := run.next
	run.next++
	run.cancels[key] = cancel
	run.members.Add(1)
	run.mu.Unlock()
	return ctx, func() {
		run.mu.Lock()
		delete(run.cancels, key)
		run.mu.Unlock()
		cancel()
		run.members.Done()
	}
}

// waitTeam waits until everyone who joined the run is done, or ctx ends.
func (run *teamRun) waitTeam(ctx context.Context) {
	done := make(chan struct{})
	go func() {
		run.members.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-ctx.Done():
	}
}

// stopRun stops a run on this node: the turn's own work, every agent that
// joined it, and the processes its commands left in the project computer.
// Reports whether the run was running here.
func (s *Service) stopRun(id string) bool {
	run := s.teams.get(id)
	if run == nil {
		return false
	}
	run.mu.Lock()
	already := run.stopped
	run.stopped = true
	cancels := make([]context.CancelFunc, 0, len(run.cancels))
	for _, c := range run.cancels {
		cancels = append(cancels, c)
	}
	run.mu.Unlock()
	for _, c := range cancels {
		c()
	}
	if !already {
		go s.killRunProcesses(run.spaceID, id)
	}
	return true
}

// runEnv marks a command, and every process it starts, as the run's, so Stop
// can end what it left running (servers, watchers, anything backgrounded).
func runEnv(runID string) string {
	if runID == "" || strings.ContainsAny(runID, "'\"\\$` \n") {
		return ""
	}
	return "export TRADERA_RUN='" + runID + "' && "
}

// killRunProcesses ends every process in the project computer marked with the
// run. It does not wait for the computer's queue: a command of the run may be
// the one holding it. A computer that is not running has nothing to end.
func (s *Service) killRunProcesses(spaceID identity.ID, runID string) {
	if runEnv(runID) == "" || spaceID.IsZero() || s.M == nil || s.Bots == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	id, ok := s.sandboxBotID(ctx, spaceID)
	if !ok {
		return
	}
	rec, err := s.Bots.GetBot(ctx, id)
	if err != nil || rec.VMID == "" || rec.Status != "running" {
		return
	}
	execVM, ok := s.K.VMMFor(vmm.Type(rec.VMType)).(interface {
		Send(ctx context.Context, vmID, command string) (string, error)
	})
	if !ok {
		return
	}
	if _, err := execVM.Send(ctx, rec.VMID, killRunCommand(runID)); err != nil {
		s.L.Warn("could not end a stopped run's processes", "space", spaceID.String(), "run", runID, "err", err)
	}
}

// killRunCommand ends the processes whose environment marks them as the run's.
func killRunCommand(runID string) string {
	return "for d in /proc/[0-9]*; do " +
		"if { tr '\\0' '\\n' < \"$d/environ\"; } 2>/dev/null | grep -qx 'TRADERA_RUN=" + runID + "'; then " +
		"kill -9 \"${d#/proc/}\" 2>/dev/null; fi; done; true"
}

// runStopped reports whether ctx belongs to a run that was stopped: its work
// must not start anything new (a command, a message bringing in an agent).
func (s *Service) runStopped(ctx context.Context) bool {
	id := vmm.ExecutionFrom(ctx).RunID
	if id == "" {
		return false
	}
	run := s.teams.get(id)
	if run == nil {
		return false
	}
	run.mu.Lock()
	defer run.mu.Unlock()
	return run.stopped
}

// JoinRun is joinRun for other namespaces (a direct message from one agent
// to another starts the second on the first one's run).
func (s *Service) JoinRun(ctx context.Context) (context.Context, func()) {
	return s.joinRun(ctx)
}
