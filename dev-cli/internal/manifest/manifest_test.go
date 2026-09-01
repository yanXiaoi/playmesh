package manifest

import "testing"

func TestConfigValueReadsOnlyExistingObjectPath(t *testing.T) {
	config := map[string]any{
		"webRuntime": map[string]any{
			"multithreading": true,
			"nullable":       nil,
		},
	}
	if value := ConfigValue(
		config,
		"webRuntime",
		"multithreading",
	); value != true {
		t.Fatalf("unexpected config value: %#v", value)
	}
	for _, test := range []struct {
		name   string
		config any
		path   []string
	}{
		{name: "missing config", config: nil, path: []string{"webRuntime"}},
		{name: "opaque config", config: "opaque", path: []string{"webRuntime"}},
		{name: "empty path", config: config, path: nil},
		{name: "missing field", config: config, path: []string{"webRuntime", "missing"}},
		{name: "empty field", config: config, path: []string{""}},
	} {
		t.Run(test.name, func(t *testing.T) {
			if value := ConfigValue(test.config, test.path...); value != nil {
				t.Fatalf("expected nil, got %#v", value)
			}
		})
	}
}
