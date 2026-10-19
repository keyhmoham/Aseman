package developer

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/developer/models"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// The node admin's view of the developer API: every organization that uses
// it, what each spends, and their requests. Read-only; the admin sees which
// provider served a request, which developers are not told.

// adminWindow is the period the admin's totals cover (the logs' retention).
const adminWindow = 30

// AdminOrgRow is an organization in the admin's list.
type AdminOrgRow struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Kind  string `json:"kind"`
	Owner string `json:"owner"`
	// CreatedAt is the team's creation; empty for a personal organization.
	CreatedAt string `json:"createdAt,omitempty"`
	Balance   int64  `json:"balance"`
	Members   int64  `json:"members"`
	Keys      int64  `json:"keys"`
	// Requests, Spend and Errors cover the last 30 days.
	Requests  int64  `json:"requests"`
	Spend     int64  `json:"spend"`
	Errors    int64  `json:"errors"`
	LastAt    string `json:"lastAt,omitempty"`
	Computers int64  `json:"computers"`
	Running   int64  `json:"running"`
	Files     int64  `json:"files"`
	Bytes     int64  `json:"bytes"`
}

// AdminOverview is the admin's list of organizations and the totals over them.
type AdminOverview struct {
	Orgs   []AdminOrgRow `json:"orgs"`
	Totals struct {
		Orgs      int64 `json:"orgs"`
		Active    int64 `json:"active"`
		Keys      int64 `json:"keys"`
		Requests  int64 `json:"requests"`
		Spend     int64 `json:"spend"`
		Errors    int64 `json:"errors"`
		Running   int64 `json:"running"`
		Bytes     int64 `json:"bytes"`
		Balances  int64 `json:"balances"`
		WindowDay int   `json:"windowDays"`
	} `json:"totals"`
}

// AdminLogView is a request as the admin sees it: whose it was, and which
// provider served it.
type AdminLogView struct {
	LogView
	Org      string `json:"org"`
	OrgName  string `json:"orgName"`
	Provider string `json:"provider,omitempty"`
}

// AdminOrgDetail is one organization in full.
type AdminOrgDetail struct {
	Org       AdminOrgRow    `json:"org"`
	Held      int64          `json:"held"`
	Settings  SettingsView   `json:"settings"`
	Members   []MemberView   `json:"members"`
	KeyList   []KeyView      `json:"keyList"`
	Usage     *UsageReport   `json:"usage"`
	Logs      []AdminLogView `json:"logs"`
	Computers []ComputerView `json:"computerList"`
	Storage   *StorageInfo   `json:"storage"`
}

// orgNamer names organizations by id, remembering what it has looked up.
type orgNamer struct {
	s     *Service
	ctx   context.Context
	names map[string][3]string // id → name, kind, owner handle
}

func (n *orgNamer) of(id string) (name, kind, owner string) {
	if v, ok := n.names[id]; ok {
		return v[0], v[1], v[2]
	}
	parsed, err := identity.Parse(id)
	name, kind = id, "personal"
	if err == nil {
		var org models.Org
		if n.s.R.Get(n.ctx, "dev_orgs", parsed, &org) == nil {
			name, kind, owner = org.Name, "team", n.s.handleOf(n.ctx, org.OwnerID)
		} else {
			var acc account.Account
			if n.s.R.Get(n.ctx, "accounts", parsed, &acc) == nil {
				owner = acc.Handle
				name = "@" + acc.Handle
			}
		}
	}
	n.names[id] = [3]string{name, kind, owner}
	return name, kind, owner
}

func (s *Service) namer(ctx context.Context) *orgNamer {
	return &orgNamer{s: s, ctx: ctx, names: map[string][3]string{}}
}

