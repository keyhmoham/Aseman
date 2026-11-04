package users

import (
	"context"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// A person's Aseman: their notes to themselves (the Aseman chat) are a
// conversation with their own brain. Every note is read, with no @mention or
// command: a note to keep is kept (✓, "saved"), anything that wants a reply is
// answered, and everything goes into the person's own memory.
//
// One message, fast:
//
//	note ─┬─ decision model: keep or answer? lasting fact? about their rooms?
//	      ├─ recall: what their memory holds about it (their own, in the agent runtime's memory)
//	      └─ their rooms: the ones they let it read (brain_access.go)
//	      → keep: ✓, and remembered
//	      → answer: one streamed call (bots.BrainAnswerStream) with what it knows of them
//
// Each step has a deadline and none is needed: without the decision model the
// answer model itself may keep a note silently (brainSilent); without memory
// models it answers from the conversation, its notes and the rooms alone.
//
// The memory is the person's own (vmm.PersonMemory): nothing of a room
// is copied into it, and nothing of it reaches any room. Rooms are read as the
// person, when a message is about them (their latest messages and shared
// notes), never searched by meaning: that would spend the room's memory budget
// on someone's private questions. The person pays for all of it, as chats.

const (
	// brainDecisionTimeout and brainRecallTimeout bound the steps before an
	// answer starts; they run side by side.
	brainDecisionTimeout = 1200 * time.Millisecond
	brainRecallTimeout   = 1200 * time.Millisecond
	// brainRecallTokens is the most of their memory recalled for one message.
	brainRecallTokens = 1500
	// brainNotesChars is the most of what it knows of the person (its notes)
	// that goes into every answer.
	brainNotesChars = 6000
	// brainDepth is how many of the latest notes it is shown, brainBudget the
	// most text of them (characters).
	brainDepth  = 12
	brainBudget = 16000
	// brainRooms is how many rooms it reads for a message about them (the most
	// active it may read), brainRoomLines how many messages of each and
	// brainRoomNotes how much of each room's shared notes.
	brainRooms      = 4
	brainRoomLines  = 6
	brainRoomNotes  = 1500
	brainRememberAt = 300 // characters of a note kept in its notes
)

// What the decision model must be sure of before it is followed: keeping a
// question without answering is worse than answering a note, so a note is
// kept silently only when it is clearly one.
const (
	brainSaveAt     = 0.8
	brainRememberIf = 0.7
	brainRoomsIf    = 0.5
	brainActIf      = 0.5
)

// brainSilent is how the answer model says "nothing to answer" when there is no
// decision model to ask first.
const brainSilent = "<saved>"

// brainPlan is what the brain does with one note.
type brainPlan struct {
	decided  bool // the decision model (or an obvious rule) said; else the answer model decides
	save     bool // keep it without answering
	act      bool // a request to do something: the answer may use its tools
	remember bool // a lasting fact about the person: into its notes
	rooms    bool // about their rooms: read them
}

var urlOnly = regexp.MustCompile(`^(?:\s*https?://\S+\s*)+$`)

// obviousNote is a note that needs no model to know it wants no answer: files
// with no words, or links alone.
func obviousNote(body string, files int) bool {
	body = strings.TrimSpace(body)
	return (body == "" && files > 0) || (body != "" && urlOnly.MatchString(body))
}

// asksAseman: the person named it, so it answers whatever the note looks like.
func asksAseman(body string) bool {
	return strings.Contains(strings.ToLower(body), "@"+assistantHandle)
}

// assistantHandle is how people name it in a message.
const assistantHandle = "aseman"

// brainQuestions are what the decision model is asked about a note.
func brainQuestions() map[string]any {
	return map[string]any{
		"mode": map[string]any{"type": "choice",
			"instructions": "The person wrote `message` in their own notes, which their assistant reads. Do they want an answer now?",
			"criteria": map[string]any{
				"save":   "a note, list, link or idea to keep: nothing is asked or requested",
				"answer": "a question or a remark that expects a reply",
				"do":     "a request to do something for them: create a room, message or invite someone, hand work to a room, set a reminder, look up their rooms, balance or reminders, look at a website or link they name, or do work that needs a computer (research across many sites, run code, build something)",
			}},
		"remember": map[string]any{"type": "boolean",
			"instructions": "Does `message` state a lasting fact, preference or instruction about the person: who they are, the people in their life, what they like, how they want things done? (Not passwords, codes or one-off tasks.)"},
		"rooms": map[string]any{"type": "boolean",
			"instructions": "Is `message` about the person's rooms, projects, teams or work going on with others?"},
	}
}

// brainPlanOf reads the decision model's answers.
func brainPlanOf(answers map[string]any) brainPlan {
	p := brainPlan{decided: true}
	if mode, _ := answers["mode"].(map[string]any); mode != nil {
		probs, _ := mode["probabilities"].(map[string]any)
		switch mode["choice"] {
		case "save":
			p.save = number(probs["save"]) >= brainSaveAt
		case "do":
			p.act = number(probs["do"]) >= brainActIf
		}
	}
	p.remember = probability(answers, "remember") >= brainRememberIf
	p.rooms = probability(answers, "rooms") >= brainRoomsIf
	return p
}

func probability(answers map[string]any, key string) float64 {
	a, _ := answers[key].(map[string]any)
	return number(a["probability"])
}

func number(v any) float64 {
	f, _ := v.(float64)
	return f
}

var secretish = regexp.MustCompile(`(?i)\b(password|passcode|pin|otp|api[ _-]?key|token|secret|seed phrase|cvv)\b`)

// rememberLine is a note as a line of what it knows of the person, or "" for
// one that must never go into every prompt (anything that looks like a secret).
func rememberLine(body string, at time.Time) string {
	line := strings.Join(strings.Fields(body), " ")
	line = strings.ReplaceAll(line, "@"+assistantHandle, "")
	line = strings.TrimSpace(line)
	if line == "" || secretish.MatchString(line) {
		return ""
	}
	if r := []rune(line); len(r) > brainRememberAt {
		line = string(r[:brainRememberAt]) + "…"
	}
	return fmt.Sprintf("- %s (%s)\n", line, at.Format("2006-01-02"))
}

// silentSoFar: the answer so far could still be brainSilent, so nothing of it is shown yet.
func silentSoFar(text string) bool {
	t := strings.TrimSpace(text)
	return strings.HasPrefix(brainSilent, t) || t == brainSilent
}

// ── memory ──────────────────────────────────────────────────────────────────

// brainMemory is the person's memory in the agent runtime (nil when the node
// has none).
func (s *Service) brainMemory() vmm.PersonMemory {
	if s.memoryFn != nil {
		return s.memoryFn()
	}
	if s.K == nil {
		return nil
	}
	pm, _ := s.K.VMMFor(vmm.TypeHarness).(vmm.PersonMemory)
	return pm
}

// brainNotesCache keeps each person's notes for a little while: they go into
// every answer and change only when a note is remembered or the person edits them.
var brainNotesCache = struct {
	sync.Mutex
	by map[identity.ID]cachedNotes
}{by: map[identity.ID]cachedNotes{}}

type cachedNotes struct {
	text string
	at   time.Time
}

const brainNotesFresh = 2 * time.Minute

// brainNotes is what the person's Aseman knows of them ("" when nothing yet).
func (s *Service) brainNotes(ctx context.Context, me identity.ID) (string, error) {
	brainNotesCache.Lock()
	c, ok := brainNotesCache.by[me]
	brainNotesCache.Unlock()
	if ok && time.Since(c.at) < brainNotesFresh {
		return c.text, nil
	}
	ov := s.brainMemory()
	if ov == nil {
		return "", nil
	}
	text, err := ov.PersonNotes(ctx, me.String())
	if err != nil {
		return "", err
	}
	brainNotesCache.Lock()
	brainNotesCache.by[me] = cachedNotes{text: text, at: time.Now()}
	brainNotesCache.Unlock()
	return text, nil
}

func forgetCachedNotes(me identity.ID) {
	brainNotesCache.Lock()
	delete(brainNotesCache.by, me)
	brainNotesCache.Unlock()
}

// brainRecord hands what was said to the person's memory, which learns about
// them in the background. Best effort.
func (s *Service) brainRecord(ctx context.Context, me identity.ID, said, reply string) {
	ov := s.brainMemory()
	if ov == nil || strings.TrimSpace(said) == "" {
		return
	}
	ov.PersonLearn(ctx, me.String(), said, reply)
}

func (s *Service) warn(msg string, me identity.ID, err error) {
	if s.L != nil {
		s.L.Warn(msg, "person", me.String(), "error", err)
	}
}

// ── one note ────────────────────────────────────────────────────────────────

// brainNote is a note the person just wrote to themselves.
type brainNote struct {
	msg   *message.Direct
	files []string // the names of the files it carries
	// voice: spoken in a live voice chat. It is always answered (never just kept), and quickly: no decision
	// model, memory and rooms only within a very short deadline, an answer meant to be heard.
	voice bool
}

// NoteSaved is called by the messenger when someone writes in their Saved
// Messages room: the note is already on the room timeline, so this only
// records it as a Direct (for the brain's thread) and starts the personal
// Aseman. It does not mirror back into the room. The Direct id is returned so
// the room message can carry it (react / hide / keep).
func (s *Service) NoteSaved(ctx context.Context, me identity.ID, body string, voice bool) (identity.ID, error) {
	if me.IsZero() {
		return identity.ID{}, errs.Unauthenticated("authentication required")
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return identity.ID{}, err
	}
	now := time.Now().UTC()
	dm := &message.Direct{
		Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		From:   me, To: me, Body: body, SentAt: now,
	}
	if err := s.storeDirect(ctx, dm); err != nil {
		return identity.ID{}, err
	}
	s.startBrain(ctx, me, brainNote{msg: dm, voice: voice})
	return id, nil
}

// RecordDirect stores a person↔person (or person↔agent) Direct that already
// lives as a room message, so dm_react / dm_hide / dm_keep can address it.
// peerKey is spaces.direct_key ("smallerID:largerID").
func (s *Service) RecordDirect(ctx context.Context, me identity.ID, peerKey, body string) (identity.ID, error) {
	if me.IsZero() || body == "" {
		return identity.ID{}, errs.InvalidArgument("message required")
	}
	parts := strings.Split(peerKey, ":")
	if len(parts) != 2 {
		return identity.ID{}, errs.InvalidArgument("direct key")
	}
	a, errA := identity.Parse(parts[0])
	b, errB := identity.Parse(parts[1])
	if errA != nil || errB != nil {
		return identity.ID{}, errs.InvalidArgument("direct key")
	}
	peer := b
	if peer == me {
		peer = a
	}
	if peer == me {
		return s.NoteSaved(ctx, me, body, false)
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return identity.ID{}, err
	}
	now := time.Now().UTC()
	dm := &message.Direct{
		Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		From:   me, To: peer, Body: body, SentAt: now,
	}
	if err := s.storeDirect(ctx, dm); err != nil {
		return identity.ID{}, err
	}
	return id, nil
}

// ReactionsFor returns emoji reactions keyed by Direct message id (JSON maps
// for the spaces bridge).
func (s *Service) ReactionsFor(ctx context.Context, directIDs []string) map[string][]map[string]any {
	if len(directIDs) == 0 {
		return nil
	}
	ids := make([]any, 0, len(directIDs))
	for _, id := range directIDs {
		if id != "" {
			ids = append(ids, id)
		}
	}
	if len(ids) == 0 {
		return nil
	}
	var rows []directReaction
	if err := s.R.List(ctx, "direct_reactions", database.Filter{In: map[string][]any{"message_id": ids}, OrderBy: "created_at", Asc: true}, &rows); err != nil {
		return nil
	}
	out := map[string][]map[string]any{}
	for _, r := range rows {
		out[r.MessageID] = append(out[r.MessageID], map[string]any{
			"user_id": r.UserID, "emoji": r.Emoji,
		})
	}
	return out
}

// HiddenDirectsFor is which Direct ids [user] hid for themselves.
func (s *Service) HiddenDirectsFor(ctx context.Context, user identity.ID) map[string]bool {
	hidden, err := s.hiddenDirects(ctx, user)
	if err != nil {
		return nil
	}
	return hidden
}

// startBrain has the person's Aseman take a note they just wrote to
// themselves, without holding up the request. An answer shows as "working"
// once it is known one is coming (dm_list's agents_working); a note it keeps
// is marked saved.
func (s *Service) startBrain(ctx context.Context, me identity.ID, note brainNote) {
	rec, err := s.assistant(ctx)
	if err != nil {
		return // no assistant on this node: notes are only notes
	}
	answering := startSavedAsk(me, savedAsk{note: note.msg.ID.String(), agent: rec.AccountID, conv: convKey(me, me),
		since: time.Now().UTC(), deciding: true})
	go s.runBrain(helper.WithActor(context.WithoutCancel(ctx), me), me, rec, note, answering)
}

// runBrain answers (or keeps) a note. The spoken reply text is returned when one
// was produced ("" when the note was only remembered or nothing came of it).
func (s *Service) runBrain(ctx context.Context, me identity.ID, rec *bot.Bot, note brainNote, answering bool) string {
	noteID := note.msg.ID.String()
	ctx, cancel := context.WithTimeout(ctx, savedAskTimeout)
	defer cancel()
	body := strings.TrimSpace(note.msg.Body)
	said := brainSaid(body, note.files)
	if !answering {
		// The person already waits for as many answers as allowed: this note
		// is remembered, not answered (and not marked kept: it may be a question).
		s.brainRecord(ctx, me, said, "")
		return ""
	}
	defer endSavedAsk(me, noteID)
	// The admin's AI log: what was asked, what it did and what came of it (logged when this returns).
	entry := aiEntry{person: me, kind: aiKindAseman, prompt: body, plan: "answer", status: aiOK, started: time.Now()}
	defer func() { s.logAI(context.WithoutCancel(ctx), entry) }()

	// "Yes" (or "no") to what it just proposed: done (or not), with no model asked.
	if yes, no := sayYes.MatchString(body), sayNo.MatchString(body); yes || no {
		if dm, p := s.pendingProposal(ctx, me); dm != nil {
			result, err := s.resolve(ctx, me, dm, p, yes)
			entry.plan, entry.status, entry.answer = "confirm", aiAction, result
			if err != nil {
				result = "Something went wrong. Please try again later."
				entry.status, entry.err = aiError, err
			}
			s.storeAnswer(ctx, me, me, rec, noteID, result, "")
			s.brainRecord(ctx, me, said, result)
			return result
		}
	}
	thread := s.brainThread(ctx, me)

	if note.voice {
		// Someone waits to hear it: the model may think less before its first words.
		ctx = helper.WithFast(ctx)
	}

	// What to do, what memory holds and what the rooms say, side by side.
	var (
		wg     sync.WaitGroup
		plan   brainPlan
		recall string
		notes  string
		rooms  []brainRoomView
	)
	wg.Add(3)
	go func() {
		defer wg.Done()
		switch {
		case note.voice:
			plan = brainPlan{decided: true, act: voiceWantsAction(body), rooms: voiceMentionsRooms(body)}
		case obviousNote(body, len(note.files)) && !asksAseman(body):
			plan = brainPlan{decided: true, save: true}
		default:
			plan = s.brainDecide(ctx, me, rec, body, thread, note.files)
		}
	}()
	go func() {
		defer wg.Done()
		notes, _ = s.brainNotes(ctx, me)
		if note.voice {
			// Memory may add a line, but a voice answer does not wait on it.
			rctx, stop := context.WithTimeout(ctx, voiceRecallTimeout)
			defer stop()
			recall = s.brainRecall(rctx, me, body, thread)
			return
		}
		recall = s.brainRecall(ctx, me, body, thread)
	}()
	go func() {
		defer wg.Done()
		if note.voice && !voiceMentionsRooms(body) {
			return
		}
		rooms = s.brainRoomContext(ctx, me)
	}()
	wg.Wait()
	if asksAseman(body) {
		plan.save = false
	}
	// A site or link in a note that is not just kept: the answer may read it.
	if !plan.save && mentionsSite(body) {
		plan.act = true
	}
	switch {
	case plan.save:
		entry.plan = "save"
	case plan.act || !plan.decided:
		entry.plan = "act"
	}

	if plan.remember {
		if line := rememberLine(body, note.msg.CreatedAt); line != "" {
			if ov := s.brainMemory(); ov != nil {
				if err := ov.PersonSetNotes(ctx, me.String(), notes+line); err != nil {
					s.warn("brain: remember", me, err)
				} else {
					forgetCachedNotes(me)
					notes += line
				}
			}
		}
	}
	if plan.save {
		entry.status = aiSaved
		s.markSaved(ctx, note.msg.ID)
		s.brainRecord(ctx, me, said, "")
		return ""
	}

	if plan.decided {
		setSavedAskDeciding(me, noteID, false)
	}
	turns := brainTurns(thread, brainContext(time.Now().UTC(), recall, rooms, plan.rooms || !plan.decided))
	shown := func(text string) {
		if !plan.decided && silentSoFar(text) {
			return
		}
		setSavedAskDeciding(me, noteID, false)
		setSavedAskText(me, noteID, text)
	}
	// Something to do (or no decision model to say it is not): Aseman acts on
	// the agent runtime, as the person. Otherwise it streams an answer.
	var (
		reply string
		err   error
	)
	if plan.act || !plan.decided {
		reply, err = s.brainAct(ctx, me, rec, brainBrief(notes, rooms)+s.jobsBrief(ctx, me)+voiceBrief(note.voice), turns, shown)
	} else {
		reply, err = s.brainAnswer(ctx, me, rec, brainBrief(notes, rooms)+s.jobsBrief(ctx, me)+voiceBrief(note.voice), turns, shown)
	}
	reply = strings.TrimSpace(reply)
	if err == nil && !plan.decided && silentSoFar(reply) {
		entry.status, entry.plan = aiSaved, "save"
		s.markSaved(ctx, note.msg.ID)
		s.brainRecord(ctx, me, said, "")
		return ""
	}
	entry.answer = reply
	if err != nil && outOfCredits(err) {
		entry.status, entry.err = aiCredits, err
		// Not a failure to apologise for: a way to add credits, and to pick this note up again after.
		s.storeAnswerMarked(ctx, me, me, rec, noteID, creditsReply, "", message.BrainCredits)
		return creditsReply
	}
	if err != nil {
		entry.status, entry.err = aiError, err
		s.warn("brain: answer", me, err)
		reply = strings.TrimSpace(reply + "\n\nSomething went wrong. Please try again later.")
	}
	if reply == "" {
		return ""
	}
	// Work the answer started shows as cards under it.
	s.storeAnswer(ctx, me, me, rec, noteID, reply, encodeProposal(nil, takeAnswerCards(noteID)))
	if err == nil {
		s.brainRecord(ctx, me, said, reply)
	}
	return reply
}

// answerVoiceNote stores a spoken turn as a Saved note and waits for Aseman's
// reply (used by users.voice_turn so TTS can speak it in the same request).
func (s *Service) answerVoiceNote(ctx context.Context, me identity.ID, text string) (string, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return "", errs.InvalidArgument("nothing heard")
	}
	rec, err := s.assistant(ctx)
	if err != nil {
		return "", err
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return "", err
	}
	now := time.Now().UTC()
	dm := &message.Direct{
		Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		From:   me, To: me, Body: text, SentAt: now,
	}
	if err := s.storeDirect(ctx, dm); err != nil {
		return "", err
	}
	// Show what they said in Saved Messages (Talk otherwise only stored directs).
	s.mirrorDirectID(context.WithoutCancel(ctx), me, me, text, id)
	answering := startSavedAsk(me, savedAsk{note: dm.ID.String(), agent: rec.AccountID, conv: convKey(me, me),
		since: now, deciding: true})
	reply := s.runBrain(helper.WithActor(ctx, me), me, rec, brainNote{msg: dm, voice: true}, answering)
	return strings.TrimSpace(reply), nil
}

