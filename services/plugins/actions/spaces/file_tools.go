package spaces

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/actions/spaces/models/execution"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
	"github.com/tradera/tradera/plugins/actions/usage/models/usage"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
	"gopkg.in/yaml.v3"
)

// fileSendTool implements the file_send / file_upload agent tools: an agent
// uploads a file it generated (read from the sandbox path, or given as base64
// content) into the space/room and optionally posts it in the room chat as an
// attachment message from the agent. This lets agents deliver multimodal data
// (images, audio, documents, ...) to users right in the chat.
func (s *Service) fileSendTool(ctx context.Context, spaceID identity.ID, agentName, toolName, argsJSON string) (string, error) {
	var in struct {
		Path    string        `json:"path"`
		Files   []ArchiveFile `json:"files"`
		Content string        `json:"content"`
		Name    string        `json:"name"`
		Mime    string        `json:"mime"`
		Room    string        `json:"room"`
		Caption string        `json:"caption"`
		Input   string        `json:"input"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("bad " + toolName + " args")
	}
	// Tolerate the generic "input" style (key=value) used by older tool calls.
	if in.Path == "" && in.Content == "" && in.Input != "" {
		for _, pair := range strings.Split(in.Input, "&") {
			if i := strings.IndexByte(pair, '='); i >= 0 {
				k, v := strings.TrimSpace(pair[:i]), strings.TrimSpace(pair[i+1:])
				switch k {
				case "path":
					in.Path = v
				case "content":
					in.Content = v
				case "name":
					in.Name = v
				case "mime":
					in.Mime = v
				case "room":
					in.Room = v
				case "caption":
					in.Caption = v
				}
			}
		}
	}
	agent := s.agentBotByName(ctx, spaceID, agentName)
	if agent == nil {
		return "", errs.New(errs.CodeUnavailable, "agent "+agentName+" not found in space")
	}
	// Obtain the file bytes: from the sandbox path (recommended) or base64 content.
	var data []byte
	var err error
	if len(in.Files) > 0 {
		if in.Path != "" || in.Content != "" || !strings.HasSuffix(strings.ToLower(in.Name), ".zip") {
			return "", errs.InvalidArgument("archive files require a .zip name and cannot be combined with path/content")
		}
		data, err = archiveFiles(ctx, in.Files, func(ctx context.Context, path string) ([]byte, error) { return s.sandboxReadFile(ctx, spaceID, path) })
		if err != nil {
			return "", err
		}
		in.Mime = "application/zip"
	} else if in.Path != "" {
		data, err = s.sandboxReadFile(ctx, spaceID, in.Path)
		if err != nil {
			return "", err
		}
		if in.Name == "" {
			in.Name = filepath.Base(in.Path)
		}
	} else if strings.TrimSpace(in.Content) != "" {
		data, err = base64.StdEncoding.DecodeString(strings.TrimSpace(in.Content))
		if err != nil {
			return "", errs.InvalidArgument("invalid base64 content")
		}
	} else {
		return "", errs.InvalidArgument(toolName + " requires a sandbox path or base64 content")
	}
	if in.Name == "" {
		in.Name = "file"
	}
	return s.deliverAgentFile(ctx, spaceID, agent, in.Room, in.Name, in.Mime, in.Caption, data, toolName == "file_send")
}

// deliverAgentFile uploads file bytes produced by an agent into the space/room
// and, when [send] is set, posts them in the room chat as an attachment message
// from the agent.
func (s *Service) deliverAgentFile(ctx context.Context, spaceID identity.ID, agent *bot.Bot, room, name, mime, caption string, data []byte, send bool) (string, error) {
	if room == "" {
		// Default to the room the request is running in so the file lands in
		// the chat where the agent is actually working, not the general room.
		room = vmm.RoomFrom(ctx)
	}
	roomID, err := s.resolveRoomID(ctx, spaceID, room)
	if err != nil {
		return "", err
	}
	// Repair a common PNG corruption produced by hand-rolled sandbox encoders
	// (garbage inserted between a chunk length and its type name), so the
	// delivered image is actually valid.
	if len(data) >= 8 && bytes.Equal(data[:8], pngSignature) {
		data = repairPNG(data)
	}
	file, err := s.UploadFile(ctx, agent.AccountID, spaceID, roomID, name, mime, data)
	if err != nil {
		return "", err
	}
	run := vmm.ExecutionFrom(ctx)
	if run.RunID != "" {
		now := time.Now().UTC()
		artifact := &execution.Artifact{Entity: entity.Entity{ID: file.ID, CreatedAt: now, UpdatedAt: now}, FileID: file.ID, SpaceID: spaceID, RoomID: roomID, RunID: run.RunID, StepID: run.StepID, AttemptID: run.AttemptID, AgentID: run.AgentID}
		if err := s.R.CreateID(ctx, "execution_artifacts", artifact.ID, artifact); err != nil {
			return "", err
		}
	}
	if send {
		if err := s.PostAttachmentMessage(ctx, spaceID, roomID, agent.AccountID, caption, []string{file.ID.String()}); err != nil {
			return "", err
		}
		if run.RunID != "" {
			var artifact execution.Artifact
			if err := s.R.Get(ctx, "execution_artifacts", file.ID, &artifact); err != nil {
				return "", err
			}
			artifact.Delivered = true
			if err := s.R.Update(ctx, "execution_artifacts", file.ID, &artifact); err != nil {
				return "", err
			}
		}
		return fmt.Sprintf("Sent %s to the chat (file id %s)", file.Name, file.ID.String()), nil
	}
	return fmt.Sprintf("Uploaded %s (file id %s)", file.Name, file.ID.String()), nil
}

// imageGenerateTool implements the image_generate agent tool: the AI image
// model generates the picture natively from the prompt and it is posted into
// the room chat as an attachment from the agent. No sandbox is involved.
func (s *Service) imageGenerateTool(ctx context.Context, spaceID identity.ID, agentName, argsJSON string) (string, error) {
	var in struct {
		Prompt  string `json:"prompt"`
		Size    string `json:"size"`
		Caption string `json:"caption"`
		Name    string `json:"name"`
		Room    string `json:"room"`
		Input   string `json:"input"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("bad image_generate args")
	}
	if in.Prompt == "" {
		in.Prompt = in.Input
	}
	if strings.TrimSpace(in.Prompt) == "" {
		return "", errs.InvalidArgument("image_generate requires a prompt")
	}
	agent := s.agentBotByName(ctx, spaceID, agentName)
	if agent == nil {
		return "", errs.New(errs.CodeUnavailable, "agent "+agentName+" not found in space")
	}
	// The image model of the agent's own provider is preferred; its price per
	// image is metered on the invocation so the person is charged for it.
	var spec struct {
		Provider string `yaml:"provider"`
	}
	_ = yaml.Unmarshal([]byte(agent.SpecYML), &spec)
	var data []byte
	var mime string
	var price float64
	var imageModel string
	var tokensIn, tokensOut int64
	// An image the provider has started is billed to the node whether or not
	// the person stops the turn meanwhile: it is finished, charged and
	// delivered, so a stop never leaves it made but unpaid.
	ctx = context.WithoutCancel(ctx)
	if err := bridge.Invoke(ctx, s.K, "llm", "GenerateImage", []any{ctx, spec.Provider, in.Prompt, in.Size}, &data, &mime, &price, &imageModel, &tokensIn, &tokensOut); err != nil {
		return "", err
	}
	// Metered on the invocation: the price is charged to the person, and the
	// model, count and tokens go to the admin log.
	vmm.AddInvocationUsage(ctx, usage.Delta{Images: int64(price), ImageCount: 1, ImageIn: tokensIn, ImageOut: tokensOut, ImageModel: imageModel})
	name := in.Name
	if name == "" {
		name = "image"
	}
	if filepath.Ext(name) == "" {
		if ext := strings.TrimPrefix(mime, "image/"); ext != "" && ext != mime {
			if ext == "jpeg" {
				ext = "jpg"
			}
			name += "." + ext
		}
	}
	return s.deliverAgentFile(ctx, spaceID, agent, in.Room, name, mime, in.Caption, data, true)
}

