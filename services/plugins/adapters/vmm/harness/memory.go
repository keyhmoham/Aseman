package harness

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/idutil"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// The agents' memory, kept by the node.
//
//   - Notes: short and curated, always in the agent's context. The space's
//     shared notes, each agent's own notes in the space, and a person's notes
//     with Aseman (personal chat).
//   - Memories: facts, preferences, decisions, procedures and what is known
//     about people, kept with an embedding of their text and recalled by
//     meaning: PostgreSQL with pgvector when the database has it
//     (database.VectorIndex), an exact search over the stored embeddings
//     otherwise, and by words when the admin has picked no embedding model.
//     Agents keep them (remember) and the node learns them from finished
//     turns with the memory chat model.
//
// Every read and write is scoped by the turn: a room agent reaches its own
// memories and its space's shared ones, never another space's or another
// agent's; a person's assistant reaches the person's. The memory models'
// tokens are billed to the project (memory_billing.go).

const (
	notesModel    = "agent_notes"
	memoriesModel = "agent_memories"
	// vectorCollection is the pgvector side table of the memories.
	vectorCollection = "agent_memories"

	maxNoteBytes     = 32 * 1024
	maxMemoryText    = 2000
	maxRecall        = 30
	exactScanLimit   = 5000
	duplicateWithin  = 0.08 // cosine distance under which a new memory repeats an old one
	memoryCallTimout = 2 * time.Minute
)

func memoryModels() []database.Model {
	f := func(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }
	ix := func(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k, Index: true} }
	return []database.Model{
		{Name: notesModel, Table: notesModel, Fields: []database.Field{
			f("id", database.KindString), f("scope", database.KindString), f("content", database.KindString),
			f("updated_at", database.KindTime),
		}},
		{Name: memoriesModel, Table: memoriesModel, Fields: []database.Field{
			f("id", database.KindString), ix("scope", database.KindString), f("text", database.KindString),
			f("kind", database.KindString), f("source", database.KindString), f("embedding", database.KindString),
			f("dim", database.KindInt64), f("created_at", database.KindTime),
		}},
	}
}

// Note is one scope's notes.
type Note struct {
	ID        string    `db:"id" json:"id"`
	Scope     string    `db:"scope" json:"scope"`
	Content   string    `db:"content" json:"content"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}

// Memory is one long-term memory.
type Memory struct {
	ID        string    `db:"id" json:"id"`
	Scope     string    `db:"scope" json:"scope"`
	Text      string    `db:"text" json:"text"`
	Kind      string    `db:"kind" json:"kind,omitempty"`
	Source    string    `db:"source" json:"source,omitempty"` // "told" (remember) or "learned" (from a turn)
	Embedding string    `db:"embedding" json:"-"`
	Dim       int64     `db:"dim" json:"-"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}

// memoryScope is where a turn's memory lives.
type memoryScope struct {
	// own is the agent's (or the person's) scope; shared is the space's ("" in
	// personal chat).
	own, shared string
	// payer is the project billed for the memory models (a person in personal chat).
	payer    identity.ID
	personal bool
}

func spaceScope(space string) string        { return "space:" + space }
func agentScope(space, agent string) string { return "agent:" + space + ":" + agent }
func personScope(account string) string     { return "person:" + account }

// scopeOf is a session's memory scope.
func (s *session) memoryScope() (memoryScope, error) {
	if s.personal {
		return memoryScope{own: personScope(s.account.String()), payer: s.account, personal: true}, nil
	}
	space, err := identity.Parse(s.spaceID)
	if err != nil || s.botID == "" {
		return memoryScope{}, errs.InvalidArgument("this turn has no space or agent")
	}
	return memoryScope{own: agentScope(s.spaceID, s.botID), shared: spaceScope(s.spaceID), payer: space}, nil
}

func (m memoryScope) scopes() []string {
	if m.shared == "" {
		return []string{m.own}
	}
	return []string{m.own, m.shared}
}

