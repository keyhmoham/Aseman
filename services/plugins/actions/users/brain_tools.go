package users

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/openviking"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// What a person's Aseman can do for them. Each tool is the node's own
// actions, run as the person (s.actAs): it can never do what they could not,
// and every rule an action keeps (permissions, privacy, budgets) still holds.
//
//	look things up   at once: rooms, chats, members, agents, apps, balance, people, reminders
//	their own        at once: remember a fact, set or cancel a reminder
//	change something only proposed: create a room, hand work, invite, message,
//	                               post in a room, recruit/hire an agent
//
// A proposal is stored with the answer that makes it (message.Direct.Action,
// sealed) and runs when the person confirms it: the button in the app
// (users.brain_confirm) or a reply of "yes" in their notes, which is how any
// other surface (a phone number, a bot) will confirm too. "No" cancels it. So
// nothing a room or a forwarded message says can make it act on its own.

// brainTool is one thing it can do.
type brainTool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Parameters  map[string]any `json:"parameters"`
	// propose: it changes something, so it only runs once the person says yes.
	propose bool `json:"-"`
	// summary is what the person is asked to confirm.
	summary func(args map[string]any) string                                                           `json:"-"`
	run     func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) `json:"-"`
}

// params is a tool's JSON schema. "required" is left out when nothing is: a nil list would be sent as
// null, which providers refuse (a 400 on every request that carries the tools).
func params(required []string, props map[string]any) map[string]any {
	schema := map[string]any{"type": "object", "properties": props}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}

func str(desc string) map[string]any { return map[string]any{"type": "string", "description": desc} }

func arg(args map[string]any, key string) string {
	v, _ := args[key].(string)
	return strings.TrimSpace(v)
}

