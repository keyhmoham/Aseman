package spaces

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"sort"
	"strings"
	"unicode"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// toolDetail renders a human sentence describing what an agent tool call does,
// for the room's live working indicator.
func toolDetail(toolName string) string {
	switch toolName {
	case "sandbox_exec":
		return "running in the sandbox…"
	case "image_generate":
		return "generating an image…"
	case "file_send":
		return "sending a file…"
	case "file_upload":
		return "uploading a file…"
	case "file_read":
		return "reading a file…"
	case "file_edit":
		return "editing a file…"
	case "message_send":
		return "posting a message…"
	case "room_info":
		return "checking the room…"
	case "ask_user":
		return "asking the user…"
	case "routine_create":
		return "scheduling a routine…"
	case "proxy_create":
		return "opening a gateway proxy…"
	case "ui_compose":
		return "composing a widget…"
	case "frontend_show":
		return "opening the result on the desk…"
	case "desk_state", "desk_arrange", "desk_close":
		return "arranging the desk…"
	default:
		return "using tool " + toolName + "…"
	}
}

// SpaceTools lists the tools (miniapps/tools and the shared sandbox) installed
// in a space, with a human description for each. This is what a langchain agent
// sees when it wakes up in a space: every tool becomes a callable function that
// routes back through spaces.ask.
func (s *Service) SpaceTools(ctx context.Context, spaceID, roomID identity.ID) ([]vmm.Tool, error) {
	eq := map[string]any{
		"space_id": spaceID.String(),
		"role":     string(membership.RoleBot),
	}
	if !roomID.IsZero() {
		eq["room_id"] = roomID.String()
	}
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{Equal: eq}, &mems); err != nil {
		return nil, err
	}
	// Database providers need not return memberships in a stable order.
	// Keep discovery and dispatch names deterministic for colliding bot names.
	sort.Slice(mems, func(i, j int) bool { return mems[i].MemberID.String() < mems[j].MemberID.String() })
	var tools []vmm.Tool
	used := map[string]bool{}
	toolBots := map[string]bool{}
	for _, name := range vmm.Names() {
		used[name] = true
	}
	sandboxID, hasSandbox := s.sandboxBotID(ctx, spaceID)
	for i := range mems {
		rec, err := s.botForMember(ctx, mems[i].MemberID)
		if err != nil {
			continue
		}
		if rec.Kind != bot.KindMiniapp && rec.Kind != bot.KindTool {
			continue
		}
		if toolBots[rec.ID.String()] {
			continue
		}
		toolBots[rec.ID.String()] = true
		// The shared sandbox is exposed once, as the dedicated sandbox_exec tool.
		if hasSandbox && rec.ID == sandboxID {
			continue
		}
		name := slugToolName(rec.Name, rec.ID.String(), used)
		tool := vmm.Tool{
			Name:        name,
			Description: s.toolDescription(ctx, rec),
			BotID:       rec.ID.String(),
			Kind:        string(rec.Kind),
		}
		if rec.IsToolBackend() {
			tool.Commands = s.appCommands(ctx, spaceID, rec)
			tool.Frontend = s.toolFrontend(ctx, rec)
			// Every result of a tool is shown in an interface on the desk.
			show := " Show people the results you get from it with frontend_show ({\"tool\": \"" + rec.ID.String() + "\", \"microtool\": <the one you called>, \"args\": <the same arguments>}): it opens them as a card window on the desk, not as text"
			switch tool.Frontend {
			case "generative":
				tool.Description += " It has a generative frontend." + show + ", in that frontend."
			case "static":
				tool.Description += " It has a static frontend (frontend_show without a microtool opens and runs it)." + show + ", in an interface generated for it automatically."
			default:
				tool.Description += " It has no frontend of its own." + show + ", in an interface generated for it automatically."
			}
		}
		tools = append(tools, tool)
	}
	for _, t := range vmm.Builtins() {
		if strings.HasPrefix(t.Name, "routine_") && s.Routines == nil {
			continue
		}
		if t.Name == "sandbox_exec" && hasSandbox {
			t.BotID = sandboxID.String()
		}
		tools = append(tools, t)
	}

	return tools, nil
}

