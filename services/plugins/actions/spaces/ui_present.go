package spaces

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/agui"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// uiPresentTool shows an AG-UI surface either inline in chat or as a desk
// window. Never use this for interactive API-backed apps — those are
// appui_create.
func (s *Service) uiPresentTool(ctx context.Context, spaceID identity.ID, argsJSON string) (string, error) {
	var in struct {
		Caption    string         `json:"caption"`
		Title      string         `json:"title"`
		Surface    map[string]any `json:"surface"`
		Root       map[string]any `json:"root"`
		Question   string         `json:"question"`
		Options    []string       `json:"options"`
		Room       string         `json:"room"`
		Data       map[string]any `json:"data"`
		Placement  string         `json:"placement"`  // chat | desk | auto
		Complexity string         `json:"complexity"` // low | high (hint for auto)
		Intent     string         `json:"intent"`     // optional free text for InferSignals
		X          *float64       `json:"x"`
		Y          *float64       `json:"y"`
		W          *float64       `json:"w"`
		H          *float64       `json:"h"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("ui_present arguments must be a JSON object")
	}

	surf := agui.Surface{
		Version: agui.SpecVersion,
		Title:   strings.TrimSpace(in.Title),
		Data:    in.Data,
	}
	switch {
	case in.Surface != nil:
		raw, _ := json.Marshal(in.Surface)
		_ = json.Unmarshal(raw, &surf)
	case in.Root != nil:
		surf.Root = in.Root
	case strings.TrimSpace(in.Question) != "":
		surf = agui.QuestionSurface(strings.TrimSpace(in.Question), in.Options)
		if in.Title != "" {
			surf.Title = in.Title
		}
	default:
		return "", errs.InvalidArgument("ui_present needs surface, root, or question")
	}
	if surf.Root == nil && in.Surface != nil {
		if r, ok := in.Surface["root"].(map[string]any); ok {
			surf.Root = r
		}
	}
	if err := agui.ValidateRoot(surf); err != nil {
		return "", errs.InvalidArgument(err.Error())
	}

	placement := strings.ToLower(strings.TrimSpace(in.Placement))
	if placement == "" || placement == "auto" {
		sig := agui.InferSignals(in.Intent + " " + in.Caption + " " + in.Title + " " + in.Question)
		if strings.EqualFold(in.Complexity, "high") {
			sig.HighComplexity = true
			sig.StructuredData = true
		}
		if strings.EqualFold(in.Complexity, "low") {
			sig.ExplicitMinimal = true
			sig.StructuredData = true
		}
		if strings.TrimSpace(in.Question) != "" {
			sig.NeedsHumanInput = true
		}
		d := agui.Classify(sig)
		if d.Medium == agui.MediumAppui {
			return "", errs.InvalidArgument("this request needs an interactive App UI — use appui_create, not ui_present")
		}
		placement = string(d.Placement)
		if placement == string(agui.PlacementNone) {
			placement = "chat"
		}
	}
	if placement != "chat" && placement != "desk" {
		return "", errs.InvalidArgument("placement must be chat, desk, or auto")
	}
	surf.Layout = placement
	// The answer the person reads is where the card has to be. A separate post
	// lands in another room, and the chat only keeps the takeaway.
	if vmm.NoteSurface(ctx, "") {
		carried := surf
		carried.Layout = "chat"
		body, err := agui.FormatMessage(in.Caption, carried)
		if err != nil {
			return "", errs.Wrap(errs.CodeInternal, err, "encode agui")
		}
		vmm.NoteSurface(ctx, body)
		if placement != "desk" {
			return "showing it with your answer: say the takeaway in a sentence or two and do not repeat the card", nil
		}
	}

	sender, err := s.toolSender(ctx)
	var roomID identity.ID
	if err == nil {
		roomID, err = s.toolRoom(ctx, in.Room)
	}
	if err == nil {
		err = helper.CheckContextAccess(ctx, s.R, spaceID, roomID, true)
	}
	if err != nil {
		if vmm.NoteSurface(ctx, "") {
			return "showing it with your answer: say the takeaway in a sentence or two and do not repeat the card", nil
		}
		return "", err
	}

	if placement == "desk" {
		rawSurf, _ := json.Marshal(surf)
		var surfMap map[string]any
		_ = json.Unmarshal(rawSurf, &surfMap)
		args := map[string]any{"surface": surfMap}
		if surf.SurfaceID != "" {
			args["surfaceId"] = surf.SurfaceID
		}
		op := DeskOp{
			Op: "open", Kind: DeskAgUi, Title: surf.Title,
			Args: args, X: in.X, Y: in.Y, W: in.W, H: in.H,
		}
		if op.Title == "" {
			op.Title = "Visualization"
		}
		_, ids, err := s.UpdateDesk(ctx, spaceID, roomID, sender.String(), []DeskOp{op})
		if err != nil {
			if vmm.NoteSurface(ctx, "") {
				return "showing it with your answer: say the takeaway in a sentence or two and do not repeat the card", nil
			}
			return "", err
		}
		id := ""
		if len(ids) > 0 {
			id = ids[0]
		}
		if vmm.NoteSurface(ctx, "") {
			return fmt.Sprintf("showing it with your answer (also on the desk, window=%s): say the takeaway in a sentence or two and do not repeat the card", id), nil
		}
		caption := strings.TrimSpace(in.Caption)
		if caption == "" {
			caption = "Opened **" + op.Title + "** on the desk."
		} else if !strings.Contains(strings.ToLower(caption), "desk") {
			caption = caption + "\n\n_(shown on the desk)_"
		}
		_ = s.postMessage(ctx, spaceID, roomID, sender, caption, message.KindMessage)
		return fmt.Sprintf("AG-UI surface opened on the desk (window=%s)", id), nil
	}

	body, err := agui.FormatMessage(in.Caption, surf)
	if err != nil {
		return "", errs.Wrap(errs.CodeInternal, err, "encode agui")
	}
	if err := s.postMessage(ctx, spaceID, roomID, sender, body, message.KindMessage); err != nil {
		return "", err
	}
	return "AG-UI surface posted to chat", nil
}

func (s *Service) toolSender(ctx context.Context) (identity.ID, error) {
	if a := helper.Actor(ctx); !a.IsZero() {
		return a, nil
	}
	return s.AsemanAccount(ctx)
}

func (s *Service) toolRoom(ctx context.Context, room string) (identity.ID, error) {
	if room != "" {
		id, err := identity.Parse(room)
		if err != nil {
			return identity.ID{}, errs.InvalidArgument("invalid room id")
		}
		return id, nil
	}
	if r := vmm.RoomFrom(ctx); r != "" {
		id, err := identity.Parse(r)
		if err != nil {
			return identity.ID{}, errs.InvalidArgument("invalid room from context")
		}
		return id, nil
	}
	return identity.ID{}, nil
}
