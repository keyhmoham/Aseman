package spaces

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	rt "github.com/aseman/aseman/plugins/actions/routines/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// RoutineManager is the subset of the routine service agents use to manage
// per-room routines. Implemented by the routine service.
type RoutineManager interface {
	Create(ctx context.Context, spaceID, roomID, creator identity.ID, name string, typ rt.Type, target, task string, delaySec, intervalSec int64) (*rt.Routine, error)
	List(ctx context.Context, spaceID, roomID identity.ID) ([]rt.Routine, error)
	Get(ctx context.Context, id identity.ID) (*rt.Routine, error)
	Update(ctx context.Context, id identity.ID, name, target, task string, delaySec, intervalSec int64) (*rt.Routine, error)
	Delete(ctx context.Context, id identity.ID) error
	SetDaily(ctx context.Context, id identity.ID, at, tz string) (*rt.Routine, error)
}

// handleRoutineTool routes a routine_* tool call made by an agent.
func (s *Service) handleRoutineTool(ctx context.Context, spaceID, roomID identity.ID, toolName, argsJSON string) (string, error) {
	if s.Routines == nil {
		return "", errs.New(errs.CodeUnavailable, "routine manager not wired")
	}
	// Routines are per-room. When the tool caller did not resolve a room (the
	// agent tool dispatch passes zero), default to the room the request is
	// running in — otherwise agent-created routines would be stored under the
	// zero room and never show up in the room's routines panel.
	if roomID.IsZero() {
		if r := vmm.RoomFrom(ctx); r != "" {
			if parsed, perr := identity.Parse(r); perr == nil {
				roomID = parsed
			}
		}
	}
	var in struct {
		Input       string `json:"input"`
		Key         string `json:"key"`
		Value       string `json:"value"`
		Name        string `json:"name"`
		Type        string `json:"type"`
		Target      string `json:"target"`
		Task        string `json:"task"`
		DelaySec    int64  `json:"delay_sec"`
		IntervalSec int64  `json:"interval_sec"`
		At          string `json:"at"`
		Timezone    string `json:"timezone"`
		Id          string `json:"id"`
		Routine     string `json:"routine"`
	}
	_ = json.Unmarshal([]byte(argsJSON), &in)
	// Fallback: parse "input" as key=value pairs for agent tool calls.
	if in.Input != "" && in.Task == "" {
		for _, pair := range strings.Split(in.Input, "&") {
			if i := strings.IndexByte(pair, '='); i >= 0 {
				k, v := strings.TrimSpace(pair[:i]), strings.TrimSpace(pair[i+1:])
				switch k {
				case "type":
					in.Type = v
				case "target":
					in.Target = v
				case "task":
					in.Task = v
				case "name":
					in.Name = v
				case "delay_sec", "delay":
					in.DelaySec, _ = strconv.ParseInt(v, 10, 64)
				case "interval_sec", "interval":
					in.IntervalSec, _ = strconv.ParseInt(v, 10, 64)
				case "at":
					in.At = v
				case "timezone", "tz":
					in.Timezone = v
				case "id", "routine":
					in.Id = v
				}
			}
		}
	}
	switch toolName {
	case "routine_create":
		if in.Task == "" {
			return "", errs.InvalidArgument("routine_create requires a task")
		}
		typ := rt.Type(in.Type)
		if in.Type == "every" || in.At != "" {
			typ = rt.Periodic // "every day at HH:MM" is periodic
		}
		if typ != rt.Delayed && typ != rt.Periodic {
			return "", errs.InvalidArgument("routine type must be delayed or periodic")
		}
		if in.At != "" {
			if _, err := rt.NextDaily(in.At, in.Timezone, time.Now()); err != nil {
				return "", err // before anything is created
			}
		}
		r, err := s.Routines.Create(ctx, spaceID, roomID, helper.Actor(ctx), in.Name, typ, in.Target, in.Task, in.DelaySec, in.IntervalSec)
		if err != nil {
			return "", err
		}
		if in.At != "" {
			if r, err = s.Routines.SetDaily(ctx, r.ID, in.At, in.Timezone); err != nil {
				_ = s.Routines.Delete(ctx, r.ID)
				return "", err
			}
		}
		data, err := json.Marshal(r)
		return string(data), err
	case "routine_list":
		list, err := s.Routines.List(ctx, spaceID, roomID)
		if err != nil {
			return "", err
		}
		if list == nil {
			list = []rt.Routine{}
		}
		data, err := json.Marshal(list)
		return string(data), err
	case "routine_get", "routine_update", "routine_delete":
		ref := in.Id
		if ref == "" {
			ref = in.Routine
		}
		if ref == "" {
			return "", errs.InvalidArgument(toolName + " requires a routine id")
		}
		id, err := identity.Parse(ref)
		if err != nil {
			return "", errs.InvalidArgument("invalid routine id")
		}
		r, err := s.Routines.Get(ctx, id)
		if err != nil {
			return "", err
		}
		if r.SpaceID != spaceID || r.RoomID != roomID {
			return "", errs.Permission("routine belongs to another workspace or room")
		}
		if toolName == "routine_update" {
			r, err = s.Routines.Update(ctx, id, in.Name, in.Target, in.Task, in.DelaySec, in.IntervalSec)
			if err != nil {
				return "", err
			}
			if in.At != "" {
				if r, err = s.Routines.SetDaily(ctx, id, in.At, in.Timezone); err != nil {
					return "", err
				}
			}
		}
		if toolName != "routine_delete" {
			data, err := json.Marshal(r)
			return string(data), err
		}
		if err := s.Routines.Delete(ctx, id); err != nil {
			return "", err
		}
		return "routine deleted", nil
	default:
		return "", errs.NotFound("routine tool " + toolName)
	}
}
