// Package timeline gives every space a timeline its agents can read: a dated,
// queryable record of the space's work and events, kept in the node's own
// database (timeline_entries).
//
// The node reads what happens in each space (people's requests and how they
// ended, the tools agents ran, messages and work logs, model usage, files,
// members, rooms, routines and their runs) from the records the other
// namespaces keep, and writes each as a dated entry: what happened, to whom,
// when. Agents read the timeline through the agent gateway
// (/harness/v1/timeline/search and /entry), which answers for the turn's own
// space only: what happened when, what an agent or person did over a period,
// what changed in a window. No model is involved, in writing or reading.
//
// A timeline is the space's: every role in a space (bots included) reads every
// room of it, so the timeline shows an agent nothing its room reads would not.
//
// ASEMAN_TIMELINE=off turns timelines off.
package timeline

import (
	"context"
	"encoding/json"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// EnvSwitch turns the timelines off ("off", "0", "false").
const EnvSwitch = "ASEMAN_TIMELINE"

const (
	// syncEvery is how often the feeds are read.
	syncEvery = 10 * time.Second
	// batch is how many records one feed reads per pass.
	batch = 200
	// holdBack is how long a feed's cursor waits for a record that is not
	// final yet (a tool still running), so its outcome is not missed.
	holdBack = 30 * time.Minute
	// scanLimit bounds the entries one text search reads.
	scanLimit = 2000
	// maxResults bounds what one search returns.
	maxResults = 100
)

type apiKernel interface {
	Env() map[string]string
}

// Service keeps the spaces' timelines.
type Service struct {
	K     apiKernel
	R     *repo.Repo
	L     *logger.Logger
	names *names
	feeds []feed
	now   func() time.Time

	enabled bool

	mu sync.Mutex
	// written remembers recent entries, so a record the cursor holds back is
	// not written again on every pass.
	written map[string]bool
}

// NewService builds the service; config comes from the environment.
func NewService(k apiKernel, r *repo.Repo, log *logger.Logger) *Service {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(EnvSwitch))) {
	case "off", "0", "false", "no":
		return &Service{K: k, R: r, L: log.Named("timeline"), names: newNames(r), feeds: feeds(), now: time.Now, written: map[string]bool{}}
	}
	return &Service{K: k, R: r, L: log.Named("timeline"), names: newNames(r), feeds: feeds(), now: time.Now,
		enabled: true, written: map[string]bool{}}
}

// Enabled reports whether the node keeps timelines.
func (s *Service) Enabled(ctx context.Context) (bool, error) {
	return s.enabled, nil
}

// --- reading -------------------------------------------------------------------

// SearchQuery narrows a space's timeline.
type SearchQuery struct {
	// Query: every word must appear in the entry (case-insensitive).
	Query string `json:"query,omitempty"`
	// Kinds: only these feeds (requests, tools, messages, usage, files, …).
	Kinds []string  `json:"kinds,omitempty"`
	Since time.Time `json:"since,omitempty"`
	Until time.Time `json:"until,omitempty"`
	Limit int       `json:"limit,omitempty"`
}

// Search returns a space's entries, newest first.
func (s *Service) Search(ctx context.Context, spaceID string, q SearchQuery) ([]Entry, error) {
	if !s.enabled {
		return nil, errs.New(errs.CodeUnavailable, "timelines are off on this node")
	}
	if strings.TrimSpace(spaceID) == "" {
		return nil, errs.InvalidArgument("space required")
	}
	limit := q.Limit
	if limit <= 0 || limit > maxResults {
		limit = 30
	}
	words := strings.Fields(strings.ToLower(q.Query))
	f := database.Filter{Equal: map[string]any{"space_id": spaceID}, OrderBy: "at", Asc: false, Limit: limit}
	if len(words) > 0 {
		f.Limit = scanLimit
	}
	if len(q.Kinds) > 0 {
		kinds := make([]any, 0, len(q.Kinds))
		for _, k := range q.Kinds {
			kinds = append(kinds, k)
		}
		f.In = map[string][]any{"kind": kinds}
	}
	if !q.Since.IsZero() {
		f.GreaterThan = map[string]any{"at": q.Since.UTC()}
	}
	if !q.Until.IsZero() {
		f.LessThan = map[string]any{"at": q.Until.UTC()}
	}
	var rows []Entry
	if err := s.R.DB.List(ctx, entriesTable, f, &rows); err != nil {
		return nil, err
	}
	out := rows[:0]
	for _, e := range rows {
		if matches(e, words) {
			out = append(out, e)
			if len(out) == limit {
				break
			}
		}
	}
	return out, nil
}