// brainSaid is a note as the memory is given it: its words, and the files it carries.
func brainSaid(body string, files []string) string {
	if len(files) > 0 {
		body = strings.TrimSpace(body + "\n[attached: " + strings.Join(files, ", ") + "]")
	}
	return body
}

// brainDecide asks the decision model what to do with a note. Without one (off,
// slow, failing) the answer model decides.
func (s *Service) brainDecide(ctx context.Context, me identity.ID, rec *bot.Bot, body string, thread []threadMsg, files []string) brainPlan {
	if s.decideFn != nil {
		return s.decideFn(ctx, body)
	}
	state := map[string]any{"message": body}
	if earlier := lastWords(thread, 2, 600); earlier != "" {
		state["earlier"] = earlier
	}
	if len(files) > 0 {
		state["attachments"] = files
	}
	var answers map[string]any
	if err := bridge.Invoke(ctx, s.K, "bots", "ChatDecide", []any{ctx, me, rec.ID, state, brainQuestions(), brainDecisionTimeout}, &answers); err != nil {
		return brainPlan{}
	}
	return brainPlanOf(answers)
}

// lastWords are the notes before the newest one (at most n, each clipped), oldest first.
func lastWords(thread []threadMsg, n, clip int) string {
	if len(thread) < 2 {
		return ""
	}
	before := thread[:len(thread)-1]
	if len(before) > n {
		before = before[len(before)-n:]
	}
	var lines []string
	for _, m := range before {
		text := strings.TrimSpace(m.body)
		if r := []rune(text); len(r) > clip {
			text = string(r[:clip]) + "…"
		}
		who := "Them"
		if m.agent {
			who = "Aseman"
		}
		if text != "" {
			lines = append(lines, who+": "+text)
		}
	}
	return strings.Join(lines, "\n")
}

