package cli

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestGetInitializesJavaScriptArchitectureInEmptyDirectory(t *testing.T) {
	root := t.TempDir()
	projectID := "com.example.existing"
	packageBytes := createTestProjectPackage(t, map[string]string{
		"main.json": `{
		  "id":"com.example.existing",
		  "name":"Existing",
		  "version":"1.0.0",
		  "entries":{"game":"index.html"}
		}`,
		"app/index.html":          "<!doctype html>",
		"app/static/js/player.js": "console.log('player');",
		"capabilities.json":       `{"required":[]}`,
	})
	encoded := func(value string) string {
		return base64.StdEncoding.EncodeToString([]byte(value))
	}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/dev/api/projects/" + projectID + "/package":
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

	if err := commandGet(context.Background(), []string{projectID}); err != nil {
		t.Fatal(err)
	}
	for _, relative := range []string{
		"playmesh-cli.json",
		"package.json",
		"jsconfig.json",
		"src/index.html",
		"src/static/js/player.js",
		"playmesh/package/main.json",
		"playmesh/sdk/playmesh-main.d.ts",
	} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(relative))); err != nil {
			t.Fatalf("get did not initialize %s: %v", relative, err)
		}
	}
}

func TestGetRejectsNonEmptyInitializedProject(t *testing.T) {
	root := t.TempDir()
	config, err := (typescriptProjectAdapter{}).Configuration(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeProjectConfig(root, config); err != nil {
		t.Fatal(err)
	}
	writeTestFile(
		t,
		filepath.Join(root, "playmesh", "package", "main.json"),
		`{"id":"com.example.typescript"}`,
	)
	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(previous) })

	err = commandGet(context.Background(), []string{"com.example.typescript"})
	if err == nil || !strings.Contains(err.Error(), "已经执行过") {
		t.Fatalf("non-empty get destination must be rejected, got %v", err)
	}
}

func TestUpdateWithoutProjectConfigOnlyRefreshesNativeSDK(t *testing.T) {
	root := t.TempDir()
	encoded := func(value string) string {
		return base64.StdEncoding.EncodeToString([]byte(value))
	}
	server := httptest.NewServer(http.HandlerFunc(func(
		response http.ResponseWriter,
		request *http.Request,
	) {
		if request.URL.Path != "/dev/api/sdk" {
			http.NotFound(response, request)
			return
		}
		_ = json.NewEncoder(response).Encode(sdkBundle{
			GameSDKVersion: requiredGameSDKVersion,
			AppSDKVersion:  requiredAppSDKVersion,
			Encoding:       "base64",
			Files: map[string]string{
				"playmesh-main.js": encoded(
					`const PLAYMESH_SDK_VERSION = "4.1.0";`,
				),
				"playmesh-app.js": encoded(
					`const PLAYMESH_APP_SDK_VERSION = "3.3.0";`,
				),
				"playmesh-main.d.ts": encoded(
					"declare const playmesh: unknown;",
				),
				"playmesh-app.d.ts": encoded(
					"declare const playmeshApp: unknown;",
				),
			},
		})
	}))
	t.Cleanup(server.Close)
	t.Setenv("APPDATA", t.TempDir())
	if err := saveTarget(
		targetConfig{BaseURL: server.URL, Token: "test-token"},
	); err != nil {
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
		"playmesh/sdk/playmesh-app.d.ts",
	} {
		if _, err := os.Stat(
			filepath.Join(root, filepath.FromSlash(relative)),
		); err != nil {
			t.Fatalf("configless update did not write %s: %v", relative, err)
		}
	}
	if _, err := os.Stat(
		filepath.Join(root, projectConfigName),
	); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("configless update must not create project config: %v", err)
	}
}