func matches(e Entry, words []string) bool {
	if len(words) == 0 {
		return true
	}
	hay := strings.ToLower(e.Summary + "\n" + e.Subjects + "\n" + e.Kind)
	for _, w := range words {
		if !strings.Contains(hay, w) {
			return false
		}
	}
	return true
}

// EntryView is one entry with the entries recorded around it.
type EntryView struct {
	Entry  Entry   `json:"entry"`
	Before []Entry `json:"before"`
	After  []Entry `json:"after"`
}

// Entry returns one entry of the space and its neighbours in time.
func (s *Service) Entry(ctx context.Context, spaceID, id string) (*EntryView, error) {
	if !s.enabled {
		return nil, errs.New(errs.CodeUnavailable, "timelines are off on this node")
	}
	var e Entry
	if err := s.R.GetString(ctx, entriesTable, id, &e); err != nil {
		return nil, err
	}
	if e.SpaceID != spaceID {
		// Another space's entry is not this space's to see.
		return nil, errs.NotFound("timeline entry")
	}
	view := &EntryView{Entry: e, Before: []Entry{}, After: []Entry{}}
	if err := s.R.DB.List(ctx, entriesTable, database.Filter{Equal: map[string]any{"space_id": spaceID},
		LessThan: map[string]any{"at": e.At}, OrderBy: "at", Asc: false, Limit: 5}, &view.Before); err != nil {
		return nil, err
	}
	if err := s.R.DB.List(ctx, entriesTable, database.Filter{Equal: map[string]any{"space_id": spaceID},
		GreaterThan: map[string]any{"at": e.At}, OrderBy: "at", Asc: true, Limit: 5}, &view.After); err != nil {
		return nil, err
	}
	return view, nil
}

// --- writing: the feeds -------------------------------------------------------