// brainRecall is what the person's memory holds about the note ("" when nothing
// or no memory), within its deadline.
func (s *Service) brainRecall(ctx context.Context, me identity.ID, body string, thread []threadMsg) string {
	ov := s.brainMemory()
	if ov == nil || strings.TrimSpace(body) == "" {
		return ""
	}
	// A short follow-up is searched with what came just before it.
	query := body
	if len([]rune(body)) < 80 {
		if earlier := lastWords(thread, 1, 400); earlier != "" {
			query = earlier + "\n" + body
		}
	}
	ctx, cancel := context.WithTimeout(ctx, brainRecallTimeout)
	defer cancel()
	out, err := ov.PersonRecall(ctx, me.String(), query, 8)
	if err != nil {
		if ctx.Err() == nil {
			s.warn("brain: recall", me, err)
		}
		return ""
	}
	if len(out) == 0 {
		return ""
	}
	return "- " + strings.Join(out, "\n- ")
}

// brainAnswer has the assistant answer as the person's Aseman.
func (s *Service) brainAnswer(ctx context.Context, me identity.ID, rec *bot.Bot, brief string, turns []map[string]string, onText func(string)) (string, error) {
	if s.brainAnswerFn != nil {
		return s.brainAnswerFn(ctx, me, rec, brief, turns, onText)
	}
	var reply string
	err := bridge.Invoke(ctx, s.K, "bots", "BrainAnswerStream", []any{ctx, me, rec.ID, brief, turns, onText}, &reply)
	return reply, err
}