func TestImportProjectPackageNormalizesVersionsAndUploadsPublishedFiles(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, projectConfigName), `{
	  "schemaVersion": 1,
	  "packageRoot": "playmesh/package",
	  "sdkRoot": "playmesh/sdk",
	  "integration": {
	    "type": "javascript",
	    "projectRoot": ".",
	    "sourceRoot": "src",
	    "outputDirectory": ".",
	    "entry": "index.html"
	  }
	}`)
	packageRoot := filepath.Join(root, "playmesh", "package")
	writeTestFile(t, filepath.Join(packageRoot, "main.json"), `{"id":"com.example.push","version":"1.0.0","sdkVersion":"9.9.9","entries":{"game":"index.html"}}`)
	writeTestFile(t, filepath.Join(packageRoot, "capabilities.json"), `{"required":[]}`)
	writeTestFile(t, filepath.Join(packageRoot, "app", "index.html"), "<!doctype html>")
	writeTestBytes(t, filepath.Join(packageRoot, rootIconName), validRootIcon(t))
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh-main.js"), `const PLAYMESH_SDK_VERSION = "4.1.0";`)
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh-app.js"), `const PLAYMESH_APP_SDK_VERSION = "3.3.0";`)

	var uploaded []byte
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "Bearer test-token" {
			http.Error(response, "unauthorized", http.StatusUnauthorized)
			return
		}
		switch request.URL.Path {
		case "/dev/api/status":
			_ = json.NewEncoder(response).Encode(map[string]any{
				"enabled": true, "gameSdkVersion": "4.1.0", "appSdkVersion": "3.3.0",
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

	project, err := currentProjectContext()
	if err != nil {
		t.Fatal(err)
	}
	projectID, client, err := prepareTargetProject(
		context.Background(),
		project,
	)
	if err != nil {
		t.Fatal(err)
	}
	packageBytes, err := buildPackage(project.PackageRoot)
	if err != nil {
		t.Fatal(err)
	}
	if err := importProjectPackage(
		context.Background(),
		client,
		projectID,
		packageBytes,
		true,
	); err != nil {
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
	data, err := os.ReadFile(filepath.Join(packageRoot, "main.json"))
	if err != nil || json.Unmarshal(data, &manifest) != nil {
		t.Fatalf("read normalized manifest: %v", err)
	}
	if manifest["sdkVersion"] != "4.1.0" || manifest["appSdkVersion"] != "3.3.0" {
		t.Fatalf("manifest SDK versions were not normalized: %#v", manifest)
	}
}

func TestRunUploadsConfiguredPackageAndStartsWithoutLogs(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, projectConfigName), `{
	  "schemaVersion": 1,
	  "packageRoot": "playmesh/package",
	  "sdkRoot": "playmesh/sdk",
	  "integration": {
	    "type": "cocos",
	    "projectRoot": ".",
	    "platform": "web-mobile",
	    "outputDirectory": ".",
	    "entry": "index.html",
	    "autoRunAfterBuild": true
	  }
	}`)
	if err := os.MkdirAll(filepath.Join(root, "assets"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "settings"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(
		t,
		filepath.Join(
			root,
			"settings",
			"v2",
			"packages",
			"project.json",
		),
		`{"general":{"designResolution":{"width":240,"height":426}}}`,
	)
	writeTestFile(t, filepath.Join(root, "package.json"), `{
	  "name":"Cocos",
	  "creator":{"version":"3.8.8"}
	}`)
	packageRoot := filepath.Join(root, "playmesh", "package")
	sdkRoot := filepath.Join(root, "playmesh", "sdk")
	writeTestFile(t, filepath.Join(packageRoot, "main.json"), `{
	  "id":"com.example.cocos",
	  "name":"Cocos",
	  "version":"1.0.0",
	  "orientation":"landscape",
	  "modes":["solo"],
	  "displayModes":["multi_screen"],
	  "players":{"min":1,"max":1}
	  ,"entries":{"game":"index.html"}
	}`)
	writeTestFile(t, filepath.Join(packageRoot, "capabilities.json"), `{"required":[]}`)
	writeTestFile(t, filepath.Join(packageRoot, "app", "index.html"), "<!doctype html>")
	writeTestFile(t, filepath.Join(sdkRoot, "playmesh-main.js"), `const PLAYMESH_SDK_VERSION = "4.1.0";`)
	writeTestFile(t, filepath.Join(sdkRoot, "playmesh-app.js"), `const PLAYMESH_APP_SDK_VERSION = "3.3.0";`)

	var formalImports atomic.Int32
	var previews atomic.Int32
	var logRequests atomic.Int32
	var uploaded []byte
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/dev/api/status":
			_ = json.NewEncoder(response).Encode(map[string]any{
				"enabled": true, "gameSdkVersion": "4.1.0", "appSdkVersion": "3.3.0",
			})
		case "/dev/api/packages/import":
			formalImports.Add(1)
			http.Error(response, "formal import forbidden", http.StatusConflict)
		case "/dev/api/projects/com.example.cocos/preview":
			previews.Add(1)
			uploaded, _ = io.ReadAll(request.Body)
			_ = json.NewEncoder(response).Encode(map[string]any{
				"gameId": "com.example.cocos",
				"run": runStatus{
					ProjectID: "com.example.cocos",
					RunID:     "run-cocos",
					Phase:     "running",
				},
			})
		case "/dev/api/logs", "/dev/api/events":
			logRequests.Add(1)
			http.Error(response, "unexpected logs", http.StatusInternalServerError)
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

	if err := commandRun(context.Background()); err != nil {
		t.Fatal(err)
	}
	if formalImports.Load() != 0 || previews.Load() != 1 {
		t.Fatalf(
			"run must use one temporary preview and no formal import: previews=%d imports=%d",
			previews.Load(),
			formalImports.Load(),
		)
	}
	if logRequests.Load() != 0 {
		t.Fatalf("run must not attach logs: %d requests", logRequests.Load())
	}
	assertPackageOrientation(t, uploaded, "portrait")
	localData, err := os.ReadFile(filepath.Join(packageRoot, "main.json"))
	if err != nil {
		t.Fatal(err)
	}
	var localManifest map[string]any
	if err := json.Unmarshal(localData, &localManifest); err != nil {
		t.Fatal(err)
	}
	if localManifest["orientation"] != "portrait" {
		t.Fatalf(
			"Cocos upload hook did not update local main.json: %#v",
			localManifest,
		)
	}
}

func assertPackageOrientation(
	t *testing.T,
	archive []byte,
	expected string,
) {
	t.Helper()
	reader, err := zip.NewReader(
		bytes.NewReader(archive),
		int64(len(archive)),
	)
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range reader.File {
		if file.Name != "main.json" {
			continue
		}
		input, err := file.Open()
		if err != nil {
			t.Fatal(err)
		}
		data, readErr := io.ReadAll(input)
		closeErr := input.Close()
		if readErr != nil {
			t.Fatal(readErr)
		}
		if closeErr != nil {
			t.Fatal(closeErr)
		}
		var manifest map[string]any
		if err := json.Unmarshal(data, &manifest); err != nil {
			t.Fatal(err)
		}
		if manifest["orientation"] != expected {
			t.Fatalf(
				"uploaded orientation = %#v, want %q",
				manifest["orientation"],
				expected,
			)
		}
		return
	}
	t.Fatal("uploaded package is missing main.json")
}

func TestRunStopsBeforeUploadWhenAdapterReleaseIsMissing(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, projectConfigName), `{
	  "schemaVersion": 1,
	  "packageRoot": "playmesh/package",
	  "sdkRoot": "playmesh/sdk",
	  "integration": {
	    "type": "cocos",
	    "projectRoot": ".",
	    "platform": "web-mobile",
	    "outputDirectory": ".",
	    "entry": "index.html",
	    "autoRunAfterBuild": true
	  }
	}`)
	for _, directory := range []string{"assets", "settings"} {
		if err := os.MkdirAll(filepath.Join(root, directory), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeTestFile(t, filepath.Join(root, "package.json"), `{
	  "name":"Missing Build",
	  "creator":{"version":"3.8.8"}
	}`)
	writeTestFile(
		t,
		filepath.Join(root, "playmesh", "package", "main.json"),
		`{"id":"com.example.missing","entries":{"game":"index.html"}}`,
	)
	writeTestFile(
		t,
		filepath.Join(root, "playmesh", "package", "capabilities.json"),
		`{"required":[]}`,
	)
	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(previous) })

	if err := commandRun(context.Background()); err == nil ||
		!strings.Contains(err.Error(), "正式构建结果缺少入口") {
		t.Fatalf("run must stop before target access, got %v", err)
	}
}

func TestDevUsesCredentialedProxyAndTemporaryBasePackage(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, projectConfigName), `{
	  "schemaVersion": 1,
	  "packageRoot": "playmesh/package",
	  "sdkRoot": "playmesh/sdk",
	  "integration": {
	    "type": "javascript",
	    "projectRoot": ".",
	    "sourceRoot": "src",
	    "outputDirectory": ".",
	    "entry": "index.html"
	  }
	}`)
	packageRoot := filepath.Join(root, "playmesh", "package")
	sdkRoot := filepath.Join(root, "playmesh", "sdk")
	writeTestFile(t, filepath.Join(packageRoot, "main.json"), `{
	  "id":"com.example.dev",
	  "name":"Development",
	  "version":"1.0.0",
	  "orientation":"landscape",
	  "modes":["multiplayer"],
	  "displayModes":["single_screen_multiplayer"],
	  "players":{"min":2,"max":4},
	  "entries":{
	    "game":"index.html",
	    "controller":"controller/index.html"
	  },
	  "authority":{"entry":"static/js/service/index.js"}
	}`)
	writeTestFile(
		t,
		filepath.Join(packageRoot, "capabilities.json"),
		`{"required":[]}`,
	)
	writeTestBytes(
		t,
		filepath.Join(packageRoot, rootIconName),
		validRootIcon(t),
	)
	writeTestFile(
		t,
		filepath.Join(packageRoot, "app", "index.html"),
		"<title>formal build</title>",
	)
	writeTestFile(
		t,
		filepath.Join(root, "src", "index.html"),
		"<title>live development</title>",
	)
	writeTestFile(
		t,
		filepath.Join(sdkRoot, "playmesh-main.js"),
		`const PLAYMESH_SDK_VERSION = "4.1.0";`,
	)
	writeTestFile(
		t,
		filepath.Join(sdkRoot, "playmesh-app.js"),
		`const PLAYMESH_APP_SDK_VERSION = "3.3.0";`,
	)

	var imported []byte
	var imports atomic.Int32
	var developmentStarts atomic.Int32
	var developmentStops atomic.Int32
	attachmentReady := make(chan struct{}, 2)
	server := httptest.NewServer(http.HandlerFunc(func(
		response http.ResponseWriter,
		request *http.Request,
	) {
		switch {
		case request.URL.Path == "/dev/api/status":
			_ = json.NewEncoder(response).Encode(map[string]any{
				"enabled":        true,
				"gameSdkVersion": "4.1.0",
				"appSdkVersion":  "3.3.0",
			})
		case request.URL.Path ==
			"/dev/api/projects/com.example.dev/development/package":
			imports.Add(1)
			imported, _ = io.ReadAll(request.Body)
			_ = json.NewEncoder(response).Encode(map[string]any{
				"packageId": "package-0123456789abcdef0123456789abcdef",
				"gameId":    "com.example.dev",
				"expiresAt": time.Now().Add(15 * time.Minute).UnixMilli(),
			})
		case request.Method == "POST" &&
			request.URL.Path ==
				"/dev/api/projects/com.example.dev/development":
			developmentStarts.Add(1)
			var payload developmentSessionRequest
			if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
				http.Error(response, err.Error(), http.StatusBadRequest)
				return
			}
			if payload.ExpiresAt <= time.Now().UnixMilli() ||
				payload.Credential == "" || payload.PackageID == "" {
				http.Error(response, "invalid development session", http.StatusBadRequest)
				return
			}
			resourceRequest, _ := http.NewRequest(
				"GET",
				payload.ResourceBaseURL+"/index.html",
				nil,
			)
			resourceRequest.Header.Set(
				developmentCredentialHeader,
				payload.Credential,
			)
			resourceResponse, err := http.DefaultClient.Do(resourceRequest)
			if err != nil {
				http.Error(response, err.Error(), http.StatusBadGateway)
				return
			}
			resourceBody, _ := io.ReadAll(resourceResponse.Body)
			resourceResponse.Body.Close()
			if resourceResponse.StatusCode != http.StatusOK ||
				!bytes.Contains(resourceBody, []byte("live development")) {
				http.Error(response, "development resource mismatch", http.StatusBadGateway)
				return
			}
			unauthorized, err := http.Get(
				payload.ResourceBaseURL + "/index.html",
			)
			if err != nil {
				http.Error(response, err.Error(), http.StatusBadGateway)
				return
			}
			unauthorized.Body.Close()
			if unauthorized.StatusCode != http.StatusUnauthorized {
				http.Error(response, "credential was not enforced", http.StatusBadGateway)
				return
			}
			reservedRequest, _ := http.NewRequest(
				"GET",
				payload.ResourceBaseURL+"/playmesh/sdk/v1/playmesh-main.js",
				nil,
			)
			reservedRequest.Header.Set(
				developmentCredentialHeader,
				payload.Credential,
			)
			reserved, err := http.DefaultClient.Do(reservedRequest)
			if err != nil {
				http.Error(response, err.Error(), http.StatusBadGateway)
				return
			}
			reserved.Body.Close()
			if reserved.StatusCode != http.StatusForbidden {
				http.Error(response, "reserved path was forwarded", http.StatusBadGateway)
				return
			}
			_ = json.NewEncoder(response).Encode(runStatus{
				ProjectID: "com.example.dev",
				RunID:     "run-dev",
				Phase:     "running",
			})
		case request.Method == "DELETE" &&
			request.URL.Path ==
				"/dev/api/projects/com.example.dev/development":
			developmentStops.Add(1)
			response.WriteHeader(http.StatusNoContent)
		case request.URL.Path == "/dev/api/logs":
			_ = json.NewEncoder(response).Encode(
				map[string]any{"logs": []any{}},
			)
			select {
			case attachmentReady <- struct{}{}:
			default:
			}
		case request.URL.Path == "/dev/api/run":
			_ = json.NewEncoder(response).Encode(map[string]any{"run": nil})
		default:
			http.NotFound(response, request)
		}
	}))
	t.Cleanup(server.Close)
	t.Setenv("APPDATA", t.TempDir())
	if err := saveTarget(
		targetConfig{BaseURL: server.URL, Token: "test-token"},
	); err != nil {
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

	runDevelopment := func() {
		t.Helper()
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() {
			done <- commandDev(ctx, nil)
		}()
		select {
		case <-attachmentReady:
		case <-time.After(10 * time.Second):
			t.Fatal("development logs were not attached")
		}
		time.Sleep(100 * time.Millisecond)
		cancel()
		select {
		case err := <-done:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("development command did not stop after cancellation")
		}
	}
	runDevelopment()
	writeTestFile(t, filepath.Join(packageRoot, "main.json"), `{
	  "id":"com.example.dev",
	  "name":"Updated Development",
	  "version":"2.0.0",
	  "orientation":"portrait",
	  "modes":["multiplayer"],
	  "displayModes":["single_screen_multiplayer"],
	  "players":{"min":2,"max":6},
	  "entries":{
	    "game":"index.html",
	    "controller":"controller/index.html"
	  },
	  "authority":{"entry":"static/js/service/index.js"}
	}`)
	writeTestFile(
		t,
		filepath.Join(packageRoot, "capabilities.json"),
		`{
		  "required":["sensor.accelerometer"],
		  "controllerRequired":["device.vibration"]
		}`,
	)
	runDevelopment()
	if developmentStarts.Load() != 2 || developmentStops.Load() != 2 {
		t.Fatalf(
			"development lifecycle mismatch: starts=%d stops=%d",
			developmentStarts.Load(),
			developmentStops.Load(),
		)
	}
	if imports.Load() != 2 {
		t.Fatalf(
			"every dev session must stage current base metadata: stages=%d",
			imports.Load(),
		)
	}
	reader, err := zip.NewReader(bytes.NewReader(imported), int64(len(imported)))
	if err != nil {
		t.Fatal(err)
	}
	files := map[string]string{}
	for _, entry := range reader.File {
		stream, openErr := entry.Open()
		if openErr != nil {
			t.Fatal(openErr)
		}
		data, readErr := io.ReadAll(stream)
		stream.Close()
		if readErr != nil {
			t.Fatal(readErr)
		}
		files[entry.Name] = string(data)
	}
	for _, expected := range []string{
		"main.json",
		"capabilities.json",
		rootIconName,
		"app/index.html",
		"app/controller/index.html",
		"app/static/js/service/index.js",
	} {
		if _, exists := files[expected]; !exists {
			t.Fatalf("development base package lacks %s: %#v", expected, files)
		}
	}
	var importedManifest map[string]any
	if err := json.Unmarshal(
		[]byte(files["main.json"]),
		&importedManifest,
	); err != nil {
		t.Fatal(err)
	}
	if importedManifest["name"] != "Updated Development" ||
		importedManifest["version"] != "2.0.0" ||
		importedManifest["orientation"] != "portrait" {
		t.Fatalf(
			"second dev did not upload current main.json: %#v",
			importedManifest,
		)
	}
	var importedCapabilities map[string]any
	if err := json.Unmarshal(
		[]byte(files["capabilities.json"]),
		&importedCapabilities,
	); err != nil {
		t.Fatal(err)
	}
	required, _ := importedCapabilities["required"].([]any)
	controllerRequired, _ :=
		importedCapabilities["controllerRequired"].([]any)
	if len(required) != 1 ||
		required[0] != "sensor.accelerometer" ||
		len(controllerRequired) != 1 ||
		controllerRequired[0] != "device.vibration" {
		t.Fatalf(
			"second dev did not upload current capabilities: %#v",
			importedCapabilities,
		)
	}
	if strings.Contains(files["app/index.html"], "live development") ||
		strings.Contains(files["app/index.html"], "formal build") {
		t.Fatalf(
			"development base package must use a placeholder: %q",
			files["app/index.html"],
		)
	}
}

