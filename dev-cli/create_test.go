package main

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCreateUsesDeveloperProjectAPIAndDownloadsCurrentDirectory(t *testing.T) {
	packageBytes := createTestProjectPackage(t, map[string]string{
		"main.json":         `{"id":"com.example.created","name":"Created","version":"1.0.0"}`,
		"capabilities.json": `{"required":["sensor.accelerometer"]}`,
		"app/index.html":    "<!doctype html><title>Created</title>",
	})
	var request createProjectRequest
	encoded := func(value string) string {
		return base64.StdEncoding.EncodeToString([]byte(value))
	}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, incoming *http.Request) {
		if incoming.Header.Get("Authorization") != "Bearer test-token" {
			http.Error(response, "unauthorized", http.StatusUnauthorized)
			return
		}
		switch incoming.URL.Path {
		case "/dev/api/capabilities":
			_ = json.NewEncoder(response).Encode(map[string]any{"capabilities": []map[string]any{{
				"code": "sensor.accelerometer", "name": "加速度计", "description": "动作输入",
				"appSupported": true, "htmlSupported": false,
			}}})
		case "/dev/api/projects":
			if incoming.Method != http.MethodPost {
				http.Error(response, "method", http.StatusMethodNotAllowed)
				return
			}
			if err := json.NewDecoder(incoming.Body).Decode(&request); err != nil {
				t.Fatal(err)
			}
			response.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(response).Encode(map[string]any{"project": map[string]any{
				"id": "com.example.created", "name": "Created",
			}})
		case "/dev/api/projects/com.example.created/package":
			_, _ = response.Write(packageBytes)
		case "/dev/api/sdk":
			_ = json.NewEncoder(response).Encode(sdkBundle{
				GameSDKVersion: "1.4.0", AppSDKVersion: "1.2.0", Encoding: "base64",
				Files: map[string]string{
					"playmesh.js":       encoded(`const PLAYMESH_SDK_VERSION = "1.4.0";`),
					"playmesh-app.js":   encoded(`const PLAYMESH_APP_SDK_VERSION = "1.2.0";`),
					"playmesh.d.ts":     encoded("declare const playmesh: unknown;"),
					"playmesh-app.d.ts": encoded("declare const playmeshApp: unknown;"),
				},
			})
		default:
			http.NotFound(response, incoming)
		}
	}))
	t.Cleanup(server.Close)

	root := t.TempDir()
	t.Setenv("APPDATA", t.TempDir())
	if err := saveTarget(targetConfig{BaseURL: server.URL, Token: "test-token"}); err != nil {
		t.Fatal(err)
	}
	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(previous) })

	input := strings.NewReader(strings.Join([]string{
		"com.example.created", "Created", "动作派对", "1", "2", "2", "3", "6", "体感, 聚会", "1", "1", "1", "",
	}, "\n"))
	if err := commandCreateFrom(context.Background(), input); err != nil {
		t.Fatal(err)
	}
	if request.Mode != "multiplayer" || request.Orientation != "portrait" || request.DisplayMode != "single_screen_multiplayer" {
		t.Fatalf("create options were not forwarded: %#v", request)
	}
	if request.ControllerOrientation != "portrait" {
		t.Fatalf("controller orientation was not forwarded: %#v", request)
	}
	if request.MinPlayers != 3 || request.MaxPlayers != 6 || request.ClientID != "cli" {
		t.Fatalf("player options were not forwarded: %#v", request)
	}
	if len(request.RequiredCapabilities) != 1 || request.RequiredCapabilities[0] != "sensor.accelerometer" {
		t.Fatalf("capabilities were not forwarded: %#v", request.RequiredCapabilities)
	}
	if len(request.ControllerRequiredCapabilities) != 1 ||
		request.ControllerRequiredCapabilities[0] != "sensor.accelerometer" {
		t.Fatalf("controller capabilities were not forwarded: %#v", request.ControllerRequiredCapabilities)
	}
	for _, path := range []string{"main.json", "capabilities.json", "app/index.html", "playmesh/sdk/playmesh.js"} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(path))); err != nil {
			t.Fatalf("created project was not downloaded (%s): %v", path, err)
		}
	}
}

func TestCreateRejectsNonEmptyDestinationBeforeCallingDeveloperAPI(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "keep.txt"), "user content")
	if err := ensureCreateDestination(root); err == nil || !strings.Contains(err.Error(), "必须为空") {
		t.Fatalf("expected non-empty destination error, got %v", err)
	}
	data, err := os.ReadFile(filepath.Join(root, "keep.txt"))
	if err != nil || string(data) != "user content" {
		t.Fatalf("existing content was changed: %q, %v", data, err)
	}
}

func createTestProjectPackage(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for path, content := range files {
		entry, err := writer.Create(path)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(entry, content); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}