// brainAct has the person's Aseman act for them on the agent runtime (DeepSeek
// Harness), as the person, with the runtime's tools and their access.
func (s *Service) brainAct(ctx context.Context, me identity.ID, rec *bot.Bot, brief string, turns []map[string]string, onText func(string)) (string, error) {
	if s.actFn != nil {
		reply, err := s.actFn(ctx, me, brief, turns)
		if reply != "" && onText != nil {
			onText(reply)
		}
		return reply, err
	}
	var reply string
	err := bridge.Invoke(ctx, s.K, "bots", "BrainAct", []any{ctx, me, rec.ID, brief, turns, onText}, &reply)
	return reply, err
}

// brainThread is the latest notes of the person's conversation with themselves,
// oldest first: what they wrote and what Aseman answered.
func (s *Service) brainThread(ctx context.Context, me identity.ID) []threadMsg {
	var rows []message.Direct
	if err := s.R.List(ctx, "directs", database.Filter{
		Equal:   map[string]any{"from_id": me.String(), "to_id": me.String()},
		OrderBy: "created_at", Asc: false, Limit: brainDepth * 2,
	}, &rows); err != nil {
		return nil
	}
	st, _, _ := s.directStateOf(ctx, me, me)
	hidden, _ := s.hiddenDirects(ctx, me)
	var newestFirst []threadMsg
	for i := range rows {
		dm := &rows[i]
		if !dm.DeletedAt.IsZero() || hidden[dm.ID.String()] || (!st.ClearedAt.IsZero() && !dm.CreatedAt.After(st.ClearedAt)) {
			continue
		}
		s.openDirect(dm)
		body := dm.Body
		if strings.TrimSpace(body) == "" && dm.AttachmentIDs != "" && dm.AttachmentIDs != "[]" {
			body = "[a file]"
		}
		newestFirst = append(newestFirst, threadMsg{from: dm.From, body: body, agent: dm.AgentID != ""})
		if len(newestFirst) == brainDepth {
			break
		}
	}
	out := make([]threadMsg, 0, len(newestFirst))
	for i := len(newestFirst) - 1; i >= 0; i-- {
		out = append(out, newestFirst[i])
	}
	return out
}