func TestLogsRejectsDifferentRunningProject(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, projectConfigName), `{
	  "schemaVersion": 1,
	  "packageRoot": "playmesh/package",
	  "sdkRoot": "playmesh/sdk"
	}`)
	writeTestFile(t, filepath.Join(root, "playmesh", "package", "main.json"), `{"id":"com.example.local"}`)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/dev/api/run" {
			_ = json.NewEncoder(response).Encode(map[string]any{
				"run": runStatus{
					ProjectID: "com.example.other",
					RunID:     "run-other",
					Phase:     "running",
				},
			})
			return
		}
		http.NotFound(response, request)
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

	err = commandLogs(context.Background())
	if err == nil || !strings.Contains(err.Error(), "不是当前项目") {
		t.Fatalf("expected project mismatch, got %v", err)
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
	if err := attachEvents(
		ctx,
		client,
		"com.example.dev",
		"run-1",
		logAttachmentKeepsRun,
	); err != nil {
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
	if err := attachEvents(
		ctx,
		client,
		"com.example.dev",
		"run-1",
		logAttachmentKeepsRun,
	); err != nil {
		t.Fatal(err)
	}
	if logRequests.Load() != 1 {
		t.Fatalf("expected stopped run logs to be replayed, got %d requests", logRequests.Load())
	}
}

func TestAttachEventsDevelopmentStopsWhenAppRunEnds(t *testing.T) {
	var runRequests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(
		response http.ResponseWriter,
		request *http.Request,
	) {
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
			switch count {
			case 1:
				_ = json.NewEncoder(response).Encode(map[string]any{
					"run": map[string]any{
						"projectId": "com.example.dev",
						"runId":     "run-1",
						"phase":     "running",
					},
				})
			case 2:
				_ = json.NewEncoder(response).Encode(map[string]any{"run": nil})
			default:
				t.Errorf(
					"development attachment kept polling after App exit: request %d",
					count,
				)
				_ = json.NewEncoder(response).Encode(map[string]any{"run": nil})
			}
		case "/dev/api/logs":
			_ = json.NewEncoder(response).Encode(map[string]any{
				"logs": []map[string]any{},
			})
		default:
			http.NotFound(response, request)
		}
	}))
	t.Cleanup(server.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	client := newAPIClient(targetConfig{
		BaseURL: server.URL,
		Token:   "test-token",
	})
	if err := attachEvents(
		ctx,
		client,
		"com.example.dev",
		"run-1",
		logAttachmentStopsDevelopment,
	); err != nil {
		t.Fatal(err)
	}
	if runRequests.Load() != 2 {
		t.Fatalf(
			"expected development attachment to stop on the first empty run state, got %d status requests",
			runRequests.Load(),
		)
	}
}