// brainTools is everything it can do.
func brainTools() []brainTool {
	return []brainTool{
		{Name: "list_rooms", Description: "The person's rooms (projects): id, name, whether they own it and whether you may read it.",
			Parameters: params(nil, map[string]any{}),
			run: func(ctx context.Context, s *Service, me identity.ID, _ map[string]any) (string, error) {
				rooms, err := s.brainRoomsOf(ctx, me)
				if err != nil {
					return "", err
				}
				choices := s.brainChoices(ctx, me)
				out := make([]map[string]any, 0, len(rooms))
				for _, r := range rooms {
					out = append(out, map[string]any{"id": r.ID, "name": r.Name, "owner": r.Owner, "readable": readable(choices, r)})
				}
				return jsonText(out), nil
			}},
		{Name: "read_webpage", Description: "Read a public web page (a site's home page, its about or team page): its text and the links on that site, " +
			"so you can follow one with another call. Use it whenever they ask about a website or a link, and look at a few pages if one is not enough. " +
			"It cannot run scripts: a page drawn only by scripts comes back nearly empty. It cannot search the web.",
			Parameters: params([]string{"url"}, map[string]any{"url": str("the address, e.g. https://example.com/about")}),
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				fetch := readWebpage
				if s.webFn != nil {
					fetch = s.webFn
				}
				text, err := fetch(ctx, arg(args, "url"))
				if err != nil {
					return "", errs.Wrap(errs.CodeUnavailable, err, "couldn't read it: "+err.Error())
				}
				return text, nil
			}},
		{Name: "show_rooms", Description: "Show rooms to the person as tappable cards under your answer, when they would want to open them " +
			"(\"which rooms have X\", \"open my café room\"). Use sparingly: only the rooms that matter, at most six.",
			Parameters: params([]string{"rooms"}, map[string]any{"rooms": map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "room ids (from list_rooms)"}}),
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				ids, _ := args["rooms"].([]any)
				shown := 0
				for _, v := range ids {
					id, _ := v.(string)
					room, err := s.memberRoom(ctx, me, strings.TrimSpace(id))
					if err != nil {
						continue
					}
					sub := "Shared with you"
					if room.Owner {
						sub = "Your room"
					}
					addCard(ctx, brainCard{Type: cardRoom, ID: room.ID, Title: room.Name, Subtitle: sub})
					shown++
				}
				if shown == 0 {
					return "", errs.InvalidArgument("none of those are the person's rooms: use list_rooms")
				}
				return fmt.Sprintf("showing %d room card(s) under your answer", shown), nil
			}},
		{Name: "show_chart", Description: "Show a small bar chart under your answer, only when numbers you have are clearer as a chart than as words " +
			"(a comparison of a few things). Use real numbers from other tools or the conversation, never invented ones.",
			Parameters: params([]string{"title", "points"}, map[string]any{
				"title":  str("what the chart shows"),
				"unit":   str("the unit of the numbers, e.g. credits"),
				"points": map[string]any{"type": "array", "description": "two to twelve bars", "items": map[string]any{"type": "object", "properties": map[string]any{"label": str("the bar's name"), "value": map[string]any{"type": "number"}}, "required": []string{"label", "value"}}},
			}),
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				points, _ := args["points"].([]any)
				card, err := chartCard(arg(args, "title"), arg(args, "unit"), points)
				if err != nil {
					return "", err
				}
				addCard(ctx, card)
				return "showing the chart under your answer", nil
			}},
		{Name: "room_activity", Description: "The latest messages of one of the person's rooms. Only rooms they let you read.",
			Parameters: params([]string{"room"}, map[string]any{"room": str("the room id (from list_rooms)")}),
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				room, err := s.memberRoom(ctx, me, arg(args, "room"))
				if err != nil {
					return "", err
				}
				if !readable(s.brainChoices(ctx, me), room) {
					return "", errs.Permission("the person has not let you read " + room.Name + ": they can allow it on the Aseman page")
				}
				return jsonText(s.brainLinesOf(ctx, me, room.ID)), nil
			}},
		{Name: "wallet_balance", Description: "The person's credit balance (1 credit = 1 US cent).",
			Parameters: params(nil, map[string]any{}),
			run: func(ctx context.Context, s *Service, me identity.ID, _ map[string]any) (string, error) {
				raw, err := s.actAs(ctx, me, "finance", "wallet_get", map[string]any{})
				if err != nil {
					return "", err
				}
				var w struct {
					Available int64 `json:"available"`
				}
				_ = json.Unmarshal(raw, &w)
				return fmt.Sprintf("%.2f credits available", float64(w.Available)/10_000), nil
			}},
		{Name: "find_people", Description: "Find people on Aseman by name, handle or email: their id and handle.",
			Parameters: params([]string{"query"}, map[string]any{"query": str("a name, @handle or email")}),
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				raw, err := s.actAs(ctx, me, "users", "search", map[string]any{"query": strings.TrimPrefix(arg(args, "query"), "@"), "limit": 5})
				if err != nil {
					return "", err
				}
				return clip(string(raw), 3000), nil
			}},
		{Name: "remember", Description: "Keep a lasting fact, preference or instruction about the person in what you know of them. Never passwords or codes.",
			Parameters: params([]string{"fact"}, map[string]any{"fact": str("one self-contained fact")}),
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				line := rememberLine(arg(args, "fact"), time.Now().UTC())
				if line == "" {
					return "", errs.InvalidArgument("that is not something to keep in every answer")
				}
				ov := s.brainMemory()
				if ov == nil {
					return "", errs.New(errs.CodeUnavailable, "this node keeps no memory")
				}
				if err := ov.Append(ctx, openviking.PersonAccount(me.String()), openviking.BrainUser, openviking.BrainNotes, line); err != nil {
					return "", err
				}
				forgetCachedNotes(me)
				return "remembered", nil
			}},
		{Name: "remind_me", Description: "Remind the person of something at a time: you write it in their notes and their phone is notified. " +
			"`at` is ISO 8601 with its offset; if you do not know their time zone and the time is local to them, ask first.",
			Parameters: params([]string{"at", "text"}, map[string]any{"at": str("when, e.g. 2026-11-02T09:00:00+00:00"), "text": str("what to remind them of")}),
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				at, err := time.Parse(time.RFC3339, arg(args, "at"))
				if err != nil {
					return "", errs.InvalidArgument("`at` must be ISO 8601 with an offset")
				}
				r, err := s.addReminder(ctx, me, at, arg(args, "text"))
				if err != nil {
					return "", err
				}
				return "reminder " + r.ID + " set for " + r.DueAt.Format(time.RFC3339), nil
			}},
		{Name: "list_reminders", Description: "The person's reminders still to come.",
			Parameters: params(nil, map[string]any{}),
			run: func(ctx context.Context, s *Service, me identity.ID, _ map[string]any) (string, error) {
				rs, err := s.reminders(ctx, me)
				if err != nil {
					return "", err
				}
				out := make([]map[string]any, 0, len(rs))
				for _, r := range rs {
					out = append(out, map[string]any{"id": r.ID, "at": r.DueAt.Format(time.RFC3339), "text": r.Text})
				}
				return jsonText(out), nil
			}},
		{Name: "cancel_reminder", Description: "Cancel one of the person's reminders.",
			Parameters: params([]string{"id"}, map[string]any{"id": str("the reminder id (from list_reminders)")}),
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				return "cancelled", s.cancelReminder(ctx, me, arg(args, "id"))
			}},
		{Name: "create_room", Description: "Create a new room (project) for the person. Proposed: they confirm it.",
			Parameters: params([]string{"name"}, map[string]any{"name": str("the room's name"), "description": str("what it is for")}),
			propose:    true,
			summary:    func(a map[string]any) string { return "Create the room “" + arg(a, "name") + "”" },
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				name := arg(args, "name")
				if name == "" {
					return "", errs.InvalidArgument("a room needs a name")
				}
				raw, err := s.actAs(ctx, me, "spaces", "space_create", map[string]any{"name": name, "description": arg(args, "description")})
				if err != nil {
					return "", err
				}
				// space_create answers {space_id, name, …}: the person is told the room is made (no id to read out).
				var sp struct {
					ID   string `json:"space_id"`
					Name string `json:"name"`
				}
				_ = json.Unmarshal(raw, &sp)
				if sp.Name != "" {
					name = sp.Name
				}
				if sp.ID != "" {
					addCard(ctx, brainCard{Type: cardRoom, ID: sp.ID, Title: name, Subtitle: "Room created"})
				}
				return "created the room “" + name + "”", nil
			}},
		{Name: "ask_room", Description: "Hand work to one of the person's rooms: its lead agent and team do it there, with their tools and computer, " +
			"and the results stay in the room. Proposed: they confirm it.",
			Parameters: params([]string{"room", "request"}, map[string]any{"room": str("the room id (from list_rooms)"), "request": str("what to do, written as the person would ask")}),
			propose:    true,
			summary:    nil, // set below: it names the room
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				room, err := s.memberRoom(ctx, me, arg(args, "room"))
				if err != nil {
					return "", err
				}
				id, _ := identity.Parse(room.ID)
				var thread string
				if err := bridge.Invoke(ctx, s.K, "spaces", "BrainAsk", []any{ctx, me, id, arg(args, "request")}, &thread); err != nil {
					return "", err
				}
				addCard(ctx, brainCard{Type: cardRoom, ID: room.ID, Title: room.Name, Subtitle: "Handed to its team"})
				return "handed to " + room.Name + "'s team: the work happens in the room", nil
			}},
		{Name: "work_on_it", Description: "Do work that needs a computer, in the person's own workspace (their Home), where a team of agents has one: " +
			"research across many sites, running code, analysing files, building a page, a script or a document. It takes minutes: you do not wait, " +
			"and when it is finished you tell them what came of it. Proposed: they confirm it once. Not for a quick question, " +
			"one web page (read_webpage) or what you can answer yourself. Write the request as a full brief: what they want, any addresses, the form the result should take.",
			Parameters: params([]string{"request"}, map[string]any{"request": str("the whole task, written so a team that has not seen this chat can do it")}),
			propose:    true,
			summary: func(a map[string]any) string {
				return "Work on this in your workspace: “" + clip(arg(a, "request"), 240) + "”"
			},
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				request := arg(args, "request")
				if request == "" {
					return "", errs.InvalidArgument("say what the work is")
				}
				start, err := s.startWork(ctx, me, request)
				if err != nil {
					return "", err
				}
				if err := s.addJob(ctx, me, start, request, noteOf(ctx)); err != nil {
					return "", err
				}
				addCard(ctx, brainCard{Type: cardRoom, ID: start.SpaceID, Title: start.Name, Subtitle: "Working on it: I'll tell you here when it's done"})
				return "started in your workspace; you will be told here when it is finished", nil
			}},
		{Name: "list_chats", Description: "The person's conversations in the messenger: Aseman (personal chat), direct chats and project rooms " +
			"(id, title, whether it is the personal Aseman chat or a direct chat).",
			Parameters: params(nil, map[string]any{"kind": str("optional: direct, room, or empty for both")}),
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				body := map[string]any{}
				if kind := arg(args, "kind"); kind != "" {
					body["kind"] = kind
				}
				raw, err := s.actAs(ctx, me, "spaces", "chat_list", body)
				if err != nil {
					return "", err
				}
				return clip(string(raw), 6000), nil
			}},
		{Name: "list_participants", Description: "People and bots in one of the person's rooms (participants): id, name/handle, role, kind.",
			Parameters: params([]string{"room"}, map[string]any{
				"room": str("the room id (from list_rooms)"),
				"kind": str("optional: user (people only) or bot (agents and apps only)"),
			}),
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				room, err := s.memberRoom(ctx, me, arg(args, "room"))
				if err != nil {
					return "", err
				}
				body := map[string]any{"space": room.ID}
				if kind := arg(args, "kind"); kind != "" {
					body["kind"] = kind
				}
				raw, err := s.actAs(ctx, me, "spaces", "members_list", body)
				if err != nil {
					return "", err
				}
				return clip(string(raw), 6000), nil
			}},
		{Name: "list_agents", Description: "Agents (and optionally apps) installed in one of the person's rooms.",
			Parameters: params([]string{"room"}, map[string]any{"room": str("the room id (from list_rooms)")}),
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				room, err := s.memberRoom(ctx, me, arg(args, "room"))
				if err != nil {
					return "", err
				}
				raw, err := s.actAs(ctx, me, "spaces", "bots_list", map[string]any{"space": room.ID})
				if err != nil {
					return "", err
				}
				return clip(string(raw), 6000), nil
			}},
		{Name: "list_apps", Description: "Apps and agents available in the marketplace catalog (to browse or hire into a room). " +
			"Each item's listing.id is what hire_agent needs.",
			Parameters: params(nil, map[string]any{"query": str("optional name or category filter")}),
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				raw, err := s.actAs(ctx, me, "market", "catalog", map[string]any{})
				if err != nil {
					return "", err
				}
				q := strings.ToLower(arg(args, "query"))
				if q == "" {
					return clip(string(raw), 6000), nil
				}
				var catalog struct {
					Items []map[string]any `json:"items"`
				}
				if json.Unmarshal(raw, &catalog) != nil {
					return clip(string(raw), 6000), nil
				}
				kept := make([]map[string]any, 0, len(catalog.Items))
				for _, item := range catalog.Items {
					blob, _ := json.Marshal(item)
					if strings.Contains(strings.ToLower(string(blob)), q) {
						kept = append(kept, item)
					}
				}
				return jsonText(map[string]any{"items": kept}), nil
			}},
		{Name: "invite_to_room", Description: "Invite someone to one of the person's rooms. Proposed: they confirm it.",
			Parameters: params([]string{"room", "person"}, map[string]any{"room": str("the room id"), "person": str("the person's id (from find_people)")}),
			propose:    true,
			summary: func(a map[string]any) string {
				return "Invite " + arg(a, "person_label") + " to " + arg(a, "room_label")
			},
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				room, err := s.memberRoom(ctx, me, arg(args, "room"))
				if err != nil {
					return "", err
				}
				if _, err := s.actAs(ctx, me, "spaces", "invite", map[string]any{"space": room.ID, "invitee": arg(args, "person")}); err != nil {
					return "", err
				}
				addCard(ctx, brainCard{Type: cardRoom, ID: room.ID, Title: room.Name, Subtitle: "Invitation sent"})
				return "invited them to " + room.Name, nil
			}},
		{Name: "message_person", Description: "Send someone a message from the person, as a personal chat. Proposed: they confirm it.",
			Parameters: params([]string{"person", "text"}, map[string]any{"person": str("the person's id (from find_people)"), "text": str("the message, written as the person would")}),
			propose:    true,
			summary: func(a map[string]any) string {
				return "Send " + arg(a, "person_label") + ": “" + clip(arg(a, "text"), 200) + "”"
			},
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				to := arg(args, "person")
				if to == me.String() {
					return "", errs.InvalidArgument("that is the person themselves")
				}
				if _, err := s.actAs(ctx, me, "users", "dm_send", map[string]any{"to": to, "body": arg(args, "text")}); err != nil {
					return "", err
				}
				return "sent", nil
			}},
		{Name: "message_room", Description: "Post a message into one of the person's rooms as them. Proposed: they confirm it.",
			Parameters: params([]string{"room", "text"}, map[string]any{"room": str("the room id (from list_rooms)"), "text": str("what to post, written as the person would")}),
			propose:    true,
			summary: func(a map[string]any) string {
				return "Post in " + arg(a, "room_label") + ": “" + clip(arg(a, "text"), 200) + "”"
			},
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				room, err := s.memberRoom(ctx, me, arg(args, "room"))
				if err != nil {
					return "", err
				}
				roomID, err := s.generalRoomID(ctx, me, room.ID)
				if err != nil {
					return "", err
				}
				if _, err := s.actAs(ctx, me, "spaces", "message_send", map[string]any{
					"space": room.ID, "room": roomID, "body": arg(args, "text"),
				}); err != nil {
					return "", err
				}
				addCard(ctx, brainCard{Type: cardRoom, ID: room.ID, Title: room.Name, Subtitle: "Message posted"})
				return "posted in " + room.Name, nil
			}},
		{Name: "recruit_agent", Description: "Create a specialist agent and add it to one of the person's rooms. Proposed: they confirm it.",
			Parameters: params([]string{"room", "name", "instructions"}, map[string]any{
				"room":         str("the room id (from list_rooms)"),
				"name":         str("short name for the agent"),
				"description":  str("what it does"),
				"instructions": str("standing instructions for the agent"),
			}),
			propose: true,
			summary: func(a map[string]any) string {
				return "Recruit agent “" + arg(a, "name") + "” into " + arg(a, "room_label")
			},
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				room, err := s.memberRoom(ctx, me, arg(args, "room"))
				if err != nil {
					return "", err
				}
				name, instructions := arg(args, "name"), arg(args, "instructions")
				if name == "" || instructions == "" {
					return "", errs.InvalidArgument("a recruit needs a name and instructions")
				}
				desc := arg(args, "description")
				if desc == "" {
					desc = instructions
				}
				raw, err := s.actAs(ctx, me, "spaces", "agent_recruit", map[string]any{
					"space": room.ID, "name": name, "description": desc, "instructions": instructions,
				})
				if err != nil {
					return "", err
				}
				addCard(ctx, brainCard{Type: cardRoom, ID: room.ID, Title: room.Name, Subtitle: "Agent recruited"})
				return "recruited into " + room.Name + ": " + clip(string(raw), 500), nil
			}},
		{Name: "hire_agent", Description: "Hire an agent from the marketplace into one of the person's rooms. Proposed: they confirm it. Use list_apps first for a listing id.",
			Parameters: params([]string{"room", "listing"}, map[string]any{
				"room":    str("the room id (from list_rooms)"),
				"listing": str("the marketplace listing id (from list_apps)"),
			}),
			propose: true,
			summary: func(a map[string]any) string {
				return "Hire marketplace agent into " + arg(a, "room_label")
			},
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				room, err := s.memberRoom(ctx, me, arg(args, "room"))
				if err != nil {
					return "", err
				}
				raw, err := s.actAs(ctx, me, "spaces", "agent_hire", map[string]any{
					"space": room.ID, "listing": arg(args, "listing"),
				})
				if err != nil {
					return "", err
				}
				addCard(ctx, brainCard{Type: cardRoom, ID: room.ID, Title: room.Name, Subtitle: "Agent hired"})
				return "hired into " + room.Name + ": " + clip(string(raw), 500), nil
			}},
		{Name: "call_action", Description: "Call any other platform action as the person (spaces, users, posts, market, bots, " +
			"routines, finance, …): namespace + action + JSON body. Use when no named tool fits — explore, threads, " +
			"participants, apps, posts, files, chats. It runs with their permissions. Never admin or provider-key actions.",
			Parameters: params([]string{"namespace", "action"}, map[string]any{
				"namespace": str("e.g. spaces, users, posts, market, bots, finance"),
				"action":    str("e.g. thread_list, space_search, post_feed, follow, install"),
				"body":      map[string]any{"type": "object", "description": "action body fields"},
			}),
			run: func(ctx context.Context, s *Service, me identity.ID, args map[string]any) (string, error) {
				ns, action := arg(args, "namespace"), arg(args, "action")
				if ns == "" || action == "" {
					return "", errs.InvalidArgument("namespace and action are required")
				}
				if deniedBrainAction(ns, action) {
					return "", errs.Permission(ns + "." + action + " is not available to the assistant")
				}
				body, _ := args["body"].(map[string]any)
				if body == nil {
					body = map[string]any{}
				}
				raw, err := s.actAs(ctx, me, ns, action, body)
				if err != nil {
					return "", err
				}
				return clip(string(raw), 6000), nil
			}},
	}
}

