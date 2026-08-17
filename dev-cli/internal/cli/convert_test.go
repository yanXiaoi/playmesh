package cli

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/project"
)

func TestConvertLocalPackageCreatesStandardJavaScriptProject(t *testing.T) {
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
		if request.Header.Get("Authorization") != "Bearer test-token" {
			http.Error(response, "unauthorized", http.StatusUnauthorized)
			return
		}
		_ = json.NewEncoder(response).Encode(sdkBundle{
			GameSDKVersion: requiredGameSDKVersion,
			AppSDKVersion:  requiredAppSDKVersion,
			Encoding:       "base64",
			Files: map[string]string{
				"playmesh-main.js": encoded(
					`const PLAYMESH_SDK_VERSION = "` + requiredGameSDKVersion + `";`,
				),
				"playmesh-app.js": encoded(
					`const PLAYMESH_APP_SDK_VERSION = "` + requiredAppSDKVersion + `";`,
				),
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

	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "main.json"), `{
	  "id":"com.example.converted",
	  "name":"Converted",
	  "version":"1.2.3",
	  "sdkVersion":"1.0.0",
	  "appSdkVersion":"1.0.0",
	  "orientation":"landscape",
	  "modes":["single_player"],
	  "displayModes":["multi_screen"],
	  "players":{"min":1,"max":1},
	  "entries":{"game":"pages/start.html"}
	}`)
	writeTestFile(
		t,
		filepath.Join(root, "app", "pages", "start.html"),
		"<!doctype html><title>converted</title>",
	)
	writeTestFile(t, filepath.Join(root, "app", "main.js"), "console.log('converted');")
	writeTestFile(
		t,
		filepath.Join(root, "capabilities.json"),
		`{"required":["sensor.accelerometer"]}`,
	)
	writeTestBytes(t, filepath.Join(root, rootIconName), validRootIcon(t))
	writeTestFile(t, filepath.Join(root, "README.txt"), "keep me")

	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(previous) })

	if err := commandConvert(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{
		"playmesh-cli.json",
		"package.json",
		".gitignore",
		"jsconfig.json",
		"src/pages/start.html",
		"src/main.js",
		"src/playmesh-env.d.ts",
		"playmesh/build.mjs",
		"playmesh/package/main.json",
		"playmesh/package/capabilities.json",
		"playmesh/package/icon.png",
		"playmesh/package/app/pages/start.html",
		"playmesh/sdk/playmesh-main.js",
	} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(path))); err != nil {
			t.Fatalf("converted project lacks %s: %v", path, err)
		}
	}
	for _, path := range []string{"main.json", "app", "capabilities.json", "icon.png"} {
		if _, err := os.Stat(filepath.Join(root, path)); !errorsIsNotExist(err) {
			t.Fatalf("source package entry %s was retained: %v", path, err)
		}
	}
	readme, err := os.ReadFile(filepath.Join(root, "README.txt"))
	if err != nil || string(readme) != "keep me" {
		t.Fatalf("unrelated file was not preserved: %q, %v", readme, err)
	}
	converted, err := project.Resolve(root)
	if err != nil {
		t.Fatal(err)
	}
	if converted.Config.Integration.Type != "javascript" ||
		converted.Config.Integration.Entry != "pages/start.html" {
		t.Fatalf("unexpected converted config: %#v", converted.Config.Integration)
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
	if manifest["sdkVersion"] != requiredGameSDKVersion ||
		manifest["appSdkVersion"] != requiredAppSDKVersion {
		t.Fatalf("converted manifest did not use current SDK versions: %#v", manifest)
	}
}

func TestConvertRejectsGeneratedFileConflictWithoutChangingSource(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "main.json"), `{}`)
	writeTestFile(t, filepath.Join(root, "app", "index.html"), "source")
	writeTestFile(t, filepath.Join(root, "package.json"), `{"private":false}`)

	err := validateLocalPackageConversion(root)
	if err == nil || !strings.Contains(err.Error(), "package.json") ||
		!strings.Contains(err.Error(), "拒绝覆盖") {
		t.Fatalf("expected package.json conflict, got %v", err)
	}
	data, readErr := os.ReadFile(filepath.Join(root, "app", "index.html"))
	if readErr != nil || string(data) != "source" {
		t.Fatalf("source package changed after rejection: %q, %v", data, readErr)
	}
}

func TestConvertRejectsArguments(t *testing.T) {
	err := commandConvert(context.Background(), []string{"project"})
	if err == nil || !strings.Contains(err.Error(), "playmesh-cli convert") {
		t.Fatalf("expected convert usage error, got %v", err)
	}
}

func errorsIsNotExist(err error) bool {
	return err != nil && os.IsNotExist(err)
}