// brainTurns is the conversation the answer model is given: the latest notes,
// with what was recalled and read for this one put before the newest. The
// fixed part of the prompt (brainBrief) stays the same from one note to the next.
func brainTurns(thread []threadMsg, found string) []map[string]string {
	if len(thread) == 0 {
		return nil
	}
	turns := assistantTurns(thread, nil, false, brainBudget)
	if found = strings.TrimSpace(found); found != "" {
		last := turns[len(turns)-1]
		if last["role"] == "user" {
			last["content"] = found + "\n\n" + last["content"]
		}
	}
	return turns
}

// brainBrief is what the person's Aseman knows of them in every answer: its
// notes about them and the rooms it may read. It changes rarely.
func brainBrief(notes string, rooms []brainRoomView) string {
	var b strings.Builder
	notes = strings.TrimSpace(notes)
	if r := []rune(notes); len(r) > brainNotesChars {
		notes = string(r[len(r)-brainNotesChars:]) // the newest lines
	}
	if notes != "" {
		b.WriteString("<about_them>\nWhat you know of this person (from what they told you):\n" + notes + "\n</about_them>")
	}
	if len(rooms) > 0 {
		names := make([]string, 0, len(rooms))
		for _, r := range rooms {
			names = append(names, r.Name)
		}
		sort.Strings(names)
		if b.Len() > 0 {
			b.WriteString("\n\n")
		}
		b.WriteString("Their rooms you may read: " + strings.Join(names, ", ") + ".")
	}
	return b.String()
}