// AdminOrgs lists every organization that uses the developer API: the teams,
// and the people whose personal organization has keys, requests, computers or
// files. The busiest (by spend over the last 30 days) come first.
func (s *Service) AdminOrgs(ctx context.Context) (*AdminOverview, error) {
	rows := map[string]*AdminOrgRow{}
	row := func(id string) *AdminOrgRow {
		if r := rows[id]; r != nil {
			return r
		}
		r := &AdminOrgRow{ID: id}
		rows[id] = r
		return r
	}
	var teams []models.Org
	if err := s.R.List(ctx, "dev_orgs", database.Filter{}, &teams); err != nil {
		return nil, err
	}
	for _, t := range teams {
		r := row(t.ID.String())
		r.CreatedAt = stamp(t.CreatedAt)
	}
	var members []models.Member
	if err := s.R.List(ctx, "dev_members", database.Filter{Equal: map[string]any{"status": models.StatusActive}}, &members); err != nil {
		return nil, err
	}
	for _, m := range members {
		if r := rows[m.OrgID.String()]; r != nil {
			r.Members++
		}
	}
	var keys []models.Key
	if err := s.R.List(ctx, "dev_keys", database.Filter{}, &keys); err != nil {
		return nil, err
	}
	for _, k := range keys {
		if k.Status == "active" {
			row(k.OrgID.String()).Keys++
		} else {
			row(k.OrgID.String())
		}
	}
	var computers []models.Computer
	if err := s.R.List(ctx, "dev_computers", database.Filter{}, &computers); err != nil {
		return nil, err
	}
	for _, c := range computers {
		r := row(c.OrgID.String())
		r.Computers++
		if c.Status == "running" || c.Status == "starting" {
			r.Running++
		}
	}
	var files []models.File
	if err := s.R.List(ctx, "dev_files", database.Filter{}, &files); err != nil {
		return nil, err
	}
	for _, f := range files {
		r := row(f.OrgID.String())
		r.Files++
		r.Bytes += f.Size
	}
	since := s.now().AddDate(0, 0, -adminWindow)
	last := map[string]time.Time{}
	for offset := 0; offset < 200000; offset += 1000 {
		var list []models.Log
		if err := s.R.List(ctx, "dev_logs", database.Filter{GreaterThan: map[string]any{"created_at": since}, OrderBy: "created_at", Asc: true, Limit: 1000, Offset: offset}, &list); err != nil {
			return nil, err
		}
		for _, l := range list {
			r := row(l.OrgID)
			r.Requests++
			r.Spend += l.Cost
			if l.Status >= 400 {
				r.Errors++
			}
			if l.CreatedAt.After(last[l.OrgID]) {
				last[l.OrgID] = l.CreatedAt
			}
		}
		if len(list) < 1000 {
			break
		}
	}
	names := s.namer(ctx)
	out := &AdminOverview{Orgs: make([]AdminOrgRow, 0, len(rows))}
	for id, r := range rows {
		r.Name, r.Kind, r.Owner = names.of(id)
		if r.Kind == "personal" {
			r.Members = 1
		}
		if t, ok := last[id]; ok {
			r.LastAt = stamp(t)
		}
		if parsed, err := identity.Parse(id); err == nil {
			if w, err := s.Fin.GetWallet(ctx, parsed); err == nil {
				r.Balance = w.Available()
			}
		}
		out.Orgs = append(out.Orgs, *r)
		t := &out.Totals
		t.Orgs++
		if r.Requests > 0 {
			t.Active++
		}
		t.Keys += r.Keys
		t.Requests += r.Requests
		t.Spend += r.Spend
		t.Errors += r.Errors
		t.Running += r.Running
		t.Bytes += r.Bytes
		t.Balances += r.Balance
	}
	out.Totals.WindowDay = adminWindow
	sort.SliceStable(out.Orgs, func(i, j int) bool {
		a, b := out.Orgs[i], out.Orgs[j]
		if a.Spend != b.Spend {
			return a.Spend > b.Spend
		}
		if a.LastAt != b.LastAt {
			return a.LastAt > b.LastAt
		}
		return strings.ToLower(a.Name) < strings.ToLower(b.Name)
	})
	return out, nil
}

// AdminOrg is one organization in full: its people, keys, usage, latest
// requests, computers and storage.
func (s *Service) AdminOrg(ctx context.Context, ref string) (*AdminOrgDetail, error) {
	id, err := identity.Parse(strings.TrimSpace(ref))
	if err != nil {
		return nil, errs.NotFound("organization")
	}
	name, personal, err := s.ScopeOf(ctx, id)
	if err != nil {
		return nil, err
	}
	sc := Scope{Org: id, Personal: personal, Name: name, Role: models.RoleOwner}
	overview, err := s.AdminOrgs(ctx)
	if err != nil {
		return nil, err
	}
	d := &AdminOrgDetail{}
	for _, r := range overview.Orgs {
		if r.ID == id.String() {
			d.Org = r
		}
	}
	if d.Org.ID == "" {
		n, kind, owner := s.namer(ctx).of(id.String())
		d.Org = AdminOrgRow{ID: id.String(), Name: n, Kind: kind, Owner: owner}
	}
	if w, err := s.Fin.GetWallet(ctx, id); err == nil {
		d.Org.Balance, d.Held = w.Available(), w.Locked
	}
	if set, err := s.Settings(ctx, sc); err == nil {
		d.Settings = *set
	}
	if personal {
		d.Members = []MemberView{{ID: id.String(), Handle: s.handleOf(ctx, id), Role: models.RoleOwner, Status: models.StatusActive}}
	} else if list, err := s.members(ctx, id); err == nil {
		for _, m := range list {
			d.Members = append(d.Members, MemberView{ID: m.ID.String(), Handle: m.Handle, Role: m.Role, Status: m.Status, JoinedAt: stamp(m.CreatedAt)})
		}
	}
	if keys, err := s.Keys(ctx, sc); err == nil {
		d.KeyList = keys
	}
	if d.Usage, err = s.Usage(ctx, id, adminWindow, 0); err != nil {
		return nil, err
	}
	if d.Logs, err = s.AdminLogs(ctx, id.String(), LogFilter{}, 50); err != nil {
		return nil, err
	}
	if list, err := s.Computers(ctx, id); err == nil {
		d.Computers = list
	}
	if info, err := s.Storage(ctx, id); err == nil {
		d.Storage = info
	}
	if d.Members == nil {
		d.Members = []MemberView{}
	}
	if d.KeyList == nil {
		d.KeyList = []KeyView{}
	}
	if d.Computers == nil {
		d.Computers = []ComputerView{}
	}
	return d, nil
}

// AdminLogs lists requests across organizations (one, when org is given),
// newest first, with whose they were and which provider served them.
func (s *Service) AdminLogs(ctx context.Context, org string, f LogFilter, limit int) ([]AdminLogView, error) {
	var id identity.ID
	if strings.TrimSpace(org) != "" {
		parsed, err := identity.Parse(strings.TrimSpace(org))
		if err != nil {
			return nil, errs.NotFound("organization")
		}
		id = parsed
	}
	list, err := s.findLogs(ctx, id, f, limit)
	if err != nil {
		return nil, err
	}
	names := s.namer(ctx)
	out := make([]AdminLogView, 0, len(list))
	for _, l := range list {
		name, _, _ := names.of(l.OrgID)
		out = append(out, AdminLogView{LogView: logView(l), Org: l.OrgID, OrgName: name, Provider: l.Provider})
	}
	return out, nil
}
