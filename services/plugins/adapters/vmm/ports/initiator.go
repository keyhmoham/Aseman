package vmm

import "context"

// What started a run, as distinct from whose authority it carries. The actor
// of a routine's run is its creator, so the actor alone cannot tell somebody
// typing from a schedule firing while nobody watches; the initiator can. It is
// set by the host where a run begins and inherited by everything the run
// starts. A model never chooses it.
const (
	// InitiatorPerson: somebody was in the room. The default.
	InitiatorPerson = "person"
	// InitiatorRoutine: a schedule fired, as its creator.
	InitiatorRoutine = "routine"
	// InitiatorResponsibility: a standing trigger fired, as its owner.
	InitiatorResponsibility = "responsibility"
	// InitiatorProactive: background research, read-only, as its owner.
	InitiatorProactive = "proactive"
	// InitiatorHandoff: another agent asked, on the person's behalf.
	InitiatorHandoff = "handoff"
	// InitiatorChannel: a person wrote from Slack, Teams or SMS.
	InitiatorChannel = "channel"
	// InitiatorDeployment: the node itself, with no person at all.
	InitiatorDeployment = "deployment"
)

// Initiator names what started a run and, where there is one, which routine,
// responsibility, agent or channel it was.
type Initiator struct {
	Kind string `json:"kind"`
	ID   string `json:"id,omitempty"`
}

// Unattended reports a run nobody was watching when it acted.
func (i Initiator) Unattended() bool {
	switch i.Kind {
	case InitiatorRoutine, InitiatorResponsibility, InitiatorProactive, InitiatorHandoff:
		return true
	}
	return false
}

type initiatorKey struct{}

// WithInitiator marks what started the run carried by ctx.
func WithInitiator(ctx context.Context, i Initiator) context.Context {
	if i.Kind == "" {
		i.Kind = InitiatorPerson
	}
	return context.WithValue(ctx, initiatorKey{}, i)
}

// InitiatorFrom is the run's initiator; a person when none was set.
func InitiatorFrom(ctx context.Context) Initiator {
	if i, ok := ctx.Value(initiatorKey{}).(Initiator); ok && i.Kind != "" {
		return i
	}
	return Initiator{Kind: InitiatorPerson}
}
