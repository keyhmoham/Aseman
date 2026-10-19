// Package wallet defines the in-platform wallet used to pay for VM (bot)
// execution live. Amounts are integer "credits" (the smallest unit).
package wallet

import (
	"time"

	"github.com/tradera/tradera/internal/plugins/identity"
)

// Wallet is the balance record of one account.
type Wallet struct {
	ID        identity.ID `db:"id" json:"id"`
	OwnerID   identity.ID `db:"owner_id" json:"owner_id"`
	Balance   int64       `db:"balance" json:"balance"` // spendable credits
	Locked    int64       `db:"locked" json:"locked"`   // credits locked for VM pools
	UpdatedAt time.Time   `db:"updated_at" json:"updated_at"`
}

// Available returns the spendable balance.
func (w *Wallet) Available() int64 { return w.Balance }

// LockedTotal returns credits currently reserved in pools.
func (w *Wallet) LockedTotal() int64 { return w.Locked }

// EntryType of a ledger entry.
type EntryType string

const (
	EntryMint     EntryType = "mint"      // fiat -> credits at central node
	EntryTransfer EntryType = "transfer"  // user -> user
	EntryPoolLock EntryType = "pool_lock" // credits locked into a VM execution pool
	EntryPoolFree EntryType = "pool_free" // unused pool credits returned
	EntrySpend    EntryType = "spend"     // VM (bot) execution consumption
	EntryPayBot   EntryType = "pay_bot"   // customer pays bot owner
	EntryPayNode  EntryType = "pay_node"  // customer pays node owner
	EntryPayLLM   EntryType = "pay_llm"   // customer pays the LLM API key owner for tokens/images
)

// LedgerEntry is an immutable financial record in the distributed ledger.
type LedgerEntry struct {
	ID          identity.ID     `db:"id" json:"id"`
	Seq         int64           `db:"seq" json:"seq"` // deterministic global order
	NodeID      identity.NodeID `db:"node_id" json:"node_id"`
	Type        EntryType       `db:"type" json:"type"`
	FromID      identity.ID     `db:"from_id" json:"from_id,omitempty"`
	ToID        identity.ID     `db:"to_id" json:"to_id,omitempty"`
	Amount      int64           `db:"amount" json:"amount"`
	Description string          `db:"description" json:"description,omitempty"`
	CreatedAt   time.Time       `db:"created_at" json:"created_at"`
}

// ChargeLine is one part of a metered charge: Amount credits split evenly
// between the eligible Payees (the customer itself and accounts without a
// wallet are skipped), recorded with entry Type (or the payee's entry in
// PayeeTypes when set).
type ChargeLine struct {
	Amount     int64
	Payees     []identity.ID
	PayeeTypes []EntryType // optional, parallel to Payees
	Type       EntryType
	Desc       string
	// Category says what the line pays for, for per-project usage:
	// CategoryAgent (an agent's time), CategoryCompute (the project's
	// computer), CategoryTool (an app's time and calls) or
	// CategoryLLM (model tokens and images). Empty lines are classified by
	// their payees, as before.
	Category string
	// Bot is the bot the line is for (a tool called by an agent is billed
	// under the tool, not the agent that called it).
	Bot string
}

// Charge line categories.
const (
	CategoryAgent   = "agent"
	CategoryCompute = "compute"
	CategoryTool    = "tool"
	CategoryLLM     = "llm"
)
