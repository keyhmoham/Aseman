// Package developer is the developer API: organizations with their own wallets,
// API keys, a unified model catalog served from the node's LLM providers, and
// the HTTP door (the developer host's /v1/...) that runs models, computers and
// storage, and exposes the non-admin platform action collection
// (/v1/platform/...) so a key can drive the same product surface as the
// Aseman client.
//
// The console (the app's Developer API pages) manages all of it through ordinary
// signed actions in this namespace; the API itself is plain bearer-key HTTP.
package developer

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
	"github.com/aseman/aseman/plugins/actions/llm/dto"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/filesystem/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Finance is what the namespace needs of the wallets: an organization is
// charged through its own wallet, and funded from a person's.
type Finance interface {
	EnsureWallet(ctx context.Context, owner identity.ID) error
	GetWallet(ctx context.Context, owner identity.ID) (*wallet.Wallet, error)
	Transfer(ctx context.Context, from, to identity.ID, amount int64) (*wallet.LedgerEntry, error)
	EnsureFunds(ctx context.Context, customer identity.ID, minCost int64) error
	ChargeLines(ctx context.Context, customer identity.ID, desc string, lines []wallet.ChargeLine) error
}

// Providers is the node's LLM provider catalog, with the keys.
type Providers interface {
	Offerings(ctx context.Context) ([]dto.Offering, error)
}

// Service is the developer namespace.
type Service struct {
	K         api.Kernel
	R         *repo.Repo
	L         *logger.Logger
	Fin       Finance
	Providers Providers
	// Infra is what computers need of the node's settings and owner.
	Infra Infra
	// Frontends is the spaces namespace's side of platform frontends (the
	// host bridge when nil; replaced in tests).
	Frontends FrontendSpaces
	// VMs finds the provider of a kind of machine (the kernel's, replaced in tests).
	VMs func(vmm.Type) vmm.VMM
	// FS stores files (the kernel's, replaced in tests).
	FS func() filesystem.FileStorage
	// SandboxBackend and SandboxImage are the node's sandbox configuration:
	// computers run on the same provider as the projects' computers.
	SandboxBackend string
	SandboxImage   string

	// HTTP is how provider calls are made (replaced in tests).
	HTTP Doer
	// Now is the clock (replaced in tests).
	Now func() time.Time

	limitMu  sync.Mutex
	limiters map[string]*window

	catalogMu sync.Mutex
	catalogAt time.Time
	catalog   []CatalogModel

	touchMu sync.Mutex
	touched map[string]time.Time

	// compMu orders changes of a computer's state; compActive counts the
	// commands running on each, which keep it from being stopped as idle.
	compMu     sync.Mutex
	compActMu  sync.Mutex
	compActive map[string]int
}

// SandboxType is the kind of machine computers are: what the node's sandbox
// backend is configured to.
func (s *Service) SandboxType() string {
	if strings.EqualFold(s.SandboxBackend, "modal") {
		return string(vmm.TypeModal)
	}
	return string(vmm.TypeContainer)
}

// NewService builds the service.
func NewService(k api.Kernel, r *repo.Repo, log *logger.Logger) *Service {
	s := &Service{K: k, R: r, L: log.Named("developer"), HTTP: defaultDoer(), Now: func() time.Time { return time.Now().UTC() },
		limiters: map[string]*window{}, touched: map[string]time.Time{}, compActive: map[string]int{}}
	s.VMs = func(t vmm.Type) vmm.VMM { return k.VMMFor(t) }
	s.FS = func() filesystem.FileStorage { return k.FS() }
	return s
}

func (s *Service) now() time.Time { return s.Now() }

// newID allocates an entity id.
func (s *Service) newID() (identity.ID, error) { return identity.New(s.K.NodeID()) }

// decode reads an action's JSON body; an empty body is an empty request.
func decode(req *api.ActionRequest, out any) error {
	if len(req.Body) == 0 {
		return nil
	}
	if err := json.Unmarshal(req.Body, out); err != nil {
		return errs.Wrap(errs.CodeInvalidArgument, err, "invalid request body")
	}
	return nil
}

// stamp renders a time for the console ("" when never).
func stamp(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}