// deniedBrainAction refuses node-admin / identity / provider-key surfaces from call_action.
func deniedBrainAction(namespace, action string) bool {
	ns := strings.ToLower(strings.TrimSpace(namespace))
	name := ns + "." + strings.TrimSpace(action)
	switch ns {
	case "admin", "plugins", "usage":
		return true
	}
	switch name {
	case "spaces.agent_engine_get", "spaces.agent_engine_set", "spaces.space_list_all",
		"spaces.admin_files", "spaces.admin_work_log", "spaces.admin_terminate_sandbox",
		"spaces.admin_sandboxes", "spaces.admin_storage",
		"llm.llm_provider_set", "llm.llm_provider_delete", "llm.llm_import_vercel", "llm.llm_providers_list",
		"users.accounts_list", "users.account_update", "users.account_password",
		"users.account_delete", "users.account_create",
		"auth.login", "auth.register", "auth.logout",
		"market.approve", "market.deny", "market.stats":
		return true
	}
	return false
}

func findBrainTool(name string) *brainTool {
	for _, t := range brainTools() {
		if t.Name == name {
			return &t
		}
	}
	return nil
}

// plainError is an error as the person is told it: its message, without its cause.
func plainError(err error) string {
	var e *errs.Error
	if errors.As(err, &e) && e.Message != "" {
		return e.Message
	}
	return err.Error()
}

