package users

import (
	"context"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
)

// The in-app inbox: every notification Push sends is also kept for the
// person it was for, so the app can list the latest ones, phone or not.

// keptNotifications is how many notifications a person keeps; older ones go.
const keptNotifications = 100

// Notification is one thing a person was told about.
type Notification struct {
	ID       string `db:"id" json:"id"`
	Account  string `db:"account" json:"-"`
	Title    string `db:"title" json:"title"`
	Body     string `db:"body" json:"body"`
	Kind     string `db:"kind" json:"kind"`
	Space    string `db:"space" json:"space,omitempty"`
	Room     string `db:"room" json:"room,omitempty"`
	Collapse string `db:"collapse" json:"-"`
	// Read is set once the person has seen it in the app.
	Read      bool      `db:"read" json:"read"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}

func notificationActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "users", Name: "notifications_list", Summary: "List your latest notifications", Handler: s.notificationsList},
		helper.Action{Namespace: "users", Name: "notifications_read", Summary: "Mark your notifications read", Handler: s.notificationsRead},
	}
}

// keep stores [note] in [account]'s inbox. A note with a Collapse replaces
// the earlier one with the same value, like it does on the phone.
func (s *Service) keep(ctx context.Context, account identity.ID, note PushNote) {
	row := &Notification{
		Account: account.String(), Title: note.Title, Body: note.Body, Kind: note.Kind,
		Space: note.Space, Room: note.Room, Collapse: note.Collapse, CreatedAt: time.Now().UTC(),
	}
	var (
		key identity.ID
		err error
	)
	if note.Collapse != "" {
		key, err = identity.Parse(s.K.NodeID().String() + repo.ExecutionKey("note/" + row.Account + "/" + note.Collapse)[16:])
	} else {
		key, err = identity.New(s.K.NodeID())
	}
	if err != nil {
		return
	}
	row.ID = key.String()
	if err = s.R.CreateID(ctx, "notifications", key, row); errs.CodeOf(err) == errs.CodeAlreadyExists {
		err = s.R.Update(ctx, "notifications", key, row)
	}
	if err != nil {
		if s.L != nil {
			s.L.Warn("notification not kept", "account", row.Account, "error", err)
		}
		return
	}
	var old []Notification
	if s.R.List(ctx, "notifications", database.Filter{
		Equal:   map[string]any{"account": row.Account},
		OrderBy: "created_at", Offset: keptNotifications,
	}, &old) == nil {
		for i := range old {
			if id, e := identity.Parse(old[i].ID); e == nil {
				_ = s.R.Delete(ctx, "notifications", id)
			}
		}
	}
}

// Notifications lists [account]'s latest notifications, newest first, and
// how many of them are unread.
func (s *Service) Notifications(ctx context.Context, account identity.ID, limit, offset int) ([]Notification, int, error) {
	var list []Notification
	if err := s.R.List(ctx, "notifications", database.Filter{
		Equal:   map[string]any{"account": account.String()},
		OrderBy: "created_at", Limit: limit, Offset: offset,
	}, &list); err != nil {
		return nil, 0, err
	}
	var unread []Notification
	if err := s.R.List(ctx, "notifications", database.Filter{
		Equal: map[string]any{"account": account.String(), "read": false},
	}, &unread); err != nil {
		return nil, 0, err
	}
	if list == nil {
		list = []Notification{}
	}
	return list, len(unread), nil
}

// MarkNotificationsRead marks every notification of [account] read.
func (s *Service) MarkNotificationsRead(ctx context.Context, account identity.ID) error {
	var unread []Notification
	if err := s.R.List(ctx, "notifications", database.Filter{
		Equal: map[string]any{"account": account.String(), "read": false},
	}, &unread); err != nil {
		return err
	}
	for i := range unread {
		n := unread[i]
		id, err := identity.Parse(n.ID)
		if err != nil {
			continue
		}
		n.Read = true
		if err := s.R.Update(ctx, "notifications", id, &n); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) notificationsList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Limit  int `json:"limit,omitempty"`
		Offset int `json:"offset,omitempty"`
	}
	_ = helper.Decode(req, &in)
	limit, offset := helper.Paging(in.Limit, in.Offset, 30, keptNotifications)
	list, unread, err := s.Notifications(ctx, req.Caller.ID, limit, offset)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"notifications": list, "unread": unread})
}

func (s *Service) notificationsRead(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	if err := s.MarkNotificationsRead(ctx, req.Caller.ID); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}