// appCommands lists the functions of a connected app (a remote MCP server) as
// the person the turn acts for may call them. Best effort: an app that cannot
// be reached, or that the person has not connected, is listed without any.
func (s *Service) appCommands(ctx context.Context, spaceID identity.ID, rec *bot.Bot) []vmm.ToolCommand {
	actor := vmm.ExecutionFrom(ctx).ActorID
	if actor == "" {
		actor = helper.Actor(ctx).String()
	}
	var rows []map[string]any
	if err := bridge.Invoke(ctx, s.K, "tools", "CommandsFor", []any{ctx, rec.ID.String(), actor, spaceID.String()}, &rows); err != nil {
		return nil
	}
	out := make([]vmm.ToolCommand, 0, len(rows))
	for _, r := range rows {
		name, _ := r["name"].(string)
		if name == "" {
			continue
		}
		description, _ := r["description"].(string)
		schema, _ := r["schema"].(map[string]any)
		out = append(out, vmm.ToolCommand{Name: name, Description: description, Schema: schema})
	}
	return out
}

// toolFrontend is the mode of a tool's frontend (static, generative or none).
func (s *Service) toolFrontend(ctx context.Context, rec *bot.Bot) string {
	var mode string
	if err := bridge.Invoke(ctx, s.K, "tools", "FrontendMode", []any{ctx, rec.ID.String()}, &mode); err != nil {
		return ""
	}
	return mode
}

// botForMember resolves a membership member id (a bot account or bot record id)
// onto its bot record.
func (s *Service) botForMember(ctx context.Context, memberID identity.ID) (*bot.Bot, error) {
	if rec, err := s.Bots.GetBot(ctx, memberID); err == nil {
		return rec, nil
	}
	var list []bot.Bot
	if err := s.R.List(ctx, "bots", database.Filter{
		Equal: map[string]any{"account_id": memberID.String()},
	}, &list); err == nil && len(list) > 0 {
		return &list[0], nil
	}
	return nil, errs.NotFound("bot for member")
}

// toolDescription derives a tool's description from its metadata (tool/profile)
// or falls back to a standard line.
func (s *Service) toolDescription(ctx context.Context, rec *bot.Bot) string {
	if m, err := s.M.Get(ctx, rec.AccountID); err == nil && m != nil {
		for _, key := range []string{"tool", "profile"} {
			if node, ok := m.Tree[key].(map[string]any); ok {
				if d, ok := node["description"].(string); ok && strings.TrimSpace(d) != "" {
					return d
				}
			}
		}
	}
	switch rec.Kind {
	case bot.KindMiniapp:
		return "Miniapp " + rec.Name + ": run its backend through this tool and return the result."
	case bot.KindTool:
		return "Tool " + rec.Name + ": performs an operation and returns its output."
	default:
		return "Tool " + rec.Name
	}
}

