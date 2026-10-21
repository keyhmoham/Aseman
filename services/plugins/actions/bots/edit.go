package bots

import (
	"context"
	"encoding/json"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/jsonpatch"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
	"gopkg.in/yaml.v3"
	"strings"
	"time"
)

func (s *Service) canEdit(ctx context.Context, req *api.ActionRequest, rec *bot.Bot) error {
	if e := helper.RequireUser(req); e != nil {
		return e
	}
	if rec.OwnerID == req.Caller.ID {
		return nil
	}
	return helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"])
}
func editActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "bots", Name: "bot_edit", Summary: "Edit and activate an agent definition", Handler: s.editAction},
		helper.Action{Namespace: "bots", Name: "bot_detail", Summary: "Read bot descriptor and authorized configuration", Handler: s.detailAction},
		helper.Action{Namespace: "bots", Name: "agent_samples", Summary: "Admin: the sample agents and which are already on this node", Handler: s.agentSamples},
		helper.Action{Namespace: "bots", Name: "agent_import_samples", Summary: "Admin: add the sample agents to the catalog", Handler: s.agentImportSamples},
		bridge.ActionAlias(s.K, "bots", "llm_catalog", "llm", "llm_models", "List enabled LLM models"),
	}
}
func (s *Service) detailAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Bot string `json:"bot"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	id, e := identity.Parse(in.Bot)
	if e != nil {
		return nil, e
	}
	rec, e := s.GetBot(ctx, id)
	if e != nil {
		return nil, e
	}
	view, e := s.BotProfile(ctx, id)
	if e != nil {
		return nil, e
	}
	viewer := identity.ID{}
	if s.canEdit(ctx, req, rec) == nil {
		viewer = rec.AccountID
		view["spec_yml"] = rec.SpecYML
		if rec.Kind == bot.KindAgent {
			view["agent"] = agentConfig(rec.SpecYML)
		}
	}
	if m, e := s.M.View(ctx, viewer, rec.AccountID); e == nil {
		view["metadata"] = m.Tree
	}
	return helper.JSON(view)
}
func (s *Service) editAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Bot          string         `json:"bot"`
		Name         *string        `json:"name"`
		Instructions *string        `json:"instructions"`
		Provider     *string        `json:"provider"`
		Model        *string        `json:"model"`
		Cost         *bot.CostModel `json:"cost"`
		Descriptor   map[string]any `json:"descriptor"`
		// The rest of the agent form, so an agent stays editable after it
		// was created: what it is, how far it goes, what it can do and the
		// computer it runs on.
		Description *string              `json:"description"`
		MaxTurns    *int                 `json:"max_turns"`
		MaxTokens   *int                 `json:"max_tokens"`
		Skills      *[]SkillConfig       `json:"skills"`
		Resources   *bot.ResourceProfile `json:"resources"`
		// A stored image's id; "" removes the avatar.
		Avatar *string `json:"avatar"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	id, e := identity.Parse(in.Bot)
	if e != nil {
		return nil, e
	}
	rec, e := s.GetBot(ctx, id)
	if e != nil {
		return nil, e
	}
	if e = s.canEdit(ctx, req, rec); e != nil {
		return nil, e
	}
	builtin := IsAseman(rec)
	if builtin && in.Instructions != nil {
		return nil, errs.Permission("the built-in lead's instructions are managed by the node; you can change its name, avatar, username, model and price")
	}
	if builtin && in.Resources != nil {
		return nil, errs.Permission("the built-in lead runs on the node's shared runtime; its computer is managed by the node")
	}
	if (in.MaxTurns != nil || in.MaxTokens != nil || in.Skills != nil) && rec.Kind != bot.KindAgent {
		return nil, errs.InvalidArgument("only an agent has steps, reply length and capabilities")
	}
	if in.MaxTurns != nil && (*in.MaxTurns < 0 || *in.MaxTurns > 100) {
		return nil, errs.InvalidArgument("steps per task must be within 0..100")
	}
	if in.MaxTokens != nil && (*in.MaxTokens < 0 || *in.MaxTokens > 200000) {
		return nil, errs.InvalidArgument("reply length must be within 0..200000 tokens")
	}
	if in.Resources != nil && (in.Resources.CPU <= 0 || in.Resources.Memory <= 0 || in.Resources.Disk <= 0) {
		return nil, errs.InvalidArgument("cpu, memory and disk must be positive")
	}
	avatar := ""
	if in.Avatar != nil {
		if avatar, e = helper.AvatarFile(ctx, s.R, req.Caller.ID, *in.Avatar); e != nil {
			return nil, e
		}
	}
	if in.Descriptor != nil {
		if u, _ := in.Descriptor["username"].(string); strings.TrimSpace(u) != "" {
			u = strings.ToLower(strings.TrimPrefix(strings.TrimSpace(u), "@"))
			in.Descriptor["username"] = u
			if taken, e := s.usernameTaken(ctx, u, rec); e != nil {
				return nil, e
			} else if taken {
				return nil, errs.Conflict("the username @" + u + " is already taken")
			}
		}
	}
	oldUpdated := rec.UpdatedAt
	if in.Name != nil {
		rec.Name = strings.TrimSpace(*in.Name)
		if rec.Name == "" {
			return nil, errs.InvalidArgument("bot name required")
		}
	}
	if in.Cost != nil {
		if in.Cost.PerMinute < 0 || in.Cost.PerCall < 0 || in.Cost.CPUPerMin < 0 || in.Cost.MemoryPerGBMin < 0 || in.Cost.DiskPerGBMin < 0 || in.Cost.ImageCost < 0 || in.Cost.TokenInRate < 0 || in.Cost.TokenOutRate < 0 {
			return nil, errs.InvalidArgument("negative cost")
		}
		b, _ := json.Marshal(in.Cost)
		rec.Cost = string(b)
	}
	if in.Resources != nil {
		b, _ := json.Marshal(in.Resources)
		rec.Resources = string(b)
	}
	if in.Description != nil {
		d := strings.TrimSpace(*in.Description)
		in.Description = &d
	}
	oldVM := rec.VMID
	changedSpec := in.Instructions != nil || in.Provider != nil || in.Model != nil || in.Name != nil ||
		in.Description != nil || in.MaxTurns != nil || in.MaxTokens != nil || in.Skills != nil
	var created vmm.VM
	if changedSpec && rec.Kind == bot.KindAgent {
		var spec map[string]any
		if e = yaml.Unmarshal([]byte(rec.SpecYML), &spec); e != nil {
			return nil, e
		}
		if spec == nil {
			spec = map[string]any{}
		}
		spec["name"] = rec.Name
		if in.Instructions != nil {
			if strings.TrimSpace(*in.Instructions) == "" {
				return nil, errs.InvalidArgument("agent instructions required")
			}
			spec["instructions"] = *in.Instructions
		}
		if in.Description != nil {
			setOrDrop(spec, "description", *in.Description, *in.Description != "")
		}
		if in.MaxTurns != nil {
			setOrDrop(spec, "max_turns", *in.MaxTurns, *in.MaxTurns > 0)
		}
		if in.MaxTokens != nil {
			setOrDrop(spec, "max_tokens", *in.MaxTokens, *in.MaxTokens > 0)
		}
		if in.Skills != nil {
			if len(*in.Skills) == 0 {
				delete(spec, "skills")
			} else {
				spec["skills"] = skillsSpec(*in.Skills)
			}
		}
		provider, model := AgentBackbone(rec.SpecYML)
		if in.Provider != nil {
			provider = *in.Provider
		}
		if in.Model != nil {
			model = *in.Model
		}
		// Renaming the built-in lead must not pin it to today's default model.
		if s.LLM != nil && (!builtin || in.Provider != nil || in.Model != nil) {
			p, m, e := s.LLM.Resolve(ctx, provider, model)
			if e != nil {
				return nil, e
			}
			spec["provider"] = p.ID.String()
			spec["model"] = m.ID
		}
		b, e := yaml.Marshal(spec)
		if e != nil {
			return nil, e
		}
		rec.SpecYML = string(b)
	}
	if (changedSpec || in.Resources != nil) && rec.Kind == bot.KindAgent && !builtin {
		// The built-in lead runs on the shared deep agents runtime: its spec is
		// read per turn, so it keeps its VM and image.
		vm := s.K.VMMFor(vmm.Type(rec.VMType))
		if vm == nil {
			return nil, errs.New(errs.CodeUnavailable, "agent runtime unavailable")
		}
		img, e := vm.BuildImage(ctx, vmm.ImageSpec{Type: vmm.Type(rec.VMType), Name: rec.Name, YML: rec.SpecYML})
		if e != nil {
			return nil, e
		}
		res, _ := rec.ParseResources()
		created, e = vm.CreateVM(ctx, vmm.VMSpec{Type: vmm.Type(rec.VMType), Name: rec.Name, ImageRef: img.Ref, YML: rec.SpecYML, Resources: vmm.ResourceSpec{CPU: res.CPU, MemoryMB: res.Memory, DiskMB: res.Disk}})
		if e != nil {
			return nil, e
		}
		rec.VMID = created.ID
		rec.ImageRef = img.Ref
		rec.Status = bot.StatusRunning
	}
	rec.UpdatedAt = time.Now().UTC()
	changed, e := s.R.CompareAndSwap(ctx, "bots", id.String(), map[string]any{"updated_at": oldUpdated}, rec)
	if e != nil || !changed {
		if created.ID != "" {
			_ = s.K.VMMFor(vmm.Type(rec.VMType)).DeleteVM(ctx, created.ID)
		}
		if e != nil {
			return nil, e
		}
		return nil, errs.Conflict("bot changed; reload before saving")
	}
	if in.Description != nil {
		if e = s.M.Patch(ctx, rec.AccountID, jsonpatch.Patch{{Op: "set", Path: "profile/description", Value: *in.Description}}); e != nil {
			return nil, e
		}
	}
	if in.Descriptor != nil {
		m, e := s.M.Get(ctx, rec.AccountID)
		if e != nil {
			return nil, e
		}
		m.Tree["descriptor"] = in.Descriptor
		if e = s.M.ReplaceTree(ctx, rec.AccountID, m.Tree); e != nil {
			return nil, e
		}
		if e = s.M.SetPublicPaths(ctx, rec.AccountID, append(m.PublicPaths, "/descriptor")); e != nil {
			return nil, e
		}
	}
	if in.Avatar != nil {
		patch := jsonpatch.Patch{{Op: "set", Path: "profile/avatar", Value: avatar}}
		// A tool server shows the icon in its descriptor: keep the two the same.
		if m, e := s.M.Get(ctx, rec.AccountID); e == nil && m != nil {
			if _, ok := m.Tree["descriptor"].(map[string]any); ok {
				patch = append(patch, jsonpatch.Op{Op: "set", Path: "descriptor/avatar", Value: avatar})
			}
		}
		if e = s.M.Patch(ctx, rec.AccountID, patch); e != nil {
			return nil, e
		}
	}
	if created.ID != "" && oldVM != "" {
		if e = s.K.VMMFor(vmm.Type(rec.VMType)).DeleteVM(ctx, oldVM); e != nil {
			s.L.Warn("retired agent runtime could not be removed", "vm", oldVM, "error", e)
		}
	}
	return helper.JSON(map[string]any{"ok": true, "bot_id": rec.ID.String(), "status": rec.Status})
}

