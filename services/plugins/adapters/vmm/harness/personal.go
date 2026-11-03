package harness

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Personal Aseman sessions act as the person: Dispatch as Kind user, so each
// action's own authorization decides and anything the person could do in the
// app is reachable, within the agents' policy (policy.go).

// openPersonal mints a person-scoped gateway session for personal Aseman chat
// (the assistant chat and Talk). The runtime presents the token like a room
// turn; serveCall dispatches as the person (Kind user), with no single-space
// lock.
func (a *Adapter) openPersonal(ctx context.Context, person identity.ID) (*session, error) {
	if person.IsZero() {
		return nil, errs.InvalidArgument("personal chat needs a person")
	}
	if err := a.ensureRuntime(ctx); err != nil {
		return nil, err
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return nil, err
	}
	token := hex.EncodeToString(raw)
	base := context.WithoutCancel(ctx)
	base = vmm.WithExecution(base, vmm.Execution{ActorID: person.String()})
	s := &session{
		token: token, account: person, personal: true,
		base: base, started: time.Now(),
		sentMessages: map[string]bool{}, attachments: map[string]bool{},
	}
	a.mu.Lock()
	a.sessions[s.token] = s
	a.mu.Unlock()
	return s, nil
}

