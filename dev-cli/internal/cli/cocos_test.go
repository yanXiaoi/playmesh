package cli

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInitCocosCreatesIsolatedProjectAndExtension(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "assets"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "settings"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(root, "package.json"), `{
	  "name": "Cocos Arena",
	  "creator": { "version": "3.8.8" }
	}`)

	packageBytes := cocosTestPackage(t)
	encoded := func(value string) string {
		return base64.StdEncoding.EncodeToString([]byte(value))
	}
	var created createProjectRequest
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/dev/api/capabilities":
			_ = json.NewEncoder(response).Encode(map[string]any{"capabilities": []any{}})
		case "/dev/api/projects":
			if err := json.NewDecoder(request.Body).Decode(&created); err != nil {
				t.Fatal(err)
			}
			response.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(response).Encode(map[string]any{
				"project": map[string]any{"id": created.ID, "name": created.Name},
			})
		case "/dev/api/projects/" + created.ID + "/package":
			_, _ = response.Write(packageBytes)
		case "/dev/api/sdk":
			_ = json.NewEncoder(response).Encode(sdkBundle{
				GameSDKVersion: requiredGameSDKVersion,
				AppSDKVersion:  requiredAppSDKVersion,
				Encoding:       "base64",
				Files: map[string]string{
					"playmesh-main.js":   encoded(`const PLAYMESH_SDK_VERSION = "4.1.0";`),
					"playmesh-app.js":    encoded(`const PLAYMESH_APP_SDK_VERSION = "3.3.0";`),
					"playmesh-main.d.ts": encoded("declare const playmesh: unknown;"),
					"playmesh-app.d.ts":  encoded("declare const playmeshApp: unknown;"),
				},
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

	input := strings.NewReader(
		"com.example.cocos_arena\n" + strings.Repeat("\n", 8),
	)
	if err := commandInitFrom(context.Background(), []string{"cocos"}, input); err != nil {
		t.Fatal(err)
	}
	if created.Name != "Cocos Arena" || created.Mode != "solo" ||
		created.Orientation != "landscape" {
		t.Fatalf("adapter defaults were not applied: %#v", created)
	}
	for _, relative := range []string{
		"playmesh-cli.json",
		"playmesh/playmesh-cli.schema.json",
		"playmesh/package/main.json",
		"playmesh/package/capabilities.json",
		"playmesh/sdk/playmesh-main.js",
		"playmesh/sdk/playmesh-main.d.ts",
		"assets/playmesh-sdk.d.ts",
		"extensions/playmesh/package.json",
		"extensions/playmesh/dist/main.js",
		"extensions/playmesh/dist/builder.js",
		"extensions/playmesh/dist/hooks.js",
		"extensions/playmesh/dist/panels/settings/index.js",
		"extensions/playmesh/static/playmesh.svg",
		"extensions/playmesh/README.md",
		"extensions/playmesh/README-CN.md",
		"extensions/playmesh/README-EN.md",
		"extensions/playmesh/README.zh.md",
		"extensions/playmesh/README.en.md",
		"preview-template/index.ejs",
		"preview-template/playmesh-preview-gate.js",
	} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(relative))); err != nil {
			t.Fatalf("init did not create %s: %v", relative, err)
		}
	}
	var manifest map[string]any
	data, err := os.ReadFile(filepath.Join(root, "playmesh", "package", "main.json"))
	if err != nil || json.Unmarshal(data, &manifest) != nil {
		t.Fatalf("read initialized manifest: %v", err)
	}
	entries, _ := manifest["entries"].(map[string]any)
	if entries["game"] != "index.html" {
		t.Fatalf("Cocos game entry not configured: %#v", entries)
	}
	if _, exists := entries["controller"]; exists {
		t.Fatalf("solo Cocos init must remove controller entry: %#v", entries)
	}
	if _, exists := manifest["controllerOrientation"]; exists {
		t.Fatalf(
			"solo Cocos init must remove controller orientation: %#v",
			manifest,
		)
	}
	reference, err := os.ReadFile(filepath.Join(root, "assets", "playmesh-sdk.d.ts"))
	if err != nil ||
		!bytes.Contains(reference, []byte("../playmesh/sdk/playmesh-main.d.ts")) {
		t.Fatalf("Cocos type reference is invalid: %q, %v", reference, err)
	}
	if err := ensureProjectNotInitialized(root); err == nil {
		t.Fatal("second initialization must be rejected")
	}
	extensionData, err := os.ReadFile(filepath.Join(root, "extensions", "playmesh", "package.json"))
	if err != nil {
		t.Fatal(err)
	}
	var extensionPackage map[string]any
	if err := json.Unmarshal(extensionData, &extensionPackage); err != nil {
		t.Fatal(err)
	}
	if extensionPackage["author"] != "Playmesh" ||
		extensionPackage["editor"] != ">=3.0.0 <4.0.0" {
		t.Fatalf("extension metadata is incomplete: %#v", extensionPackage)
	}
	if strings.Contains(playmeshCLIProjectSchema, "://") {
		t.Fatal("generated project schema must not reference external URLs")
	}
	for _, fixed := range []string{
		`"packageRoot": { "const": "playmesh/package" }`,
		`"sdkRoot": { "const": "playmesh/sdk" }`,
	} {
		if !strings.Contains(playmeshCLIProjectSchema, fixed) {
			t.Fatalf("generated schema does not fix root contract: %s", fixed)
		}
	}
}