type memoryStore struct {
	k        api.Kernel
	platform platform
	meter    *memoryMeter
	log      *logger.Logger
	client   *http.Client
	// db replaces the kernel's database (tests).
	db database.Database
	// registered: the models are registered with the database.
	registered bool
}

func newMemoryStore(k api.Kernel, p platform, meter *memoryMeter, log *logger.Logger) *memoryStore {
	return &memoryStore{k: k, platform: p, meter: meter, log: log, client: &http.Client{Timeout: memoryCallTimout}}
}

func (m *memoryStore) database(ctx context.Context) (database.Database, error) {
	db := m.db
	if db == nil && m.k != nil {
		db = m.k.DB()
	}
	if db == nil {
		return nil, errs.New(errs.CodeUnavailable, "no database for the agents' memory")
	}
	if !m.registered {
		for _, model := range memoryModels() {
			if err := db.RegisterModel(ctx, model); err != nil {
				return nil, errs.Wrap(errs.CodeUnavailable, err, "register memory model "+model.Name)
			}
		}
		m.registered = true
	}
	return db, nil
}

// --- notes ---------------------------------------------------------------------

// notes are the space's and the agent's own notes (personal: the person's).
func (m *memoryStore) notes(ctx context.Context, scope memoryScope) (shared, own string, err error) {
	db, err := m.database(ctx)
	if err != nil {
		return "", "", err
	}
	read := func(id string) (string, error) {
		if id == "" {
			return "", nil
		}
		var n Note
		if err := db.Get(ctx, notesModel, id, &n); err != nil {
			if errs.CodeOf(err) == errs.CodeNotFound {
				return "", nil
			}
			return "", err
		}
		return n.Content, nil
	}
	if shared, err = read(scope.shared); err != nil {
		return "", "", err
	}
	own, err = read(scope.own)
	return shared, own, err
}

func (m *memoryStore) setNotes(ctx context.Context, id, content string) error {
	if len(content) > maxNoteBytes {
		return errs.InvalidArgument(fmt.Sprintf("notes are limited to %d bytes: keep them short and move the rest to memories", maxNoteBytes))
	}
	db, err := m.database(ctx)
	if err != nil {
		return err
	}
	n := Note{ID: id, Scope: id, Content: content, UpdatedAt: time.Now().UTC()}
	err = db.Update(ctx, notesModel, id, &n)
	if errs.CodeOf(err) == errs.CodeNotFound {
		err = db.Create(ctx, notesModel, id, &n)
	}
	return err
}

// --- memories --------------------------------------------------------------------

// remember keeps one memory in scope (embedded when an embedding model is set).
func (m *memoryStore) remember(ctx context.Context, scope memoryScope, shared bool, text, kind, source string) (*Memory, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, errs.InvalidArgument("nothing to remember")
	}
	if len([]rune(text)) > maxMemoryText {
		text = string([]rune(text)[:maxMemoryText])
	}
	target := scope.own
	if shared && scope.shared != "" {
		target = scope.shared
	}
	db, err := m.database(ctx)
	if err != nil {
		return nil, err
	}
	vec, _ := m.embed(ctx, scope, text)
	if len(vec) > 0 {
		if dup, err := m.nearest(ctx, db, []string{target}, vec, 1); err == nil && len(dup) == 1 && dup[0].distance < duplicateWithin {
			return &dup[0].Memory, nil // already known
		}
	}
	id, err := idutil.RandomHex(16)
	if err != nil {
		return nil, err
	}
	rec := Memory{ID: id, Scope: target, Text: text, Kind: kind, Source: source, CreatedAt: time.Now().UTC()}
	if len(vec) > 0 {
		raw, _ := json.Marshal(vec)
		rec.Embedding, rec.Dim = string(raw), int64(len(vec))
	}
	if err := db.Create(ctx, memoriesModel, id, &rec); err != nil {
		return nil, err
	}
	if len(vec) > 0 && vectorIndex(db) != nil {
		if err := vectorIndex(db).VectorUpsert(ctx, vectorCollection, id, target, vec); err != nil {
			m.log.Warn("agent memory: vector not indexed (exact search still finds it)", "error", err)
		}
	}
	return &rec, nil
}

