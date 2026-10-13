// Package timeline gives every space a timeline its agents can read: a dated,
// queryable record of the space's work and events, kept in the node's Utopia
// server (https://github.com/deeplethe/utopia), a bitemporal knowledge graph
// that runs on the node's own Postgres.
//
// The node pushes what happens in each space (people's requests and how they
// ended, the tools agents ran, messages and work logs, model usage, files,
// members, rooms, routines and their runs) into the space's knowledge base as
// dated statements, read from the records the other namespaces keep. Agents
// read the timeline through the agent gateway (/deepagents/v1/timeline/mcp),
// which forwards to the space's base over MCP: what happened when, what an
// agent or person did over a period, what changed in a window.
//
// A timeline is the space's: every role in a space (bots included) reads every
// room of it, so the timeline shows an agent nothing its room reads would not.
//
// Utopia's address and the node's account come from TRADERA_TIMELINE_*;
// without TRADERA_TIMELINE_URL the timeline is off.
package timeline

import (
	"context"
	"encoding/json"
	"os"
	"sync"
	"time"

	"github.com/tradera/tradera/pkg/crypto"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// Environment the node reads Utopia's address and its account from.
const (
	EnvURL      = "TRADERA_TIMELINE_URL"
	EnvEmail    = "TRADERA_TIMELINE_EMAIL"
	EnvPassword = "TRADERA_TIMELINE_PASSWORD"
)

const (
	// syncEvery is how often the feeds are read.
	syncEvery = 10 * time.Second
	// batch is how many records one feed reads per pass.
	batch = 200
	// holdBack is how long a feed's cursor waits for a record that is not
	// final yet (a tool still running), so its outcome is not missed.
	holdBack = 30 * time.Minute
)

// readTools are the MCP tools agents may use: reads of the space's timeline.
// Utopia's `remember` (a write) and `search_docs` (its own manual) are not
// served.
var readTools = map[string]bool{
	"find_entities": true, "entity_facts": true, "neighbors": true, "timeline": true,
	"paths_between": true, "changes": true, "search_chunks": true, "get_document": true,
}

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

	utopia *utopia

	mu     sync.Mutex
	spaces map[string]*spaceKeys
	reader string
	// pushed remembers recent observations, so a record the cursor holds
	// back is not sent again on every pass.
	pushed map[string]bool
	// resets counts the times a base was found missing and the feeds were
	// rewound: a pass that saw one does not move its cursor.
	resets int
}

// spaceKeys is a space's base with its push key unsealed.
type spaceKeys struct {
	kbID, sourceID, pushKey string
}

// NewService builds the service; config comes from the environment.
func NewService(k apiKernel, r *repo.Repo, log *logger.Logger) *Service {
	s := &Service{K: k, R: r, L: log.Named("timeline"), names: newNames(r), feeds: feeds(), now: time.Now,
		spaces: map[string]*spaceKeys{}, pushed: map[string]bool{}}
	if url := os.Getenv(EnvURL); url != "" {
		email := os.Getenv(EnvEmail)
		if email == "" {
			email = "timeline@tradera.local"
		}
		s.utopia = newUtopia(url, email, os.Getenv(EnvPassword))
	}
	return s
}

// Enabled reports whether the node keeps timelines (Utopia is configured).
func (s *Service) Enabled(ctx context.Context) (bool, error) {
	return s.utopia != nil, nil
}

// --- reading: the agents' MCP -------------------------------------------------

// MCP forwards one MCP JSON-RPC message from an agent of the space to the
// space's knowledge base, serving only the read tools.
func (s *Service) MCP(ctx context.Context, spaceID string, body []byte) ([]byte, error) {
	if s.utopia == nil {
		return nil, errs.New(errs.CodeUnavailable, "the timeline is not configured on this node")
	}
	if spaceID == "" {
		return nil, errs.InvalidArgument("space required")
	}
	var msg struct {
		Method string `json:"method"`
		Params struct {
			Name string `json:"name"`
		} `json:"params"`
	}
	if err := json.Unmarshal(body, &msg); err != nil {
		return nil, errs.InvalidArgument("invalid MCP message")
	}
	switch msg.Method {
	case "initialize", "tools/list", "ping", "notifications/initialized":
	case "tools/call":
		if !readTools[msg.Params.Name] {
			return nil, errs.Permission("timeline tool " + msg.Params.Name + " is not available to agents")
		}
	default:
		return nil, errs.InvalidArgument("unsupported MCP method " + msg.Method)
	}
	out, err := s.forward(ctx, spaceID, body)
	if err != nil {
		return nil, err
	}
	if msg.Method == "tools/list" {
		return filterTools(out), nil
	}
	return out, nil
}

