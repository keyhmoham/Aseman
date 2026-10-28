package governance

import (
	"context"
	"encoding/json"
	"regexp"
	"strconv"
	"strings"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/agui"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	gov "github.com/aseman/aseman/plugins/actions/governance/models"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// The secret box. An agent that needs a password asks for it by name; the
// person types it into a masked box; the value is sealed into the vault and
// never comes back out through any action. The agent writes {{secret:name}}
// where the value goes, and the gate puts it in after deciding the action,
// then redacts it from whatever the action returns. The conversation and the
// audit trail only ever say that a secret was asked for, supplied and used,
// and how long it is.

// secretRef is a placeholder for a vault secret.
var secretRef = regexp.MustCompile(`\{\{\s*secret:([A-Za-z0-9_.-]{1,64})\s*\}\}`)

var secretName = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}$`)

func sealContext(v *gov.VaultSecret) string { return "vault/" + v.ID.String() + "/" + v.SpaceID }

// substituteSecrets puts the person's secrets into an allowed action. Values
// in JSON arguments are JSON-escaped; in a command they are single-quoted for
// the shell.
func (s *Service) substituteSecrets(ctx context.Context, req gate.Request) (json.RawMessage, string, map[string]string, error) {
	args, command := req.Args, req.Command
	names := map[string]bool{}
	for _, m := range secretRef.FindAllStringSubmatch(string(args)+"\n"+command, -1) {
		names[m[1]] = true
	}
	if len(names) == 0 {
		return args, command, nil, nil
	}
	values := map[string]string{}
	for name := range names {
		v, err := s.secretValue(ctx, req.SpaceID, req.ActorID, name)
		if err != nil {
			return nil, "", nil, err
		}
		values[name] = v
	}
	replace := func(text string, quote func(string) string) string {
		return secretRef.ReplaceAllStringFunc(text, func(m string) string {
			name := secretRef.FindStringSubmatch(m)[1]
			return quote(values[name])
		})
	}
	if len(args) > 0 {
		args = json.RawMessage(replace(string(args), func(v string) string {
			raw, _ := json.Marshal(v)
			return string(raw[1 : len(raw)-1])
		}))
	}
	if command != "" {
		command = replace(command, func(v string) string { return "'" + strings.ReplaceAll(v, "'", `'\''`) + "'" })
	}
	return args, command, values, nil
}

// secretValue opens the project's secret by name, the actor's own first.
func (s *Service) secretValue(ctx context.Context, space, actor, name string) (string, error) {
	var rows []gov.VaultSecret
	if err := s.R.List(ctx, "vault_secrets", database.Filter{Equal: map[string]any{"space_id": space, "name": name},
		OrderBy: "updated_at", Limit: 20}, &rows); err != nil {
		return "", err
	}
	if len(rows) == 0 {
		return "", errs.NotFound("no secret named " + name + " in this project; ask the person for it with secret_request")
	}
	pick := rows[0]
	for _, r := range rows {
		if r.OwnerID == actor {
			pick = r
			break
		}
	}
	plain, err := crypto.OpenSecret(pick.Sealed, s.K.Env()["node_private_key"], sealContext(&pick))
	if err != nil {
		return "", errs.Wrap(errs.CodeInternal, err, "open secret")
	}
	pick.LastUsedAt = s.now().UTC()
	_ = s.R.Update(context.WithoutCancel(ctx), "vault_secrets", pick.ID, &pick)
	s.Event(ctx, "secret.used", space, actor, name)
	return plain, nil
}

// StoreSecret seals a value into the vault under a name, replacing the
// owner's earlier value of that name in the project.
func (s *Service) StoreSecret(ctx context.Context, owner identity.ID, space, name, site, value string) (*gov.VaultSecret, error) {
	if !secretName.MatchString(name) {
		return nil, errs.InvalidArgument("a secret's name is 1–64 letters, digits, dots, dashes or underscores")
	}
	if value == "" || len(value) > 8192 {
		return nil, errs.InvalidArgument("a secret is 1–8,192 characters")
	}
	var rows []gov.VaultSecret
	if err := s.R.List(ctx, "vault_secrets", database.Filter{Equal: map[string]any{"space_id": space, "name": name, "owner_id": owner.String()}, Limit: 1}, &rows); err != nil {
		return nil, err
	}
	now := s.now().UTC()
	v := &gov.VaultSecret{OwnerID: owner.String(), SpaceID: space, Name: name, Site: clip(site, 300), Length: int64(len([]rune(value)))}
	create := len(rows) == 0
	if create {
		id, err := s.newID()
		if err != nil {
			return nil, err
		}
		v.Entity = entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}
	} else {
		v.Entity = rows[0].Entity
		v.UpdatedAt = now
	}
	sealed, err := crypto.SealSecret(value, s.K.Env()["node_private_key"], sealContext(v))
	if err != nil {
		return nil, errs.Wrap(errs.CodeInternal, err, "seal secret")
	}
	v.Sealed = sealed
	if create {
		err = s.R.CreateID(ctx, "vault_secrets", v.ID, v)
	} else {
		err = s.R.Update(ctx, "vault_secrets", v.ID, v)
	}
	if err != nil {
		return nil, err
	}
	s.Event(ctx, "secret.stored", space, owner.String(), name+" ("+itoa(v.Length)+" characters)")
	return v, nil
}

// SecretRequestTool is the agents' secret_request tool: post a masked box in
// the room and wait for the person to fill it (or decline).
func (s *Service) SecretRequestTool(ctx context.Context, call gate.ToolCall) (string, error) {
	var in struct {
		Name   string `json:"name"`
		Reason string `json:"reason"`
		Site   string `json:"site"`
	}
	_ = json.Unmarshal([]byte(call.Args), &in)
	in.Name = strings.TrimSpace(in.Name)
	if !secretName.MatchString(in.Name) {
		return "", errs.InvalidArgument("secret_request needs a name of letters, digits, dots, dashes or underscores, e.g. github_password")
	}
	if strings.TrimSpace(in.Reason) == "" {
		return "", errs.InvalidArgument("secret_request needs a reason the person reads")
	}
	if _, err := s.secretValueExists(ctx, call.SpaceID, in.Name); err == nil {
		return "The person already gave " + in.Name + ". Use {{secret:" + in.Name + "}} where the value goes.", nil
	}
	id, err := s.newID()
	if err != nil {
		return "", err
	}
	now := s.now().UTC()
	r := &gov.SecretRequest{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, SpaceID: call.SpaceID, RoomID: call.RoomID,
		AgentID: call.AgentID, AgentName: call.AgentName, ActorID: call.ActorID, Name: in.Name, Reason: clip(in.Reason, 500),
		Site: clip(in.Site, 300), Status: gov.SecretPending, ExpiresAt: now.Add(s.ApprovalTimeout)}
	if err := s.R.CreateID(ctx, "secret_requests", id, r); err != nil {
		return "", err
	}
	s.Event(ctx, "secret.requested", call.SpaceID, call.ActorID, in.Name+": "+clip(in.Reason, 200))
	s.postCard(ctx, call, agui.SecretSurface(id.String(), in.Name, r.Reason, r.Site))
	s.pushActor(ctx, call, firstNonEmpty(call.AgentName, "An agent")+" needs "+in.Name, r.Reason, "secret", "secret-"+id.String())
	woke, done := s.waitFor(id.String())
	defer done()
	for {
		var cur gov.SecretRequest
		if err := s.R.Get(ctx, "secret_requests", id, &cur); err != nil {
			return "", err
		}
		switch cur.Status {
		case gov.SecretSupplied:
			return "The person entered " + in.Name + ". Write {{secret:" + in.Name + "}} exactly where the value goes " +
				"(in a command, unquoted: the node quotes it). You never see the value, and it is hidden from what comes back.", nil
		case gov.SecretDeclined:
			return "The person declined to give " + in.Name + ". Do not ask again; continue without it or tell them what is blocked.", nil
		}
		if !s.now().Before(cur.ExpiresAt) {
			cur.Status, cur.UpdatedAt = gov.SecretExpired, s.now().UTC()
			_ = s.R.Update(context.WithoutCancel(ctx), "secret_requests", id, &cur)
			return "Nobody entered " + in.Name + " in time. Tell the person what is blocked.", nil
		}
		if err := s.sleep(ctx, woke, cur.ExpiresAt); err != nil {
			return "", err
		}
	}
}

func (s *Service) secretValueExists(ctx context.Context, space, name string) (bool, error) {
	n, err := s.R.Count(ctx, "vault_secrets", database.Filter{Equal: map[string]any{"space_id": space, "name": name}})
	if err != nil {
		return false, err
	}
	if n == 0 {
		return false, errs.NotFound(name)
	}
	return true, nil
}

// AnswerSecret fills (or declines) a secret request.
func (s *Service) AnswerSecret(ctx context.Context, caller identity.ID, id identity.ID, value string, decline bool) error {
	var r gov.SecretRequest
	if err := s.R.Get(ctx, "secret_requests", id, &r); err != nil {
		return err
	}
	if caller.String() != r.ActorID && !s.isMember(ctx, caller, r.SpaceID) {
		return errs.Permission("not a member of the project")
	}
	if r.Status != gov.SecretPending {
		return errs.Conflict("this request was already " + r.Status)
	}
	if decline {
		r.Status = gov.SecretDeclined
		s.Event(ctx, "secret.declined", r.SpaceID, caller.String(), r.Name)
	} else {
		v, err := s.StoreSecret(ctx, caller, r.SpaceID, r.Name, r.Site, value)
		if err != nil {
			return err
		}
		r.Status, r.SecretID = gov.SecretSupplied, v.ID.String()
		s.Event(ctx, "secret.supplied", r.SpaceID, caller.String(), r.Name+" ("+itoa(v.Length)+" characters)")
	}
	r.UpdatedAt = s.now().UTC()
	if err := s.R.Update(ctx, "secret_requests", id, &r); err != nil {
		return err
	}
	s.wake(id.String())
	return nil
}

// Secrets lists a project's saved secrets: names, sites, lengths, never values.
func (s *Service) Secrets(ctx context.Context, caller identity.ID, space string) ([]gov.VaultSecret, error) {
	if !s.isMember(ctx, caller, space) {
		return nil, errs.Permission("not a member of the project")
	}
	f := database.Filter{Equal: map[string]any{"space_id": space}, OrderBy: "name", Asc: true, Limit: 500}
	if !s.canManage(ctx, caller, space) {
		f.Equal["owner_id"] = caller.String()
	}
	var rows []gov.VaultSecret
	if err := s.R.List(ctx, "vault_secrets", f, &rows); err != nil {
		return nil, err
	}
	for i := range rows {
		rows[i].Sealed = ""
	}
	return rows, nil
}

// DeleteSecret removes a saved secret (its owner or the project's managers).
func (s *Service) DeleteSecret(ctx context.Context, caller, id identity.ID) error {
	var v gov.VaultSecret
	if err := s.R.Get(ctx, "vault_secrets", id, &v); err != nil {
		return err
	}
	if v.OwnerID != caller.String() && !s.canManage(ctx, caller, v.SpaceID) {
		return errs.Permission("only its owner or the project's owner deletes a secret")
	}
	if err := s.R.Delete(ctx, "vault_secrets", id); err != nil {
		return err
	}
	s.Event(ctx, "secret.deleted", v.SpaceID, caller.String(), v.Name)
	return nil
}

// RevokeSecrets deletes every secret an account owns (an account deprovisioned).
func (s *Service) RevokeSecrets(ctx context.Context, owner identity.ID) (int, error) {
	var rows []gov.VaultSecret
	if err := s.R.List(ctx, "vault_secrets", database.Filter{Equal: map[string]any{"owner_id": owner.String()}}, &rows); err != nil {
		return 0, err
	}
	for _, v := range rows {
		_ = s.R.Delete(ctx, "vault_secrets", v.ID)
	}
	var grants []gov.Grant
	if err := s.R.List(ctx, "approval_grants", database.Filter{Equal: map[string]any{"account_id": owner.String()}}, &grants); err == nil {
		for _, g := range grants {
			_ = s.R.Delete(ctx, "approval_grants", g.ID)
		}
	}
	if len(rows) > 0 {
		s.Event(ctx, "secret.revoked", "", owner.String(), itoa(int64(len(rows)))+" secrets")
	}
	return len(rows), nil
}

// postCard posts an AG-UI card into the call's room as its agent.
func (s *Service) postCard(ctx context.Context, call gate.ToolCall, surf agui.Surface) {
	space, err := identity.Parse(call.SpaceID)
	if err != nil || s.Spaces == nil {
		return
	}
	room, _ := identity.Parse(call.RoomID)
	sender, _ := identity.Parse(call.AgentAccount)
	if sender.IsZero() {
		sender, _ = s.Spaces.AsemanAccount(ctx)
	}
	body, err := agui.FormatMessage("", surf)
	if err != nil || sender.IsZero() {
		return
	}
	if err := s.Spaces.PostMessage(context.WithoutCancel(ctx), space, room, sender, body); err != nil && s.L != nil {
		s.L.Warn("card not posted", "error", err)
	}
}

func (s *Service) pushActor(ctx context.Context, call gate.ToolCall, title, body, kind, collapse string) {
	if s.Users == nil {
		return
	}
	actor, err := identity.Parse(call.ActorID)
	if err != nil || !s.isPerson(ctx, call.ActorID) {
		return
	}
	s.Users.Push(context.WithoutCancel(ctx), []identity.ID{actor}, PushNote{Title: clip(title, 120), Body: clip(body, 180), Kind: kind,
		Space: call.SpaceID, Room: call.RoomID, Collapse: collapse})
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
