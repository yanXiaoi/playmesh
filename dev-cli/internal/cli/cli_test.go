package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/target"
)

func TestBreakingCommandsCreateSDKAndPushAreRemoved(t *testing.T) {
	for _, command := range []string{"create", "sdk", "push"} {
		err := Run(context.Background(), []string{command})
		if err == nil || !strings.Contains(err.Error(), "未知命令") {
			t.Fatalf("%s must be removed in CLI 2.0, got %v", command, err)
		}
	}
}

func TestCommandCapabilitiesOutputsTargetRegistryAsJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(
		func(response http.ResponseWriter, request *http.Request) {
			if request.URL.Path != "/dev/api/capabilities" {
				http.NotFound(response, request)
				return
			}
			if request.Header.Get("Authorization") != "Bearer test-token" {
				http.Error(response, "missing token", http.StatusUnauthorized)
				return
			}
			_, _ = response.Write([]byte(`{
			  "capabilities": [{
			    "code": "sensor.accelerometer",
			    "name": "加速度计",
			    "description": "动作输入",
			    "supportedPlatforms": ["WINDOWS", "ANDROID"]
			  }]
			}`))
		},
	))
	t.Cleanup(server.Close)
	t.Setenv("APPDATA", t.TempDir())
	if err := saveTarget(target.Config{
		BaseURL: server.URL,
		Token:   "test-token",
	}); err != nil {
		t.Fatal(err)
	}

	var output bytes.Buffer
	if err := commandCapabilities(context.Background(), &output); err != nil {
		t.Fatal(err)
	}
	var registry capabilityRegistry
	if err := json.Unmarshal(output.Bytes(), &registry); err != nil {
		t.Fatal(err)
	}
	if len(registry.Capabilities) != 1 ||
		registry.Capabilities[0].Code != "sensor.accelerometer" {
		t.Fatalf("unexpected capability registry: %#v", registry)
	}
}