// PostAttachmentMessage posts a room message from [sender] carrying file
// attachments (rendered by the client), with an optional caption. This is how
// bots/agents deliver files into the room chat.
func (s *Service) PostAttachmentMessage(ctx context.Context, spaceID, roomID, sender identity.ID, caption string, fileIDs []string) error {
	if roomID.IsZero() {
		room, err := s.generalRoom(ctx, spaceID)
		if err != nil {
			return err
		}
		roomID = room.ID
	}
	if len(fileIDs) == 0 {
		return errs.InvalidArgument("at least one file id required")
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	msg := &message.Message{
		Entity:  entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		SpaceID: spaceID, RoomID: roomID, SenderID: sender, Body: caption, Kind: message.KindMessage,
	}
	msg.SetAttachments(fileIDs)
	msg.SetMentions(nil)
	if err := s.R.CreateID(ctx, "messages", id, msg); err != nil {
		return err
	}
	s.notifyRoomMessage(msg)
	return nil
}

// sandboxReadFile reads a file's bytes from inside the space's sandbox (agents
// generate files there). It shells out to `base64` so binary content round-trips
// safely through the exec output.
func (s *Service) sandboxReadFile(ctx context.Context, spaceID identity.ID, path string) ([]byte, error) {
	if strings.TrimSpace(path) == "" {
		return nil, errs.InvalidArgument("sandbox path required")
	}
	out, err := s.SandboxExec(ctx, spaceID, "base64 -w0 "+shellFilePath(path)+" 2>/dev/null || base64 "+shellFilePath(path))
	if err != nil {
		return nil, err
	}
	idx := strings.IndexByte(out, '\n')
	if idx < 0 {
		return nil, errs.New(errs.CodeUnavailable, "unexpected sandbox output")
	}
	if out[:idx] != "exit=0" {
		return nil, errs.New(errs.CodeNotFound, "cannot read sandbox file: "+path)
	}
	b64 := strings.TrimSpace(out[idx+1:])
	b64 = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == ' ' || r == '\t' {
			return -1
		}
		return r
	}, b64)
	data, derr := base64.StdEncoding.DecodeString(b64)
	if derr != nil {
		return nil, errs.Wrap(errs.CodeInternal, derr, "decode sandbox file")
	}
	return data, nil
}

