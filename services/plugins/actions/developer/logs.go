package developer

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/developer/models"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// LogRetention is how long a request is kept.
const LogRetention = 30 * 24 * time.Hour

// LogView is a request as the console shows it.
type LogView struct {
	ID             string `json:"id"`
	At             string `json:"at"`
	KeyID          string `json:"keyId"`
	KeyName        string `json:"keyName"`
	Service        string `json:"service"`
	Method         string `json:"method"`
	Path           string `json:"path"`
	Status         int64  `json:"status"`
	LatencyMs      int64  `json:"latencyMs"`
	Model          string `json:"model,omitempty"`
	Provider       string `json:"provider,omitempty"`
	RequestedModel string `json:"requestedModel,omitempty"`
	TokensIn       int64  `json:"tokensIn"`
	TokensOut      int64  `json:"tokensOut"`
	Cost           int64  `json:"cost"`
	Request        any    `json:"request,omitempty"`
	Response       any    `json:"response,omitempty"`
	Error          string `json:"error,omitempty"`
}

// LogFilter picks which requests to list.
type LogFilter struct {
	Query    string `json:"query"`
	Status   string `json:"status"`
	KeyID    string `json:"keyId"`
	Service  string `json:"service"`
	Model    string `json:"model"`
	Provider string `json:"provider"`
}

// writeLog records a request and returns its id.
func (s *Service) writeLog(ctx context.Context, l models.Log) string {
	id, err := s.newID()
	if err != nil {
		return ""
	}
	l.ID, l.CreatedAt = id.String(), s.now()
	if err := s.R.DB.Create(ctx, "dev_logs", l.ID, &l); err != nil {
		s.L.Warn("developer: could not write a log", "error", err)
		return ""
	}
	return l.ID
}

func rawJSON(text string) any {
	if text == "" {
		return nil
	}
	var v any
	if json.Unmarshal([]byte(text), &v) == nil {
		return v
	}
	return text
}

// logView is a request as its organization sees it: which provider served it
// is the node's business, not the developer's.
func logView(l models.Log) LogView {
	return LogView{ID: l.ID, At: stamp(l.CreatedAt), KeyID: l.KeyID, KeyName: l.KeyName, Service: l.Service, Method: l.Method, Path: l.Path,
		Status: l.Status, LatencyMs: l.LatencyMs, Model: l.Model, RequestedModel: l.RequestedModel,
		TokensIn: l.TokensIn, TokensOut: l.TokensOut, Cost: l.Cost, Request: rawJSON(l.Request), Response: rawJSON(l.Response), Error: l.Error}
}

// Logs lists an organization's requests, newest first.
func (s *Service) Logs(ctx context.Context, org identity.ID, f LogFilter, limit int) ([]LogView, error) {
	list, err := s.findLogs(ctx, org, f, limit)
	if err != nil {
		return nil, err
	}
	out := make([]LogView, 0, len(list))
	for _, l := range list {
		out = append(out, logView(l))
	}
	return out, nil
}

// findLogs lists requests, newest first: one organization's, or every one's
// for a zero org (the node admin).
func (s *Service) findLogs(ctx context.Context, org identity.ID, f LogFilter, limit int) ([]models.Log, error) {
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	eq := map[string]any{}
	if !org.IsZero() {
		eq["org_id"] = org.String()
	}
	if f.KeyID != "" {
		eq["key_id"] = f.KeyID
	}
	if f.Model != "" {
		eq["model"] = f.Model
	}
	if f.Provider != "" {
		eq["provider"] = f.Provider
	}
	if f.Service != "" && f.Service != "all" {
		eq["service"] = f.Service
	}
	needle := strings.ToLower(strings.TrimSpace(f.Query))
	out := []models.Log{}
	// Page through, since the status and the search are checked here.
	for offset := 0; len(out) < limit && offset < 5000; offset += 500 {
		var list []models.Log
		if err := s.R.List(ctx, "dev_logs", database.Filter{Equal: eq, OrderBy: "created_at", Limit: 500, Offset: offset}, &list); err != nil {
			return nil, err
		}
		for _, l := range list {
			if f.Status == "ok" && l.Status >= 400 || f.Status == "error" && l.Status < 400 {
				continue
			}
			if needle != "" && !strings.Contains(strings.ToLower(strings.Join([]string{l.Path, l.Model, l.Provider, l.KeyName, l.ID, l.Request, l.Error}, " ")), needle) {
				continue
			}
			out = append(out, l)
			if len(out) == limit {
				break
			}
		}
		if len(list) < 500 {
			break
		}
	}
	return out, nil
}

// UsagePoint is one day of usage.
type UsagePoint struct {
	Day       string `json:"day"`
	Spend     int64  `json:"spend"`
	Requests  int64  `json:"requests"`
	TokensIn  int64  `json:"tokensIn"`
	TokensOut int64  `json:"tokensOut"`
}

