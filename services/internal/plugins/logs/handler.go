package logs

import (
	"context"
	"log/slog"
	"strings"
)

// Handler is a slog.Handler that copies records into the ring buffer.
type Handler struct {
	ring *Ring
}

// NewHandler returns a slog handler writing into ring.
func NewHandler(ring *Ring) *Handler {
	return &Handler{ring: ring}
}

// Enabled implements slog.Handler.
func (h *Handler) Enabled(ctx context.Context, level slog.Level) bool { return true }

// Handle implements slog.Handler.
func (h *Handler) Handle(ctx context.Context, r slog.Record) error {
	var b strings.Builder
	r.Attrs(func(a slog.Attr) bool {
		b.WriteString(a.Key)
		b.WriteByte('=')
		b.WriteString(a.Value.String())
		b.WriteByte(' ')
		return true
	})
	entry := Entry{
		Time:    r.Time,
		Level:   r.Level.String(),
		Message: r.Message,
	}
	if b.Len() > 0 {
		entry.Message = entry.Message + " " + strings.TrimSpace(b.String())
	}
	h.ring.Add(entry)
	return nil
}

// WithAttrs implements slog.Handler.
func (h *Handler) WithAttrs(attrs []slog.Attr) slog.Handler { return h }

// WithGroup implements slog.Handler.
func (h *Handler) WithGroup(name string) slog.Handler { return h }