// agentBotByName returns the bot member of a space whose name matches, used to
// attribute agent tool actions (uploads, file messages) to the right account.
// The built-in tradera orchestrator is skipped: it is never a tool caller, and
// skipping it keeps attribution correct even if a worker agent's name ever
// collides with "tradera".
func (s *Service) agentBotByName(ctx context.Context, spaceID identity.ID, name string) *bot.Bot {
	if strings.TrimSpace(name) == "" {
		return nil
	}
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "role": string(membership.RoleBot)},
	}, &mems); err != nil {
		return nil
	}
	for i := range mems {
		rec, err := s.botForMember(ctx, mems[i].MemberID)
		if err != nil {
			continue
		}
		if !strings.EqualFold(rec.Name, name) {
			continue
		}
		return rec
	}
	return nil
}

// resolveRoomID parses an optional room id, defaulting to the space's first room.
func (s *Service) resolveRoomID(ctx context.Context, spaceID identity.ID, room string) (identity.ID, error) {
	if room != "" {
		r, err := identity.Parse(room)
		if err != nil {
			return identity.ID{}, errs.InvalidArgument("invalid room id")
		}
		return r, nil
	}
	gr, err := s.generalRoom(ctx, spaceID)
	if err != nil {
		return identity.ID{}, err
	}
	return gr.ID, nil
}
