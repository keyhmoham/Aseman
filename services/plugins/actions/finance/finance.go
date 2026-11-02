// Package finance implements the finance namespace: wallets, the distributed
// ledger, token pools for VM execution and payments. The central node mints
// credits and broadcasts ledger changes; other nodes hold replicas.
package finance

import (
	"context"
	"encoding/json"
	"strconv"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/internal/plugins/signing"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/mechanisms/mail"
	nodetypes "github.com/aseman/aseman/plugins/actions/federation/models/node"
	financial "github.com/aseman/aseman/plugins/actions/finance/models"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
	network "github.com/aseman/aseman/plugins/adapters/network/ports"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Service implements finance operations.
type Service struct {
	K api.Kernel
	R *repo.Repo
	L *logger.Logger

	// chargesAsked is when each account's purchase revenue was last looked up.
	chargesMu    sync.Mutex
	chargesAsked map[string]time.Time

	// Mail sends the credit request emails; nil until first used (see mailer).
	Mail mail.Sender
}

// GetWallet loads a wallet by owner.
func (s *Service) GetWallet(ctx context.Context, owner identity.ID) (*wallet.Wallet, error) {
	var list []wallet.Wallet
	if err := s.R.List(ctx, "wallets", database.Filter{Equal: map[string]any{"owner_id": owner.String()}}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, errs.NotFound("wallet for " + owner.String())
	}
	return &list[0], nil
}

func (s *Service) persist(ctx context.Context, w *wallet.Wallet) error {
	w.UpdatedAt = time.Now().UTC()
	return s.R.Update(ctx, "wallets", w.ID, w)
}

// nextSeq returns the next deterministic ledger sequence number.
func (s *Service) nextSeq(ctx context.Context) (int64, error) {
	max, err := s.MaxSeq(ctx)
	if err != nil {
		return 0, err
	}
	return max + 1, nil
}

// MaxSeq returns the highest local ledger sequence.
func (s *Service) MaxSeq(ctx context.Context) (int64, error) {
	var max int64
	var entries []wallet.LedgerEntry
	if err := s.R.List(ctx, "ledger", database.Filter{OrderBy: "seq", Asc: false, Limit: 1}, &entries); err != nil {
		return 0, err
	}
	if len(entries) > 0 {
		max = entries[0].Seq
	}
	return max, nil
}

// appendLedger records an immutable ledger entry and broadcasts it to peers.
func (s *Service) appendLedger(ctx context.Context, typ wallet.EntryType, from, to identity.ID, amount int64, desc string) (*wallet.LedgerEntry, error) {
	seq, err := s.nextSeq(ctx)
	if err != nil {
		return nil, err
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	entry := &wallet.LedgerEntry{
		ID: id, Seq: seq, NodeID: s.K.NodeID(), Type: typ,
		FromID: from, ToID: to, Amount: amount, Description: desc,
		CreatedAt: time.Now().UTC(),
	}
	if err := s.R.CreateID(ctx, "ledger", id, entry); err != nil {
		return nil, err
	}
	s.broadcast(ctx, entry)
	return entry, nil
}

// AppendReplica appends a ledger entry replicated from a peer. Entries are
// accepted only in strict monotonic seq order (deterministic replication);
// duplicates and out-of-order entries are ignored.
func (s *Service) AppendReplica(ctx context.Context, entry *wallet.LedgerEntry) error {
	if entry.ID.IsZero() || entry.Seq <= 0 {
		return errs.InvalidArgument("invalid replicated ledger entry")
	}
	max, err := s.MaxSeq(ctx)
	if err != nil {
		return err
	}
	if entry.Seq <= max {
		s.L.Debug("ledger replica entry skipped (already applied)", "seq", entry.Seq, "local_max", max)
		return nil
	}
	if err := s.R.CreateID(ctx, "ledger", entry.ID, entry); err != nil {
		if errs.CodeOf(err) == errs.CodeAlreadyExists {
			return nil
		}
		return err
	}
	s.L.Info("ledger replica appended", "seq", entry.Seq, "node", entry.NodeID.String(), "type", entry.Type)
	return nil
}

// broadcast pushes a ledger entry to every known peer so replicas converge in
// seq order. Requests are signed with the node keypair and run with their own
// context (the action context is cancelled when the handler returns).
func (s *Service) broadcast(ctx context.Context, entry *wallet.LedgerEntry) {
	net := s.K.Network()
	if net == nil {
		return
	}
	priv := s.K.Env()["node_private_key"]
	if priv == "" {
		return
	}
	bctx := context.WithoutCancel(ctx)
	selfURL := s.K.Env()["node_url"]
	var peers []nodetypes.Node
	if err := s.R.List(ctx, "nodes", database.Filter{}, &peers); err != nil {
		return
	}
	body, err := json.Marshal(entry)
	if err != nil {
		return
	}
	for _, p := range peers {
		if p.ID == s.K.NodeID() || p.URL == "" || p.URL == selfURL {
			continue
		}
		go s.pushReplica(bctx, p.URL, body, priv)
	}
}

// pushReplica delivers a signed ledger entry to one peer.
func (s *Service) pushReplica(ctx context.Context, url string, body []byte, priv string) {
	pctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	headers, err := signing.SignRequest(priv, "POST", "/fed/ledger", body)
	if err != nil {
		return
	}
	headers[signing.HdrNode] = s.K.NodeID().String()
	net := s.K.Network()
	if net == nil {
		return
	}
	resp, err := net.Call(pctx, url, &network.Request{
		Method: network.MethodPost, Path: "/fed/ledger", Header: headers, Body: body,
	})
	if err != nil {
		s.L.Warn("ledger broadcast failed", "peer", url, "error", err)
		return
	}
	_ = resp
}

// Mint creates credits on the central node (fiat -> credits) and credits the
// target wallet.
func (s *Service) Mint(ctx context.Context, operator, target identity.ID, amount int64, desc string) (*wallet.LedgerEntry, error) {
	return s.mint(ctx, operator, target, amount, desc, false)
}

// mint is Mint; restricted credits can't be used on the Developer API or sent on.
func (s *Service) mint(ctx context.Context, operator, target identity.ID, amount int64, desc string, restricted bool) (*wallet.LedgerEntry, error) {
	if amount <= 0 {
		return nil, errs.InvalidArgument("amount must be positive")
	}
	if !s.isCentral() {
		return nil, errs.Permission("minting is only allowed on the central node")
	}
	w, err := s.GetWallet(ctx, target)
	if err != nil {
		return nil, err
	}
	if restricted {
		w.Restricted += amount
	}
	if _, err := s.credit(ctx, w, amount); err != nil {
		return nil, err
	}
	entry, err := s.appendLedger(ctx, wallet.EntryMint, operator, target, amount, desc)
	if err != nil {
		return nil, err
	}
	return entry, nil
}

// Transfer moves credits between wallets. Both wallets are resolved BEFORE any
// mutation so a missing recipient never swallows the sender's balance.
func (s *Service) Transfer(ctx context.Context, from identity.ID, to identity.ID, amount int64) (*wallet.LedgerEntry, error) {
	if amount <= 0 {
		return nil, errs.InvalidArgument("amount must be positive")
	}
	if from == to {
		return nil, errs.InvalidArgument("cannot transfer to self")
	}
	src, err := s.GetWallet(ctx, from)
	if err != nil {
		return nil, err
	}
	if src.Available() < amount {
		return nil, errs.New(errs.CodeFinance, "insufficient balance")
	}
	if src.Unrestricted() < amount {
		return nil, errs.New(errs.CodeFinance, "complimentary credits can’t be sent to others or to the Developer API")
	}
	dst, err := s.GetWallet(ctx, to)
	if err != nil {
		return nil, err
	}
	// Only the unrestricted part can be sent, so the restricted credits stay put.
	if err := s.debit(wallet.WithoutRestricted(ctx), src, amount); err != nil {
		return nil, err
	}
	if _, err := s.credit(ctx, dst, amount); err != nil {
		// Roll back the debit so the sender's balance is never lost.
		_, _ = s.credit(ctx, src, amount)
		return nil, err
	}
	return s.appendLedger(ctx, wallet.EntryTransfer, from, to, amount, "transfer")
}

// PoolCreate locks credits from a wallet into an execution pool.
func (s *Service) PoolCreate(ctx context.Context, owner identity.ID, amount int64, poolRef string) (*wallet.LedgerEntry, error) {
	if amount <= 0 {
		return nil, errs.InvalidArgument("amount must be positive")
	}
	w, err := s.GetWallet(ctx, owner)
	if err != nil {
		return nil, err
	}
	if w.Available() < amount {
		return nil, errs.New(errs.CodeFinance, "insufficient balance to lock pool")
	}
	w.Spent(ctx, amount)
	w.Locked += amount
	if err := s.persist(ctx, w); err != nil {
		return nil, err
	}
	return s.appendLedger(ctx, wallet.EntryPoolLock, owner, identity.ID{}, amount, "pool lock "+poolRef)
}

// PoolFree returns locked credits to the wallet.
func (s *Service) PoolFree(ctx context.Context, owner identity.ID, amount int64, poolRef string) (*wallet.LedgerEntry, error) {
	if amount <= 0 {
		return nil, errs.InvalidArgument("amount must be positive")
	}
	w, err := s.GetWallet(ctx, owner)
	if err != nil {
		return nil, err
	}
	if w.Locked < amount {
		return nil, errs.New(errs.CodeFinance, "locked amount insufficient")
	}
	w.Locked -= amount
	w.Balance += amount
	if err := s.persist(ctx, w); err != nil {
		return nil, err
	}
	return s.appendLedger(ctx, wallet.EntryPoolFree, owner, identity.ID{}, amount, "pool free "+poolRef)
}

// PoolConsume spends credits from the pool for live VM execution.
func (s *Service) PoolConsume(ctx context.Context, owner identity.ID, amount int64, poolRef string) (*wallet.LedgerEntry, error) {
	if amount <= 0 {
		return nil, errs.InvalidArgument("amount must be positive")
	}
	w, err := s.GetWallet(ctx, owner)
	if err != nil {
		return nil, err
	}
	if w.Locked < amount {
		return nil, errs.New(errs.CodeFinance, "pool exhausted")
	}
	w.Locked -= amount
	if err := s.persist(ctx, w); err != nil {
		return nil, err
	}
	return s.appendLedger(ctx, wallet.EntrySpend, owner, identity.ID{}, amount, "vm consumption "+poolRef)
}

// PayBot pays the bot owner from a customer's wallet for bot usage. Money moves
// in a single ledger entry (EntryPayBot).
func (s *Service) PayBot(ctx context.Context, customer identity.ID, botOwner identity.ID, amount int64) (*wallet.LedgerEntry, error) {
	if amount <= 0 {
		return nil, errs.InvalidArgument("amount must be positive")
	}
	src, err := s.GetWallet(ctx, customer)
	if err != nil {
		return nil, err
	}
	if src.Available() < amount {
		return nil, errs.New(errs.CodeFinance, "insufficient balance")
	}
	dst, err := s.GetWallet(ctx, botOwner)
	if err != nil {
		return nil, err
	}
	if err := s.debit(ctx, src, amount); err != nil {
		return nil, err
	}
	if _, err := s.credit(ctx, dst, amount); err != nil {
		_, _ = s.credit(ctx, src, amount)
		return nil, err
	}
	return s.appendLedger(ctx, wallet.EntryPayBot, customer, botOwner, amount, "bot usage payment")
}

// PayNode pays the node owner from a customer's wallet for VM execution on
// their node. Money moves in a single ledger entry (EntryPayNode).
func (s *Service) PayNode(ctx context.Context, customer identity.ID, nodeOwner identity.ID, amount int64) (*wallet.LedgerEntry, error) {
	if amount <= 0 {
		return nil, errs.InvalidArgument("amount must be positive")
	}
	src, err := s.GetWallet(ctx, customer)
	if err != nil {
		return nil, err
	}
	if src.Available() < amount {
		return nil, errs.New(errs.CodeFinance, "insufficient balance")
	}
	dst, err := s.GetWallet(ctx, nodeOwner)
	if err != nil {
		return nil, err
	}
	if err := s.debit(ctx, src, amount); err != nil {
		return nil, err
	}
	if _, err := s.credit(ctx, dst, amount); err != nil {
		_, _ = s.credit(ctx, src, amount)
		return nil, err
	}
	return s.appendLedger(ctx, wallet.EntryPayNode, customer, nodeOwner, amount, "node usage payment")
}

// Bill charges a customer's wallet for bot/sandbox execution measured in
// seconds, priced by the bot's per-minute cost, and splits the proceeds between
// the bot owner (when using someone else's agent/tool) and the node owner
// (infrastructure). Recipients are resolved before any money moves so a missing
// wallet never consumes the charge.
func (s *Service) Bill(ctx context.Context, customer, botOwner, nodeOwner identity.ID, perMinute, seconds int64, desc string) error {
	if perMinute <= 0 {
		return nil
	}
	if seconds < 1 {
		seconds = 1 // floor: every execution is metered at least one second
	}
	cost := (seconds*perMinute + 59) / 60 // ceil to whole credits
	if cost <= 0 {
		cost = 1
	}
	return s.Charge(ctx, customer, botOwner, nodeOwner, cost, desc)
}

// Charge debits an exact credit amount from a customer's wallet and pays the
// bot owner / node owner. Recipients are resolved before any money moves.
func (s *Service) Charge(ctx context.Context, customer, botOwner, nodeOwner identity.ID, amount int64, desc string) error {
	return s.ChargeLines(ctx, customer, desc, []wallet.ChargeLine{{
		Amount: amount, Payees: []identity.ID{botOwner, nodeOwner},
		PayeeTypes: []wallet.EntryType{wallet.EntryPayBot, wallet.EntryPayNode}, Desc: desc,
	}})
}

// ChargeLines debits a customer's wallet for several charge lines at once
// (e.g. bot execution split between the bot owner and node owner, plus LLM
// token usage paid entirely to the API key owner). Every line's recipients are
// resolved and the full total checked against the balance before any money
// moves; a line with no eligible recipient is not charged.
func (s *Service) ChargeLines(ctx context.Context, customer identity.ID, desc string, lines []wallet.ChargeLine) error {
	type payout struct {
		id     identity.ID
		typ    wallet.EntryType
		amount int64
		desc   string
	}
	var payouts []payout
	var total int64
	// What each category cost and which bot the charge is for, for the
	// project's usage record.
	byCategory := map[string]int64{}
	// Work whose only recipient is the customer themselves (the node's owner
	// using their own computer or model key): no money moves, but it is still
	// usage, and the project's record says so.
	ownByCategory := map[string]int64{}
	var own int64
	subject := ""
	for _, line := range lines {
		if line.Amount <= 0 {
			continue
		}
		typ := line.Type
		if typ == "" {
			typ = wallet.EntryPayBot
		}
		type target struct {
			id  identity.ID
			typ wallet.EntryType
		}
		var targets []target
		seen := map[identity.ID]bool{}
		toSelf := false
		for i, id := range line.Payees {
			if id == customer && !id.IsZero() {
				toSelf = true
			}
			if id.IsZero() || id == customer || seen[id] {
				continue
			}
			seen[id] = true
			if s.walletExists(ctx, id) {
				t := typ
				if i < len(line.PayeeTypes) && line.PayeeTypes[i] != "" {
					t = line.PayeeTypes[i]
				}
				targets = append(targets, target{id, t})
			}
		}
		if len(targets) == 0 {
			if toSelf {
				category := line.Category
				if category == "" {
					category = wallet.CategoryAgent
				}
				ownByCategory[category] += line.Amount
				own += line.Amount
				if subject == "" && line.Bot != "" && category != wallet.CategoryLLM {
					subject = line.Bot
				}
			}
			continue
		}
		ldesc := line.Desc
		if ldesc == "" {
			ldesc = desc
		}
		base := line.Amount / int64(len(targets))
		rem := line.Amount - base*int64(len(targets))
		for i, t := range targets {
			amt := base
			if i == 0 {
				amt += rem
			}
			if amt <= 0 {
				continue
			}
			payouts = append(payouts, payout{t.id, t.typ, amt, ldesc})
		}
		total += line.Amount
		category := line.Category
		if category == "" { // lines from older callers: classify by who is paid
			category = wallet.CategoryAgent
			for _, t := range targets {
				switch t.typ {
				case wallet.EntryPayLLM:
					category = wallet.CategoryLLM
				case wallet.EntryPayNode:
					category = wallet.CategoryCompute
				}
			}
		}
		byCategory[category] += line.Amount
		if subject == "" && line.Bot != "" && category != wallet.CategoryLLM {
			subject = line.Bot
		}
	}
	if total <= 0 && own <= 0 {
		return nil
	}
	src, err := s.GetWallet(ctx, customer)
	if err != nil {
		return err
	}

	destinations := map[string]*wallet.Wallet{}
	for _, p := range payouts {
		w, e := s.GetWallet(ctx, p.id)
		if e != nil {
			return e
		}
		destinations[p.id.String()] = w
	}
	execution := vmm.ExecutionFrom(ctx)
	return s.moneyOperation(ctx, func(ctx context.Context, tx database.Tx, seq int64) error {
		if total > 0 { // the money part; skipped when the work was all the customer's own
			var source wallet.Wallet
			if e := tx.Get(ctx, "wallets", src.ID.String(), &source); e != nil {
				return e
			}
			if source.Spendable(ctx) < total {
				return errs.New(errs.CodeFinance, "insufficient balance for "+desc)
			}
			if e := s.chargeBudget(ctx, tx, execution.SpaceID, total); e != nil {
				return e
			}
			source.Spent(ctx, total)
			source.UpdatedAt = time.Now().UTC()
			if e := tx.Update(ctx, "wallets", src.ID.String(), &source); e != nil {
				return e
			}
			if e := s.entry(ctx, tx, seq, wallet.EntrySpend, customer, identity.ID{}, total, "execution "+desc); e != nil {
				return e
			}
			seq++
		}
		for _, p := range payouts {
			target := destinations[p.id.String()]
			var dst wallet.Wallet
			if e := tx.Get(ctx, "wallets", target.ID.String(), &dst); e != nil {
				return e
			}
			dst.Balance += p.amount
			dst.UpdatedAt = time.Now().UTC()
			if e := tx.Update(ctx, "wallets", dst.ID.String(), &dst); e != nil {
				return e
			}
			if e := s.entry(ctx, tx, seq, p.typ, customer, p.id, p.amount, p.desc); e != nil {
				return e
			}
			seq++
		}
		if execution.SpaceID != "" {
			id, e := identity.New(s.K.NodeID())
			if e != nil {
				return e
			}
			name := ""
			var project struct {
				Name string `db:"name"`
			}
			if e := tx.Get(ctx, "spaces", execution.SpaceID, &project); e == nil {
				name = project.Name
			}
			botID := execution.AgentID
			if subject != "" {
				botID = subject
			}
			record := financial.Record{ID: id.String(), Owner: customer.String(), Kind: "settlement", Amount: total, Status: "completed", Data: map[string]any{"space_id": execution.SpaceID, "space_name": name, "room_id": execution.RoomID, "bot_id": botID, "agent_id": execution.AgentID, "run_id": execution.RunID, "description": desc, "llm_minor": byCategory[wallet.CategoryLLM], "compute_minor": byCategory[wallet.CategoryCompute], "tool_minor": byCategory[wallet.CategoryTool], "agent_minor": byCategory[wallet.CategoryAgent],
				// Usage that cost the customer nothing because it was their own; Amount and the *_minor keys above are money only.
				"own_minor": own, "own_llm_minor": ownByCategory[wallet.CategoryLLM], "own_compute_minor": ownByCategory[wallet.CategoryCompute], "own_tool_minor": ownByCategory[wallet.CategoryTool], "own_agent_minor": ownByCategory[wallet.CategoryAgent]}, CreatedAt: time.Now().UTC(), UpdatedAt: time.Now().UTC()}
			if e = tx.Create(ctx, "financial_records", id.String(), &record); e != nil {
				return e
			}
		}
		return nil
	})
}

// EnsureWallet gives an owner a wallet when it has none: an organization of
// the developer API has its own balance, apart from any person's.
func (s *Service) EnsureWallet(ctx context.Context, owner identity.ID) error {
	if s.walletExists(ctx, owner) {
		return nil
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	return s.R.CreateID(ctx, "wallets", id, &wallet.Wallet{ID: id, OwnerID: owner, UpdatedAt: time.Now().UTC()})
}

func (s *Service) walletExists(ctx context.Context, owner identity.ID) bool {
	_, err := s.GetWallet(ctx, owner)
	return err == nil
}

// EnsureFunds verifies a customer's wallet can cover a minimum cost before an
// execution is allowed to run. This is the hard-enforcement gate for metered
// agents, tools and sandbox usage.
func (s *Service) EnsureFunds(ctx context.Context, customer identity.ID, minCost int64) error {
	scope := vmm.ExecutionFrom(ctx).SpaceID
	if scope != "" {
		budget, e := s.Budget(ctx, scope)
		if e != nil {
			return e
		}
		cap, spent := moneyNumber(budget["cap"]), moneyNumber(budget["spent"])
		if cap > 0 && spent+minCost > cap {
			return errs.New(errs.CodeFinance, "project budget exceeded")
		}
	}

	if minCost <= 0 {
		return nil
	}
	w, err := s.GetWallet(ctx, customer)
	if err != nil {
		return err
	}
	if w.Spendable(ctx) < minCost {
		return errs.New(errs.CodeFinance,
			"insufficient balance to run metered execution (needs "+itoa(minCost)+" credits, has "+itoa(w.Spendable(ctx))+")")
	}
	return nil
}

func itoa(n int64) string {
	return strconv.FormatInt(n, 10)
}

func (s *Service) credit(ctx context.Context, w *wallet.Wallet, amount int64) (*wallet.Wallet, error) {
	w.Balance += amount
	if err := s.persist(ctx, w); err != nil {
		return nil, err
	}
	return w, nil
}

func (s *Service) debit(ctx context.Context, w *wallet.Wallet, amount int64) error {
	w.Spent(ctx, amount)
	if err := s.persist(ctx, w); err != nil {
		return err
	}
	return nil
}

func (s *Service) isCentral() bool {
	return s.K.Env()["central"] == "true"
}

// ListLedger returns ledger entries (ordered, paged).
func (s *Service) ListLedger(ctx context.Context, limit int) ([]wallet.LedgerEntry, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	var out []wallet.LedgerEntry
	if err := s.R.List(ctx, "ledger", database.Filter{OrderBy: "seq", Asc: false, Limit: limit}, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// Faucet claims a small demo credit for the caller so wallet flows can be
// exercised without central-node admin access. Rate limited to one claim per
// minute per account.
func (s *Service) Faucet(ctx context.Context, user identity.ID) (*wallet.LedgerEntry, error) {
	var recent []wallet.LedgerEntry
	if err := s.R.List(ctx, "ledger", database.Filter{
		Equal: map[string]any{
			"from_id": user.String(), "type": string(wallet.EntryMint),
		},
		OrderBy: "created_at", Asc: false, Limit: 1,
	}, &recent); err == nil && len(recent) > 0 {
		if time.Since(recent[0].CreatedAt) < time.Minute {
			return nil, errs.New(errs.CodeFinance,
				"faucet recently claimed; try again in a moment")
		}
	}
	return s.Mint(ctx, user, user, 1000, "faucet demo credit")
}

// BuildActions assembles the finance namespace actions.
func BuildActions(s *Service) []api.Action {
	return append([]api.Action{
		&walletGetAction{s: s}, &walletMintAction{s: s},
		&poolCreateAction{s: s}, &poolFreeAction{s: s}, &poolConsumeAction{s: s},
		&payBotAction{s: s}, &ledgerListAction{s: s}, &faucetAction{s: s},
	}, clientActions(s)...)
}

// --- actions ---

type walletGetAction struct{ s *Service }

func (a *walletGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "finance", Name: "wallet_get", Summary: "Get my wallet balance"}
}
func (a *walletGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Account string `json:"account,omitempty"`
	}
	_ = helper.Decode(req, &in)
	targetID := req.Caller.ID
	if in.Account != "" {
		if err := helper.RequireNodeAdmin(ctx, a.s.R, req, a.s.K.Env()["admin_handle"]); err != nil {
			return nil, err
		}
		parsed, err := identity.Parse(in.Account)
		if err != nil {
			return nil, err
		}
		targetID = parsed
	}
	w, err := a.s.GetWallet(ctx, targetID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"balance": w.Balance, "locked": w.Locked, "available": w.Available(), "restricted": w.Restricted, "developer_available": w.Unrestricted()})
}

type walletMintAction struct{ s *Service }

func (a *walletMintAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "finance", Name: "wallet_mint", Summary: "Mint credits (central node only)"}
}
func (a *walletMintAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Target string `json:"target"`
		Amount int64  `json:"amount"`
		Reason string `json:"reason,omitempty"`
		// ExpiresAt (RFC 3339) makes the grant lapse; empty means it never does.
		ExpiresAt string `json:"expires_at,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	target, err := identity.Parse(in.Target)
	if err != nil {
		return nil, err
	}
	var entry *wallet.LedgerEntry
	if in.ExpiresAt != "" {
		at, perr := time.Parse(time.RFC3339, in.ExpiresAt)
		if perr != nil {
			return nil, errs.InvalidArgument("expires_at must be an RFC 3339 time")
		}
		entry, err = a.s.MintExpiring(ctx, req.Caller.ID, target, in.Amount, in.Reason, at)
	} else {
		entry, err = a.s.Mint(ctx, req.Caller.ID, target, in.Amount, in.Reason)
	}
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"seq": entry.Seq, "amount": entry.Amount})
}

type transferAction struct{ s *Service }

func (a *transferAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "finance", Name: "transfer", Summary: "Transfer credits to another account"}
}
func (a *transferAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		To     string `json:"to"`
		Amount int64  `json:"amount"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	to, err := identity.Parse(in.To)
	if err != nil {
		return nil, err
	}
	entry, err := a.s.Transfer(ctx, req.Caller.ID, to, in.Amount)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"seq": entry.Seq, "amount": entry.Amount})
}

