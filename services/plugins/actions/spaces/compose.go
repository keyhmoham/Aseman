package spaces

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// composeInput is an agent's ui_compose call.
type composeInput struct {
	Title      string           `json:"title"`
	Components []map[string]any `json:"components"`
	Data       []struct {
		Path      string         `json:"path"`
		Tool      string         `json:"tool"`
		Microtool string         `json:"microtool"`
		Args      map[string]any `json:"args"`
	} `json:"data"`
	Room string `json:"room"`
}

// maxComposedComponents bounds one composed widget.
const maxComposedComponents = 200

// composeUI implements the ui_compose agent tool: an agent puts together a
// widget from A2UI components, data its microtool calls return, and the
// frontends of the space's tools (ToolFrontend components), and posts it as
// its message in the room. Every call and every embedded tool is checked to
// belong to the space; the data is fetched now, in the agent's scope, so the
// widget shows what was true when it was made, and embedded frontends fetch
// their own data for whoever opens them.
func (s *Service) composeUI(ctx context.Context, spaceID, roomID identity.ID, agentName, argsJSON string) (string, error) {
	var in composeInput
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("ui_compose arguments must be a JSON object")
	}
	if len(in.Components) == 0 || len(in.Components) > maxComposedComponents {
		return "", errs.InvalidArgument("ui_compose needs 1..200 components")
	}
	tools, err := s.SpaceTools(ctx, spaceID, identity.ID{})
	if err != nil {
		return "", err
	}
	inSpace := map[string]vmm.Tool{}
	for _, t := range tools {
		if t.BotID != "" {
			inSpace[t.BotID] = t
		}
	}
	hasRoot := false
	for _, c := range in.Components {
		id, _ := c["id"].(string)
		kind, _ := c["component"].(string)
		if id == "" || kind == "" {
			return "", errs.InvalidArgument("every component needs an id and a component type")
		}
		hasRoot = hasRoot || id == "root"
		if kind == "ToolFrontend" {
			tool, _ := c["tool"].(string)
			t, ok := inSpace[tool]
			if !ok {
				return "", errs.InvalidArgument("ToolFrontend " + id + " names no tool of this space")
			}
			if t.Frontend == "" {
				return "", errs.InvalidArgument(t.Name + " has no frontend to embed; show its data instead")
			}
			c["frontend"] = t.Frontend
			c["name"] = t.Name
		}
	}
	if !hasRoot {
		return "", errs.InvalidArgument("one component must have id \"root\"")
	}
	data := map[string]any{}
	var failed []string
	for _, b := range in.Data {
		if !strings.HasPrefix(b.Path, "/") || b.Microtool == "" {
			return "", errs.InvalidArgument("each data binding needs a path (/...) and a microtool")
		}
		botID, err := identity.Parse(b.Tool)
		if _, ok := inSpace[b.Tool]; err != nil || !ok {
			return "", errs.InvalidArgument("data binding " + b.Path + " names no tool of this space")
		}
		payload := b.Args
		if payload == nil {
			payload = map[string]any{}
		}
		body, _ := json.Marshal(map[string]any{"function": b.Microtool, "payload": payload})
		reply, err := s.AskBot(ctx, spaceID, botID, string(body), nil, nil)
		var value any
		if err == nil {
			value, err = vmm.ToolResultValue(reply)
		}
		if err != nil {
			failed = append(failed, b.Path+": "+err.Error())
			value = map[string]any{"error": err.Error()}
		}
		setDataPointer(data, b.Path, value)
	}
	surface := "ui-" + strings.ReplaceAll(strings.ToLower(agentName), " ", "-")
	body, _ := json.Marshal(map[string]any{
		"title": in.Title,
		"messages": []map[string]any{
			{"version": "v0.9", "createSurface": map[string]any{"surfaceId": surface, "catalogId": "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"}},
			{"version": "v0.9", "updateComponents": map[string]any{"surfaceId": surface, "components": in.Components}},
			{"version": "v0.9", "updateDataModel": map[string]any{"surfaceId": surface, "path": "/", "value": data}},
		},
	})
	target := roomID
	if in.Room != "" {
		if target, err = identity.Parse(in.Room); err != nil {
			return "", errs.InvalidArgument("invalid room")
		}
	}
	sender, err := s.agentAccount(ctx, agentName)
	if err != nil {
		return "", err
	}
	if target.IsZero() {
		room, err := s.generalRoom(ctx, spaceID)
		if err != nil {
			return "", err
		}
		target = room.ID
	}
	id, err := s.storeRoomMessage(ctx, spaceID, target, sender, string(body), message.KindUI, "")
	if err != nil {
		return "", err
	}
	out := map[string]any{"ok": true, "message_id": id.String(), "data_paths": len(in.Data)}
	if len(failed) > 0 {
		out["failed"] = failed
	}
	raw, _ := json.Marshal(out)
	return string(raw), nil
}

// agentAccount is the account a composing agent posts as: the execution's
// agent, else the space's lead.
func (s *Service) agentAccount(ctx context.Context, agentName string) (identity.ID, error) {
	if id := vmm.ExecutionFrom(ctx).AgentID; id != "" {
		if botID, err := identity.Parse(id); err == nil {
			if rec, err := s.Bots.GetBot(ctx, botID); err == nil {
				return rec.AccountID, nil
			}
		}
	}
	return s.TraderaAccount(ctx)
}

func setDataPointer(model map[string]any, path string, value any) {
	parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
	node := model
	for i, p := range parts {
		p = strings.ReplaceAll(strings.ReplaceAll(p, "~1", "/"), "~0", "~")
		if i == len(parts)-1 {
			node[p] = value
			return
		}
		next, ok := node[p].(map[string]any)
		if !ok {
			next = map[string]any{}
			node[p] = next
		}
		node = next
	}
}