// UsageRow is usage grouped by something.
type UsageRow struct {
	Name     string `json:"name"`
	Spend    int64  `json:"spend"`
	Requests int64  `json:"requests"`
	Tokens   int64  `json:"tokens"`
}

// UsageTotal sums a period.
type UsageTotal struct {
	Spend     int64 `json:"spend"`
	Requests  int64 `json:"requests"`
	TokensIn  int64 `json:"tokensIn"`
	TokensOut int64 `json:"tokensOut"`
	Errors    int64 `json:"errors"`
}

// UsageReport is what an organization used over some days.
type UsageReport struct {
	Days       []UsagePoint `json:"days"`
	Total      UsageTotal   `json:"total"`
	ByModel    []UsageRow   `json:"byModel"`
	ByProvider []UsageRow   `json:"byProvider"`
	ByKey      []UsageRow   `json:"byKey"`
	ByService  []UsageRow   `json:"byService"`
}

var serviceName = map[string]string{"models": "Models", "computers": "Computers", "storage": "Storage", "account": "Account"}

// Usage reports an organization's last days (every organization's for a zero
// org), with days counted in the viewer's timezone (tzOffset: minutes behind
// UTC, as a browser reports it).
func (s *Service) Usage(ctx context.Context, org identity.ID, days int, tzOffset int) (*UsageReport, error) {
	if days < 1 {
		days = 30
	}
	if days > 90 {
		days = 90
	}
	local := func(t time.Time) time.Time { return t.UTC().Add(-time.Duration(tzOffset) * time.Minute) }
	today := local(s.now())
	first := time.Date(today.Year(), today.Month(), today.Day()-(days-1), 0, 0, 0, 0, time.UTC)
	since := first.Add(time.Duration(tzOffset) * time.Minute)
	report := &UsageReport{Days: make([]UsagePoint, days)}
	index := map[string]int{}
	for i := range report.Days {
		day := first.AddDate(0, 0, i).Format("2006-01-02")
		report.Days[i].Day, index[day] = day, i
	}
	groups := map[string]map[string]*UsageRow{"model": {}, "provider": {}, "key": {}, "service": {}}
	add := func(kind, name string, l models.Log) {
		if name == "" {
			return
		}
		row := groups[kind][name]
		if row == nil {
			row = &UsageRow{Name: name}
			groups[kind][name] = row
		}
		row.Spend += l.Cost
		row.Requests++
		row.Tokens += l.TokensIn + l.TokensOut
	}
	for offset := 0; offset < 20000; offset += 1000 {
		var list []models.Log
		eq := map[string]any{}
		if !org.IsZero() {
			eq["org_id"] = org.String()
		}
		f := database.Filter{Equal: eq, GreaterThan: map[string]any{"created_at": since}, OrderBy: "created_at", Asc: true, Limit: 1000, Offset: offset}
		if err := s.R.List(ctx, "dev_logs", f, &list); err != nil {
			return nil, err
		}
		for _, l := range list {
			if l.CreatedAt.Before(since) {
				continue
			}
			if i, ok := index[local(l.CreatedAt).Format("2006-01-02")]; ok {
				p := &report.Days[i]
				p.Spend, p.Requests, p.TokensIn, p.TokensOut = p.Spend+l.Cost, p.Requests+1, p.TokensIn+l.TokensIn, p.TokensOut+l.TokensOut
			}
			t := &report.Total
			t.Spend, t.Requests, t.TokensIn, t.TokensOut = t.Spend+l.Cost, t.Requests+1, t.TokensIn+l.TokensIn, t.TokensOut+l.TokensOut
			if l.Status >= 400 {
				t.Errors++
			}
			add("model", l.Model, l)
			add("provider", l.Provider, l)
			add("key", l.KeyName, l)
			add("service", serviceName[l.Service], l)
		}
		if len(list) < 1000 {
			break
		}
	}
	rows := func(kind string) []UsageRow {
		out := make([]UsageRow, 0, len(groups[kind]))
		for _, r := range groups[kind] {
			out = append(out, *r)
		}
		sort.Slice(out, func(i, j int) bool {
			if out[i].Spend != out[j].Spend {
				return out[i].Spend > out[j].Spend
			}
			if out[i].Requests != out[j].Requests {
				return out[i].Requests > out[j].Requests
			}
			return out[i].Name < out[j].Name
		})
		return out
	}
	report.ByModel, report.ByProvider, report.ByKey, report.ByService = rows("model"), rows("provider"), rows("key"), rows("service")
	return report, nil
}

// Prune deletes requests older than the retention.
func (s *Service) Prune(ctx context.Context) {
	before := s.now().Add(-LogRetention)
	for {
		var old []struct {
			ID string `db:"id"`
		}
		if err := s.R.List(ctx, "dev_logs", database.Filter{LessThan: map[string]any{"created_at": before}, Limit: 500}, &old); err != nil || len(old) == 0 {
			return
		}
		for _, row := range old {
			if err := s.R.DB.Delete(ctx, "dev_logs", row.ID); err != nil {
				return
			}
		}
	}
}
