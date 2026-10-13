package vmm

import "context"

// statusCtxKey is the context key carrying the live agent-status hook.
type statusCtxKey struct{}

// StatusHook receives live status updates while an agent works inside a space
// room (e.g. "thinking…", "using tool sandbox_exec…", "running in the sandbox",
// "generating content…"). agent is the working agent's name, detail a short
// human sentence describing its current activity. The hook is invoked
// synchronously from the agent runtime, so a room-scoped implementation can
// publish it to the chat's live working indicator.
type StatusHook func(agent, detail string)

// WithStatus installs a status hook on the context; the agent runtime calls it
// as it works so callers can surface the agent's current activity live.
func WithStatus(ctx context.Context, h StatusHook) context.Context {
	return context.WithValue(ctx, statusCtxKey{}, h)
}

// StatusFrom returns the status hook installed on the context, or nil.
func StatusFrom(ctx context.Context) StatusHook {
	h, _ := ctx.Value(statusCtxKey{}).(StatusHook)
	return h
}
