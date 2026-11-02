package users

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// The chat assistant: "@aseman" in a person's personal chats. A message that mentions it is
// answered by one model call, streamed into the chat as a reply to that message, with only the thread
// the message belongs to as context: no computer, no tools, no memory, nothing from anyone's rooms. It
// is the node's built-in assistant (bots.chat_assistant), not a market agent. In a person's own notes
// (Saved Messages) the same assistant is their Aseman, with a memory of its own: see brain.go.
//
// What it sees is decided by assistantTurns/assistantChain, the one place to widen it later (a setting
// the other person must agree to, or the conversation recalled from memory).

// savedAskTimeout bounds one answer; a quick question that takes longer is not one.
const savedAskTimeout = 3 * time.Minute

// maxSavedAsks is how many answers one person can be waiting for at once.
const maxSavedAsks = 3

// threadDepth is how many messages of a reply thread the assistant is given, and threadBudget the
// most text (in characters, about four to a token) it is sent.
const (
	threadDepth  = 8
	threadBudget = 12000
)

// savedAsk is an answer being written: the message it answers, who answers, where, and the text so far.
type savedAsk struct {
	note  string
	agent identity.ID
	conv  string
	since time.Time
	text  string
	// deciding: the person's Aseman is still deciding whether the note wants
	// an answer at all (brain.go). The app polls quickly but shows nothing yet.
	deciding bool
}

// savedAsks are the answers being written now, per person who asked (in memory: a restart drops
// the "working" state, never an answer already stored).
var savedAsks = struct {
	sync.Mutex
	by map[identity.ID][]*savedAsk
}{by: map[identity.ID][]*savedAsk{}}

// convKey names a conversation: the same for both people, and for one's own notes.
func convKey(a, b identity.ID) string {
	x, y := a.String(), b.String()
	if x > y {
		x, y = y, x
	}
	return x + ":" + y
}

// startSavedAsk records an answer being written, unless the person already waits for as many as
// allowed or this message is already being answered. Entries older than the timeout are dropped.
func startSavedAsk(person identity.ID, ask savedAsk) bool {
	savedAsks.Lock()
	defer savedAsks.Unlock()
	live := savedAsks.by[person][:0]
	for _, a := range savedAsks.by[person] {
		if time.Since(a.since) < savedAskTimeout+30*time.Second {
			live = append(live, a)
		}
	}
	savedAsks.by[person] = live
	if len(live) >= maxSavedAsks {
		return false
	}
	for _, a := range live {
		if a.note == ask.note {
			return false
		}
	}
	savedAsks.by[person] = append(live, &ask)
	return true
}

// setSavedAskText is the answer so far, for the chat to show while it is written.
func setSavedAskText(person identity.ID, note, text string) {
	savedAsks.Lock()
	defer savedAsks.Unlock()
	for _, a := range savedAsks.by[person] {
		if a.note == note {
			a.text = text
		}
	}
}

// setSavedAskDeciding says whether the answer to a note is still being decided on.
func setSavedAskDeciding(person identity.ID, note string, deciding bool) {
	savedAsks.Lock()
	defer savedAsks.Unlock()
	for _, a := range savedAsks.by[person] {
		if a.note == note {
			a.deciding = deciding
		}
	}
}

func endSavedAsk(person identity.ID, note string) {
	savedAsks.Lock()
	defer savedAsks.Unlock()
	live := savedAsks.by[person][:0]
	for _, a := range savedAsks.by[person] {
		if a.note != note {
			live = append(live, a)
		}
	}
	if len(live) == 0 {
		delete(savedAsks.by, person)
	} else {
		savedAsks.by[person] = live
	}
}

// workingAsks are the answers being written in one conversation, whoever asked: both people see them
// ("thinking", then the text as it grows).
func (s *Service) workingAsks(ctx context.Context, viewer identity.ID, conv string) []map[string]any {
	savedAsks.Lock()
	var asks []savedAsk
	for _, list := range savedAsks.by {
		for _, a := range list {
			if a.conv == conv && time.Since(a.since) < savedAskTimeout+30*time.Second {
				asks = append(asks, *a)
			}
		}
	}
	savedAsks.Unlock()
	out := []map[string]any{}
	for _, a := range asks {
		row := map[string]any{"message_id": a.note, "agent": s.publicRef(ctx, viewer, a.agent), "since": a.since, "text": a.text}
		if a.deciding {
			row["deciding"] = true
		}
		out = append(out, row)
	}
	return out
}