type poolCreateAction struct{ s *Service }

func (a *poolCreateAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "finance", Name: "pool_create", Summary: "Lock credits into a VM execution pool"}
}
func (a *poolCreateAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Pool   string `json:"pool"`
		Amount int64  `json:"amount"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	entry, err := a.s.PoolCreate(ctx, req.Caller.ID, in.Amount, in.Pool)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"seq": entry.Seq, "pool": in.Pool, "locked": true})
}

type poolFreeAction struct{ s *Service }

func (a *poolFreeAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "finance", Name: "pool_free", Summary: "Free unused locked credits"}
}
func (a *poolFreeAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Pool   string `json:"pool"`
		Amount int64  `json:"amount"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	entry, err := a.s.PoolFree(ctx, req.Caller.ID, in.Amount, in.Pool)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"seq": entry.Seq, "pool": in.Pool})
}

type poolConsumeAction struct{ s *Service }

func (a *poolConsumeAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "finance", Name: "pool_consume", Summary: "Consume locked credits for live VM execution"}
}
func (a *poolConsumeAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Pool   string `json:"pool"`
		Amount int64  `json:"amount"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	entry, err := a.s.PoolConsume(ctx, req.Caller.ID, in.Amount, in.Pool)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"seq": entry.Seq, "pool": in.Pool, "consumed": entry.Amount})
}

type payBotAction struct{ s *Service }

func (a *payBotAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "finance", Name: "pay_bot", Summary: "Pay a bot owner for bot usage"}
}
func (a *payBotAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		BotOwner string `json:"bot_owner"`
		Amount   int64  `json:"amount"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	owner, err := identity.Parse(in.BotOwner)
	if err != nil {
		return nil, err
	}
	entry, err := a.s.PayBot(ctx, req.Caller.ID, owner, in.Amount)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"seq": entry.Seq, "amount": entry.Amount})
}

type ledgerListAction struct{ s *Service }

func (a *ledgerListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "finance", Name: "ledger_list", Summary: "List the node's ledger entries (admins only)"}
}
func (a *ledgerListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	// The node's whole ledger: every account's movements. A person's own
	// activity is finance.account.
	if err := helper.RequireNodeAdmin(ctx, a.s.R, req, a.s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	var in struct {
		Limit int `json:"limit"`
	}
	_ = helper.Decode(req, &in)
	entries, err := a.s.ListLedger(ctx, in.Limit)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"entries": entries})
}

type faucetAction struct{ s *Service }

func (a *faucetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "finance", Name: "faucet", Summary: "Claim demo credits (rate limited)"}
}
func (a *faucetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	entry, err := a.s.Faucet(ctx, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"seq": entry.Seq, "amount": entry.Amount})
}
