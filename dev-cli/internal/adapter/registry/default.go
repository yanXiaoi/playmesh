package registry

import (
	"github.com/yanXiaoi/playmesh/dev-cli/internal/adapter"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/adapter/cocos"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/adapter/script"
)

func Default() *adapter.Registry {
	result := adapter.NewRegistry()
	mustRegister(result, script.JavaScript{}, false)
	mustRegister(result, script.TypeScript{}, false)
	mustRegister(result, cocos.Cocos{}, true)
	return result
}

func mustRegister(
	registry *adapter.Registry,
	value adapter.Adapter,
	platform bool,
) {
	if err := registry.Register(value, platform); err != nil {
		panic(err)
	}
}