type recalled struct {
	Memory
	distance float64
}

// recall finds the memories of the scope that matter for query, best first.
func (m *memoryStore) recall(ctx context.Context, scope memoryScope, query string, limit int) ([]map[string]any, error) {
	if limit <= 0 || limit > maxRecall {
		limit = 8
	}
	db, err := m.database(ctx)
	if err != nil {
		return nil, err
	}
	var hits []recalled
	if vec, err := m.embed(ctx, scope, query); err == nil && len(vec) > 0 {
		hits, err = m.nearest(ctx, db, scope.scopes(), vec, limit)
		if err != nil {
			return nil, err
		}
		// Weak matches are noise in the agent's context.
		kept := hits[:0]
		for _, h := range hits {
			if h.distance < 0.6 {
				kept = append(kept, h)
			}
		}
		hits = kept
	} else {
		hits, err = m.byWords(ctx, db, scope.scopes(), query, limit)
		if err != nil {
			return nil, err
		}
	}
	out := make([]map[string]any, 0, len(hits))
	for _, h := range hits {
		out = append(out, map[string]any{"id": h.ID, "text": h.Text, "kind": h.Kind, "shared": h.Scope == scope.shared && scope.shared != "",
			"at": h.CreatedAt.Format(time.RFC3339)})
	}
	return out, nil
}

func vectorIndex(db database.Database) database.VectorIndex {
	if support, ok := db.(database.VectorIndexSupport); ok && !support.SupportsVectorIndex() {
		return nil
	}
	if idx, ok := db.(database.VectorIndex); ok {
		return idx
	}
	return nil
}

// nearest is a vector search: pgvector when available, else exact cosine.
func (m *memoryStore) nearest(ctx context.Context, db database.Database, scopes []string, vec []float32, limit int) ([]recalled, error) {
	if idx := vectorIndex(db); idx != nil {
		hits, err := idx.VectorSearch(ctx, vectorCollection, scopes, vec, limit)
		if err == nil {
			out := make([]recalled, 0, len(hits))
			for _, h := range hits {
				var rec Memory
				if db.Get(ctx, memoriesModel, h.ID, &rec) == nil {
					out = append(out, recalled{Memory: rec, distance: h.Distance})
				}
			}
			return out, nil
		}
		m.log.Warn("agent memory: vector index unavailable, searching exactly", "error", err)
	}
	rows, err := m.inScopes(ctx, db, scopes)
	if err != nil {
		return nil, err
	}
	out := make([]recalled, 0, len(rows))
	for _, r := range rows {
		if int(r.Dim) != len(vec) || r.Embedding == "" {
			continue
		}
		var v []float32
		if json.Unmarshal([]byte(r.Embedding), &v) != nil {
			continue
		}
		out = append(out, recalled{Memory: r, distance: cosineDistance(vec, v)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].distance < out[j].distance })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// byWords ranks memories by how many of the query's words they contain.
func (m *memoryStore) byWords(ctx context.Context, db database.Database, scopes []string, query string, limit int) ([]recalled, error) {
	words := map[string]bool{}
	for _, w := range strings.FieldsFunc(strings.ToLower(query), func(r rune) bool { return !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r > 127) }) {
		if len([]rune(w)) > 2 {
			words[w] = true
		}
	}
	if len(words) == 0 {
		return nil, nil
	}
	rows, err := m.inScopes(ctx, db, scopes)
	if err != nil {
		return nil, err
	}
	out := []recalled{}
	for _, r := range rows {
		text := strings.ToLower(r.Text)
		n := 0
		for w := range words {
			if strings.Contains(text, w) {
				n++
			}
		}
		if n > 0 {
			out = append(out, recalled{Memory: r, distance: 1 - float64(n)/float64(len(words))})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].distance < out[j].distance })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (m *memoryStore) inScopes(ctx context.Context, db database.Database, scopes []string) ([]Memory, error) {
	in := make([]any, 0, len(scopes))
	for _, s := range scopes {
		in = append(in, s)
	}
	var rows []Memory
	err := db.List(ctx, memoriesModel, database.Filter{In: map[string][]any{"scope": in}, OrderBy: "created_at", Asc: false, Limit: exactScanLimit}, &rows)
	return rows, err
}