// ToolDispatch executes a tool call made by an agent in a space. The sandbox
// runs shell commands; every other tool routes to its bot through spaces.ask.
// agentName identifies the agent VM making the call (used to attribute file
// messages and uploads to the right bot). Every executed action is recorded
// as an execution event of its run.
func (s *Service) ToolDispatch(ctx context.Context, spaceID, agentName, toolName, argsJSON string) (string, error) {
	if vmm.ExecutionFrom(ctx).NoSandbox {
		switch toolName {
		case "sandbox_exec", "file_send", "file_upload", "file_edit", "proxy_create", "proxy_list", "proxy_get", "proxy_delete":
			return "", errs.Permission("sandbox access is disabled for this request")
		}
	}
	id, err := identity.Parse(spaceID)
	if err != nil {
		return "", errs.InvalidArgument("invalid space id in tool call")
	}
	policy := vmm.ExecutionFrom(ctx)
	if policy.SpaceID != "" && policy.SpaceID != spaceID {
		return "", errs.Permission("execution space mismatch")
	}
	if !helper.InternalAccess(ctx) && policy.ActorID != "" && policy.ActorID != helper.Actor(ctx).String() {
		return "", errs.Permission("execution actor mismatch")
	}
	if !policy.Allows(toolName) {
		return "", errs.Permission("tool capability not granted")
	}
	roomID := identity.ID{}
	if room := vmm.RoomFrom(ctx); room != "" {
		parsed, err := identity.Parse(room)
		if err != nil {
			return "", errs.InvalidArgument("invalid execution room")
		}
		roomID = parsed
	}
	if policy.RoomID != "" && policy.RoomID != roomID.String() {
		return "", errs.Permission("execution room mismatch")
	}
	if err := helper.CheckContextAccess(ctx, s.R, id, roomID, true); err != nil {
		return "", err
	}
	if policy.AgentID != "" {
		agentID, parseErr := identity.Parse(policy.AgentID)
		if parseErr != nil {
			return "", errs.Permission("invalid execution agent")
		}
		record, lookupErr := s.Bots.GetBot(ctx, agentID)
		if lookupErr != nil {
			return "", lookupErr
		}
		if record.Name != agentName {
			return "", errs.Permission("execution agent mismatch")
		}
		if err := helper.CheckSpaceAccess(ctx, s.R, record.AccountID, id, roomID, false); err != nil {
			return "", err
		}
	}
	// Publish the agent's current activity to the room's live status so the
	// chat can show e.g. "running in the sandbox" while a tool executes.
	if h := vmm.StatusFrom(ctx); h != nil {
		h(agentName, toolDetail(toolName))
	}
	input := ""
	if argsJSON != "" {
		var in struct {
			Input string `json:"input"`
		}
		if json.Unmarshal([]byte(argsJSON), &in) == nil {
			input = in.Input
		}
		if input == "" {
			// tolerate {"command": "..."} for the sandbox and raw strings.
			var raw map[string]any
			if json.Unmarshal([]byte(argsJSON), &raw) == nil {
				if c, ok := raw["command"].(string); ok {
					input = c
				}
			} else {
				input = strings.Trim(argsJSON, `"`)
			}
		}
	}
	if err := repo.CheckExecutionLease(ctx, s.R); err != nil {
		return "", err
	}
	event, cached, claimErr := s.beginToolEvent(ctx, vmm.NewExecutionEvent(ctx, agentName, toolName, argsJSON, "", "running"))
	if claimErr != nil {
		return "", claimErr
	}
	if cached {
		return event.Result, nil
	}
	var result string
	var terr error
	switch {
	case toolName == "sandbox_exec":
		if input == "" {
			terr = errs.InvalidArgument("sandbox_exec requires a command")
			break
		}
		result, terr = s.SandboxExec(ctx, id, input)
		if terr == nil {
			terr = sandboxCommandError(result)
		}
	case toolName == "file_read":
		result, terr = s.readFileForAgent(ctx, id, argsJSON)
	case toolName == "file_edit":
		result, terr = s.fileEditTool(ctx, id, argsJSON)
	case toolName == "routine_create" || toolName == "routine_list" || toolName == "routine_get" || toolName == "routine_update" || toolName == "routine_delete":
		// Routines are per-room: resolve the room this request runs in so the
		// tools schedule/list in the actual room, not the zero room.
		rid := identity.ID{}
		if r := vmm.RoomFrom(ctx); r != "" {
			if parsed, perr := identity.Parse(r); perr == nil {
				rid = parsed
			}
		}
		result, terr = s.handleRoutineTool(ctx, id, rid, toolName, argsJSON)
	case toolName == "message_send":
		result, terr = s.messageTool(ctx, id, argsJSON)
	case toolName == "image_generate" || toolName == "file_send" || toolName == "file_upload":
		// Delivery of requested software and documents is distinct from image
		// generation. Neither intent bypasses membership or capability checks.
		allowed := vmm.ArtifactIntent(ctx)
		if toolName == "image_generate" {
			allowed = vmm.MediaIntent(ctx)
		}
		if !allowed {
			terr = errs.New(errs.CodePermission,
				toolName+" requires user intent for this output. Ask the user about the missing authorization with ask_user; do not retry or bypass this denial.")
			break
		}
		if toolName == "image_generate" {
			result, terr = s.imageGenerateTool(ctx, id, agentName, argsJSON)
		} else {
			result, terr = s.fileSendTool(ctx, id, agentName, toolName, argsJSON)
		}
	case toolName == "room_info":
		result, terr = s.roomInfoTool(ctx, id, argsJSON)
	case toolName == "ask_user":
		result, terr = s.askUserTool(ctx, id, argsJSON)
	case toolName == "proxy_list" || toolName == "proxy_get" || toolName == "proxy_delete":
		result, terr = s.proxyManageTool(ctx, id, toolName, argsJSON)
	case toolName == "proxy_create":
		result, terr = s.proxyCreateTool(ctx, id, argsJSON)
	case toolName == "ui_compose":
		result, terr = s.composeUI(ctx, id, roomID, agentName, argsJSON)
	case toolName == "frontend_show":
		result, terr = s.showTool(ctx, id, roomID, agentName, argsJSON)
	case toolName == "desk_state":
		result, terr = s.deskStateTool(ctx, id, roomID, argsJSON)
	case toolName == "desk_arrange":
		result, terr = s.deskArrangeTool(ctx, id, roomID, agentName, argsJSON)
	case toolName == "desk_close":
		result, terr = s.deskCloseTool(ctx, id, roomID, agentName, argsJSON)
	default:
		var tools []vmm.Tool
		tools, terr = s.SpaceTools(ctx, id, roomID)
		if terr != nil {
			break
		}
		found := false
		for _, t := range tools {
			if t.Name == toolName {
				botID, perr := identity.Parse(t.BotID)
				if perr != nil {
					terr = errs.InvalidArgument("tool has no bot backend")
					break
				}
				result, terr = s.AskBot(ctx, id, botID, input, nil, nil)
				found = true
				break
			}
		}
		if !found && terr == nil {
			terr = errs.NotFound("tool " + toolName)
		}
	}
	if err := s.finishToolEvent(context.WithoutCancel(ctx), event, result, terr); err != nil {
		return result, err
	}
	return result, terr
}

