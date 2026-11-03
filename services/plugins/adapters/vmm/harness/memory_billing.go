package harness

import (
	"context"
	"fmt"
	"math"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// The agents' memory runs on the admin's models (Admin → Memory models), and
// a project pays for what its memory uses, like the rest of its agents' work:
// at the memory model's own token prices, to the account that owns the
// provider's API key, counted in the project's spend and against its budget.
//
// Memory model calls (an embedding per memory written or recalled, a chat
// call per turn learned from) are small and frequent, so they are metered per
// project and charged in whole ledger units every memoryBillEvery, the
// fraction carried over. The payer is whoever ran the project's latest agent
// turn, else the project's owner; a person's own memory (personal chat) is
// the person's. A project that cannot pay gets no memory model calls until it
// can.

// memoryBillEvery, the fraction carried over. The payer is whoever ran the
// project's latest agent turn (that work is what the memory is busy with),
// else the project's owner. A project that cannot pay gets no memory model
// calls until it can.

// memoryBillEvery is how often metered memory use is charged.
const memoryBillEvery = 30 * time.Second

// memoryBill is what one project owes one provider owner for memory so far.
type memoryBill struct {
	space, payee     identity.ID
	cost             float64 // ledger units, fractional
	tokensIn, tokens int64   // since the last charge, for the description
}

type memoryMeter struct {
	mu    sync.Mutex
	bills map[string]*memoryBill // space|payee
	// payers is who ran each project's latest agent turn.
	payers map[string]identity.ID
	// blocked are projects whose memory use could not be charged.
	blocked map[string]bool
	// people are the accounts metered for their own memory (personal chat),
	// charged with no project.
	people map[string]bool
	stop    chan struct{}
}

func newMemoryMeter() *memoryMeter {
	return &memoryMeter{bills: map[string]*memoryBill{}, payers: map[string]identity.ID{}, blocked: map[string]bool{},
		people: map[string]bool{}}
}

// notePayer remembers who runs a project's agents, to charge its memory to.
func (m *memoryMeter) notePayer(spaceID, actorID string) {
	payer, err := identity.Parse(actorID)
	if err != nil || payer.IsZero() || spaceID == "" {
		return
	}
	m.mu.Lock()
	m.payers[spaceID] = payer
	m.mu.Unlock()
}

// notePerson marks a metered key as a person's own memory: the person pays.
func (m *memoryMeter) notePerson(person identity.ID) {
	if person.IsZero() {
		return
	}
	m.mu.Lock()
	m.people[person.String()] = true
	m.payers[person.String()] = person
	m.mu.Unlock()
}

func (m *memoryMeter) isBlocked(space identity.ID) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.blocked[space.String()]
}

// add meters one memory model call of a project.
func (m *memoryMeter) add(space identity.ID, provider vmm.ProviderConfig, in, out int64) {
	cost := (float64(in)*provider.InputPrice + float64(out)*provider.OutputPrice) / 1e6
	payee, _ := identity.Parse(provider.OwnerID)
	if cost <= 0 || payee.IsZero() {
		return
	}
	key := space.String() + "|" + payee.String()
	m.mu.Lock()
	b := m.bills[key]
	if b == nil {
		b = &memoryBill{space: space, payee: payee}
		m.bills[key] = b
	}
	b.cost += cost
	b.tokensIn += in
	b.tokens += in + out
	m.mu.Unlock()
}

// billMemory charges every project the whole ledger units its memory has used.
func (a *Adapter) billMemory(ctx context.Context) {
	a.billMeter(ctx, a.memory, "agent memory")
}

