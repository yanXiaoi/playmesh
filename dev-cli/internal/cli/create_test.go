package cli

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

	"github.com/yanXiaoi/playmesh/dev-cli/internal/project"
)

func TestInitJavaScriptUsesDeveloperProjectAPIAndDownloadsCurrentDirectory(t *testing.T) {
	packageBytes := createTestProjectPackage(t, map[string]string{
		"main.json": `{
		  "id":"com.example.created",
		  "name":"Created",
		  "version":"1.0.0",
		  "sdkVersion":"4.1.0",
		  "appSdkVersion":"3.3.0",
		  "orientation":"portrait",
		  "controllerOrientation":"portrait",
		  "modes":["multiplayer"],
		  "displayModes":["single_screen_multiplayer"],
		  "players":{"min":3,"max":6},
		  "entries":{
		    "game":"index.html",
		    "controller":"controller/index.html"
		  },
		  "authority":{"entry":"static/js/service/index.js"}
		}`,
		rootIconName:                string(validRootIcon(t)),
		"capabilities.json":         `{"required":["sensor.accelerometer"]}`,
		"app/index.html":            "<!doctype html><title>Created</title>",
		"app/controller/index.html": "<!doctype html><title>Controller</title>",
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
				"supportedPlatforms": []capabilityPlatform{
					capabilityPlatformAndroid,
					capabilityPlatformHTML,
				},
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
				GameSDKVersion: requiredGameSDKVersion, AppSDKVersion: requiredAppSDKVersion, Encoding: "base64",
				Files: map[string]string{
					"playmesh-main.js":   encoded(`const PLAYMESH_SDK_VERSION = "4.1.0";`),
					"playmesh-app.js":    encoded(`const PLAYMESH_APP_SDK_VERSION = "3.3.0";`),
					"playmesh-main.d.ts": encoded("declare const playmesh: unknown;"),
					"playmesh-app.d.ts":  encoded("declare const playmeshApp: unknown;"),
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
		"1",
		"com.example.created",
		"Created",
		"2.0.0",
		"动作派对",
		"1",
		"2",
		"2",
		"3",
		"6",
		"services/authority.js",
		"体感, 聚会",
		"1",
		"controls/pad.html",
		"1",
		"1",
		"",
	}, "\n"))
	if err := commandInitFrom(context.Background(), nil, input); err != nil {
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
	for _, path := range []string{
		"playmesh-cli.json",
		"package.json",
		".gitignore",
		"jsconfig.json",
		"src/index.html",
		"playmesh/package/main.json",
		"playmesh/package/" + rootIconName,
		"playmesh/package/capabilities.json",
		"playmesh/package/app/index.html",
		"playmesh/package/app/controls/pad.html",
		"playmesh/sdk/playmesh-main.js",
		"playmesh/sdk/playmesh-main.d.ts",
		"playmesh/build.mjs",
	} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(path))); err != nil {
			t.Fatalf("created project was not downloaded (%s): %v", path, err)
		}
	}
	manifestData, err := os.ReadFile(
		filepath.Join(root, "playmesh", "package", "main.json"),
	)
	if err != nil {
		t.Fatal(err)
	}
	var manifest map[string]any
	if err := json.Unmarshal(manifestData, &manifest); err != nil {
		t.Fatal(err)
	}
	entries := manifest["entries"].(map[string]any)
	if entries["controller"] != "controls/pad.html" {
		t.Fatalf(
			"single-screen controller entry did not use CLI input: %#v",
			entries,
		)
	}
}

func TestCapabilityPlatformNamesOnlyReturnsRegisteredEnumValues(t *testing.T) {
	got := capabilityPlatformNames([]capabilityPlatform{
		capabilityPlatformWindows,
		capabilityPlatformAndroid,
		capabilityPlatform("UNKNOWN"),
		capabilityPlatformHTML,
	})
	want := []string{
		string(capabilityPlatformWindows),
		string(capabilityPlatformAndroid),
		string(capabilityPlatformHTML),
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("unexpected platform labels: got %v want %v", got, want)
	}
}

func TestNormalizeCreatedControllerEntryRemovesItFromMultiScreen(t *testing.T) {
	packageRoot := t.TempDir()
	writeTestFile(t, filepath.Join(packageRoot, "main.json"), `{
	  "id":"com.example.multi-screen",
	  "controllerOrientation":"portrait",
	  "displayModes":["multi_screen"],
	  "entries":{
	    "game":"index.html",
	    "controller":"controller/index.html"
	  }
	}`)
	manifestPath := filepath.Join(packageRoot, "main.json")
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	var manifest map[string]any
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	if err := applyConfigureRequest(
		project.Context{},
		manifestPath,
		manifest,
		configureRequest{
			Manifest: configureManifest{
				Name:           "Multi-screen",
				Version:        "1.0.0",
				Orientation:    "landscape",
				Mode:           "multiplayer",
				DisplayMode:    "multi_screen",
				AuthorityEntry: "static/js/service/index.js",
				MinPlayers:     2,
				MaxPlayers:     4,
			},
		},
	); err != nil {
		t.Fatal(err)
	}
	data, err = os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	manifest = nil
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	entries := manifest["entries"].(map[string]any)
	if _, exists := entries["controller"]; exists {
		t.Fatalf("multi-screen manifest retained controller: %#v", entries)
	}
	if _, exists := manifest["controllerOrientation"]; exists {
		t.Fatalf(
			"multi-screen manifest retained controller orientation: %#v",
			manifest,
		)
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

func TestNewProjectIDUsesSharedAndroidApplicationIDContract(t *testing.T) {
	data, err := os.ReadFile(filepath.Join(
		"..", "..", "..", "test", "fixtures", "new_project_game_id.json",
	))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		MaxLength int      `json:"maxLength"`
		Valid     []string `json:"valid"`
		Invalid   []string `json:"invalid"`
		Boundary  struct {
			Prefix           string `json:"prefix"`
			SegmentCharacter string `json:"segmentCharacter"`
		} `json:"boundary"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, value := range fixture.Valid {
		if err := validateNewProjectID(value); err != nil {
			t.Errorf("expected valid project ID %q: %v", value, err)
		}
	}
	for _, value := range fixture.Invalid {
		if err := validateNewProjectID(value); err == nil {
			t.Errorf("expected invalid project ID %q", value)
		}
	}
	maximum := fixture.Boundary.Prefix + strings.Repeat(
		fixture.Boundary.SegmentCharacter,
		fixture.MaxLength-len(fixture.Boundary.Prefix),
	)
	if err := validateNewProjectID(maximum); err != nil {
		t.Fatalf("maximum-length project ID was rejected: %v", err)
	}
	if err := validateNewProjectID(maximum + fixture.Boundary.SegmentCharacter); err == nil {
		t.Fatal("overlong project ID was accepted")
	}

	randomID, err := randomProjectID()
	if err != nil {
		t.Fatal(err)
	}
	if err := validateNewProjectID(randomID); err != nil {
		t.Fatalf("generated project ID %q is invalid: %v", randomID, err)
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