// setOrDrop sets a spec key, or removes it when it no longer has a value.
func setOrDrop(spec map[string]any, key string, value any, keep bool) {
	if keep {
		spec[key] = value
	} else {
		delete(spec, key)
	}
}

// skillsSpec renders agent capabilities the way renderAgentSpec does.
func skillsSpec(skills []SkillConfig) []map[string]any {
	out := make([]map[string]any, 0, len(skills))
	for _, sk := range skills {
		m := map[string]any{"name": sk.Name}
		if sk.Description != "" {
			m["description"] = sk.Description
		}
		if sk.Instructions != "" {
			m["instructions"] = sk.Instructions
		}
		if len(sk.Tools) > 0 {
			m["tools"] = sk.Tools
		}
		out = append(out, m)
	}
	return out
}

// agentConfig reads the agent form's fields back out of an agent spec, so
// its editor opens on what the agent is configured with today.
func agentConfig(specYML string) map[string]any {
	var spec struct {
		Description  string        `yaml:"description"`
		Instructions string        `yaml:"instructions"`
		Provider     string        `yaml:"provider"`
		Model        string        `yaml:"model"`
		MaxTurns     int           `yaml:"max_turns"`
		MaxTokens    int           `yaml:"max_tokens"`
		Skills       []SkillConfig `yaml:"skills"`
	}
	_ = yaml.Unmarshal([]byte(specYML), &spec)
	if spec.Skills == nil {
		spec.Skills = []SkillConfig{}
	}
	return map[string]any{
		"description": spec.Description, "instructions": strings.TrimRight(spec.Instructions, "\n"),
		"provider": spec.Provider, "model": spec.Model,
		"max_turns": spec.MaxTurns, "max_tokens": spec.MaxTokens, "skills": spec.Skills,
	}
}

