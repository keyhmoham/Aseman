package spaces

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/turn"
)

// RunBackgroundTask has the project's lead work on a task as actor in a
// temporary thread of the room, deleted when it answers: background
// research, which leaves nothing in the conversation unless it finds
// something worth saying (it then offers a task). The run keeps the caller's
// context, so what started it (vmm.Initiator) reaches every action it takes.
func (s *Service) RunBackgroundTask(ctx context.Context, spaceID, roomID, actor identity.ID, task string) (string, error) {
	room := s.ensureRoom(ctx, spaceID, roomID)
	if room.IsZero() {
		return "", errs.NotFound("no room in the project")
	}
	var reply string
	err := s.WithTempThread(ctx, spaceID, room, actor, "background", func(thread identity.ID) error {
		var err error
		reply, err = s.RunScheduledTask(ctx, spaceID, thread, actor, task)
		return err
	})
	return reply, err
}

// AskLead starts a durable turn of the project's lead in the room, for actor,
// with a prompt the room does not show (silent) or with body shown as the
// person's message: a greeting, a started task, an answer to a task.
func (s *Service) AskLead(ctx context.Context, actor, spaceID, roomID identity.ID, submission, body, prompt string, silent bool) (*turn.Turn, error) {
	lead, err := s.Bots.InstallAseman(ctx)
	if err != nil {
		return nil, err
	}
	s.ensureAseman(ctx, spaceID)
	if roomID.IsZero() {
		room, err := s.generalRoom(ctx, spaceID)
		if err != nil {
			return nil, err
		}
		roomID = room.ID
	}
	return s.SubmitRoomTurn(ctx, actor, spaceID, roomID, submission, body, prompt, []string{lead.ID.String()}, nil, silent)
}
