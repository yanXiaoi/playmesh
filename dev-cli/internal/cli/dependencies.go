package cli

import (
	"github.com/yanXiaoi/playmesh/dev-cli/internal/buildinfo"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/target"
)

var targetStore target.Store = target.NewSystemStore()

func newTargetClient(config target.Config) *target.Client {
	return target.NewClient(config, "playmesh-cli/"+buildinfo.Version)
}