// Rebuild replaces a stopped VM while preserving the bot identity and its
// provider-owned workspace volume. The namespace invoking it checks access.
func (s *Service) Rebuild(ctx context.Context, id identity.ID, image string) (*bot.Bot, error) {
	rec, e := s.GetBot(ctx, id)
	if e != nil {
		return nil, e
	}
	if rec.Status == bot.StatusRunning {
		return nil, errs.Conflict("stop the VM before replacing it")
	}
	vm := s.K.VMMFor(vmm.Type(rec.VMType))
	if vm == nil {
		return nil, errs.New(errs.CodeUnavailable, "runtime unavailable")
	}
	res, e := rec.ParseResources()
	if e != nil {
		return nil, e
	}
	if image == "" {
		image = rec.ImageRef
	}
	created, e := vm.CreateVM(ctx, vmm.VMSpec{Name: rec.Name, Type: vmm.Type(rec.VMType), ImageRef: image, YML: rec.SpecYML, Args: []string{"sleep", "infinity"}, Resources: vmm.ResourceSpec{CPU: res.CPU, MemoryMB: res.Memory, DiskMB: res.Disk}, Labels: map[string]string{"aseman.bot_id": rec.ID.String()}})
	if e != nil {
		return nil, e
	}
	old := rec.VMID
	rec.VMID = created.ID
	rec.ImageRef = image
	rec.Status = bot.StatusRunning
	rec.UpdatedAt = time.Now().UTC()
	if e = s.R.Update(ctx, "bots", id, rec); e != nil {
		_ = vm.DeleteVM(ctx, created.ID)
		return nil, e
	}
	_ = vm.DeleteVM(ctx, old)
	return rec, nil
}

// usernameTaken reports whether a public @username belongs to someone else:
// any person's handle, a reserved name, or another agent's username. Usernames
// are unique across people and agents.
func (s *Service) usernameTaken(ctx context.Context, username string, self *bot.Bot) (bool, error) {
	switch username {
	case "aseman", "lead":
		if !IsAseman(self) {
			return true, nil
		}
	}
	var people []account.Account
	if e := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"kind": "user", "handle": username}}, &people); e != nil {
		return false, e
	}
	if len(people) > 0 {
		return true, nil
	}
	var agents []bot.Bot
	if e := s.R.List(ctx, "bots", database.Filter{Equal: map[string]any{"kind": "agent"}}, &agents); e != nil {
		return false, e
	}
	for _, other := range agents {
		if other.ID == self.ID {
			continue
		}
		m, e := s.M.Get(ctx, other.AccountID)
		if e != nil {
			continue
		}
		if d, ok := m.Tree["descriptor"].(map[string]any); ok {
			if u, _ := d["username"].(string); strings.EqualFold(strings.TrimPrefix(u, "@"), username) {
				return true, nil
			}
		}
	}
	return false, nil
}
