package spaces

// Waking a published platform frontend's computer from anywhere.
//
// A platform's frontend is served by an app on a space's computer, and the
// computer sleeps when nobody uses it. The people who open the frontend are
// not the space's: they are the platform's people, visitors who have not
// signed in yet, or anyone with the platform's own client (a web page or the
// lightweight Elpian client built for it, platform_client_build), on any
// device. So waking is not a space mechanism: the gateway wakes the computer
// for whoever opens the frontend, as the person who published it (who pays
// for the computer), through one wake per preview at a time:
//
//   - WakeFrontend starts a wake (ProxyOpen: start the computer, start the
//     app's service, point the gateway at it) in the background, or joins the
//     one already under way, and reports how far it got. Many people opening
//     a sleeping platform at once wake it once.
//   - HoldFrontend renews the computer's lease while the frontend is used, so
//     it does not fall asleep under the platform's people between requests.

import (
	"context"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
)

const (
	// frontendWakeTimeout bounds one wake: the computer's start and the app
	// service's own start (previewStartWait) with room to spare.
	frontendWakeTimeout = 5 * time.Minute
	// frontendReadyFresh is how long a wake that made the app answer is
	// trusted without asking the computer again (while it is still awake).
	frontendReadyFresh = 90 * time.Second
	// frontendRetryAfterFailure is how long a failed wake is reported before
	// another is tried, so a crowd at a broken app does not start one each.
	frontendRetryAfterFailure = 15 * time.Second
	// frontendPollEvery is when a client is told to ask again while waking.
	frontendPollEvery = 2 * time.Second
)

// frontendWake is one preview's wake: under way (done open) or finished.
type frontendWake struct {
	done     chan struct{}
	started  time.Time
	finished time.Time
	ready    bool
	err      string
}

// frontendWakeOpen is how a wake opens the preview (ProxyOpen; tests replace it).
func (s *Service) frontendWakeOpen(ctx context.Context, id, actor identity.ID) (map[string]any, error) {
	if s.wakeOpenFn != nil {
		return s.wakeOpenFn(ctx, id, actor)
	}
	return s.ProxyOpen(ctx, id, actor)
}

// WakeFrontend wakes the computer behind preview [id] as [publisher] (the
// person who published it as a platform's frontend) unless it is awake and
// answering, and reports the wake. It waits up to [wait] for a wake under
// way to finish (0: it answers at once).
func (s *Service) WakeFrontend(ctx context.Context, id, publisher identity.ID, wait time.Duration) (proxy.Wake, error) {
	if publisher.IsZero() {
		return proxy.Wake{}, errs.Permission("the platform's frontend has no publisher to wake its computer as; publish it again")
	}
	p, err := s.ProxyGet(ctx, id)
	if err != nil {
		return proxy.Wake{}, errs.NotFound("the platform's frontend app was deleted; publish another")
	}
	now := time.Now()
	s.frontendWakeMu.Lock()
	if s.frontendWakes == nil {
		s.frontendWakes = map[identity.ID]*frontendWake{}
	}
	w := s.frontendWakes[id]
	switch {
	case w != nil && w.finished.IsZero():
		// Under way: join it.
	case w != nil && w.ready && now.Sub(w.finished) < frontendReadyFresh:
		s.frontendWakeMu.Unlock()
		if s.computerAwake(ctx, p.SpaceID) {
			return proxy.Wake{State: proxy.WakeReady, Ready: true}, nil
		}
		s.frontendWakeMu.Lock()
		w = s.startFrontendWake(p, publisher)
	case w != nil && !w.ready && now.Sub(w.finished) < frontendRetryAfterFailure:
		out := wakeReport(w)
		out.RetryAfterMs = int((frontendRetryAfterFailure - now.Sub(w.finished)).Milliseconds())
		s.frontendWakeMu.Unlock()
		return out, nil
	default:
		w = s.startFrontendWake(p, publisher)
	}
	s.frontendWakeMu.Unlock()
	if wait > 0 {
		timer := time.NewTimer(wait)
		select {
		case <-w.done:
		case <-timer.C:
		case <-ctx.Done():
		}
		timer.Stop()
	}
	s.frontendWakeMu.Lock()
	defer s.frontendWakeMu.Unlock()
	return wakeReport(w), nil
}

// startFrontendWake starts a wake of preview [p] in the background. The
// caller holds frontendWakeMu.
func (s *Service) startFrontendWake(p *proxy.Proxy, publisher identity.ID) *frontendWake {
	w := &frontendWake{done: make(chan struct{}), started: time.Now()}
	s.frontendWakes[p.ID] = w
	go func() {
		// The wake belongs to nobody's request: whoever asked may leave.
		ctx, cancel := context.WithTimeout(context.Background(), frontendWakeTimeout)
		defer cancel()
		out, err := s.frontendWakeOpen(ctx, p.ID, publisher)
		ready, message := false, ""
		switch {
		case err != nil:
			message = err.Error()
		case out["ready"] == true:
			ready = true
		default:
			message = "the app's service did not start on its computer"
			if log, _ := out["log"].(string); strings.TrimSpace(log) != "" {
				message += ": " + clipText(strings.TrimSpace(log), 400)
			}
		}
		if s.L != nil && !ready {
			s.L.Warn("platform frontend wake failed", "proxy", p.ID.String(), "space", p.SpaceID.String(), "error", message)
		}
		s.frontendWakeMu.Lock()
		w.ready, w.err, w.finished = ready, message, time.Now()
		s.frontendWakeMu.Unlock()
		close(w.done)
	}()
	return w
}

// wakeReport describes [w]. The caller holds frontendWakeMu.
func wakeReport(w *frontendWake) proxy.Wake {
	out := proxy.Wake{Since: w.started.UTC().Format(time.RFC3339)}
	switch {
	case w.finished.IsZero():
		out.State, out.RetryAfterMs = proxy.WakeWaking, int(frontendPollEvery.Milliseconds())
	case w.ready:
		out.State, out.Ready = proxy.WakeReady, true
	default:
		out.State, out.Error = proxy.WakeFailed, w.err
	}
	return out
}

// HoldFrontend keeps the computer behind preview [id] awake for another
// lease: the platform's people are using its frontend now.
func (s *Service) HoldFrontend(ctx context.Context, id identity.ID) error {
	p, err := s.ProxyGet(ctx, id)
	if err != nil {
		return err
	}
	s.holdPreview(p.SpaceID)
	return nil
}