func jsonText(v any) string {
	raw, _ := json.Marshal(v)
	return clip(string(raw), 6000)
}

func clip(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "…"
	}
	return s
}

// memberRoom is one of the person's rooms, by id.
func (s *Service) memberRoom(ctx context.Context, me identity.ID, id string) (brainRoom, error) {
	rooms, err := s.brainRoomsOf(ctx, me)
	if err != nil {
		return brainRoom{}, err
	}
	for _, r := range rooms {
		if r.ID == id || strings.EqualFold(r.Name, id) {
			return r, nil
		}
	}
	return brainRoom{}, errs.NotFound("no room " + id + " among the person's rooms: use list_rooms")
}

// generalRoomID is the first (general) room of a project space, for message_send.
func (s *Service) generalRoomID(ctx context.Context, me identity.ID, spaceID string) (string, error) {
	raw, err := s.actAs(ctx, me, "spaces", "space_detail", map[string]any{"space": spaceID})
	if err != nil {
		return "", err
	}
	var out struct {
		Rooms []struct {
			ID string `json:"id"`
		} `json:"rooms"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || len(out.Rooms) == 0 || out.Rooms[0].ID == "" {
		return "", errs.NotFound("that room has no chat to post in")
	}
	return out.Rooms[0].ID, nil
}

// actAs runs one of the node's actions as the person.
func (s *Service) actAs(ctx context.Context, me identity.ID, namespace, action string, body any) (json.RawMessage, error) {
	if s.dispatchFn != nil {
		return s.dispatchFn(ctx, me, namespace, action, body)
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	resp, err := s.K.Actions().Dispatch(ctx, namespace, action, &api.ActionRequest{Caller: api.Caller{ID: me, Kind: "user"}, Body: raw})
	if err != nil {
		return nil, err
	}
	return resp.Body, nil
}

// ── proposals ───────────────────────────────────────────────────────────────

const (
	proposalPending   = "pending"
	proposalDone      = "done"
	proposalShown     = "shown" // no steps: only cards under the answer
	proposalFailed    = "failed"
	proposalCancelled = "cancelled"
)

// proposalFresh is how long a proposal waits for a yes.
const proposalFresh = 24 * time.Hour

// brainStep is one proposed action.
type brainStep struct {
	Tool    string         `json:"tool"`
	Args    map[string]any `json:"args"`
	Summary string         `json:"summary"`
}

// brainProposal is what an answer proposed, and what became of it.
type brainProposal struct {
	Steps  []brainStep `json:"steps"`
	Status string      `json:"status"`
	Result string      `json:"result,omitempty"`
	// Cards are shown under the answer (brain_cards.go): what a confirmed step made, or what a tool showed.
	Cards []brainCard `json:"cards,omitempty"`
}

// proposalView is a proposal as the app shows it.
func proposalView(raw string) map[string]any {
	var p brainProposal
	if raw == "" || json.Unmarshal([]byte(raw), &p) != nil || (len(p.Steps) == 0 && len(p.Cards) == 0) {
		return nil
	}
	steps := make([]string, len(p.Steps))
	for i, st := range p.Steps {
		steps[i] = st.Summary
	}
	v := map[string]any{"steps": steps, "status": p.Status}
	if p.Result != "" {
		v["result"] = p.Result
	}
	if len(p.Cards) > 0 {
		v["cards"] = p.Cards
	}
	return v
}

// brainRun runs a tool the model called, during an answer: at once, or (for one
// that changes something) by adding it to what the answer proposes.
func (s *Service) brainRun(ctx context.Context, me identity.ID, proposed *[]brainStep, labels map[string]string) func(name, args string) string {
	var mu sync.Mutex
	return func(name, raw string) string {
		t := findBrainTool(name)
		if t == nil {
			return "error: no tool " + name
		}
		args := map[string]any{}
		if strings.TrimSpace(raw) != "" && json.Unmarshal([]byte(raw), &args) != nil {
			return "error: the arguments are not JSON"
		}
		if t.propose {
			mu.Lock()
			defer mu.Unlock()
			if len(*proposed) >= 5 {
				return "error: propose at most five things at once"
			}
			args["room_label"], args["person_label"] = s.label(ctx, me, arg(args, "room"), labels), s.label(ctx, me, arg(args, "person"), labels)
			summary := ""
			if t.summary != nil {
				summary = t.summary(args)
			} else {
				summary = "Ask " + arg(args, "room_label") + " to: " + clip(arg(args, "request"), 200)
			}
			*proposed = append(*proposed, brainStep{Tool: name, Args: args, Summary: summary})
			return "proposed, not done: " + summary + ". It runs once the person confirms (a button under your answer, or a reply of yes)."
		}
		out, err := t.run(ctx, s, me, args)
		if err != nil {
			return "error: " + err.Error()
		}
		return out
	}
}

// label names a room or a person for a proposal ("" stays "").
func (s *Service) label(ctx context.Context, me identity.ID, id string, cache map[string]string) string {
	if id == "" {
		return ""
	}
	if l, ok := cache[id]; ok {
		return l
	}
	l := id
	if r, err := s.memberRoom(ctx, me, id); err == nil {
		l = "“" + r.Name + "”"
	} else if pid, err := identity.Parse(id); err == nil {
		if ref := s.publicRef(ctx, me, pid); ref != nil {
			if h, _ := ref["handle"].(string); h != "" {
				l = "@" + h
			}
		}
	}
	cache[id] = l
	return l
}

// encodeProposal is what an answer stores of its proposals ("" when none).
func encodeProposal(steps []brainStep, cards []brainCard) string {
	if len(steps) == 0 && len(cards) == 0 {
		return ""
	}
	p := brainProposal{Steps: steps, Status: proposalPending, Cards: cards}
	if len(steps) == 0 {
		p.Status = proposalShown
	}
	raw, _ := json.Marshal(p)
	return string(raw)
}

// pendingProposal is the newest answer in the person's notes still waiting for
// a yes, if any.
func (s *Service) pendingProposal(ctx context.Context, me identity.ID) (*message.Direct, *brainProposal) {
	var rows []message.Direct
	if err := s.R.List(ctx, "directs", database.Filter{
		Equal:   map[string]any{"from_id": me.String(), "to_id": me.String()},
		OrderBy: "created_at", Asc: false, Limit: 6,
	}, &rows); err != nil {
		return nil, nil
	}
	for i := range rows {
		dm := &rows[i]
		if dm.AgentID == "" || !dm.DeletedAt.IsZero() {
			continue // the person's own notes (the yes itself among them)
		}
		// Only Aseman's latest answer can be answered with a word.
		if dm.Action == "" || time.Since(dm.CreatedAt) > proposalFresh {
			return nil, nil
		}
		s.openDirect(dm)
		var p brainProposal
		if json.Unmarshal([]byte(dm.Action), &p) == nil && p.Status == proposalPending {
			return dm, &p
		}
		return nil, nil
	}
	return nil, nil
}

var (
	sayYes = regexp.MustCompile(`(?i)^\s*(yes|yep|yeah|y|ok|okay|sure|confirm(ed)?|do it|go ahead|go|please do|بله|آره|باشه|انجام بده)\s*[.!]*\s*$`)
	sayNo  = regexp.MustCompile(`(?i)^\s*(no|nope|n|cancel|don'?t|stop|نه|لغو|نکن)\s*[.!]*\s*$`)
)

// resolve carries out (or cancels) a proposal and says what came of it.
func (s *Service) resolve(ctx context.Context, me identity.ID, dm *message.Direct, p *brainProposal, approve bool) (string, error) {
	if !approve {
		p.Status, p.Result = proposalCancelled, "Cancelled."
	} else {
		var done, failed []string
		box := &cardBox{}
		ctx = withNote(withCards(ctx, box), dm.ReplyTo)
		for _, st := range p.Steps {
			t := findBrainTool(st.Tool)
			if t == nil {
				failed = append(failed, st.Summary+": no longer possible")
				continue
			}
			if out, err := t.run(ctx, s, me, st.Args); err != nil {
				failed = append(failed, st.Summary+": "+plainError(err))
			} else {
				done = append(done, st.Summary+" — "+out)
			}
		}
		var b strings.Builder
		for _, d := range done {
			b.WriteString("✓ " + d + "\n")
		}
		for _, f := range failed {
			b.WriteString("✗ " + f + "\n")
		}
		p.Status, p.Result = proposalDone, strings.TrimSpace(b.String())
		p.Cards = append(p.Cards, box.list()...)
		if len(done) == 0 {
			p.Status = proposalFailed
		}
	}
	if err := s.setProposal(ctx, dm.ID, p); err != nil {
		return "", err
	}
	return p.Result, nil
}

// setProposal stores what became of a proposal. Only the sealed action changes.
func (s *Service) setProposal(ctx context.Context, id identity.ID, p *brainProposal) error {
	var dm message.Direct
	if err := s.R.Get(ctx, "directs", id, &dm); err != nil {
		return err
	}
	raw, _ := json.Marshal(p)
	sealed, err := s.sealAction(id, string(raw))
	if err != nil {
		return err
	}
	dm.Action, dm.UpdatedAt = sealed, time.Now().UTC()
	return s.R.Update(ctx, "directs", dm.ID, &dm)
}

// brainConfirmAction users.brain_confirm: yes or no to what your Aseman proposed.
func brainConfirmAction(s *Service) api.Action {
	return helper.Action{Namespace: "users", Name: "brain_confirm", Summary: "Confirm (or cancel) what your Aseman proposed to do",
		Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireUser(req); err != nil {
				return nil, err
			}
			var in struct {
				Message string `json:"message"`
				Approve bool   `json:"approve"`
			}
			if err := helper.Decode(req, &in); err != nil {
				return nil, err
			}
			me := req.Caller.ID
			id, err := identity.Parse(in.Message)
			if err != nil {
				return nil, errs.InvalidArgument("message required")
			}
			dm, err := s.getDirect(ctx, id)
			if err != nil || dm.From != me || dm.To != me || dm.AgentID == "" || dm.Action == "" {
				return nil, errs.NotFound("proposal")
			}
			var p brainProposal
			if json.Unmarshal([]byte(dm.Action), &p) != nil || p.Status != proposalPending {
				return nil, errs.Conflict("that was already answered")
			}
			if time.Since(dm.CreatedAt) > proposalFresh {
				return nil, errs.Conflict("that proposal is too old: ask again")
			}
			steps := make([]string, len(p.Steps))
			for i, st := range p.Steps {
				steps[i] = st.Summary
			}
			started := time.Now()
			result, err := s.resolve(helper.WithActor(ctx, me), me, dm, &p, in.Approve)
			// The admin's AI log shows the button too (a reply of yes is logged where it is read).
			confirmed := aiEntry{person: me, kind: aiKindAseman, plan: "confirm", prompt: map[bool]string{true: "Confirmed: ", false: "Cancelled: "}[in.Approve] + strings.Join(steps, "; "),
				answer: result, status: aiAction, started: started, err: err}
			if err != nil || p.Status == proposalFailed {
				confirmed.status = aiError
			}
			s.logAI(context.WithoutCancel(ctx), confirmed)
			if err != nil {
				return nil, err
			}
			return helper.JSON(map[string]any{"ok": true, "status": p.Status, "result": result})
		}}
}

// ── reminders ───────────────────────────────────────────────────────────────

// brainReminder is one reminder (brain_reminders).
type brainReminder struct {
	ID        string    `db:"id" json:"id"`
	Person    string    `db:"person" json:"person"`
	DueAt     time.Time `db:"due_at" json:"due_at"`
	Text      string    `db:"text" json:"-"` // sealed
	Status    string    `db:"status" json:"status"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}

const (
	reminderWaiting = "waiting"
	reminderSent    = "sent"
	reminderEvery   = 20 * time.Second
	maxReminders    = 100
)

func reminderContext(id string) string { return "users/brain-reminder/v1/" + id }

func (s *Service) addReminder(ctx context.Context, me identity.ID, at time.Time, text string) (*brainReminder, error) {
	if text == "" {
		return nil, errs.InvalidArgument("a reminder needs a text")
	}
	if at.Before(time.Now().Add(-time.Minute)) || at.After(time.Now().AddDate(2, 0, 0)) {
		return nil, errs.InvalidArgument("a reminder is for a time to come, within two years")
	}
	if rs, _ := s.reminders(ctx, me); len(rs) >= maxReminders {
		return nil, errs.InvalidArgument("too many reminders waiting: cancel some first")
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	sealed, err := crypto.SealSecret(clip(text, 1000), s.K.Env()["node_private_key"], reminderContext(id.String()))
	if err != nil {
		return nil, errs.New(errs.CodeUnavailable, "reminders are unavailable on this node")
	}
	r := &brainReminder{ID: id.String(), Person: me.String(), DueAt: at.UTC(), Text: sealed, Status: reminderWaiting, CreatedAt: time.Now().UTC()}
	if err := s.R.DB.Create(ctx, "brain_reminders", r.ID, r); err != nil {
		return nil, err
	}
	r.Text = text
	return r, nil
}

func (s *Service) openReminder(r *brainReminder) {
	if plain, err := crypto.OpenSecret(r.Text, s.K.Env()["node_private_key"], reminderContext(r.ID)); err == nil {
		r.Text = plain
	} else {
		r.Text = ""
	}
}

// reminders are the person's reminders still to come, soonest first.
func (s *Service) reminders(ctx context.Context, me identity.ID) ([]brainReminder, error) {
	var rows []brainReminder
	if err := s.R.List(ctx, "brain_reminders", database.Filter{
		Equal: map[string]any{"person": me.String(), "status": reminderWaiting}, OrderBy: "due_at", Asc: true,
	}, &rows); err != nil {
		return nil, err
	}
	for i := range rows {
		s.openReminder(&rows[i])
	}
	return rows, nil
}

func (s *Service) cancelReminder(ctx context.Context, me identity.ID, id string) error {
	var r brainReminder
	if err := s.R.GetString(ctx, "brain_reminders", id, &r); err != nil || r.Person != me.String() {
		return errs.NotFound("reminder")
	}
	return s.R.DB.Delete(ctx, "brain_reminders", id)
}

// deliverReminders writes every reminder that is due into its person's notes,
// as their Aseman, and tells their phone.
func (s *Service) deliverReminders(ctx context.Context, now time.Time) {
	var due []brainReminder
	if err := s.R.List(ctx, "brain_reminders", database.Filter{
		Equal: map[string]any{"status": reminderWaiting}, LessThan: map[string]any{"due_at": now}, OrderBy: "due_at", Asc: true, Limit: 200,
	}, &due); err != nil {
		return
	}
	rec, err := s.assistant(ctx)
	if err != nil {
		return
	}
	for i := range due {
		r := due[i]
		r.Status = reminderSent
		if err := s.R.DB.Update(ctx, "brain_reminders", r.ID, &r); err != nil {
			continue // another node took it, or the database is away: next round
		}
		s.openReminder(&r)
		person, err := identity.Parse(r.Person)
		if err != nil || r.Text == "" {
			continue
		}
		id, err := identity.New(s.K.NodeID())
		if err != nil {
			continue
		}
		body := "⏰ " + r.Text
		dm := &message.Direct{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, From: person, To: person, Body: body, SentAt: now, AgentID: rec.AccountID.String()}
		if err := s.storeDirect(ctx, dm); err != nil {
			s.warn("brain: reminder", person, err)
			continue
		}
		s.logAI(context.WithoutCancel(ctx), aiEntry{person: person, kind: aiKindAseman, plan: "reminder", prompt: r.Text, answer: body, status: aiOK})
		s.Push(ctx, []identity.ID{person}, PushNote{Title: "Aseman", Body: clip(r.Text, 140), Kind: "dm", Peer: person.String(), Collapse: "reminder:" + r.ID})
	}
}

var remindersOnce sync.Once

// startReminders delivers reminders as they fall due, for as long as the node runs.
func (s *Service) startReminders() {
	remindersOnce.Do(func() {
		go func() {
			tick := time.NewTicker(reminderEvery)
			defer tick.Stop()
			for now := range tick.C {
				s.deliverReminders(context.Background(), now.UTC())
			}
		}()
	})
}

// ── out of credits ──────────────────────────────────────────────────────────

// brainRetryAction users.brain_retry: after adding credits, the note an
// out-of-credits answer stands for is taken up again. The answer goes (it has
// done its job); if the wallet still cannot pay, nothing changes and the person is told.
func brainRetryAction(s *Service) api.Action {
	return helper.Action{Namespace: "users", Name: "brain_retry", Summary: "Have your Aseman take up a note it could not answer for lack of credits",
		Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
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
			id, err := identity.Parse(in.Message)
			if err != nil {
				return nil, errs.InvalidArgument("message required")
			}
			card, err := s.getDirect(ctx, id)
			if err != nil || card.From != me || card.To != me || card.AgentID == "" || card.Brain != message.BrainCredits || !card.DeletedAt.IsZero() {
				return nil, errs.NotFound("message")
			}
			noteID, err := identity.Parse(card.ReplyTo)
			if err != nil {
				return nil, errs.NotFound("the note is no longer there")
			}
			note, err := s.getDirect(ctx, noteID)
			if err != nil || note.From != me || note.To != me || !note.DeletedAt.IsZero() {
				return nil, errs.NotFound("the note is no longer there")
			}
			rec, err := s.assistant(ctx)
			if err != nil {
				return nil, err
			}
			if err := s.canPay(ctx, me, rec); err != nil {
				return nil, err
			}
			s.retire(ctx, card.ID)
			s.startBrain(ctx, me, brainNote{msg: note})
			return helper.JSON(map[string]any{"ok": true})
		}}
}

// canPay checks the person's wallet can pay for an answer now.
func (s *Service) canPay(ctx context.Context, me identity.ID, rec *bot.Bot) error {
	if s.fundsFn != nil {
		return s.fundsFn(ctx, me)
	}
	return bridge.Invoke(ctx, s.K, "bots", "EnsureFunds", []any{ctx, me, rec.ID})
}

// retire takes an answer of Aseman's out of the chat (it has done its job).
func (s *Service) retire(ctx context.Context, id identity.ID) {
	var dm message.Direct
	if err := s.R.Get(ctx, "directs", id, &dm); err != nil {
		return
	}
	now := time.Now().UTC()
	dm.DeletedAt, dm.UpdatedAt = now, now
	if err := s.R.Update(ctx, "directs", dm.ID, &dm); err != nil && s.L != nil {
		s.L.Warn("brain: retire answer", "id", id.String(), "error", err)
	}
}