func TestLogAttachmentInterruptMessagesMatchCommandSemantics(t *testing.T) {
	if message := logAttachmentInterruptMessage(
		logAttachmentKeepsRun,
	); !strings.Contains(message, "游戏继续运行") {
		t.Fatalf("logs detach message is misleading: %q", message)
	}
	if message := logAttachmentInterruptMessage(
		logAttachmentStopsDevelopment,
	); !strings.Contains(message, "停止开发会话") ||
		strings.Contains(message, "游戏继续运行") {
		t.Fatalf("dev detach message is misleading: %q", message)
	}
}

func TestVerifyDevelopmentEntryRequiresCredentialedHTML(t *testing.T) {
	const credential = "development-entry-test-credential"
	server := httptest.NewServer(http.HandlerFunc(func(
		response http.ResponseWriter,
		request *http.Request,
	) {
		if request.URL.Path != "/index.html" {
			http.NotFound(response, request)
			return
		}
		if request.Header.Get(developmentCredentialHeader) != credential {
			http.Error(response, "missing credential", http.StatusUnauthorized)
			return
		}
		response.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = io.WriteString(
			response,
			"<!doctype html><html><body>preview</body></html>",
		)
	}))
	t.Cleanup(server.Close)

	err := verifyDevelopmentEntry(
		context.Background(),
		developmentSessionRequest{
			ResourceBaseURL: server.URL,
			Credential:      credential,
			ExpiresAt:       time.Now().Add(time.Hour).UnixMilli(),
		},
		"index.html",
		"javascript",
	)
	if err != nil {
		t.Fatal(err)
	}
}