// threadMsg is one message of a thread the assistant is shown.
type threadMsg struct {
	from  identity.ID
	body  string
	agent bool // written by the assistant
}

// assistantTurns turns a thread (oldest first, the mention last) into the chat the assistant answers.
// In a chat between two people each person's messages carry their name, so it can tell who said what.
// The oldest messages go first when the text would pass the budget; the mention itself always stays.
func assistantTurns(chain []threadMsg, names map[identity.ID]string, group bool, budget int) []map[string]string {
	type turn struct{ role, text string }
	turns := make([]turn, 0, len(chain))
	for _, m := range chain {
		text := strings.TrimSpace(m.body)
		role := "user"
		switch {
		case m.agent:
			role = "assistant"
		case group:
			if name := names[m.from]; name != "" {
				text = name + ": " + text
			}
		}
		turns = append(turns, turn{role, text})
	}
	size := func() int {
		n := 0
		for _, t := range turns {
			n += len(t.text)
		}
		return n
	}
	for len(turns) > 1 && size() > budget {
		turns = turns[1:]
	}
	if last := &turns[len(turns)-1]; len(last.text) > budget {
		last.text = string([]rune(last.text)[:budget/2]) + "…"
	}
	// Models want the speakers to alternate: neighbours with the same role are one turn.
	var merged []map[string]string
	for _, t := range turns {
		if n := len(merged); n > 0 && merged[n-1]["role"] == t.role {
			merged[n-1]["content"] += "\n\n" + t.text
			continue
		}
		merged = append(merged, map[string]string{"role": t.role, "content": t.text})
	}
	return merged
}

// assistantChain is the thread the mention belongs to, oldest first: the message, then what it
// replies to, and so on up (threadDepth at most), staying inside this one conversation and
// leaving out what was taken back or deleted for the person.
func (s *Service) assistantChain(ctx context.Context, me, peer identity.ID, note *message.Direct) []threadMsg {
	hidden, _ := s.hiddenDirects(ctx, me)
	inChat := func(dm *message.Direct) bool {
		return (dm.From == me && dm.To == peer) || (dm.From == peer && dm.To == me)
	}
	var newestFirst []threadMsg
	for cur, depth := note, 0; cur != nil && depth < threadDepth; depth++ {
		newestFirst = append(newestFirst, threadMsg{from: cur.From, body: cur.Body, agent: cur.AgentID != ""})
		if cur.ReplyTo == "" {
			break
		}
		next := (*message.Direct)(nil)
		if id, err := identity.Parse(cur.ReplyTo); err == nil {
			if dm, err := s.getDirect(ctx, id); err == nil && inChat(dm) && dm.DeletedAt.IsZero() && !hidden[dm.ID.String()] {
				next = dm
			}
		}
		cur = next
	}
	chain := make([]threadMsg, 0, len(newestFirst))
	for i := len(newestFirst) - 1; i >= 0; i-- {
		chain = append(chain, newestFirst[i])
	}
	return chain
}

// assistant is the built-in chat assistant's bot record.
func (s *Service) assistant(ctx context.Context) (*bot.Bot, error) {
	if s.assistantFn != nil {
		return s.assistantFn(ctx)
	}
	var rec *bot.Bot
	if err := bridge.Invoke(ctx, s.K, "bots", "InstallChatAssistant", []any{ctx}, &rec); err != nil {
		return nil, err
	}
	return rec, nil
}

// askAssistant has the assistant answer turns for person, calling onText as the answer grows.
func (s *Service) askAssistant(ctx context.Context, person identity.ID, rec *bot.Bot, turns []map[string]string, onText func(string)) (string, error) {
	if s.answerFn != nil {
		return s.answerFn(ctx, person, rec, turns, onText)
	}
	var reply string
	err := bridge.Invoke(ctx, s.K, "bots", "ChatAnswerStream", []any{ctx, person, rec.ID, turns, onText}, &reply)
	return reply, err
}

// dmAgentAskAction users.dm_agent_ask: the chat assistant answers a message of the caller's that
// mentions it, in their notes or in a personal chat. (Older apps send an `agent`; it is ignored:
// the assistant is the only one that answers in chats.)
type dmAgentAskAction struct{ s *Service }

func (a *dmAgentAskAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "dm_agent_ask", Summary: "Have Aseman answer a message of yours in your notes or a personal chat"}
}

