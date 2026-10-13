// Package logger provides a small structured logger built on log/slog with
// pluggable handlers and child-scoped loggers (used by plugins and adapters).
package logger

import (
	"context"
	"io"
	"log/slog"
	"os"
	"strings"
	"sync"
)

// Logger is a thin wrapper around slog.Logger.
type Logger struct {
	slog *slog.Logger
}

// Handler exposes the underlying slog handler (used to build multi-sink
// loggers, e.g. per-plugin files).
func (l *Logger) Handler() slog.Handler { return l.slog.Handler() }

// WithFile returns a logger that writes to the global sinks plus an appending
// file at path. On failure it falls back to the receiver unchanged.
func (l *Logger) WithFile(path string) *Logger {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return l
	}
	file := slog.NewTextHandler(f, &slog.HandlerOptions{Level: slog.LevelDebug})
	multi := slog.NewMultiHandler(l.slog.Handler(), file)
	return &Logger{slog: slog.New(multi)}
}

var (
	mu     sync.RWMutex
	global = newLogger(os.Stderr, slog.LevelInfo)
)

// New creates a Logger writing to w at level.
func New(w io.Writer, level slog.Level) *Logger {
	return newLogger(w, level)
}

// FromHandler wraps an existing slog.Handler.
func FromHandler(h slog.Handler) *Logger {
	return &Logger{slog: slog.New(h)}
}

// NewMulti merges multiple slog handlers.
func NewMulti(handlers ...slog.Handler) *Logger {
	return &Logger{slog: slog.New(slog.NewMultiHandler(handlers...))}
}

func newLogger(w io.Writer, level slog.Level) *Logger {
	h := slog.NewTextHandler(w, &slog.HandlerOptions{Level: level})
	return &Logger{slog: slog.New(h)}
}

// Global returns the process-wide logger.
func Global() *Logger {
	mu.RLock()
	defer mu.RUnlock()
	return global
}

// SetGlobal replaces the process-wide logger.
func SetGlobal(l *Logger) {
	mu.Lock()
	defer mu.Unlock()
	global = l
}

// Level parses a level string ("debug","info","warn","error").
func Level(s string) slog.Level {
	switch strings.ToLower(s) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

// With returns a child logger carrying constant fields.
func (l *Logger) With(kv ...any) *Logger {
	return &Logger{slog: l.slog.With(kv...)}
}

// Named returns a child logger with a "logger" name field.
func (l *Logger) Named(name string) *Logger {
	return &Logger{slog: l.slog.With("logger", name)}
}

func (l *Logger) Debug(msg string, kv ...any) { l.slog.Debug(msg, kv...) }
func (l *Logger) Info(msg string, kv ...any)  { l.slog.Info(msg, kv...) }
func (l *Logger) Warn(msg string, kv ...any)  { l.slog.Warn(msg, kv...) }
func (l *Logger) Error(msg string, kv ...any) { l.slog.Error(msg, kv...) }

// Ctx attaches a context aware logger (context values are resolved lazily).
func (l *Logger) Ctx(ctx context.Context) *Logger { return l }

// Enabled reports whether the logger emits records at level.
func (l *Logger) Enabled(ctx context.Context, level slog.Level) bool {
	return l.slog.Enabled(ctx, level)
}