// brainContext is what was found for one note: the time, what memory recalled
// and, for a note about them, what is going on in their rooms.
func brainContext(now time.Time, recall string, rooms []brainRoomView, withRooms bool) string {
	var b strings.Builder
	b.WriteString("<context>\nNow: " + now.Format("Monday 2 January 2006, 15:04 MST") + "\n")
	if recall = strings.TrimSpace(recall); recall != "" {
		b.WriteString("\nFrom your memory of them:\n" + recall + "\n")
	}
	if withRooms {
		for _, r := range rooms {
			if len(r.Lines) == 0 && r.Notes == "" {
				continue
			}
			b.WriteString("\nRoom \"" + r.Name + "\":\n")
			if r.Notes != "" {
				b.WriteString("Shared notes: " + r.Notes + "\n")
			}
			for _, l := range r.Lines {
				b.WriteString(fmt.Sprintf("[%s] %s: %s\n", l.At.Format("Jan 2 15:04"), l.From, l.Body))
			}
		}
	}
	b.WriteString("</context>")
	return b.String()
}

// markSaved marks a note as kept without an answer. The stored message stays
// sealed: only the mark changes.
func (s *Service) markSaved(ctx context.Context, id identity.ID) {
	var dm message.Direct
	if err := s.R.Get(ctx, "directs", id, &dm); err != nil || !dm.DeletedAt.IsZero() {
		return
	}
	dm.Brain = message.BrainSaved
	dm.UpdatedAt = time.Now().UTC()
	if err := s.R.Update(ctx, "directs", dm.ID, &dm); err != nil && s.L != nil {
		s.L.Warn("brain: mark note saved", "id", id.String(), "error", err)
	}
}

