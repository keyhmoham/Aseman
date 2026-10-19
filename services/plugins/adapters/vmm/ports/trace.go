package vmm

import (
	"context"
	"sync"
	"time"
)

// Span is one timed phase of an agent turn (waiting in the queue, starting the
// computer, a model call, a platform tool...), so an admin can see where the
// time of a slow turn went.
type Span struct {
	Name   string    `json:"name"`
	Detail string    `json:"detail,omitempty"`
	Start  time.Time `json:"start"`
	Ms     int64     `json:"ms"`
}

// Tracer collects the spans of one turn. It is safe for concurrent use: model
// calls, tools and the host's own steps report from different goroutines.
type Tracer struct {
	mu    sync.Mutex
	spans []Span
}

type tracerKey struct{}

// WithTracer returns a context whose turn is traced, and the tracer to read it.
func WithTracer(ctx context.Context) (context.Context, *Tracer) {
	t := &Tracer{}
	return context.WithValue(ctx, tracerKey{}, t), t
}

// Spans is what has been recorded so far, in the order the phases started.
func (t *Tracer) Spans() []Span {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make([]Span, len(t.spans))
	copy(out, t.spans)
	return out
}

// Add records a phase that already happened.
func (t *Tracer) Add(name, detail string, start time.Time, d time.Duration) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if len(t.spans) >= 400 {
		return // a runaway turn must not grow its own record without bound
	}
	t.spans = append(t.spans, Span{Name: name, Detail: detail, Start: start.UTC(), Ms: d.Milliseconds()})
}

// Trace times a phase of the turn in ctx; call the result when it ends:
//
//	defer vmm.Trace(ctx, "sandbox.reserve", "")()
//
// Without a tracer in ctx it does nothing.
func Trace(ctx context.Context, name, detail string) func() {
	t, _ := ctx.Value(tracerKey{}).(*Tracer)
	if t == nil {
		return func() {}
	}
	start := time.Now()
	return func() { t.Add(name, detail, start, time.Since(start)) }
}

// TraceFrom records a phase that began at start and ends now.
func TraceFrom(ctx context.Context, name, detail string, start time.Time) {
	if t, _ := ctx.Value(tracerKey{}).(*Tracer); t != nil {
		t.Add(name, detail, start, time.Since(start))
	}
}