// slugToolName builds a stable function name for a bot, sanitizing and
// de-duplicating across the space.
func slugToolName(name, botID string, used map[string]bool) string {
	var b strings.Builder
	for _, r := range strings.ToLower(name) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
		case unicode.IsSpace(r) || r == '-' || r == '.':
			b.WriteRune('_')
		}
	}
	base := strings.Trim(b.String(), "_")
	if base == "" {
		base = "tool"
	}
	candidate := "tool_" + base
	if used[candidate] {
		suffix := botID
		if len(suffix) > 6 {
			suffix = suffix[len(suffix)-6:]
		}
		candidate = "tool_" + base + "_" + suffix
	}
	used[candidate] = true
	return candidate
}

// readFileForAgent resolves either a workspace attachment or a sandbox text
// range. Attachment ownership and sandbox capabilities are checked separately;
// binary attachments retain their metadata and multimodal representation.
func (s *Service) readFileForAgent(ctx context.Context, spaceID identity.ID, argsJSON string) (string, error) {
	var in struct {
		FileID   string `json:"file_id"`
		URL      string `json:"url"`
		MaxChars int    `json:"max_chars,omitempty"`
		Path     string `json:"path,omitempty"`
		Start    int    `json:"start_line,omitempty"`
		End      int    `json:"end_line,omitempty"`
		Pattern  string `json:"pattern,omitempty"`
		Literal  bool   `json:"literal,omitempty"`
		Inspect  bool   `json:"inspect,omitempty"`
		Context  *int   `json:"context_lines,omitempty"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("file_read requires a JSON object with file_id, url, or sandbox path")
	}
	if in.Inspect && in.Path == "" {
		return "", errs.InvalidArgument("inspect requires a sandbox HTML path")
	}
	if in.Path != "" {
		if in.FileID != "" || in.URL != "" {
			return "", errs.InvalidArgument("sandbox path cannot be combined with file_id or url")
		}
		if in.Inspect {
			if in.Pattern != "" || in.Start != 0 || in.End != 0 {
				return "", errs.InvalidArgument("inspect cannot be combined with pattern or line ranges")
			}
			return s.inspectSandboxHTML(ctx, spaceID, in.Path)
		}
		if in.Pattern != "" {
			if in.Start != 0 || in.End != 0 {
				return "", errs.InvalidArgument("pattern cannot be combined with a line range")
			}
			around := 3
			if in.Context != nil {
				around = *in.Context
			}
			return s.searchSandboxText(ctx, spaceID, in.Path, in.Pattern, around, in.MaxChars, in.Literal)
		}
		return s.readSandboxText(ctx, spaceID, in.Path, in.Start, in.End, in.MaxChars)
	}
	ref := in.FileID
	if ref == "" && in.URL != "" {
		// Accept "/v1/files/{id}/content" or a bare id.
		ref = strings.TrimSuffix(strings.TrimPrefix(in.URL, "/v1/files/"), "/content")
	}
	if ref == "" {
		return "", errs.InvalidArgument("file_read requires a file_id or content url")
	}
	fid, err := identity.Parse(ref)
	if err != nil {
		return "", errs.InvalidArgument("invalid file id")
	}
	f, err := s.GetFile(ctx, fid)
	if err != nil {
		return "", err
	}
	// The agent is a member of the space; it may only read files that belong to
	// this space (files travel with the chat messages the agent sees).
	if f.SpaceID != spaceID {
		return "", errs.Permission("file is not in this space")
	}
	maxChars := in.MaxChars
	if maxChars <= 0 || maxChars > 100000 {
		maxChars = 100000
	}
	if isTextFile(f.Mime, f.Name) {
		data, err := s.ReadFileBytes(ctx, f)
		if err != nil {
			return "", err
		}
		content := truncateText(string(data), maxChars)
		if maxChars > maxExtractChars && len(data) > maxExtractChars {
			content = truncateText(string(data), maxChars)
		}
		return "file: " + f.Name + " (" + f.Mime + ", " + humanSize(f.Size) + ")\n\n" + content, nil
	}
	if strings.HasPrefix(strings.ToLower(f.Mime), "image/") {
		// Return the image itself as multimodal input so the agent can see it.
		// The agent loop converts this marker into an image_url content part —
		// the payload only enters context because the agent explicitly asked.
		data, err := s.ReadFileBytes(ctx, f)
		if err != nil {
			return "", err
		}
		pixels, mime := imageDataForContent(f.Mime, data)
		if len(pixels) == 0 {
			return "file: " + f.Name + " (" + f.Mime + ", " + humanSize(f.Size) + ")\n" +
				"Could not decode this image for inline viewing. Raw content is available at: " + contentPath(f.ID), nil
		}
		payload, _ := json.Marshal(map[string]any{
			"__multimodal": map[string]any{
				"text":      "file: " + f.Name + " (" + f.Mime + ", " + humanSize(f.Size) + ") — this is the requested image.",
				"image_url": "data:" + mime + ";base64," + base64.StdEncoding.EncodeToString(pixels),
			},
		})
		return string(payload), nil
	}
	// Binary/media files cannot be dumped as text; describe them and point at
	// the streaming content url.
	return "file: " + f.Name + " (" + f.Mime + ", " + humanSize(f.Size) + ")\n" +
		"This is a binary/media file. Its raw content is available at: " + contentPath(f.ID) +
		"\nUse the sandbox (curl with the bearer token) or the client to open/preview it.", nil
}

// humanSize renders a byte count in a compact human-readable form.
func humanSize(n int64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(n)/(1<<10))
	default:
		return fmt.Sprintf("%d B", n)
	}
}
