package registry

import (
	"reflect"
	"testing"
)

func TestDefaultRegistryOwnsAllBuiltInAdapters(t *testing.T) {
	registry := Default()
	for _, id := range []string{"javascript", "typescript", "cocos"} {
		if value, exists := registry.Lookup(id); !exists || value.ID() != id {
			t.Fatalf("默认注册表缺少 %s 适配器", id)
		}
	}
	if actual := registry.PlatformIDs(); !reflect.DeepEqual(
		actual,
		[]string{"cocos"},
	) {
		t.Fatalf("平台适配器列表不正确: %#v", actual)
	}
}