func TestCocosAdapterReadsProjectNameAndUsesVisibleDefaults(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "package.json"), `{"name":"Puzzle Lab"}`)
	defaults, err := (cocosProjectAdapter{}).Defaults(root)
	if err != nil {
		t.Fatal(err)
	}
	if defaults.Name != "Puzzle Lab" || defaults.Mode != "solo" ||
		defaults.Orientation != "landscape" || defaults.Tags != "cocos" {
		t.Fatalf("unexpected Cocos defaults: %#v", defaults)
	}
}

func TestCocosAdapterRequiresCreator3x(t *testing.T) {
	for name, version := range map[string]string{
		"creator 2": "2.4.15",
		"creator 4": "4.0.0",
	} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			for _, directory := range []string{"assets", "settings"} {
				if err := os.MkdirAll(
					filepath.Join(root, directory),
					0o755,
				); err != nil {
					t.Fatal(err)
				}
			}
			writeTestFile(
				t,
				filepath.Join(root, "package.json"),
				fmt.Sprintf(
					`{"name":"Invalid","creator":{"version":%q}}`,
					version,
				),
			)
			if err := (cocosProjectAdapter{}).Detect(root); err == nil ||
				!strings.Contains(err.Error(), "只支持 Cocos Creator 3.x") {
				t.Fatalf("Creator %s must be rejected, got %v", version, err)
			}
		})
	}
}

