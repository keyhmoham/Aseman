package deepagents

import (
	"context"
	"testing"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/openviking"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

type memoryCharge struct {
	space, payer, payee identity.ID
	amount              int64
	desc                string
}

// billingAdapter is an adapter whose memory models answer with the given
// usage, recording the charges it makes.
func billingAdapter(t *testing.T, usage string, chat vmm.ProviderConfig) (*Adapter, *[]memoryCharge, *error) {
	srv, _, _ := provider(t, func(path string, _ map[string]any) string {
		if path == "/v1/embeddings" {
			return `{"data":[{"index":0,"embedding":[1,0]}]` + usage + `}`
		}
		return `{"choices":[{"message":{"role":"assistant","content":"ok"}}]` + usage + `}`
	})
	chat.BaseURL = srv.URL + "/v1"
	embedding := chat
	a, _, _ := newTestAdapter(t)
	a.memoryKey = "root-key"
	a.platform = fakePlatform{memoryChat: &chat, memoryEmbedding: &embedding}
	charges := []memoryCharge{}
	var failWith error
	a.memoryRecordFn = func(identity.ID, int64, int64, int64) {}
	a.memoryChargeFn = func(_ context.Context, space, payer, payee identity.ID, amount int64, desc string) error {
		if failWith != nil {
			return failWith
		}
		charges = append(charges, memoryCharge{space, payer, payee, amount, desc})
		return nil
	}
	return a, &charges, &failWith
}

func memoryRequest(t *testing.T, a *Adapter, space identity.ID, body string, chat bool) *network.Response {
	t.Helper()
	header := map[string]string{"Authorization": "Bearer root-key"}
	if !space.IsZero() {
		header[MemoryAccountHeader] = openviking.SpaceAccount(space.String())
	}
	serve := a.serveMemoryEmbeddings
	if chat {
		serve = a.serveMemoryChat
	}
	resp, err := serve(context.Background(), &network.Request{Header: header, Body: []byte(body)})
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func ids(t *testing.T, n int) []identity.ID {
	out := make([]identity.ID, n)
	for i := range out {
		id, err := identity.New(1)
		if err != nil {
			t.Fatal(err)
		}
		out[i] = id
	}
	return out
}

func TestAProjectPaysForItsMemoryAtTheMemoryModelsPrices(t *testing.T) {
	p := ids(t, 3)
	space, person, keyOwner := p[0], p[1], p[2]
	// One ledger unit per input token, two per output token.
	a, charges, _ := billingAdapter(t, `,"usage":{"prompt_tokens":3,"completion_tokens":2}`,
		vmm.ProviderConfig{Model: "mini", InputPrice: 1e6, OutputPrice: 2e6, OwnerID: keyOwner.String()})
	a.memory.notePayer(space.String(), person.String())

	if resp := memoryRequest(t, a, space, `{"messages":[{"role":"user","content":"x"}]}`, true); resp.Status != 200 {
		t.Fatalf("%d %s", resp.Status, resp.Body)
	}
	a.billMemory(context.Background())
	if len(*charges) != 1 {
		t.Fatalf("charges: %+v", *charges)
	}
	c := (*charges)[0]
	if c.space != space || c.payer != person || c.payee != keyOwner || c.amount != 3+2*2 {
		t.Fatalf("charge: %+v", c)
	}
	// Nothing is charged twice.
	a.billMemory(context.Background())
	if len(*charges) != 1 {
		t.Fatalf("charged again: %+v", *charges)
	}
}

func TestAMemorySettlementIsRecordedForTheAdminLog(t *testing.T) {
	p := ids(t, 3)
	space, person, keyOwner := p[0], p[1], p[2]
	a, _, _ := billingAdapter(t, `,"usage":{"prompt_tokens":3,"completion_tokens":2}`,
		vmm.ProviderConfig{Model: "mini", InputPrice: 1e6, OutputPrice: 2e6, OwnerID: keyOwner.String()})
	a.memory.notePayer(space.String(), person.String())
	type rec struct {
		space                    identity.ID
		tokens, tokensIn, amount int64
	}
	var got []rec
	a.memoryRecordFn = func(sp identity.ID, tokens, tokensIn, amount int64) {
		got = append(got, rec{sp, tokens, tokensIn, amount})
	}
	memoryRequest(t, a, space, `{"messages":[{"role":"user","content":"x"}]}`, true)
	a.billMemory(context.Background())
	if len(got) != 1 || got[0] != (rec{space, 5, 3, 7}) {
		t.Fatalf("recorded: %+v", got)
	}
}

func TestSmallMemoryCallsAddUpBeforeTheyAreCharged(t *testing.T) {
	p := ids(t, 3)
	space, owner, keyOwner := p[0], p[1], p[2]
	// 0.6 of a ledger unit a call.
	a, charges, _ := billingAdapter(t, `,"usage":{"prompt_tokens":6,"total_tokens":6}`,
		vmm.ProviderConfig{Model: "embed", InputPrice: 1e5, OwnerID: keyOwner.String()})
	// Nobody has run an agent here since the node started: the owner pays.
	a.memoryOwnerFn = func(context.Context, identity.ID) identity.ID { return owner }

	memoryRequest(t, a, space, `{"input":"a note"}`, false)
	a.billMemory(context.Background())
	if len(*charges) != 0 {
		t.Fatalf("a fraction of a unit is not charged yet: %+v", *charges)
	}
	memoryRequest(t, a, space, `{"input":"a note"}`, false)
	a.billMemory(context.Background())
	if len(*charges) != 1 || (*charges)[0].amount != 1 || (*charges)[0].payer != owner {
		t.Fatalf("1.2 units: one charged: %+v", *charges)
	}
	// The 0.2 left over is carried: three more calls make 2.0.
	for i := 0; i < 3; i++ {
		memoryRequest(t, a, space, `{"input":"a note"}`, false)
	}
	a.billMemory(context.Background())
	if len(*charges) != 2 || (*charges)[1].amount != 2 {
		t.Fatalf("the fraction carries over: %+v", *charges)
	}
}

func TestAProjectThatCannotPayGetsNoMemoryModelsUntilItCan(t *testing.T) {
	p := ids(t, 3)
	space, person, keyOwner := p[0], p[1], p[2]
	a, charges, failWith := billingAdapter(t, `,"usage":{"prompt_tokens":5,"completion_tokens":0}`,
		vmm.ProviderConfig{Model: "mini", InputPrice: 1e6, OwnerID: keyOwner.String()})
	a.memory.notePayer(space.String(), person.String())
	a.memoryOwnerFn = func(context.Context, identity.ID) identity.ID { return person }
	memoryRequest(t, a, space, `{"messages":[]}`, true)

	*failWith = errs.New(errs.CodeFinance, "project budget exceeded")
	a.billMemory(context.Background())
	if resp := memoryRequest(t, a, space, `{"messages":[]}`, true); resp.Status != 402 {
		t.Fatalf("an unpaid project's memory is refused: %d", resp.Status)
	}
	// Another project is not affected.
	if resp := memoryRequest(t, a, ids(t, 1)[0], `{"messages":[]}`, true); resp.Status != 200 {
		t.Fatalf("another project: %d", resp.Status)
	}
	// Once the debt is paid, memory works again; nothing was lost.
	*failWith = nil
	a.billMemory(context.Background())
	mine := []memoryCharge{}
	for _, c := range *charges {
		if c.space == space {
			mine = append(mine, c)
		}
	}
	if len(mine) != 1 || mine[0].amount != 5 {
		t.Fatalf("the debt is charged when it can be: %+v", *charges)
	}
	if resp := memoryRequest(t, a, space, `{"messages":[]}`, true); resp.Status != 200 {
		t.Fatalf("paid up: %d", resp.Status)
	}
}

func TestMemoryCallsWithoutAProjectAreNotCharged(t *testing.T) {
	keyOwner := ids(t, 1)[0]
	a, charges, _ := billingAdapter(t, `,"usage":{"prompt_tokens":50}`,
		vmm.ProviderConfig{Model: "embed", InputPrice: 1e6, OwnerID: keyOwner.String()})
	memoryRequest(t, a, identity.ID{}, `{"input":"housekeeping"}`, false)
	// An account that is not a project's is not either.
	resp, _ := a.serveMemoryEmbeddings(context.Background(), &network.Request{Body: []byte(`{"input":"x"}`),
		Header: map[string]string{"Authorization": "Bearer root-key", MemoryAccountHeader: "default"}})
	if resp.Status != 200 {
		t.Fatalf("%d", resp.Status)
	}
	a.billMemory(context.Background())
	if len(*charges) != 0 {
		t.Fatalf("charges: %+v", *charges)
	}
}

func TestEmbeddingsWithoutUsageAreEstimated(t *testing.T) {
	p := ids(t, 3)
	space, person, keyOwner := p[0], p[1], p[2]
	a, charges, _ := billingAdapter(t, ``, vmm.ProviderConfig{Model: "embed", InputPrice: 1e6, OwnerID: keyOwner.String()})
	a.memory.notePayer(space.String(), person.String())
	memoryRequest(t, a, space, `{"input":["0123456789abcdef","0123"]}`, false) // 20 characters: 5 tokens
	a.billMemory(context.Background())
	if len(*charges) != 1 || (*charges)[0].amount != 5 {
		t.Fatalf("estimated: %+v", *charges)
	}
}

func TestAnIdleOrUnsetMemoryRecordsNothing(t *testing.T) {
	a, _, _ := newTestAdapter(t)
	a.memoryKey = "root-key"
	a.platform = fakePlatform{} // no memory models picked
	recorded := 0
	a.memoryRecordFn = func(identity.ID, int64, int64, int64) { recorded++ }
	space := ids(t, 1)[0]
	if resp := memoryRequest(t, a, space, `{"input":"x"}`, false); resp.Status != 409 {
		t.Fatalf("an unset model says so: %d", resp.Status)
	}
	a.billMemory(context.Background())
	a.billMemory(context.Background())
	if recorded != 0 {
		t.Fatalf("recorded %d settlements with the memory models off", recorded)
	}
}
