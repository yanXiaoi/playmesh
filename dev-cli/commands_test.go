package main

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestPushProjectNormalizesVersionsAndUploadsPublishedFiles(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "main.json"), `{"id":"com.example.push","version":"1.0.0","sdkVersion":"9.9.9"}`)
	writeTestFile(t, filepath.Join(root, "capabilities.json"), `{"required":[]}`)
	writeTestFile(t, filepath.Join(root, "app", "index.html"), "<!doctype html>")
	writeTestBytes(t, filepath.Join(root, rootIconName), validRootIcon(t))
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh.js"), `const PLAYMESH_SDK_VERSION = "1.4.0";`)
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh-app.js"), `const PLAYMESH_APP_SDK_VERSION = "1.2.0";`)

	var uploaded []byte
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "Bearer test-token" {
			http.Error(response, "unauthorized", http.StatusUnauthorized)
			return
		}
		switch request.URL.Path {
		case "/dev/api/status":
			_ = json.NewEncoder(response).Encode(map[string]any{
				"enabled": true, "gameSdkVersion": "1.4.0", "appSdkVersion": "1.2.0",
			})
		case "/dev/api/packages/import":
			uploaded, _ = io.ReadAll(request.Body)
			_ = json.NewEncoder(response).Encode(map[string]any{
				"committed": true,
				"project":   map[string]any{"id": "com.example.push", "version": "1.0.0"},
			})
		default:
			http.NotFound(response, request)
		}
	}))
	t.Cleanup(server.Close)

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

	projectID, err := pushProject(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if projectID != "com.example.push" || len(uploaded) == 0 {
		t.Fatalf("unexpected push result: id=%s bytes=%d", projectID, len(uploaded))
	}
	reader, err := zip.NewReader(bytes.NewReader(uploaded), int64(len(uploaded)))
	if err != nil {
		t.Fatal(err)
	}
	paths := map[string]bool{}
	for _, entry := range reader.File {
		paths[entry.Name] = true
	}
	if !paths["main.json"] || !paths["capabilities.json"] ||
		!paths[rootIconName] || !paths["app/index.html"] {
		t.Fatalf("uploaded package is incomplete: %#v", paths)
	}
	for path := range paths {
		if len(path) >= len("playmesh/") && path[:len("playmesh/")] == "playmesh/" {
			t.Fatalf("local SDK leaked into upload: %s", path)
		}
	}
	var manifest map[string]any
	data, err := os.ReadFile(filepath.Join(root, "main.json"))
	if err != nil || json.Unmarshal(data, &manifest) != nil {
		t.Fatalf("read normalized manifest: %v", err)
	}
	if manifest["sdkVersion"] != "1.4.0" || manifest["appSdkVersion"] != "1.2.0" {
		t.Fatalf("manifest SDK versions were not normalized: %#v", manifest)
	}
}

func TestAttachEventsReplaysLogsAndStopsWhenRunDisappears(t *testing.T) {
	var runRequests atomic.Int32
	var logRequests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/dev/api/events":
			response.Header().Set("Content-Type", "text/event-stream")
			response.WriteHeader(http.StatusOK)
			if flusher, ok := response.(http.Flusher); ok {
				flusher.Flush()
			}
			<-request.Context().Done()
		case "/dev/api/run":
			count := runRequests.Add(1)
			if count < 3 {
				_ = json.NewEncoder(response).Encode(map[string]any{
					"run": map[string]any{
						"projectId": "com.example.dev",
						"runId":     "run-1",
						"phase":     "running",
					},
				})
			} else {
				_ = json.NewEncoder(response).Encode(map[string]any{"run": nil})
			}
		case "/dev/api/logs":
			logRequests.Add(1)
			_ = json.NewEncoder(response).Encode(map[string]any{
				"logs": []map[string]any{{
					"type":      "runtime.log",
					"eventId":   "event-1",
					"projectId": "com.example.dev",
					"runId":     "run-1",
					"source":    "app-webview",
					"level":     "log",
					"message":   "early log",
				}},
			})
		default:
			http.NotFound(response, request)
		}
	}))
	t.Cleanup(server.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client := newAPIClient(targetConfig{BaseURL: server.URL, Token: "test-token"})
	if err := attachEvents(ctx, client, "com.example.dev", "run-1"); err != nil {
		t.Fatal(err)
	}
	if logRequests.Load() < 1 {
		t.Fatalf("expected recent log replay requests, got %d", logRequests.Load())
	}
	if runRequests.Load() < 3 {
		t.Fatalf("expected status polling to observe exit, got %d requests", runRequests.Load())
	}
}

func TestAttachEventsReplaysLogsBeforeAlreadyStoppedRunExits(t *testing.T) {
	var logRequests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/dev/api/events":
			response.Header().Set("Content-Type", "text/event-stream")
			response.WriteHeader(http.StatusOK)
			if flusher, ok := response.(http.Flusher); ok {
				flusher.Flush()
			}
			<-request.Context().Done()
		case "/dev/api/logs":
			logRequests.Add(1)
			_ = json.NewEncoder(response).Encode(map[string]any{
				"logs": []map[string]any{{
					"type":      "runtime.log",
					"eventId":   "event-1",
					"projectId": "com.example.dev",
					"runId":     "run-1",
					"source":    "app-webview",
					"level":     "log",
					"message":   "final log",
				}},
			})
		case "/dev/api/run":
			_ = json.NewEncoder(response).Encode(map[string]any{"run": nil})
		default:
			http.NotFound(response, request)
		}
	}))
	t.Cleanup(server.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client := newAPIClient(targetConfig{BaseURL: server.URL, Token: "test-token"})
	if err := attachEvents(ctx, client, "com.example.dev", "run-1"); err != nil {
		t.Fatal(err)
	}
	if logRequests.Load() != 1 {
		t.Fatalf("expected stopped run logs to be replayed, got %d requests", logRequests.Load())
	}
}