func cosineDistance(a, b []float32) float64 {
	var dot, na, nb float64
	for i := range a {
		dot += float64(a[i]) * float64(b[i])
		na += float64(a[i]) * float64(a[i])
		nb += float64(b[i]) * float64(b[i])
	}
	if na == 0 || nb == 0 {
		return 2
	}
	return 1 - dot/(math.Sqrt(na)*math.Sqrt(nb))
}

// --- the memory models -------------------------------------------------------------

// embed is the admin's embedding model's vector of text, metered to the scope's
// payer. No embedding model (or a project that cannot pay): no vector.
func (m *memoryStore) embed(ctx context.Context, scope memoryScope, text string) ([]float32, error) {
	if m.platform == nil {
		return nil, errs.New(errs.CodeUnavailable, "no memory models")
	}
	if m.meter.isBlocked(scope.payer) {
		return nil, errs.New(errs.CodeFinance, "this project cannot pay for its memory right now")
	}
	provider, err := m.platform.ResolveMemoryEmbedding(ctx)
	if err != nil {
		return nil, err
	}
	up, err := providerRequest(ctx, provider, "/embeddings", map[string]any{"input": []string{text}})
	if err != nil {
		return nil, err
	}
	data, err := m.do(up)
	if err != nil {
		return nil, err
	}
	var out struct {
		Data []struct {
			Embedding []float32 `json:"embedding"`
		} `json:"data"`
		Usage struct {
			PromptTokens int64 `json:"prompt_tokens"`
			TotalTokens  int64 `json:"total_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(data, &out); err != nil || len(out.Data) == 0 || len(out.Data[0].Embedding) == 0 {
		return nil, errs.New(errs.CodeUnavailable, "the embedding model returned no vector")
	}
	tokens := out.Usage.PromptTokens
	if tokens == 0 {
		tokens = out.Usage.TotalTokens
	}
	if tokens == 0 {
		tokens = int64(len(text)/4 + 1)
	}
	m.meter.add(scope.payer, provider, tokens, 0)
	return out.Data[0].Embedding, nil
}

const learnPrompt = `You keep the long-term memory of an AI agent that works with people.
Read the exchange below and list only what is worth remembering for later
conversations: lasting facts about the people or the project, their
preferences, decisions made, how a task was done (a procedure that worked),
and commitments. Skip small talk, anything only true right now, secrets and
credentials, and anything already obvious from the request itself.
Answer with JSON only: {"memories": [{"text": "...", "kind": "fact|preference|decision|procedure|person|event", "shared": true|false}]}
"shared" is true when the whole team of the project should know it, false when it is only about this agent's own work.
Return {"memories": []} when nothing is worth keeping.`

// learn extracts what a finished turn taught and keeps it (memory chat model).
func (m *memoryStore) learn(ctx context.Context, scope memoryScope, t transcript) (int, error) {
	if strings.TrimSpace(t.Reply) == "" && strings.TrimSpace(t.Message) == "" {
		return 0, nil
	}
	if m.platform == nil || m.meter.isBlocked(scope.payer) {
		return 0, nil
	}
	provider, err := m.platform.ResolveMemoryChat(ctx)
	if err != nil {
		return 0, nil // no memory chat model: nothing is learned, notes still work
	}
	exchange := fmt.Sprintf("REQUEST:\n%s\n\nTOOLS USED: %s\n\nANSWER:\n%s", clip(t.Message, 6000), strings.Join(t.Tools, ", "), clip(t.Reply, 6000))
	up, err := providerRequest(ctx, provider, "/chat/completions", map[string]any{
		"messages": []map[string]any{{"role": "system", "content": learnPrompt}, {"role": "user", "content": exchange}},
		"temperature": 0,
	})
	if err != nil {
		return 0, err
	}
	data, err := m.do(up)
	if err != nil {
		return 0, err
	}
	in, out := parseUsage(data, false)
	m.meter.add(scope.payer, provider, in, out)
	var resp struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if json.Unmarshal(data, &resp) != nil || len(resp.Choices) == 0 {
		return 0, nil
	}
	found := parseLearned(resp.Choices[0].Message.Content)
	kept := 0
	for _, item := range found {
		if _, err := m.remember(ctx, scope, item.Shared, item.Text, item.Kind, "learned"); err == nil {
			kept++
		}
	}
	return kept, nil
}

type learned struct {
	Text   string `json:"text"`
	Kind   string `json:"kind"`
	Shared bool   `json:"shared"`
}

// parseLearned reads the model's JSON answer, tolerating a fenced block.
func parseLearned(content string) []learned {
	s := strings.TrimSpace(content)
	if i := strings.Index(s, "{"); i >= 0 {
		if j := strings.LastIndex(s, "}"); j > i {
			s = s[i : j+1]
		}
	}
	var out struct {
		Memories []learned `json:"memories"`
	}
	if json.Unmarshal([]byte(s), &out) != nil {
		return nil
	}
	kept := out.Memories[:0]
	for _, m := range out.Memories {
		if strings.TrimSpace(m.Text) != "" {
			kept = append(kept, m)
		}
	}
	if len(kept) > 10 {
		kept = kept[:10]
	}
	return kept
}

func (m *memoryStore) do(up *http.Request) ([]byte, error) {
	resp, err := m.client.Do(up)
	if err != nil {
		return nil, errs.Wrap(errs.CodeUnavailable, err, "memory model unreachable")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 300 {
		return nil, errs.New(errs.CodeUnavailable, fmt.Sprintf("memory model %d: %s", resp.StatusCode, clip(string(data), 300)))
	}
	return data, nil
}

// transcript is what the runtime reports of a finished turn, to learn from.
type transcript struct {
	Message string   `json:"message"`
	Reply   string   `json:"reply"`
	Tools   []string `json:"tools"`
}

// learnLater learns from a finished turn in the background (a few at once).
func (a *Adapter) learnLater(s *session, t *transcript) {
	if a.mem == nil || t == nil || vmm.ExecutionFrom(s.base).NoMemory {
		return
	}
	scope, err := s.memoryScope()
	if err != nil {
		return
	}
	select {
	case a.learnSlots <- struct{}{}:
	default:
		return // busy: this turn is not learned from
	}
	go func() {
		defer func() { <-a.learnSlots }()
		ctx, cancel := context.WithTimeout(context.WithoutCancel(s.base), memoryCallTimout)
		defer cancel()
		if _, err := a.mem.learn(ctx, scope, *t); err != nil {
			a.Log.Warn("agent memory: learning from a turn failed", "space", s.spaceID, "error", err)
		}
	}()
}

// --- the gateway's memory endpoints ------------------------------------------------

func (a *Adapter) memorySession(req *network.Request) (*session, memoryScope, *network.Response) {
	s := a.byToken(bearer(req.Header))
	if s == nil {
		return nil, memoryScope{}, errorResponse(errs.Unauthenticated("invalid or expired agent turn token"))
	}
	if vmm.ExecutionFrom(s.base).NoMemory {
		return nil, memoryScope{}, errorResponse(errs.Permission("memory is disabled for this request"))
	}
	if a.mem == nil {
		return nil, memoryScope{}, errorResponse(errs.New(errs.CodeUnavailable, "the agents' memory is not available"))
	}
	scope, err := s.memoryScope()
	if err != nil {
		return nil, memoryScope{}, errorResponse(err)
	}
	if scope.personal {
		a.memory.notePerson(s.account)
	} else {
		a.memory.notePayer(s.spaceID, vmm.ExecutionFrom(s.base).ActorID)
	}
	return s, scope, nil
}

// serveNotesGet: GET {gateway}/memory/notes → {space, own}.
func (a *Adapter) serveNotesGet(ctx context.Context, req *network.Request) (*network.Response, error) {
	s, scope, resp := a.memorySession(req)
	if resp != nil {
		return resp, nil
	}
	defer s.begin()()
	shared, own, err := a.mem.notes(ctx, scope)
	if err != nil {
		return errorResponse(err), nil
	}
	return jsonResponse(http.StatusOK, map[string]any{"space": shared, "own": own}), nil
}

// serveNotesSet: POST {gateway}/memory/notes {content, shared}.
func (a *Adapter) serveNotesSet(ctx context.Context, req *network.Request) (*network.Response, error) {
	s, scope, resp := a.memorySession(req)
	if resp != nil {
		return resp, nil
	}
	defer s.begin()()
	var in struct {
		Content string `json:"content"`
		Shared  bool   `json:"shared"`
	}
	if err := json.Unmarshal(req.Body, &in); err != nil {
		return errorResponse(errs.InvalidArgument("invalid notes")), nil
	}
	id := scope.own
	if in.Shared {
		if scope.shared == "" {
			return errorResponse(errs.InvalidArgument("there are no shared notes here")), nil
		}
		id = scope.shared
	}
	if err := a.mem.setNotes(ctx, id, in.Content); err != nil {
		return errorResponse(err), nil
	}
	return jsonResponse(http.StatusOK, map[string]any{"ok": true}), nil
}

// serveRemember: POST {gateway}/memory/remember {text, kind, shared}.
func (a *Adapter) serveRemember(ctx context.Context, req *network.Request) (*network.Response, error) {
	s, scope, resp := a.memorySession(req)
	if resp != nil {
		return resp, nil
	}
	defer s.begin()()
	var in struct {
		Text   string `json:"text"`
		Kind   string `json:"kind"`
		Shared bool   `json:"shared"`
	}
	if err := json.Unmarshal(req.Body, &in); err != nil {
		return errorResponse(errs.InvalidArgument("invalid memory")), nil
	}
	rec, err := a.mem.remember(scoped{Context: ctx, values: s.base}, scope, in.Shared, in.Text, in.Kind, "told")
	if err != nil {
		return errorResponse(err), nil
	}
	return jsonResponse(http.StatusOK, map[string]any{"ok": true, "id": rec.ID}), nil
}

// serveRecall: POST {gateway}/memory/recall {query, limit} → {items}.
func (a *Adapter) serveRecall(ctx context.Context, req *network.Request) (*network.Response, error) {
	s, scope, resp := a.memorySession(req)
	if resp != nil {
		return resp, nil
	}
	defer s.begin()()
	var in struct {
		Query string `json:"query"`
		Limit int    `json:"limit"`
	}
	if err := json.Unmarshal(req.Body, &in); err != nil {
		return errorResponse(errs.InvalidArgument("invalid recall")), nil
	}
	items, err := a.mem.recall(scoped{Context: ctx, values: s.base}, scope, in.Query, in.Limit)
	if err != nil {
		return errorResponse(err), nil
	}
	return jsonResponse(http.StatusOK, map[string]any{"items": items}), nil
}

// --- the project's Memory screen (vmm.EngineMemory) ---------------------------------

// EngineMemoryRead implements vmm.EngineMemory: the space's shared notes, or
// one agent's notes and what it most recently learned.
func (a *Adapter) EngineMemoryRead(ctx context.Context, _ string, spaceID, agentID string) (*vmm.EngineMemoryView, error) {
	if a.mem == nil {
		return nil, errs.New(errs.CodeUnavailable, "the agents' memory is not available")
	}
	view := &vmm.EngineMemoryView{Engine: "harness", Agents: []string{}}
	shared, _, err := a.mem.notes(ctx, memoryScope{shared: spaceScope(spaceID)})
	if err != nil {
		return nil, err
	}
	view.SpaceNotes = shared
	if agentID == "" {
		return view, nil
	}
	_, own, err := a.mem.notes(ctx, memoryScope{own: agentScope(spaceID, agentID)})
	if err != nil {
		return nil, err
	}
	view.Agent, view.Notes = agentID, own
	db, err := a.mem.database(ctx)
	if err != nil {
		return nil, err
	}
	var rows []Memory
	if err := db.List(ctx, memoriesModel, database.Filter{Equal: map[string]any{"scope": agentScope(spaceID, agentID)},
		OrderBy: "created_at", Asc: false, Limit: 200}, &rows); err != nil {
		return nil, err
	}
	byDay := map[string][]string{}
	days := []string{}
	for _, r := range rows {
		day := r.CreatedAt.Format("2006-01-02")
		if _, ok := byDay[day]; !ok {
			days = append(days, day)
		}
		byDay[day] = append(byDay[day], "- "+r.Text)
	}
	for _, d := range days {
		view.Journal = append(view.Journal, vmm.EngineMemoryJournal{Day: d, Text: strings.Join(byDay[d], "\n")})
	}
	return view, nil
}

// EngineMemoryWrite implements vmm.EngineMemory: a person corrects the notes.
func (a *Adapter) EngineMemoryWrite(ctx context.Context, _ string, spaceID, agentID, content string) error {
	if a.mem == nil {
		return errs.New(errs.CodeUnavailable, "the agents' memory is not available")
	}
	if agentID == "" {
		return a.mem.setNotes(ctx, spaceScope(spaceID), content)
	}
	return a.mem.setNotes(ctx, agentScope(spaceID, agentID), content)
}

var _ vmm.EngineMemory = (*Adapter)(nil)

// --- a person's own memory (vmm.PersonMemory) -------------------------------------

func (a *Adapter) personScope(person string) (memoryScope, error) {
	id, err := identity.Parse(person)
	if err != nil || id.IsZero() {
		return memoryScope{}, errs.InvalidArgument("invalid person")
	}
	if a.mem == nil {
		return memoryScope{}, errs.New(errs.CodeUnavailable, "the agents' memory is not available")
	}
	a.memory.notePerson(id)
	return memoryScope{own: personScope(id.String()), payer: id, personal: true}, nil
}

// PersonNotes implements vmm.PersonMemory.
func (a *Adapter) PersonNotes(ctx context.Context, person string) (string, error) {
	scope, err := a.personScope(person)
	if err != nil {
		return "", err
	}
	_, own, err := a.mem.notes(ctx, scope)
	return own, err
}

// PersonSetNotes implements vmm.PersonMemory.
func (a *Adapter) PersonSetNotes(ctx context.Context, person, content string) error {
	scope, err := a.personScope(person)
	if err != nil {
		return err
	}
	return a.mem.setNotes(ctx, scope.own, content)
}

// PersonRecall implements vmm.PersonMemory.
func (a *Adapter) PersonRecall(ctx context.Context, person, query string, limit int) ([]string, error) {
	scope, err := a.personScope(person)
	if err != nil {
		return nil, err
	}
	items, err := a.mem.recall(ctx, scope, query, limit)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(items))
	for _, it := range items {
		if text, _ := it["text"].(string); text != "" {
			out = append(out, text)
		}
	}
	return out, nil
}

// PersonLearn implements vmm.PersonMemory.
func (a *Adapter) PersonLearn(ctx context.Context, person, said, reply string) {
	scope, err := a.personScope(person)
	if err != nil {
		return
	}
	select {
	case a.learnSlots <- struct{}{}:
	default:
		return
	}
	go func() {
		defer func() { <-a.learnSlots }()
		lctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), memoryCallTimout)
		defer cancel()
		if _, err := a.mem.learn(lctx, scope, transcript{Message: said, Reply: reply}); err != nil {
			a.Log.Warn("agent memory: learning from a note failed", "error", err)
		}
	}()
}

var _ vmm.PersonMemory = (*Adapter)(nil)