// Start reads the feeds until the plugin stops.
func (s *Service) Start(ctx context.Context) {
	if !s.enabled {
		s.L.Info("timeline off: " + EnvSwitch + " turns it off")
		return
	}
	ticker := time.NewTicker(syncEvery)
	defer ticker.Stop()
	for {
		if err := s.Sync(ctx); err != nil && ctx.Err() == nil {
			s.L.Warn("timeline sync pass failed", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// Sync reads every feed from its cursor and writes what it finds.
func (s *Service) Sync(ctx context.Context) error {
	var first error
	for _, f := range s.feeds {
		if ctx.Err() != nil {
			break
		}
		if err := s.syncFeed(ctx, f); err != nil && first == nil {
			first = errs.Wrap(errs.CodeOf(err), err, "feed "+f.name)
		}
	}
	return first
}

// syncFeed reads a feed to its end in batches and writes each record. The
// saved cursor stops at the first record that is not final yet (while it is
// young), so its outcome is read again; reading goes on past it.
func (s *Service) syncFeed(ctx context.Context, f feed) error {
	var cur Cursor
	if err := s.R.GetString(ctx, cursorsTable, f.name, &cur); err != nil && errs.CodeOf(err) != errs.CodeNotFound {
		return err
	}
	scan, saved, held := cur.At, cur.At, false
	defer func() { _ = s.saveCursor(ctx, f.name, saved, cur.At) }()
	for ctx.Err() == nil {
		records, err := f.read(ctx, s, scan, batch)
		if err != nil {
			return err
		}
		from := scan
		for _, rec := range records {
			for _, obs := range rec.obs {
				if err := s.write(ctx, f.name, obs); err != nil {
					return err // the next pass writes this record again
				}
			}
			if rec.pending && s.now().Sub(rec.at) < holdBack {
				held = true
			}
			if rec.at.After(scan) {
				scan = rec.at
			}
			if !held && rec.at.After(saved) {
				saved = rec.at
			}
		}
		if len(records) < batch {
			return nil
		}
		if !scan.After(from) {
			// A whole batch at one moment: step past it rather than stall.
			scan = scan.Add(time.Microsecond)
			if !held {
				saved = scan
			}
		}
	}
	return nil
}

func (s *Service) saveCursor(ctx context.Context, name string, at, was time.Time) error {
	if !at.After(was) {
		return nil
	}
	return s.upsert(ctx, cursorsTable, name, &Cursor{ID: name, At: at, UpdatedAt: s.now().UTC()})
}

// upsert writes a record of this namespace, creating it the first time.
func (s *Service) upsert(ctx context.Context, model, id string, v any) error {
	err := s.R.UpdateString(ctx, model, id, v)
	if errs.CodeOf(err) == errs.CodeNotFound {
		err = s.R.DB.Create(ctx, model, id, v)
	}
	return err
}

// write stores one observation as a timeline entry. An observation's id says
// what it states, so writing the same one again changes nothing.
func (s *Service) write(ctx context.Context, kind string, obs observation) error {
	if len(obs.S) == 0 || obs.space == "" {
		return nil
	}
	s.mu.Lock()
	done := s.written[obs.ExternalID]
	s.mu.Unlock()
	if done {
		return nil
	}
	e := entryOf(kind, obs, s.now().UTC())
	if err := s.upsert(ctx, entriesTable, e.ID, &e); err != nil {
		return err
	}
	s.mu.Lock()
	if len(s.written) > 50_000 {
		s.written = map[string]bool{}
	}
	s.written[obs.ExternalID] = true
	s.mu.Unlock()
	return nil
}

// entryOf renders an observation's statements as one readable entry.
func entryOf(kind string, obs observation, now time.Time) Entry {
	at, _ := time.Parse(time.RFC3339, obs.DocTime)
	subjects := map[string]bool{}
	var lines []string
	for _, st := range obs.S {
		subject, _ := st[1].(string)
		phrase, _ := st[2].(string)
		line := subject + " " + phrase
		if obj, ok := st[3].(string); ok && obj != "" {
			line += " " + obj
			subjects[obj] = true
		} else if v, ok := st[4].(string); ok && v != "" {
			line += ": " + v
		}
		if q, ok := st[5].(map[string]string); ok && len(q) > 0 {
			keys := make([]string, 0, len(q))
			for k := range q {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			parts := make([]string, 0, len(keys))
			for _, k := range keys {
				parts = append(parts, k+": "+q[k])
			}
			line += " (" + strings.Join(parts, ", ") + ")"
		}
		subjects[subject] = true
		lines = append(lines, line)
	}
	names := make([]string, 0, len(subjects))
	for n := range subjects {
		names = append(names, n)
	}
	sort.Strings(names)
	if at.IsZero() {
		at = now
	}
	return Entry{ID: obs.ExternalID, SpaceID: obs.space, Kind: kind, At: at.UTC(), Summary: strings.Join(lines, "; "),
		Subjects: strings.Join(names, "\n"), RecordedAt: now}
}

// clip shortens text to n runes for an entry.
func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}

// --- status -------------------------------------------------------------------

// Status is what the admin sees of the timelines.
type Status struct {
	Enabled bool                 `json:"enabled"`
	Entries int64                `json:"entries"`
	Feeds   map[string]time.Time `json:"feeds"`
}

func (s *Service) Status(ctx context.Context) (Status, error) {
	out := Status{Enabled: s.enabled, Feeds: map[string]time.Time{}}
	if n, err := s.R.Count(ctx, entriesTable, database.Filter{}); err == nil {
		out.Entries = n
	}
	for _, f := range s.feeds {
		var c Cursor
		if s.R.GetString(ctx, cursorsTable, f.name, &c) == nil {
			out.Feeds[f.name] = c.At
		}
	}
	return out, nil
}

// --- the agent gateway's bridge ---------------------------------------------------

// SearchJSON is Search for the agent gateway: query and result as JSON.
func (s *Service) SearchJSON(ctx context.Context, spaceID string, query []byte) ([]byte, error) {
	var q SearchQuery
	if len(query) > 0 {
		if err := json.Unmarshal(query, &q); err != nil {
			return nil, errs.InvalidArgument("invalid timeline query: " + err.Error())
		}
	}
	items, err := s.Search(ctx, spaceID, q)
	if err != nil {
		return nil, err
	}
	if items == nil {
		items = []Entry{}
	}
	return json.Marshal(map[string]any{"items": items})
}

// EntryJSON is Entry for the agent gateway.
func (s *Service) EntryJSON(ctx context.Context, spaceID, id string) ([]byte, error) {
	view, err := s.Entry(ctx, spaceID, id)
	if err != nil {
		return nil, err
	}
	return json.Marshal(view)
}
