package developer

import (
	"context"
	"math"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// StorageInfo is what an organization keeps in Storage and what that costs.
type StorageInfo struct {
	Files        int64 `json:"files"`
	UsedBytes    int64 `json:"usedBytes"`
	MaxFileBytes int64 `json:"maxFileBytes"`
	// PriceGBMonth is the price of a GB for a month, in ledger units.
	PriceGBMonth int64 `json:"priceGbMonth"`
	// PerMonth is what the files stored now would cost for a month, in ledger units.
	PerMonth int64 `json:"perMonth"`
}

const (
	gib           = float64(1 << 30)
	hoursPerMonth = 730.0
	// StorageEvery is how often storage is charged.
	StorageEvery = time.Hour
)

func (s *Service) storedBytes(ctx context.Context, org identity.ID) (files, bytes int64, err error) {
	var list []models.File
	if err = s.R.List(ctx, "dev_files", database.Filter{Equal: map[string]any{"org_id": org.String()}}, &list); err != nil {
		return 0, 0, err
	}
	for _, f := range list {
		files++
		bytes += f.Size
	}
	return files, bytes, nil
}

// Storage reports an organization's stored files and what they cost.
func (s *Service) Storage(ctx context.Context, org identity.ID) (*StorageInfo, error) {
	files, used, err := s.storedBytes(ctx, org)
	if err != nil {
		return nil, err
	}
	price, err := s.Infra.StoragePrice(ctx)
	if err != nil {
		return nil, err
	}
	return &StorageInfo{Files: files, UsedBytes: used, MaxFileBytes: MaxFileBytes, PriceGBMonth: price,
		PerMonth: int64(math.Ceil(float64(used) / gib * float64(price)))}, nil
}

// MeterStorage charges every organization for the time its files have been
// stored since the last charge: the GB held, for the hours elapsed, at the
// platform's monthly price. The part of a unit not yet charged is carried to
// the next time, so small amounts are neither dropped nor rounded up.
func (s *Service) MeterStorage(ctx context.Context) {
	price, err := s.Infra.StoragePrice(ctx)
	if err != nil {
		return
	}
	var files []models.File
	if err := s.R.List(ctx, "dev_files", database.Filter{}, &files); err != nil {
		return
	}
	held := map[identity.ID]int64{}
	for _, f := range files {
		held[f.OrgID] += f.Size
	}
	now := s.now()
	for org, bytes := range held {
		st, err := s.settings(ctx, org)
		if err != nil {
			continue
		}
		since := st.StorageBilledAt
		if since.IsZero() || now.Sub(since) < StorageEvery {
			if since.IsZero() {
				st.StorageBilledAt, st.UpdatedAt = now, now
				_ = s.R.DB.Update(ctx, "dev_settings", org.String(), st)
			}
			continue
		}
		// Never more than two days at once: a long outage does not become a surprise bill.
		hours := math.Min(now.Sub(since).Hours(), 48)
		owed := st.StorageFrac + float64(bytes)/gib*float64(price)*hours/hoursPerMonth
		due := int64(math.Floor(owed))
		if due > 0 {
			desc := "developer API storage"
			lines := []wallet.ChargeLine{{Amount: due, Payees: []identity.ID{s.Infra.NodeOwner(ctx)}, Type: wallet.EntryPayNode, Category: wallet.CategoryCompute, Desc: desc}}
			if err := s.Fin.ChargeLines(ctx, org, desc, lines); err != nil {
				// Not paid: the files stay, the time is not forgotten, and uploads are refused until it is.
				s.L.Info("developer: storage could not be charged", "org", org.String(), "error", err)
				continue
			}
		}
		st.StorageFrac, st.StorageBilledAt, st.UpdatedAt = owed-float64(due), now, now
		if err := s.R.DB.Update(ctx, "dev_settings", org.String(), st); err != nil {
			s.L.Warn("developer: storage billing was not recorded", "org", org.String(), "error", err)
		}
	}
}