func TestVerifyDevelopmentEntryReportsUpstreamStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(
		response http.ResponseWriter,
		request *http.Request,
	) {
		http.Error(response, "preview entry missing", http.StatusNotFound)
	}))
	t.Cleanup(server.Close)

	err := verifyDevelopmentEntry(
		context.Background(),
		developmentSessionRequest{
			ResourceBaseURL: server.URL,
			Credential:      "development-entry-test-credential",
			ExpiresAt:       time.Now().Add(time.Hour).UnixMilli(),
		},
		"index.html",
		"javascript",
	)
	if err == nil ||
		!strings.Contains(err.Error(), "HTTP 404") ||
		!strings.Contains(err.Error(), "preview entry missing") ||
		!strings.Contains(err.Error(), server.URL) ||
		!strings.Contains(err.Error(), "text/plain") {
		t.Fatalf("entry preflight did not expose upstream failure: %v", err)
	}
}

func TestVerifyDevelopmentEntryRequiresCocosGameCanvas(t *testing.T) {
	const credential = "development-entry-secret-token"
	const redirectedToken = "redirect-query-secret-token"
	const htmlToken = "html-body-secret-token"
	server := httptest.NewServer(http.HandlerFunc(func(
		response http.ResponseWriter,
		request *http.Request,
	) {
		if request.Header.Get(developmentCredentialHeader) != credential {
			http.Error(response, "missing credential", http.StatusUnauthorized)
			return
		}
		switch request.URL.Path {
		case "/index.html":
			http.Redirect(
				response,
				request,
				"/resolved.html?token="+redirectedToken,
				http.StatusTemporaryRedirect,
			)
		case "/resolved.html":
			response.Header().Set(
				"Content-Type",
				"text/html; charset=utf-8",
			)
			_, _ = io.WriteString(
				response,
				"<!doctype html><html><head><title>Cocos preview error</title></head>"+
					"<body><script>console.log('#GameCanvas')</script>"+
					"<p>credential="+credential+"</p>"+
					"<p>token="+htmlToken+"</p></body></html>",
			)
		default:
			http.NotFound(response, request)
		}
	}))
	t.Cleanup(server.Close)

	err := verifyDevelopmentEntry(
		context.Background(),
		developmentSessionRequest{
			ResourceBaseURL: server.URL,
			Credential:      credential,
			ExpiresAt:       time.Now().Add(time.Hour).UnixMilli(),
		},
		"index.html",
		"cocos",
	)
	if err == nil {
		t.Fatal("Cocos HTML without #GameCanvas must fail preflight")
	}
	message := err.Error()
	for _, expected := range []string{
		"#GameCanvas",
		server.URL + "/resolved.html",
		"text/html; charset=utf-8",
		"Cocos preview error",
		"[REDACTED]",
	} {
		if !strings.Contains(message, expected) {
			t.Fatalf(
				"Cocos entry diagnostic lacks %q: %v",
				expected,
				err,
			)
		}
	}
	for _, secret := range []string{
		credential,
		redirectedToken,
		htmlToken,
	} {
		if strings.Contains(message, secret) {
			t.Fatalf(
				"Cocos entry diagnostic leaked token %q: %v",
				secret,
				err,
			)
		}
	}
}

func TestVerifyDevelopmentEntryAcceptsCocosGameCanvasAfterLargeHead(
	t *testing.T,
) {
	server := httptest.NewServer(http.HandlerFunc(func(
		response http.ResponseWriter,
		request *http.Request,
	) {
		response.Header().Set(
			"Content-Type",
			"text/html; charset=utf-8",
		)
		_, _ = io.WriteString(
			response,
			"<!doctype html><html><head>"+
				strings.Repeat(" ", 16<<10)+
				"</head><body><canvas class=\"game\" id = 'GameCanvas'>"+
				"</canvas></body></html>",
		)
	}))
	t.Cleanup(server.Close)

	err := verifyDevelopmentEntry(
		context.Background(),
		developmentSessionRequest{
			ResourceBaseURL: server.URL,
			Credential:      "development-entry-test-credential",
			ExpiresAt:       time.Now().Add(time.Hour).UnixMilli(),
		},
		"index.html",
		"cocos",
	)
	if err != nil {
		t.Fatal(err)
	}
}