// creditsReply is what Aseman says when the person cannot pay for an answer.
const creditsReply = "You're out of credits, so I couldn't get to this one. Add some and I'll pick it up right where we left off."

// outOfCredits reports whether an error is the person's wallet/budget, or the
// upstream LLM provider refusing the call for lack of credit (e.g. 429
// insufficient_quota from an OpenAI-compatible gateway).
func outOfCredits(err error) bool {
	if err == nil {
		return false
	}
	if errs.CodeOf(err) == errs.CodeFinance || errs.CodeOf(err) == errs.CodeBudgetExhausted {
		return true
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "fund") ||
		strings.Contains(msg, "insufficient_quota") ||
		strings.Contains(msg, "insufficient credit") ||
		strings.Contains(msg, "insufficient_credit") ||
		strings.Contains(msg, "exceeded your current quota")
}

// storeAnswer stores an answer of the assistant's in a conversation, as a
// reply to the message it answers.
func (s *Service) storeAnswer(ctx context.Context, me, peer identity.ID, rec *bot.Bot, noteID, reply, action string) {
	s.storeAnswerMarked(ctx, me, peer, rec, noteID, reply, action, "")
}

// storeAnswerMarked is storeAnswer with a mark for the app (message.Direct.Brain).
func (s *Service) storeAnswerMarked(ctx context.Context, me, peer identity.ID, rec *bot.Bot, noteID, reply, action, mark string) {
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return
	}
	now := time.Now().UTC()
	dm := &message.Direct{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, From: me, To: peer, Body: reply, SentAt: now, ReplyTo: noteID, AgentID: rec.AccountID.String(), Action: action, Brain: mark}
	if err := s.storeDirect(context.WithoutCancel(ctx), dm); err != nil && s.L != nil {
		s.L.Warn("store chat assistant answer", "bot", rec.ID.String(), "error", err)
		return
	}
	ctx = context.WithoutCancel(ctx)
	if peer == me {
		// Personal Aseman chat: keep the whole thread in the self-chat.
		// Mirroring as assistant→person would open a separate Direct that only
		// ever held the assistant's side.
		s.mirrorSavedAnswer(ctx, me, rec.AccountID, reply, id)
		return
	}
	// Person↔person / person↔agent: show the answer in that direct room.
	s.mirrorDirectID(ctx, rec.AccountID, peer, reply, id)
}