func (s *Service) forward(ctx context.Context, spaceID string, body []byte) ([]byte, error) {
	for attempt := 0; ; attempt++ {
		keys, err := s.space(ctx, spaceID)
		if err != nil {
			return nil, err
		}
		token, err := s.readToken(ctx)
		if err != nil {
			return nil, err
		}
		out, err := s.utopia.mcp(ctx, keys.kbID, token, body)
		if err == nil || attempt > 0 {
			return out, err
		}
		switch {
		case err == errNotFound:
			s.forgetSpace(ctx, spaceID)
		case errs.CodeOf(err) == errs.CodeUnauthenticated:
			s.forgetReader(ctx)
		default:
			return nil, err
		}
	}
}

// filterTools keeps the read tools in a tools/list reply.
func filterTools(raw []byte) []byte {
	var msg map[string]any
	if json.Unmarshal(raw, &msg) != nil {
		return raw
	}
	result, _ := msg["result"].(map[string]any)
	tools, _ := result["tools"].([]any)
	if result == nil || tools == nil {
		return raw
	}
	kept := make([]any, 0, len(tools))
	for _, t := range tools {
		if m, ok := t.(map[string]any); ok && readTools[str(m["name"])] {
			kept = append(kept, t)
		}
	}
	result["tools"] = kept
	out, err := json.Marshal(msg)
	if err != nil {
		return raw
	}
	return out
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

// readToken is the node's read token, issued once and kept sealed.
func (s *Service) readToken(ctx context.Context) (string, error) {
	s.mu.Lock()
	reader := s.reader
	s.mu.Unlock()
	if reader != "" {
		return reader, nil
	}
	id := s.stateID()
	var st State
	if err := s.R.GetString(ctx, stateTable, id, &st); err == nil && st.Secret != "" {
		if token, err := s.open(st.Secret); err == nil && token != "" {
			s.mu.Lock()
			s.reader = token
			s.mu.Unlock()
			return token, nil
		}
	}
	token, err := s.utopia.issueReadToken(ctx)
	if err != nil {
		return "", err
	}
	sealed, err := s.seal(token)
	if err != nil {
		return "", err
	}
	st = State{ID: id, Secret: sealed, UpdatedAt: s.now().UTC()}
	if err := s.upsert(ctx, stateTable, id, &st); err != nil {
		return "", err
	}
	s.mu.Lock()
	s.reader = token
	s.mu.Unlock()
	return token, nil
}

func (s *Service) forgetReader(ctx context.Context) {
	s.mu.Lock()
	s.reader = ""
	s.mu.Unlock()
	_ = s.R.DB.Delete(ctx, stateTable, s.stateID())
}

func (s *Service) stateID() string { return "timeline" }

// --- the spaces' bases --------------------------------------------------------

// space returns a space's base, creating it in Utopia the first time.
func (s *Service) space(ctx context.Context, spaceID string) (*spaceKeys, error) {
	s.mu.Lock()
	keys := s.spaces[spaceID]
	s.mu.Unlock()
	if keys != nil {
		return keys, nil
	}
	var sp Space
	if err := s.R.GetString(ctx, spacesTable, spaceID, &sp); err == nil && sp.KBID != "" {
		if push, err := s.open(sp.Secret); err == nil {
			keys = &spaceKeys{kbID: sp.KBID, sourceID: sp.SourceID, pushKey: push}
		}
	}
	if keys == nil {
		project := s.names.space(ctx, spaceID)
		kb, source, push, err := s.utopia.createBase(ctx, "Timeline · "+project.name,
			"The dated timeline of Tradera project "+spaceID+": requests, agents' work, messages, files, members and routines.")
		if err != nil {
			return nil, err
		}
		sealed, err := s.seal(push)
		if err != nil {
			return nil, err
		}
		now := s.now().UTC()
		sp = Space{ID: spaceID, KBID: kb, SourceID: source, Secret: sealed, CreatedAt: now, UpdatedAt: now}
		if err := s.upsert(ctx, spacesTable, spaceID, &sp); err != nil {
			return nil, err
		}
		keys = &spaceKeys{kbID: kb, sourceID: source, pushKey: push}
		s.L.Info("timeline created for project", "space", spaceID, "kb", kb)
	}
	s.mu.Lock()
	s.spaces[spaceID] = keys
	s.mu.Unlock()
	return keys, nil
}

// forgetSpace drops a space's base Utopia no longer knows; the next use
// creates it again, and the feeds are read from the start to refill it.
func (s *Service) forgetSpace(ctx context.Context, spaceID string) {
	s.mu.Lock()
	delete(s.spaces, spaceID)
	s.pushed = map[string]bool{}
	s.resets++
	s.mu.Unlock()
	_ = s.R.DB.Delete(ctx, spacesTable, spaceID)
	for _, f := range s.feeds {
		_ = s.R.DB.Delete(ctx, cursorsTable, f.name)
	}
	s.L.Warn("timeline base missing in utopia; recreating and refilling", "space", spaceID)
}

func (s *Service) seal(value string) (string, error) {
	master := s.K.Env()["node_private_key"]
	if master == "" {
		return "", errs.New(errs.CodeUnavailable, "node credential encryption is not available")
	}
	return crypto.EncryptPrivateKey(value, master)
}

func (s *Service) open(sealed string) (string, error) {
	return crypto.DecryptPrivateKey(sealed, s.K.Env()["node_private_key"])
}

// --- writing: the feeds -------------------------------------------------------

// Start pushes the feeds until the plugin stops.
func (s *Service) Start(ctx context.Context) {
	if s.utopia == nil {
		s.L.Info("timeline off: " + EnvURL + " is not set")
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

// Sync reads every feed from its cursor and pushes what it finds.
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

// syncFeed reads a feed to its end in batches and pushes each record. The
// saved cursor stops at the first record that is not final yet (while it is
// young), so its outcome is read again; reading goes on past it.
func (s *Service) syncFeed(ctx context.Context, f feed) error {
	var cur Cursor
	if err := s.R.GetString(ctx, cursorsTable, f.name, &cur); err != nil && errs.CodeOf(err) != errs.CodeNotFound {
		return err
	}
	s.mu.Lock()
	resets := s.resets
	s.mu.Unlock()
	scan, saved, held := cur.At, cur.At, false
	defer func() {
		s.mu.Lock()
		rewound := s.resets != resets
		s.mu.Unlock()
		if !rewound {
			_ = s.saveCursor(ctx, f.name, saved, cur.At)
		}
	}()
	for ctx.Err() == nil {
		records, err := f.read(ctx, s, scan, batch)
		if err != nil {
			return err
		}
		from := scan
		for _, rec := range records {
			for _, obs := range rec.obs {
				if err := s.pushObservation(ctx, obs); err != nil {
					return err // the next pass sends this record again
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

func (s *Service) pushObservation(ctx context.Context, obs observation) error {
	if len(obs.S) == 0 {
		return nil
	}
	s.mu.Lock()
	done := s.pushed[obs.ExternalID]
	s.mu.Unlock()
	if done {
		return nil
	}
	for attempt := 0; ; attempt++ {
		keys, err := s.space(ctx, obs.space)
		if err != nil {
			return err
		}
		_, err = s.utopia.push(ctx, keys.sourceID, keys.pushKey, obs)
		if err == errNotFound && attempt == 0 {
			s.forgetSpace(ctx, obs.space)
			continue
		}
		if err != nil {
			return err
		}
		break
	}
	s.mu.Lock()
	if len(s.pushed) > 50_000 {
		s.pushed = map[string]bool{}
	}
	s.pushed[obs.ExternalID] = true
	s.mu.Unlock()
	return nil
}

// --- status -------------------------------------------------------------------

// Status is what the admin sees of the timelines.
type Status struct {
	Enabled bool                 `json:"enabled"`
	URL     string               `json:"url,omitempty"`
	Spaces  int64                `json:"spaces"`
	Feeds   map[string]time.Time `json:"feeds"`
}

func (s *Service) Status(ctx context.Context) (Status, error) {
	out := Status{Enabled: s.utopia != nil, Feeds: map[string]time.Time{}}
	if s.utopia != nil {
		out.URL = os.Getenv(EnvURL)
	}
	n, err := s.R.Count(ctx, spacesTable, database.Filter{})
	if err == nil {
		out.Spaces = n
	}
	for _, f := range s.feeds {
		var c Cursor
		if s.R.GetString(ctx, cursorsTable, f.name, &c) == nil {
			out.Feeds[f.name] = c.At
		}
	}
	return out, nil
}
