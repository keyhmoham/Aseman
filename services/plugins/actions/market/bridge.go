// Typed namespace facades resolve the current provider for every call.
package market

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
)

type botLoaderBridge struct{ K api.Kernel }

var _ BotLoader = botLoaderBridge{}

func (p botLoaderBridge) GetBot(ctx context.Context, id identity.ID) (*bot.Bot, error) {
	var result0 *bot.Bot
	err := bridge.Invoke(ctx, p.K, "bots", "GetBot", []any{ctx, id}, &result0)
	return result0, err
}

type spaceInstallerBridge struct{ K api.Kernel }

var _ SpaceInstaller = spaceInstallerBridge{}

func (p spaceInstallerBridge) AddBot(ctx context.Context, actor identity.ID, spaceID identity.ID, roomID identity.ID, botID identity.ID) error {
	err := bridge.Invoke(ctx, p.K, "spaces", "AddBot", []any{ctx, actor, spaceID, roomID, botID})
	return err
}
