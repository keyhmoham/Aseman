// Typed namespace facades resolve the current provider for every call.
package market

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
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

func applyThemeListing(ctx context.Context, k api.Kernel, user, listingID identity.ID) error {
	return bridge.Invoke(ctx, k, "themes", "ApplyFromListing", []any{ctx, user, listingID})
}
