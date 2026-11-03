package users

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// The AI log: one row for each time someone's Aseman (their notes) or the chat assistant (@aseman in
// a personal chat) took a prompt: what was asked, what it did and what came of it, so the node's admin can
// see how they are used and why one failed. The prompt and the answer are sealed at rest like messages are,
// only the node's admin can read the log (users.admin_ai_log), and a row is kept for aiLogKeep.

const (
	aiKindAseman = "aseman" // a note to yourself, read by your Aseman (brain.go)
	aiKindChat      = "chat"      // @aseman in a personal chat (saved_agents.go)

	aiOK      = "ok"      // answered
	aiSaved   = "saved"   // kept as a note, no answer
	aiAction  = "action"  // "yes" or "no" to a proposal
	aiCredits = "credits" // the wallet could not pay
	aiError   = "error"   // failed

	aiLogKeep  = 30 * 24 * time.Hour
	aiLogClip  = 6000
	aiLogLimit = 200
)

// aiLog is one row (ai_logs).
type aiLog struct {
	ID        string    `db:"id" json:"id"`
	Person    string    `db:"person" json:"person"`
	Kind      string    `db:"kind" json:"kind"`
	Peer      string    `db:"peer" json:"peer"`     // the other person of a chat; empty for notes
	Prompt    string    `db:"prompt" json:"prompt"` // sealed
	Answer    string    `db:"answer" json:"answer"` // sealed
	Plan      string    `db:"plan" json:"plan"`     // what it decided: save, answer, act, confirm, mention
	Tools     string    `db:"tools" json:"tools"`   // the tools it called, comma separated
	Status    string    `db:"status" json:"status"`
	Error     string    `db:"error" json:"error"`
	Millis    int64     `db:"millis" json:"millis"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}

func aiLogContext(id, field string) string { return "users/ailog/v1/" + field + "/" + id }

// aiEntry is what a caller reports; logAI stores it.
type aiEntry struct {
	person, peer identity.ID
	kind         string
	prompt       string
	answer       string
	plan         string
	tools        []string
	status       string
	err          error
	started      time.Time
}

// logAI records one prompt. It never fails the caller: a log that cannot be written is only a warning.
func (s *Service) logAI(ctx context.Context, e aiEntry) {
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return
	}
	key := s.K.Env()["node_private_key"]
	prompt, err1 := crypto.SealSecret(clip(e.prompt, aiLogClip), key, aiLogContext(id.String(), "prompt"))
	answer, err2 := crypto.SealSecret(clip(e.answer, aiLogClip), key, aiLogContext(id.String(), "answer"))
	if err1 != nil || err2 != nil {
		return
	}
	row := &aiLog{ID: id.String(), Person: e.person.String(), Kind: e.kind, Prompt: prompt, Answer: answer, Plan: e.plan,
		Tools: strings.Join(e.tools, ","), Status: e.status, CreatedAt: time.Now().UTC()}
	if e.peer != (identity.ID{}) {
		row.Peer = e.peer.String()
	}
	if e.err != nil {
		row.Error = clip(e.err.Error(), 600)
	}
	if !e.started.IsZero() {
		row.Millis = time.Since(e.started).Milliseconds()
	}
	if err := s.R.DB.Create(ctx, "ai_logs", row.ID, row); err != nil {
		s.warn("ai log", e.person, err)
	}
}

var aiLogPurged sync.Mutex
var aiLogPurgedAt time.Time

// purgeAILog removes rows past their keeping time, at most once an hour.
func (s *Service) purgeAILog(ctx context.Context) {
	aiLogPurged.Lock()
	if time.Since(aiLogPurgedAt) < time.Hour {
		aiLogPurged.Unlock()
		return
	}
	aiLogPurgedAt = time.Now()
	aiLogPurged.Unlock()
	var old []aiLog
	if err := s.R.List(ctx, "ai_logs", database.Filter{LessThan: map[string]any{"created_at": time.Now().Add(-aiLogKeep).UTC()}, Limit: 500}, &old); err != nil {
		return
	}
	for _, r := range old {
		_ = s.R.DB.Delete(ctx, "ai_logs", r.ID)
	}
}

// adminAILogAction users.admin_ai_log: the AI log, newest first, for the node's admin.
// {kind?, status?, person?: id or @handle, q?: text in the prompt or answer, before?: time, limit?}
func adminAILogAction(s *Service) api.Action {
	return helper.Action{Namespace: "users", Name: "admin_ai_log", Summary: "Admin: what people asked their Aseman and the chat assistant, and what came of it",
		Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
				return nil, err
			}
			var in struct {
				Kind   string `json:"kind"`
				Status string `json:"status"`
				Person string `json:"person"`
				Q      string `json:"q"`
				Before string `json:"before"`
				Limit  int    `json:"limit"`
			}
			if err := helper.Decode(req, &in); err != nil {
				return nil, err
			}
			s.purgeAILog(ctx)
			limit := in.Limit
			if limit <= 0 || limit > aiLogLimit {
				limit = 50
			}
			filter := database.Filter{Equal: map[string]any{}, OrderBy: "created_at", Limit: limit}
			if in.Kind != "" {
				filter.Equal["kind"] = in.Kind
			}
			if in.Status != "" {
				filter.Equal["status"] = in.Status
			}
			if p := strings.TrimSpace(in.Person); p != "" {
				id := p
				if parsed, err := identity.Parse(p); err != nil {
					acc, err := s.GetAccount(ctx, strings.TrimPrefix(p, "@"))
					if err != nil {
						return helper.JSON(map[string]any{"rows": []any{}, "more": false})
					}
					id = acc.ID.String()
				} else {
					id = parsed.String()
				}
				filter.Equal["person"] = id
			}
			if in.Before != "" {
				if t, err := time.Parse(time.RFC3339Nano, in.Before); err == nil {
					filter.LessThan = map[string]any{"created_at": t.UTC()}
				}
			}
			needle := strings.ToLower(strings.TrimSpace(in.Q))
			if needle != "" {
				// The text is sealed: read a larger page and filter after opening it.
				filter.Limit = aiLogLimit * 3
			}
			var rows []aiLog
			if err := s.R.List(ctx, "ai_logs", filter, &rows); err != nil {
				return nil, err
			}
			key := s.K.Env()["node_private_key"]
			out := make([]map[string]any, 0, len(rows))
			names := map[string]string{}
			who := func(id string) string {
				if id == "" {
					return ""
				}
				if n, ok := names[id]; ok {
					return n
				}
				if pid, err := identity.Parse(id); err == nil {
					if acc, err := s.GetAccount(ctx, pid.String()); err == nil {
						names[id] = "@" + acc.Handle
						return names[id]
					}
				}
				names[id] = id
				return id
			}
			for _, r := range rows {
				prompt, _ := crypto.OpenSecret(r.Prompt, key, aiLogContext(r.ID, "prompt"))
				answer, _ := crypto.OpenSecret(r.Answer, key, aiLogContext(r.ID, "answer"))
				if needle != "" && !strings.Contains(strings.ToLower(prompt+"\n"+answer), needle) {
					continue
				}
				out = append(out, map[string]any{
					"id": r.ID, "created_at": r.CreatedAt, "kind": r.Kind, "status": r.Status, "plan": r.Plan,
					"person": r.Person, "person_handle": who(r.Person), "peer": r.Peer, "peer_handle": who(r.Peer),
					"prompt": prompt, "answer": answer, "tools": splitTools(r.Tools), "error": r.Error, "millis": r.Millis,
				})
				if len(out) >= limit {
					break
				}
			}
			return helper.JSON(map[string]any{"rows": out, "more": len(rows) >= filter.Limit})
		}}
}

func splitTools(s string) []string {
	if s == "" {
		return []string{}
	}
	return strings.Split(s, ",")
}

var _ = errs.NotFound