// mirrorSavedAnswer posts a brain reply into the person's Aseman chat as the assistant.
func (s *Service) mirrorSavedAnswer(ctx context.Context, person, assistant identity.ID, body string, directID identity.ID) {
	if err := bridge.Invoke(ctx, s.K, "spaces", "PostSavedAnswer", []any{ctx, person, assistant, body, directID}); err != nil && s.L != nil {
		s.L.Debug("mirror saved answer", "person", person.String(), "error", err)
	}
}

// ── voice ────────────────────────────────────────────────────────────────────

// voiceRecallTimeout is how long a spoken note waits for what memory holds.
const voiceRecallTimeout = 350 * time.Millisecond

// voiceBrief tells the answer it is being spoken.
func voiceBrief(voice bool) string {
	if !voice {
		return ""
	}
	return "\n\nThis is a spoken conversation and your answer is read aloud as it is written: answer in one to three short " +
		"sentences in plain spoken words, with no lists, markdown, links or symbols, and give detail only if they ask for it."
}

var (
	voiceAction = regexp.MustCompile(`(?i)\b(create|make|set up|start|open)\b.*\b(room|project|reminder)\b|\b(check|look up|look at|read|open|visit|go to)\b.*\b(website|site|page|link|url)\b|\bremind me\b|\b(research|investigate|build me|write me a (script|program|page|site))\b|\b(send|text|message)\b.+\b(to|saying|that)\b|\binvite\b|\bschedule\b|\bcancel (my|the|that) (reminder|room)\b|\bwhat('s| is) my (balance|credit)`)
	voiceRooms  = regexp.MustCompile(`(?i)\b(room|rooms|project|projects|workspace|team)\b`)
)

// voiceWantsAction is a spoken request to do something: the answer then has its tools (slower, and worth it).
func voiceWantsAction(body string) bool { return voiceAction.MatchString(body) || mentionsSite(body) }

// voiceMentionsRooms is a spoken note about their rooms: they are read for it.
func voiceMentionsRooms(body string) bool { return voiceRooms.MatchString(body) }
