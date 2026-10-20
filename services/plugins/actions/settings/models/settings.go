package models

import (
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"time"
)

type Settings struct {
	ID        string         `db:"id" json:"id"`
	Values    map[string]any `db:"values" json:"values"`
	Version   int64          `db:"version" json:"version"`
	UpdatedAt time.Time      `db:"updated_at" json:"updated_at"`
}

func Models() []database.Model {
	return []database.Model{{Name: "platform_settings", Table: "platform_settings", Fields: []database.Field{{Name: "id", Kind: database.KindString}, {Name: "values", Kind: database.KindJSON}, {Name: "version", Kind: database.KindInt64}, {Name: "updated_at", Kind: database.KindTime}}}}
}

// Rate is what a minute of execution costs (credits): a flat rate plus a rate
// per unit of the resources the VM was given.
type Rate struct {
	PerMinute      int64 `json:"per_minute"`
	CPUPerMin      int64 `json:"cpu_per_min"`       // per vCPU
	MemoryPerGBMin int64 `json:"memory_per_gb_min"` // per GB of RAM
	DiskPerGBMin   int64 `json:"disk_per_gb_min"`   // per GB of disk
}

// Zero reports whether the rate charges nothing.
func (r Rate) Zero() bool {
	return r.PerMinute == 0 && r.CPUPerMin == 0 && r.MemoryPerGBMin == 0 && r.DiskPerGBMin == 0
}

// Valid reports whether every component is non-negative.
func (r Rate) Valid() bool {
	return r.PerMinute >= 0 && r.CPUPerMin >= 0 && r.MemoryPerGBMin >= 0 && r.DiskPerGBMin >= 0
}

// Pricing is the node's price list for execution (credits; 1,000,000 credits
// = 1 USD). Model tokens are priced per model on their LLM provider.
type Pricing struct {
	// Sandbox is every space's shared computer.
	Sandbox Rate `json:"sandbox"`
	// Tool is what apps cost when none is set on the tool itself.
	Tool Rate `json:"tool"`
	// AgentPerMinute is an agent's time when the agent sets no rate of its own.
	AgentPerMinute int64 `json:"agent_per_minute"`
	// StorageGBMonth is what a developer organization pays for each GB it keeps
	// in Storage for a month (ledger units), charged by the hour.
	StorageGBMonth int64 `json:"storage_gb_month"`
}

// DefaultStorageGBMonth is $0.05 per GB-month: a few times what the object store costs.
const DefaultStorageGBMonth int64 = 50_000

// DefaultPricing is the price list before an administrator sets one.
func DefaultPricing() Pricing {
	return Pricing{Sandbox: Rate{PerMinute: 1}, Tool: Rate{PerMinute: 1}, AgentPerMinute: 1, StorageGBMonth: DefaultStorageGBMonth}
}

// Machine is the size of a project's computer, set from the admin console.
//
//   - CPU, MemoryMB and DiskMB are the size projects are sold at: what customers
//     are billed for (Pricing), and what a computer is created with.
//   - ReserveCPU and ReserveMemoryMB are the small share the provider guarantees
//     (and bills) while the computer is awake and idle.
//   - MaxCPU and MaxMemoryMB are the most a busy computer may use.
//
// A value of zero in what is stored means "automatic"; Machine on the service
// returns every field filled in.
type Machine struct {
	CPU             float64 `json:"cpu"`
	MemoryMB        int64   `json:"memory_mb"`
	DiskMB          int64   `json:"disk_mb"`
	ReserveCPU      float64 `json:"reserve_cpu"`
	ReserveMemoryMB int64   `json:"reserve_memory_mb"`
	MaxCPU          float64 `json:"max_cpu"`
	MaxMemoryMB     int64   `json:"max_memory_mb"`
	// The sandbox provider's own limits, a safety net under the platform's idle
	// stop: it ends a computer the node has lost track of.
	//   - ProviderIdleMin: minutes without activity before the provider ends it.
	//   - MaxLifetimeMin: the longest minutes one computer may run, busy or not.
	//   - CommandTimeoutSec: the longest one command may run.
	ProviderIdleMin   int64 `json:"provider_idle_min"`
	MaxLifetimeMin    int64 `json:"max_lifetime_min"`
	CommandTimeoutSec int64 `json:"command_timeout_sec"`
}

// The provider limits a computer gets when none are set.
const (
	DefaultProviderIdleMin   = 30
	DefaultMaxLifetimeMin    = 8 * 60
	DefaultCommandTimeoutSec = 300
)