func (a *dmAgentAskAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Message string `json:"message"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	me := req.Caller.ID
	noteID, err := identity.Parse(in.Message)
	if err != nil {
		return nil, errs.InvalidArgument("message required")
	}
	note, err := a.s.getDirect(ctx, noteID)
	if err != nil || note.From != me || !note.DeletedAt.IsZero() {
		return nil, errs.InvalidArgument("Aseman answers your own messages only")
	}
	if note.AgentID != "" {
		return nil, errs.InvalidArgument("that is an answer from Aseman")
	}
	peer := note.To
	if peer == me {
		// Your own notes are your Aseman's: it reads every note as it is sent
		// (brain.go), so there is nothing more to ask.
		return helper.JSON(map[string]any{"ok": true})
	}
	if peer != me {
		// A personal chat: not when either side has blocked the other.
		if blocked, _, err := a.s.directBlocked(ctx, me, peer); err != nil {
			return nil, err
		} else if blocked {
			return nil, errs.InvalidArgument("this chat is blocked")
		}
	}
	rec, err := a.s.assistant(ctx)
	if err != nil {
		return nil, err
	}
	chain := a.s.assistantChain(ctx, me, peer, note)
	names := map[identity.ID]string{}
	group := peer != me
	if group {
		for _, id := range []identity.ID{me, peer} {
			if ref := a.s.publicRef(ctx, me, id); ref != nil {
				names[id], _ = ref["display_name"].(string)
			}
		}
	}
	turns := assistantTurns(chain, names, group, threadBudget)
	if !startSavedAsk(me, savedAsk{note: note.ID.String(), agent: rec.AccountID, conv: convKey(me, peer), since: time.Now().UTC()}) {
		return nil, errs.Conflict("wait for Aseman to answer first")
	}
	go a.s.answerSavedAsk(helper.WithActor(context.WithoutCancel(ctx), me), me, peer, rec, note.ID.String(), turns)
	return helper.JSON(map[string]any{"ok": true})
}

// answerSavedAsk runs the assistant and stores its answer in the chat as a reply to the message. A failure is
// answered too, so nobody is left waiting on a message that will not be answered.
func (s *Service) answerSavedAsk(ctx context.Context, me, peer identity.ID, rec *bot.Bot, noteID string, turns []map[string]string) {
	defer endSavedAsk(me, noteID)
	ctx, cancel := context.WithTimeout(ctx, savedAskTimeout)
	defer cancel()
	started := time.Now()
	reply, err := s.askAssistant(ctx, me, rec, turns, func(text string) { setSavedAskText(me, noteID, text) })
	reply = strings.TrimSpace(reply)
	// The admin's AI log, whatever came of it.
	logged := aiEntry{person: me, peer: peer, kind: aiKindChat, plan: "mention", prompt: lastUserTurn(turns), answer: reply, status: aiOK, started: started}
	if err != nil {
		logged.err = err
		logged.status = aiError
		if errs.CodeOf(err) == errs.CodeFinance || errs.CodeOf(err) == errs.CodeBudgetExhausted {
			logged.status = aiCredits
		}
	}
	defer func() { s.logAI(context.WithoutCancel(ctx), logged) }()
	if err != nil {
		if s.L != nil {
			s.L.Warn("chat assistant answer failed", "bot", rec.ID.String(), "error", err)
		}
		why := "Something went wrong. Please try again later."
		if errs.CodeOf(err) == errs.CodeFinance || errs.CodeOf(err) == errs.CodeBudgetExhausted || strings.Contains(strings.ToLower(err.Error()), "fund") {
			why = "Your wallet needs credits."
		}
		reply = strings.TrimSpace(reply + "\n\n" + why)
	}
	if reply == "" {
		return
	}
	s.storeAnswer(ctx, me, peer, rec, noteID, reply, "")
}

// dmAssistantAction users.dm_assistant: who answers when a chat mentions @aseman (for the picker).
type dmAssistantAction struct{ s *Service }

func (a *dmAssistantAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "dm_assistant", Summary: "The assistant people mention as @aseman in their chats"}
}

func (a *dmAssistantAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	rec, err := a.s.assistant(ctx)
	if err != nil {
		return nil, err
	}
	ref := a.s.publicRef(ctx, req.Caller.ID, rec.AccountID)
	ref["bot_id"] = rec.ID.String()
	ref["name"] = rec.Name
	return helper.JSON(ref)
}

// lastUserTurn is the latest line the person wrote in a chat's turns (what the assistant was asked).
func lastUserTurn(turns []map[string]string) string {
	for i := len(turns) - 1; i >= 0; i-- {
		if turns[i]["role"] == "user" {
			return turns[i]["content"]
		}
	}
	return ""
}
