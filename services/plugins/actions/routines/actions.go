package routine

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	rt "github.com/aseman/aseman/plugins/actions/routines/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// BuildActions assembles the routines namespace actions.
func BuildActions(s *Service) []api.Action {
	return []api.Action{
		&createAction{s: s}, &listAction{s: s}, &getAction{s: s},
		&updateAction{s: s}, &deleteAction{s: s}, &pauseAction{s: s}, &resumeAction{s: s},
	}
}

// createAction implements routines.create.
type createAction struct{ s *Service }

func (a *createAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "routines", Name: "create", Summary: "Create a delayed or periodic routine for a room"}
}
func (a *createAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	ctx = helper.WithActor(ctx, req.Caller.ID)
	var in struct {
		Space       string `json:"space"`
		Room        string `json:"room,omitempty"`
		Name        string `json:"name,omitempty"`
		Type        string `json:"type"`
		Target      string `json:"target,omitempty"`
		Task        string `json:"task"`
		DelaySec    int64  `json:"delay_sec,omitempty"`
		IntervalSec int64  `json:"interval_sec,omitempty"`
		At          string `json:"at,omitempty"`
		Timezone    string `json:"timezone,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	var roomID identity.ID
	if in.Room != "" {
		roomID, err = identity.Parse(in.Room)
		if err != nil {
			return nil, errs.InvalidArgument("invalid room id")
		}
	}
	if in.At != "" {
		// Validate before anything is created.
		if _, err := rt.NextDaily(in.At, in.Timezone, time.Now()); err != nil {
			return nil, err
		}
		in.Type = string(rt.Periodic)
	}
	r, err := a.s.Create(ctx, spaceID, roomID, req.Caller.ID, in.Name, rt.Type(in.Type), in.Target, in.Task, in.DelaySec, in.IntervalSec)
	if err != nil {
		return nil, err
	}
	if in.At != "" {
		if r, err = a.s.SetDaily(ctx, r.ID, in.At, in.Timezone); err != nil {
			_ = a.s.Delete(ctx, r.ID)
			return nil, err
		}
	}
	return helper.JSON(a.s.toMap(r))
}

// listAction implements routines.list.
type listAction struct{ s *Service }

func (a *listAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "routines", Name: "list", Summary: "List a room's routines"}
}
func (a *listAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	ctx = helper.WithActor(ctx, req.Caller.ID)
	var in struct {
		Space string `json:"space"`
		Room  string `json:"room,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	var roomID identity.ID
	if in.Room != "" {
		roomID, err = identity.Parse(in.Room)
		if err != nil {
			return nil, errs.InvalidArgument("invalid room id")
		}
	}
	list, err := a.s.List(ctx, spaceID, roomID)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(list))
	for i := range list {
		out = append(out, a.s.toMap(&list[i]))
	}
	return helper.JSON(map[string]any{"routines": out})
}

// getAction implements routines.get.
type getAction struct{ s *Service }

func (a *getAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "routines", Name: "get", Summary: "Get a routine"}
}
func (a *getAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	ctx = helper.WithActor(ctx, req.Caller.ID)
	var in struct {
		Routine string `json:"routine"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Routine)
	if err != nil {
		return nil, errs.InvalidArgument("invalid routine id")
	}
	r, err := a.s.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	return helper.JSON(a.s.toMap(r))
}

// updateAction implements routines.update.
type updateAction struct{ s *Service }

func (a *updateAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "routines", Name: "update", Summary: "Modify a routine"}
}
func (a *updateAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	ctx = helper.WithActor(ctx, req.Caller.ID)
	var in struct {
		Routine     string `json:"routine"`
		Name        string `json:"name,omitempty"`
		Target      string `json:"target,omitempty"`
		Task        string `json:"task,omitempty"`
		DelaySec    int64  `json:"delay_sec,omitempty"`
		IntervalSec int64  `json:"interval_sec,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Routine)
	if err != nil {
		return nil, errs.InvalidArgument("invalid routine id")
	}
	r, err := a.s.Update(ctx, id, in.Name, in.Target, in.Task, in.DelaySec, in.IntervalSec)
	if err != nil {
		return nil, err
	}
	return helper.JSON(a.s.toMap(r))
}

// deleteAction implements routines.delete.
type deleteAction struct{ s *Service }

func (a *deleteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "routines", Name: "delete", Summary: "Delete a routine"}
}
func (a *deleteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	ctx = helper.WithActor(ctx, req.Caller.ID)
	var in struct {
		Routine string `json:"routine"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Routine)
	if err != nil {
		return nil, errs.InvalidArgument("invalid routine id")
	}
	if err := a.s.Delete(ctx, id); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

// pauseAction implements routines.pause.
type pauseAction struct{ s *Service }

func (a *pauseAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "routines", Name: "pause", Summary: "Pause a routine"}
}
func (a *pauseAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	ctx = helper.WithActor(ctx, req.Caller.ID)
	var in struct {
		Routine string `json:"routine"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Routine)
	if err != nil {
		return nil, errs.InvalidArgument("invalid routine id")
	}
	r, err := a.s.Pause(ctx, id)
	if err != nil {
		return nil, err
	}
	return helper.JSON(a.s.toMap(r))
}

// resumeAction implements routines.resume.
type resumeAction struct{ s *Service }

func (a *resumeAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "routines", Name: "resume", Summary: "Resume a paused routine"}
}
func (a *resumeAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	ctx = helper.WithActor(ctx, req.Caller.ID)
	var in struct {
		Routine string `json:"routine"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Routine)
	if err != nil {
		return nil, errs.InvalidArgument("invalid routine id")
	}
	r, err := a.s.Resume(ctx, id)
	if err != nil {
		return nil, err
	}
	return helper.JSON(a.s.toMap(r))
}