func TestCocosDevelopmentUsesTransientPreviewEnvironment(t *testing.T) {
	root := t.TempDir()
	for _, directory := range []string{"assets", "settings"} {
		if err := os.MkdirAll(filepath.Join(root, directory), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeTestFile(t, filepath.Join(root, "package.json"), `{
	  "name":"Preview",
	  "creator":{"version":"3.8.8"}
	}`)
	config, err := (cocosProjectAdapter{}).Configuration(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeProjectConfig(root, config); err != nil {
		t.Fatal(err)
	}
	project, err := resolveProjectContext(root)
	if err != nil {
		t.Fatal(err)
	}
	source, err := (cocosProjectAdapter{}).PrepareDevelopment(
		context.Background(),
		project,
		[]string{
			"http://127.0.0.1:7456/web-mobile/task-42/index.html?scene=main#debug",
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	previewTemplate, err := os.ReadFile(
		filepath.Join(root, "preview-template", "index.ejs"),
	)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(previewTemplate, []byte(`id="GameCanvas"`)) {
		t.Fatal("Cocos dev preparation did not refresh the complete preview template")
	}
	mapping, err := source.Start(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer source.Stop(context.Background())
	if mapping.SourceURI().String() != "http://127.0.0.1:7456" {
		t.Fatalf(
			"unexpected Cocos preview URL: %s",
			mapping.SourceURI(),
		)
	}
	entryMapping, ok := mapping.(interface {
		DevelopmentGameEntry() string
	})
	if !ok {
		t.Fatal("Cocos mapping did not provide a temporary development entry")
	}
	const previewEntry = "web-mobile/task-42/index.html?scene=main"
	if entryMapping.DevelopmentGameEntry() != previewEntry {
		t.Fatalf(
			"unexpected temporary Cocos entry: %s",
			entryMapping.DevelopmentGameEntry(),
		)
	}
	entry, err := mapping.MapRequest(
		&url.URL{
			Path:     "/web-mobile/task-42/index.html",
			RawQuery: "scene=main",
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if entry.String() !=
		"http://127.0.0.1:7456/web-mobile/task-42/index.html?scene=main" {
		t.Fatalf("Cocos preview entry lost its page URL: %s", entry)
	}
	asset, err := mapping.MapRequest(
		&url.URL{Path: "/assets/main.js", RawQuery: "v=7"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if asset.String() !=
		"http://127.0.0.1:7456/assets/main.js?v=7" {
		t.Fatalf("Cocos root asset was not mapped to the preview origin: %s", asset)
	}
	stylesheet, err := mapping.MapRequest(
		&url.URL{Path: "/web-mobile/task-42/index.css"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if stylesheet.String() !=
		"http://127.0.0.1:7456/web-mobile/task-42/index.css" {
		t.Fatalf(
			"Cocos page-relative stylesheet was not transparently mapped: %s",
			stylesheet,
		)
	}
}

func TestCocosDevelopmentRequiresExplicitPreviewServer(t *testing.T) {
	root := t.TempDir()
	for _, directory := range []string{"assets", "settings"} {
		if err := os.MkdirAll(filepath.Join(root, directory), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeTestFile(t, filepath.Join(root, "package.json"), `{
	  "name":"Preview",
	  "creator":{"version":"3.8.8"}
	}`)
	config, err := (cocosProjectAdapter{}).Configuration(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeProjectConfig(root, config); err != nil {
		t.Fatal(err)
	}
	project, err := resolveProjectContext(root)
	if err != nil {
		t.Fatal(err)
	}
	_, err = (cocosProjectAdapter{}).PrepareDevelopment(
		context.Background(),
		project,
		nil,
	)
	if err == nil || !strings.Contains(err.Error(), "cocos-preview-url") {
		t.Fatalf("missing explicit Cocos preview URL must fail, got %v", err)
	}
	if _, err := (cocosProjectAdapter{}).PrepareDevelopment(
		context.Background(),
		project,
		[]string{"http://127.0.0.1:7457", "extra"},
	); err == nil || !strings.Contains(err.Error(), "cocos-preview-url") {
		t.Fatalf("extra Cocos dev arguments must fail, got %v", err)
	}
}

func TestUpdateRefreshesSDKAndCocosAdapterFiles(t *testing.T) {
	root := t.TempDir()
	for _, directory := range []string{"assets", "settings"} {
		if err := os.MkdirAll(filepath.Join(root, directory), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeTestFile(t, filepath.Join(root, "package.json"), `{
	  "name":"Update",
	  "creator":{"version":"3.8.8"}
	}`)
	config := cliProjectConfig{
		Schema:        "./playmesh/playmesh-cli.schema.json",
		SchemaVersion: 1,
		PackageRoot:   "playmesh/package",
		SDKRoot:       "playmesh/sdk",
		Integration: &cliIntegrationConfig{
			Type:              "cocos",
			ProjectRoot:       ".",
			Platform:          "web-mobile",
			OutputDirectory:   ".",
			Entry:             "index.html",
			AutoRunAfterBuild: true,
		},
	}
	if err := writeProjectConfig(root, config); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(root, "playmesh", "package", "main.json"), `{
	  "id":"com.example.update",
	  "name":"Update",
	  "version":"1.0.0",
	  "orientation":"landscape",
	  "modes":["solo"],
	  "displayModes":["multi_screen"],
	  "players":{"min":1,"max":1},
	  "entries":{"game":"index.html"}
	}`)
	encoded := func(value string) string {
		return base64.StdEncoding.EncodeToString([]byte(value))
	}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/dev/api/sdk" {
			http.NotFound(response, request)
			return
		}
		_ = json.NewEncoder(response).Encode(sdkBundle{
			GameSDKVersion: requiredGameSDKVersion,
			AppSDKVersion:  requiredAppSDKVersion,
			Encoding:       "base64",
			Files: map[string]string{
				"playmesh-main.js":   encoded(`const PLAYMESH_SDK_VERSION = "4.1.0";`),
				"playmesh-app.js":    encoded(`const PLAYMESH_APP_SDK_VERSION = "3.3.0";`),
				"playmesh-main.d.ts": encoded("declare const playmesh: unknown;"),
				"playmesh-app.d.ts":  encoded("declare const playmeshApp: unknown;"),
			},
		})
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

	if err := commandUpdate(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, relative := range []string{
		"playmesh/sdk/playmesh-main.js",
		"assets/playmesh-sdk.d.ts",
		"playmesh/playmesh-cli.schema.json",
		"extensions/playmesh/.playmesh-generated",
		"extensions/playmesh/dist/panels/settings/index.js",
		"extensions/playmesh/static/playmesh.svg",
		"preview-template/index.ejs",
		"preview-template/playmesh-preview-gate.js",
	} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(relative))); err != nil {
			t.Fatalf("update did not refresh %s: %v", relative, err)
		}
	}
}

func cocosTestPackage(t *testing.T) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for path, value := range map[string]string{
		"main.json": `{
		  "id":"com.example.cocos_arena",
		  "name":"Cocos Arena",
		  "version":"1.0.0",
		  "sdkVersion":"4.1.0",
		  "appSdkVersion":"3.3.0",
		  "orientation":"landscape",
		  "controllerOrientation":"portrait",
		  "modes":["solo"],
		  "displayModes":["multi_screen"],
		  "players":{"min":1,"max":1},
		  "entries":{
		    "game":"index.html",
		    "controller":"controller/index.html"
		  }
		}`,
		"capabilities.json": `{"required":[]}`,
		"app/index.html":    "<!doctype html>",
	} {
		entry, err := writer.Create(path)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(entry, value); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}