// billMeter charges what one meter has metered, each charge described by label.
func (a *Adapter) billMeter(ctx context.Context, m *memoryMeter, label string) {
	if m == nil {
		return
	}
	m.mu.Lock()
	due := []memoryBill{}
	for _, b := range m.bills {
		if b.cost >= 1 {
			due = append(due, *b)
		}
	}
	m.mu.Unlock()
	for _, b := range due {
		amount := int64(math.Floor(b.cost + 1e-9))
		payer := a.memoryPayer(ctx, b.space)
		if payer.IsZero() {
			continue
		}
		desc := fmt.Sprintf("%s (%d tokens)", label, b.tokens)
		m.mu.Lock()
		person := m.people[b.space.String()]
		m.mu.Unlock()
		project := b.space
		if person {
			project = identity.ID{}
		}
		err := a.chargeMemory(ctx, project, payer, b.payee, amount, desc)
		m.mu.Lock()
		switch {
		case err == nil:
			if !person {
				a.recordMemory(ctx, b.space, b.tokens, b.tokensIn, amount)
			}
			if cur := m.bills[b.space.String()+"|"+b.payee.String()]; cur != nil {
				cur.cost -= float64(amount)
				cur.tokens -= b.tokens
				cur.tokensIn -= b.tokensIn
			}
			delete(m.blocked, b.space.String())
		case errs.CodeOf(err) == errs.CodeFinance:
			// The wallet or the project's budget cannot cover it: the debt
			// stays, and the project's memory stops using models until a
			// later charge goes through.
			m.blocked[b.space.String()] = true
		}
		m.mu.Unlock()
		if err != nil {
			a.Log.Warn(label+" not charged", "space", b.space.String(), "payer", payer.String(), "amount", amount, "error", err)
		}
	}
}

// recordMemory writes a settlement to the usage ledger for the admin log. It is
// best-effort: a failed record never undoes the charge.
func (a *Adapter) recordMemory(ctx context.Context, space identity.ID, tokens, tokensIn, amount int64) {
	if a.memoryRecordFn != nil {
		a.memoryRecordFn(space, tokens, tokensIn, amount)
		return
	}
	if a.k == nil {
		return
	}
	if err := bridge.Invoke(ctx, a.k, "usage", "RecordMemory", []any{ctx, space, tokens, tokensIn, amount}); err != nil {
		a.Log.Warn("agent memory use not recorded", "space", space.String(), "error", err)
	}
}

// memoryPayer is who pays for a project's memory: whoever ran its latest
// agent turn, else its owner.
func (a *Adapter) memoryPayer(ctx context.Context, space identity.ID) identity.ID {
	a.memory.mu.Lock()
	payer := a.memory.payers[space.String()]
	a.memory.mu.Unlock()
	if !payer.IsZero() {
		return payer
	}
	if a.memoryOwnerFn != nil {
		return a.memoryOwnerFn(ctx, space)
	}
	if a.k == nil {
		return identity.ID{}
	}
	var project struct {
		OwnerID identity.ID `json:"owner_id"`
	}
	if err := bridge.Invoke(ctx, a.k, "spaces", "GetSpace", []any{ctx, space}, &project); err != nil {
		a.Log.Warn("agent memory: no one to charge", "space", space.String(), "error", err)
		return identity.ID{}
	}
	return project.OwnerID
}

// chargeMemory debits the payer for a project's memory, paid to the provider
// key's owner, in the project's spend and budget.
func (a *Adapter) chargeMemory(ctx context.Context, space, payer, payee identity.ID, amount int64, desc string) error {
	if a.memoryChargeFn != nil {
		return a.memoryChargeFn(ctx, space, payer, payee, amount, desc)
	}
	if a.k == nil {
		return nil
	}
	exec := vmm.Execution{ActorID: payer.String()}
	if !space.IsZero() {
		exec.SpaceID = space.String()
	}
	ctx = vmm.WithExecution(ctx, exec)
	lines := []wallet.ChargeLine{{Amount: amount, Payees: []identity.ID{payee}, Type: wallet.EntryPayLLM,
		Category: wallet.CategoryLLM, Desc: desc}}
	return bridge.Invoke(ctx, a.k, "finance", "ChargeLines", []any{ctx, payer, desc, lines})
}

// startMemoryBilling charges metered memory use until stopMemoryBilling.
func (a *Adapter) startMemoryBilling() {
	stop := make(chan struct{})
	a.memory.mu.Lock()
	a.memory.stop = stop
	a.memory.mu.Unlock()
	go func() {
		tick := time.NewTicker(memoryBillEvery)
		defer tick.Stop()
		for {
			select {
			case <-stop:
				return
			case <-tick.C:
				a.billMemory(context.Background())
			}
		}
	}()
}

// stopMemoryBilling stops the charging and charges what is due now.
func (a *Adapter) stopMemoryBilling(ctx context.Context) {
	a.memory.mu.Lock()
	stop := a.memory.stop
	a.memory.stop = nil
	a.memory.mu.Unlock()
	if stop != nil {
		close(stop)
	}
	a.billMemory(ctx)
}
